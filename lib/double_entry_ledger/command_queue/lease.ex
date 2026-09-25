defmodule DoubleEntryLedger.CommandQueue.Lease do
  @moduledoc """
  Per-ledger ownership lease, coordinated only through PostgreSQL.

  Ownership is proven by `(owner_id, fencing_token)` on a row whose
  `released_at` is null; expiry is consulted only by `acquire/4`. Every claim,
  processing, batch and takeover transaction calls `lock!/3` first and
  `refresh_locked!/3` last, so they serialize on the lease row lock. Contention
  (`:busy`) is never loss; only a zero-row owner update is.
  """

  import Ecto.Query, only: [from: 2]
  require Logger

  alias DoubleEntryLedger.Command
  alias DoubleEntryLedger.CommandQueue.Config
  alias DoubleEntryLedger.CommandQueue.Scheduling
  alias DoubleEntryLedger.CommandQueueLeaseRow
  alias DoubleEntryLedger.Repo.Proxy, as: Repo
  alias DoubleEntryLedger.Telemetry
  alias Ecto.Multi

  @schema_prefix DoubleEntryLedger.Config.schema_prefix()

  defmodule Grant do
    @moduledoc "Proof of ownership handed to a processor by `Lease.acquire/4`."
    @enforce_keys [:instance_id, :owner_id, :fencing_token]
    defstruct [:instance_id, :owner_id, :fencing_token, coordination: :database_polling]

    @type t :: %__MODULE__{
            instance_id: Ecto.UUID.t(),
            owner_id: String.t(),
            fencing_token: pos_integer(),
            # Who nominated this owner: a coordination strategy atom, or
            # :manual for process_command_with_id/2. Reported on every
            # lease event (R19.3).
            coordination: atom()
          }
  end

  defmodule LostError do
    @moduledoc "An owner-side update matched zero rows: another owner has the ledger."
    defexception [:grant]

    @impl true
    def message(%{grant: g}) do
      "lease for instance #{g.instance_id} is no longer held by #{g.owner_id}/#{g.fencing_token}"
    end
  end

  defmodule BusyError do
    @moduledoc "The lease row lock was not granted within the lock timeout."
    defexception [:grant]

    @impl true
    def message(%{grant: g}), do: "lease row for instance #{g.instance_id} is locked; timed out"
  end

  @type release_reason :: :drained | :shutdown | :manual | :start_failed | :monitor_down

  @type acquire_info :: %{
          previous_owner_id: String.t() | nil,
          takeover: boolean(),
          orphans: [Scheduling.orphan()]
        }

  @doc """
  A new unique owner id: `prefix:node:uuid`.

  `prefix` defaults to the configured `:processor_name`. The manual path
  (`CommandWorker.process_command_with_id/2` with a binary owner) passes its
  own prefix; it goes through here rather than interpolating its own id so
  there is exactly one definition of the format, node segment included.
  """
  @spec owner_id(String.t()) :: String.t()
  def owner_id(prefix \\ default_owner_prefix()) do
    "#{prefix}:#{node()}:#{Ecto.UUID.generate()}"
  end

  defp default_owner_prefix do
    Application.get_env(:double_entry_ledger, :command_queue, [])[:processor_name] ||
      "command_queue"
  end

  @doc """
  Acquires the lease for `instance_id` under `owner_id`, taking over an
  expired lease and rescheduling any `:processing` rows on the ledger, in one
  transaction. Emits nothing; call `emit_acquisition_events/3` afterwards.

  `:held` when a live lease exists (any holder). `:busy` when the row lock was
  not granted within the lock timeout. Concretely that is any transient
  contention condition — the lock timeout fired, a deadlock was broken, or the
  snapshot could not be serialized — and `acquire/4` follows `renew/3` and
  `release/3` in treating all of them as "another transaction is on this work,
  try again later", rather than `lock!/3`'s narrower rule.
  Nothing was written in any of those cases and the caller's response is the
  same for all of them: back off and retry on the next poll. Raises
  `ArgumentError` inside a caller's transaction.

  `opts`:

    * `:ttl` - seconds the acquired lease lives (default `Config.lease_ttl/0`)
    * `:coordination` - what nominated this owner; recorded on the grant and
      reported on every later lease event (default
      `Config.coordination_strategy/0`, `:manual` on the manual path)
  """
  @spec acquire(Ecto.UUID.t(), String.t(), Ecto.Repo.t(), keyword()) ::
          {:ok, Grant.t(), acquire_info()} | :held | :busy
  def acquire(instance_id, owner_id, repo \\ Repo, opts \\ []) do
    require_no_transaction!(repo, "acquire/4")
    ttl = Keyword.get(opts, :ttl, Config.lease_ttl())
    coordination = Keyword.get(opts, :coordination, Config.coordination_strategy())

    result =
      lease_transaction(repo, fn -> insert_or_take_over(instance_id, owner_id, ttl, repo) end)

    case unwrap_rollback(result) do
      {:ok, {grant, info}} -> {:ok, %{grant | coordination: coordination}, info}
      :held -> :held
      :busy -> :busy
    end
  end

  # `lease_transaction/2` reports its outcomes in two shapes: `{:error, :held}`
  # when the transaction body called `repo.rollback/1` for a live lease, and a
  # bare `:busy` from its own rescue of a transient PostgreSQL error. Flatten
  # the rollback shape here so `acquire/4` reads one vocabulary.
  defp unwrap_rollback({:error, reason}), do: reason
  defp unwrap_rollback(result), do: result

  # The body of the lease transaction. A ledger that has never had a lease gets
  # its row inserted here and is claimed outright; otherwise the existing row is
  # contended for. Both paths end in `finish_acquire/4`, so the orphan rescue
  # and the closing refresh happen exactly once either way.
  defp insert_or_take_over(instance_id, owner_id, ttl, repo) do
    case insert_fresh(instance_id, owner_id, ttl, repo) do
      {:ok, token} ->
        grant = %Grant{instance_id: instance_id, owner_id: owner_id, fencing_token: token}
        finish_acquire(grant, %{previous_owner_id: nil, takeover: false}, ttl, repo)

      :exists ->
        take_over(instance_id, owner_id, ttl, repo)
    end
  end

  @doc """
  Emits the events for a committed acquisition: acquired, then one recovered
  event per orphan.

  Raises `ArgumentError` inside a caller's transaction. `acquire/4` refuses to
  run in one, so its result was committed by the time it returned; emitting
  from inside a later transaction of the caller's would report an acquisition
  that a rollback can still undo, and would put `in_transaction: true` on every
  event. Callers therefore emit where they acquired.

  Never raises for any other reason. This runs AFTER the acquisition
  transaction committed, so the database already records this node as the
  owner; a raise here would abort the caller, which would then believe it holds
  nothing while no other node can take over until the lease expires — a ledger
  stranded for a full TTL by a reporting failure. Events are reporting, not
  ownership, so every failure is logged and swallowed.
  """
  @spec emit_acquisition_events(Grant.t(), acquire_info(), Ecto.Repo.t()) :: :ok
  def emit_acquisition_events(%Grant{} = grant, info, repo \\ Repo) do
    require_no_transaction!(repo, "emit_acquisition_events/3")
    report_acquisition(grant, info)
  end

  defp report_acquisition(grant, info) do
    Logger.info(
      "acquired lease for instance #{grant.instance_id} as #{grant.owner_id}/#{grant.fencing_token}" <>
        " (takeover: #{info.takeover}, orphans: #{length(info.orphans)})"
    )

    Telemetry.lease_acquired(
      grant_metadata(grant, %{
        takeover: info.takeover,
        previous_owner_id: info.previous_owner_id,
        orphans: length(info.orphans)
      })
    )

    Enum.each(info.orphans, &report_orphan/1)
  rescue
    error ->
      Logger.error(
        "lease acquisition events for instance #{grant.instance_id} failed; the lease is " <>
          "held and processing continues: " <> Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  defp report_orphan({%Command{command_queue_item: item} = command, previous_processor_id}) do
    Logger.warning("rescheduled orphan #{command.id} on lease acquisition")

    Telemetry.command_recovered(%{
      command_id: command.id,
      instance_id: command.instance_id,
      previous_processor_id: previous_processor_id,
      reason: :takeover,
      trace_context: command.trace_context
    })

    # Deliberately NOT `Scheduling.persisted_failure/1`: that returns
    # `{:error, command}` and reads the status off the command, while the
    # status that must be reported here is the one the reschedule wrote.
    Scheduling.emit_persisted_failure(command, item.status, hd(item.errors))
  end

  # `{:ok, token}` when this claim created the row, `:exists` when the ledger
  # already has a lease row, live or not.
  #
  # A query-sourced INSERT, because a literal entry list cannot hold a
  # `fragment` and both timestamps must come from the database clock. The
  # source is the constant `(SELECT 1)` and deliberately NOT the instances
  # table: selecting from `instances` would turn a missing instance into zero
  # inserted rows, which reads here as `:exists` and then makes `take_over/4`'s
  # `one!` raise `Ecto.NoResultsError`. Off a constant source the foreign key
  # does that job, and a missing instance raises a foreign key violation.
  #
  # `on_conflict: :nothing` omits the conflict target, which is equivalent here:
  # the primary key on `instance_id` is the table's only unique index, and a
  # foreign key violation is not a conflict and still raises.
  defp insert_fresh(instance_id, owner_id, ttl, repo) do
    source =
      from(l in fragment("(SELECT 1)"),
        select: %{
          instance_id: type(^instance_id, Ecto.UUID),
          owner_id: type(^owner_id, :string),
          fencing_token: type(^1, :integer),
          expires_at:
            fragment(
              "timezone(?, clock_timestamp()) + (? * interval ?)",
              "UTC",
              ^ttl,
              "1 second"
            ),
          acquired_at: fragment("timezone(?, clock_timestamp())", "UTC")
        }
      )

    case repo.insert_all(CommandQueueLeaseRow, source,
           prefix: @schema_prefix,
           on_conflict: :nothing,
           returning: [:fencing_token]
         ) do
      {1, [%{fencing_token: token}]} -> {:ok, token}
      {0, []} -> :exists
    end
  end

  # SELECT ... FOR UPDATE waits (bounded by lock_timeout) for any transaction
  # holding the row and returns it as that transaction committed it, so the
  # previous owner, release state and expiry are authoritative.
  defp take_over(instance_id, owner_id, ttl, repo) do
    {prev_owner, released_at, expired?} =
      repo.one!(
        from(l in CommandQueueLeaseRow,
          prefix: ^@schema_prefix,
          where: l.instance_id == ^instance_id,
          lock: "FOR UPDATE",
          select:
            {l.owner_id, l.released_at,
             fragment("? <= timezone('UTC', clock_timestamp())", l.expires_at)}
        )
      )

    if expired? do
      # Exactly one row, carrying the fencing token it now holds. The match is
      # an assertion, not a convenience: anything else means the guarded UPDATE
      # found no expired row under the lock. The expiry test in the `where` is
      # redundant while that lock invariant holds — deliberately so, because it
      # is what lets this assertion exist. This is the one statement in the
      # design that must never steal a live lease, so it fails loudly rather
      # than overwrite an owner.
      {1, [[token]]} =
        from(l in CommandQueueLeaseRow,
          prefix: ^@schema_prefix,
          where:
            l.instance_id == ^instance_id and
              l.expires_at <= fragment("timezone('UTC', clock_timestamp())"),
          update: [
            set: [
              owner_id: ^owner_id,
              fencing_token: fragment("? + 1", l.fencing_token),
              expires_at:
                fragment(
                  "timezone('UTC', clock_timestamp()) + (? * interval '1 second')",
                  ^ttl
                ),
              acquired_at: fragment("timezone('UTC', clock_timestamp())"),
              renewed_at: nil,
              released_at: nil
            ]
          ],
          select: [l.fencing_token]
        )
        |> repo.update_all([])

      # An unreleased row is a lease being seized from an owner that never gave
      # it up — a crash, or a node partitioned away. A stamped `released_at`
      # means the previous owner drained and handed it over, which is an
      # orderly succession rather than a takeover. Telemetry and callers read
      # this as `takeover`.
      seized? = is_nil(released_at)

      grant = %Grant{instance_id: instance_id, owner_id: owner_id, fencing_token: token}
      finish_acquire(grant, %{previous_owner_id: prev_owner, takeover: seized?}, ttl, repo)
    else
      # Live lease: somebody else owns this ledger. `rollback/1` throws, so this
      # branch returns nothing to its caller — it unwinds the transaction, which
      # is also what releases the row lock taken by the SELECT above.
      repo.rollback(:held)
    end
  end

  # Any failure while rescheduling orphans rolls the whole acquisition back:
  # the successor starts from a clean queue or not at all. Transient
  # contention is :busy (lock waits via lease_transaction/2's rescue). Every
  # other error propagates out of acquire/4 so a constraint violation or schema
  # mismatch is a visible crash of the acquisition task, not a retried "busy"
  # (R11.2).
  #
  # `predecessor` is the half of the `acquire_info/0` map that the claim path
  # already knows — `previous_owner_id` and `takeover`; this completes it with
  # the orphans it rescued.
  defp finish_acquire(grant, predecessor, ttl, repo) do
    orphans = reschedule_orphans!(grant.instance_id, repo)

    refresh_locked!(grant, repo, ttl)
    {grant, Map.put(predecessor, :orphans, orphans)}
  end

  defp reschedule_orphans!(instance_id, repo) do
    Scheduling.reschedule_orphaned_processing!(instance_id, repo)
  end

  @doc """
  The grant a write on `occable_item` must be fenced with, or `nil` when the
  item was never claimed.

  `nil` in `lease_grant` is ambiguous on its own: the field is virtual and
  defaults to nothing, so "never claimed" and "claimed, then the grant was
  dropped somewhere between claim and write" look identical. The queue row
  resolves it. A row that is `:processing` was moved there by
  `Scheduling.claim_batch_for_processing/3`, which only runs under a grant, so
  a missing grant on such a command is a dropped fence and raises.

  Everything else — the synchronous command-map path, which creates and
  processes in one go and never claims — is unclaimed and legitimately
  unfenced. That path is the only one left now that `InstanceMonitor`'s stale
  sweep is gone.

  A command whose `command_queue_item` is not loaded raises too: the preload is
  what makes the rule decidable, so an unloaded association is "cannot tell",
  and the fence is not something to skip on a "cannot tell".

  A `lease_grant` that is neither a grant nor `nil` is passed through, so it
  raises at the fence itself (`lock_step/2`, `Scheduling.fenced_update/3`,
  `BatchProcessor.batch_grant/1`) rather than here.
  """
  @spec grant_for(term()) :: Grant.t() | nil | term()
  def grant_for(occable_item) do
    checked_grant(
      Map.get(occable_item, :lease_grant),
      Map.get(occable_item, :command_queue_item)
    )
  end

  defp checked_grant(nil, %{status: :processing}), do: dropped_fence!()
  defp checked_grant(nil, %Ecto.Association.NotLoaded{}), do: dropped_fence!()
  defp checked_grant(grant, _queue_item), do: grant

  @doc false
  @spec dropped_fence!() :: no_return()
  def dropped_fence! do
    raise ArgumentError,
          "a command whose queue row is :processing, or whose queue row is not " <>
            "loaded, was or may have been claimed under a lease, so it must carry " <>
            "the grant it was claimed under; lease_grant is nil. Writing it now " <>
            "would bypass the only ownership fence there is."
  end

  @doc """
  Prepends the lease row lock to `multi` as the step `:lease_lock`.

  The counterpart to `refresh_step/2`, and the shared form of the fence for
  every writer that joins a transaction it does not own: the business `Multi`
  already exists and has named steps, so the lease is prepended and appended
  rather than wrapping the transaction the way `with_grant/3` does for the
  claim. `Occ.Processor`'s generated `build_multi/3` and final-timeout write,
  and the two account-command modules, all fence through these two.

  `nil` (an item that was never claimed under a lease) leaves `multi`
  untouched. Anything else raises: a fence that silently turns itself off for
  a malformed grant is worse than no fence, because it looks present.
  """
  @spec lock_step(Multi.t(), Grant.t() | nil) :: Multi.t()
  def lock_step(multi, %Grant{} = grant) do
    Multi.run(multi, :lease_lock, fn repo, _changes -> {:ok, lock!(grant, repo)} end)
  end

  def lock_step(multi, nil), do: multi

  @doc """
  Appends the closing lease refresh to `multi` as the step `:lease_refresh`.

  Last rather than first so the expiry is measured at commit, not at the start
  of a transaction that may run for a while. See `lock_step/2` for the `nil`
  rule.
  """
  @spec refresh_step(Multi.t(), Grant.t() | nil) :: Multi.t()
  def refresh_step(multi, %Grant{} = grant) do
    Multi.run(multi, :lease_refresh, fn repo, _changes -> {:ok, refresh_locked!(grant, repo)} end)
  end

  def refresh_step(multi, nil), do: multi

  @doc """
  First step of a claim, processing or batch transaction: takes the lease row
  lock, proves ownership, and refreshes the expiry. The caller's
  `lock_timeout` is restored before returning.

  Raises `ArgumentError` outside a transaction, `LostError` when the grant no
  longer matches, `BusyError` when the lock is not granted within
  `lease_lock_timeout_ms`.
  """
  @spec lock!(Grant.t(), Ecto.Repo.t(), pos_integer()) :: :ok
  def lock!(%Grant{} = grant, repo, ttl \\ Config.lease_ttl()) do
    require_transaction!(repo, "lock!/3")
    with_lock_timeout(repo, fn -> owner_update!(grant, repo, ttl) end)
  rescue
    e in Postgrex.Error ->
      reraise busy_or_original(e, grant), __STACKTRACE__
  end

  # Contention on the lease row surfaces as `BusyError`; every other
  # PostgreSQL error is a real fault and is re-raised unchanged.
  defp busy_or_original(error, grant) do
    if lock_not_available?(error), do: %BusyError{grant: grant}, else: error
  end

  @doc false
  # Last step of a transaction that already holds the lock from `lock!/3`.
  # Cannot block; zero rows means the caller never held the lock.
  @spec refresh_locked!(Grant.t(), Ecto.Repo.t(), pos_integer()) :: :ok
  def refresh_locked!(%Grant{} = grant, repo, ttl \\ Config.lease_ttl()) do
    require_transaction!(repo, "refresh_locked!/3")
    owner_update!(grant, repo, ttl)
  end

  @doc """
  Idle heartbeat in its own transaction. `:ok`, `:lost` (another owner has the
  row) or `:busy` (the row is locked, normally by this processor's own
  in-flight transaction).
  """
  @spec renew(Grant.t(), Ecto.Repo.t(), pos_integer()) :: :ok | :lost | :busy
  def renew(%Grant{} = grant, repo \\ Repo, ttl \\ Config.lease_ttl()) do
    require_no_transaction!(repo, "renew/3")

    case lease_transaction(repo, fn -> owner_update_count(grant, repo, ttl) end) do
      {:ok, 1} -> :ok
      {:ok, 0} -> :lost
      :busy -> :busy
    end
  end

  @doc """
  Graceful release: marks the row expired and stamps `released_at`, fenced on
  the grant. Emits `[:lease, :released]` only after the transaction committed
  one row. `:noop` when nothing matched, including a repeated release.
  """
  @spec release(Grant.t(), release_reason(), Ecto.Repo.t()) :: :ok | :noop | :busy
  def release(%Grant{} = grant, reason, repo \\ Repo) do
    require_no_transaction!(repo, "release/3")

    case lease_transaction(repo, fn -> release_count(grant, repo) end) do
      {:ok, 1} ->
        Logger.info("released lease for instance #{grant.instance_id} (#{reason})")
        Telemetry.lease_released(grant_metadata(grant, %{reason: reason}))
        :ok

      {:ok, 0} ->
        Logger.debug("release for instance #{grant.instance_id} matched no row")
        :noop

      :busy ->
        Logger.debug("release for instance #{grant.instance_id} timed out on the row lock")
        :busy
    end
  end

  @doc """
  Runs `fun.(repo)` inside a transaction that holds the lease row lock under
  `grant`: `lock!`, the fun, `refresh_locked!`, commit. This is the wrapper for
  every queue-row write that is not part of the processing Multi: retry and
  dead-letter writes after a rollback, crash retries, busy reverts.

  Returns the fun's result. Raises `LostError` or `BusyError` from `lock!`,
  and `ArgumentError` inside a caller's transaction. A `LostError` means the
  ledger moved to another owner and the write was never made.
  """
  @spec with_grant(Grant.t(), Ecto.Repo.t(), (Ecto.Repo.t() -> term())) :: term()
  def with_grant(%Grant{} = grant, repo \\ Repo, fun) do
    require_no_transaction!(repo, "with_grant/3")

    {:ok, result} =
      repo.transaction(fn ->
        lock!(grant, repo)
        result = fun.(repo)
        refresh_locked!(grant, repo)
        result
      end)

    result
  end

  @doc false
  @spec owner_update_query(Grant.t(), pos_integer()) :: Ecto.Query.t()
  def owner_update_query(%Grant{instance_id: id, owner_id: owner, fencing_token: token}, ttl) do
    from(l in CommandQueueLeaseRow,
      prefix: ^@schema_prefix,
      where:
        l.instance_id == ^id and l.owner_id == ^owner and l.fencing_token == ^token and
          is_nil(l.released_at),
      update: [
        set: [
          expires_at:
            fragment("timezone('UTC', clock_timestamp()) + (? * interval '1 second')", ^ttl),
          renewed_at: fragment("timezone('UTC', clock_timestamp())")
        ]
      ]
    )
  end

  @doc false
  @spec grant_metadata(Grant.t(), map()) :: map()
  def grant_metadata(%Grant{} = g, extra) do
    Map.merge(
      %{
        instance_id: g.instance_id,
        owner_id: g.owner_id,
        fencing_token: g.fencing_token,
        coordination: g.coordination
      },
      extra
    )
  end

  @doc false
  # Own transaction under the lease lock timeout: `{:ok, result}` or `:busy`.
  #
  # Sets the timeout and stops there — no read of the previous value, no
  # restore, unlike `with_lock_timeout/2`. Both would be pure cost here. Every
  # caller (`acquire/4`, `renew/3`, `release/3`) refuses to run inside a
  # caller's transaction, so this always opens its own; the body is one lease
  # statement and the transaction ends immediately after it, and the commit
  # discards a `SET LOCAL` regardless. There is no caller's value to protect
  # and nothing left in the transaction that could observe the restored one,
  # so the pair was two extra round trips on every heartbeat, release and
  # acquisition. That is the opposite of `lock!/3`, which joins a transaction
  # the caller owns and goes on to write queue rows under it; there the
  # restore is the guarantee that only the wait for the lease row is bounded
  # (R4.3), and it stays.
  #
  # One consequence, and it is confined to tests. Under
  # `Ecto.Adapters.SQL.Sandbox` this "transaction" is a savepoint inside the
  # test's own transaction, and releasing a savepoint does not undo a
  # `SET LOCAL` made within it. So a test that calls `renew/3`, `release/3` or
  # `acquire/4` runs its remaining statements with `lease_lock_timeout_ms`
  # rather than the connection default, until the sandbox rolls back at the end
  # of that test. Nothing leaks between tests, and production never sees it
  # because there is no enclosing transaction there to leak into.
  def lease_transaction(repo, fun) do
    repo.transaction(fn ->
      set_lease_lock_timeout(repo)
      fun.()
    end)
  rescue
    e in Postgrex.Error ->
      if transient?(e), do: :busy, else: reraise(e, __STACKTRACE__)
  end

  # Only contention is :busy. Anything else is a real error and must surface.
  defp transient?(%Postgrex.Error{postgres: %{code: code}}),
    do: code in [:lock_not_available, :deadlock_detected, :serialization_failure]

  defp transient?(_), do: false

  @doc false
  # SET LOCAL for the statements in `fun`, then the caller's value is put back.
  #
  # The restore has to run on the raising paths too, and they are not alike.
  # `LostError` follows a SUCCESSFUL zero-row UPDATE, so the transaction is
  # still usable and a caller that rescues it would otherwise keep writing
  # under the lease's lock timeout — that one must be restored. A
  # `Postgrex.Error` has already aborted the transaction, so the restore would
  # itself fail with 25P02 and, raised from the unwinding path, would replace
  # the in-flight error and hide `BusyError`; the SET dies with the rollback
  # anyway. Hence the split rescue rather than a blanket `after`.
  def with_lock_timeout(repo, fun) do
    %{rows: [[previous]]} = repo.query!("SELECT current_setting('lock_timeout')", [])
    set_lease_lock_timeout(repo)

    try do
      fun.()
    rescue
      e in Postgrex.Error ->
        reraise e, __STACKTRACE__

      e ->
        restore_lock_timeout(repo, previous)
        reraise e, __STACKTRACE__
    else
      result ->
        restore_lock_timeout(repo, previous)
        result
    end
  end

  defp set_lease_lock_timeout(repo) do
    repo.query!("SET LOCAL lock_timeout = '#{Config.lease_lock_timeout_ms()}ms'", [])
    :ok
  end

  defp restore_lock_timeout(repo, previous) do
    repo.query!("SET LOCAL lock_timeout = '#{previous}'", [])
    :ok
  end

  defp owner_update!(grant, repo, ttl) do
    case owner_update_count(grant, repo, ttl) do
      1 -> :ok
      0 -> raise LostError, grant: grant
    end
  end

  defp owner_update_count(grant, repo, ttl) do
    {count, _} = repo.update_all(owner_update_query(grant, ttl), [])
    count
  end

  defp release_count(%Grant{instance_id: id, owner_id: owner, fencing_token: token}, repo) do
    {count, _} =
      from(l in CommandQueueLeaseRow,
        prefix: ^@schema_prefix,
        where:
          l.instance_id == ^id and l.owner_id == ^owner and l.fencing_token == ^token and
            is_nil(l.released_at),
        update: [
          set: [
            expires_at: fragment("timezone('UTC', clock_timestamp())"),
            released_at: fragment("timezone('UTC', clock_timestamp())")
          ]
        ]
      )
      |> repo.update_all([])

    count
  end

  defp lock_not_available?(%Postgrex.Error{postgres: %{code: :lock_not_available}}), do: true
  defp lock_not_available?(_), do: false

  defp require_transaction!(repo, name) do
    unless repo.in_transaction?() do
      raise ArgumentError,
            "Lease.#{name} must run inside a transaction; " <>
              "outside one the statement autocommits and drops the lock"
    end
  end

  defp require_no_transaction!(repo, name) do
    if repo.in_transaction?() do
      raise ArgumentError,
            "Lease.#{name} must not run inside a caller's transaction: " <>
              "Ecto would join it and the result could not mean committed"
    end
  end
end
