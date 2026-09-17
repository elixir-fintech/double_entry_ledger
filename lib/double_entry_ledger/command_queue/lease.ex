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
  alias DoubleEntryLedger.CommandQueueLease
  alias DoubleEntryLedger.Repo.Proxy, as: Repo
  alias DoubleEntryLedger.Telemetry

  @schema_prefix DoubleEntryLedger.Config.schema_prefix()

  # Reads the reason string written by
  # `DoubleEntryLedger.CommandQueue.Scheduling.reschedule_orphaned_processing!/2`,
  # which ends in `"previous processor " <> inspect(processor_id)` and may be
  # embedded in a longer dead-letter message. Grep for this attribute from the
  # writing side before rewording that reason. Task 11 replaces the coupling by
  # carrying the id on the queue item.
  @previous_processor_regex ~r/previous processor "([^"]*)"/

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
          orphans: [Command.t()]
        }

  @doc "A new unique owner id: `prefix:node:uuid`."
  @spec owner_id() :: String.t()
  def owner_id do
    prefix =
      Application.get_env(:double_entry_ledger, :command_queue, [])[:processor_name] ||
        "command_queue"

    "#{prefix}:#{node()}:#{Ecto.UUID.generate()}"
  end

  @doc """
  Acquires the lease for `instance_id` under `owner_id`, taking over an
  expired lease and rescheduling any `:processing` rows on the ledger, in one
  transaction. Emits nothing; call `emit_acquisition_events/2` afterwards.

  `:held` when a live lease exists (any holder). `:busy` when the row lock was
  not granted within the lock timeout or an orphan reschedule lost a race.
  Concretely that is any transient contention condition — the lock timeout
  fired, a deadlock was broken, the snapshot could not be serialized, or the
  `processor_version` fence on a queue row lost — and `acquire/4` follows
  `renew/3` and `release/3` in treating all of them as "another transaction is
  on this work, try again later", rather than `lock!/3`'s narrower rule.
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

  # `lease_transaction/2` reports the three outcomes in two shapes: `{:error,
  # reason}` whenever the transaction body called `repo.rollback/1` (`:held` for
  # a live lease, `:busy` for a lost row fence), and a bare `:busy` from its own
  # rescue of a transient PostgreSQL error. Flatten the rollback shape here so
  # `acquire/4` reads one vocabulary.
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

  @doc "Emits the events for a committed acquisition: acquired, then one recovered event per orphan."
  @spec emit_acquisition_events(Grant.t(), acquire_info()) :: :ok
  def emit_acquisition_events(%Grant{} = grant, info) do
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

    Enum.each(info.orphans, fn %Command{command_queue_item: item} = command ->
      Logger.warning("rescheduled orphan #{command.id} on lease acquisition")

      Telemetry.command_recovered(%{
        command_id: command.id,
        instance_id: command.instance_id,
        previous_processor_id: previous_processor_from_error(item),
        stale_for_seconds: nil,
        reason: :takeover,
        trace_context: command.trace_context
      })

      Scheduling.emit_persisted_failure(command, item.status, hd(item.errors).message)
    end)
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

    case repo.insert_all(CommandQueueLease, source,
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
        from(l in CommandQueueLease,
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
        from(l in CommandQueueLease,
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
  # contention is :busy (lock waits via lease_transaction/2's rescue, a lost
  # row fence via reschedule_orphans!/2). Every other error propagates out of
  # acquire/4 so a constraint violation or schema mismatch is a visible crash
  # of the acquisition task, not a retried "busy" (R11.2).
  #
  # `predecessor` is the half of the `acquire_info/0` map that the claim path
  # already knows — `previous_owner_id` and `takeover`; this completes it with
  # the orphans it rescued.
  defp finish_acquire(grant, predecessor, ttl, repo) do
    orphans = reschedule_orphans!(grant.instance_id, repo)

    refresh_locked!(grant, repo, ttl)
    {grant, Map.put(predecessor, :orphans, orphans)}
  end

  # A lost `processor_version` fence means another transaction is writing the
  # same queue row right now, which is what :busy already means everywhere else
  # in this module. Rolling back as :busy turns a crashed acquisition task into
  # a clean retry on the next poll; the ledger is simply not claimed this time.
  defp reschedule_orphans!(instance_id, repo) do
    Scheduling.reschedule_orphaned_processing!(instance_id, repo)
  rescue
    Ecto.StaleEntryError -> repo.rollback(:busy)
  end

  defp previous_processor_from_error(%{errors: [%{message: message} | _]}) do
    case Regex.run(@previous_processor_regex, message) do
      [_, id] -> id
      _ -> nil
    end
  end

  defp previous_processor_from_error(_), do: nil

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
    from(l in CommandQueueLease,
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
  def lease_transaction(repo, fun) do
    repo.transaction(fn -> with_lock_timeout(repo, fun) end)
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
    repo.query!("SET LOCAL lock_timeout = '#{Config.lease_lock_timeout_ms()}ms'", [])

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
      from(l in CommandQueueLease,
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
