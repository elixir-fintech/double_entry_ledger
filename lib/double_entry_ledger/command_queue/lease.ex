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

  alias DoubleEntryLedger.CommandQueue.Config
  alias DoubleEntryLedger.CommandQueueLease
  alias DoubleEntryLedger.Repo.Proxy, as: Repo
  alias DoubleEntryLedger.Telemetry

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

  @doc "A new unique owner id: `prefix:node:uuid`."
  @spec owner_id() :: String.t()
  def owner_id do
    prefix =
      Application.get_env(:double_entry_ledger, :command_queue, [])[:processor_name] ||
        "command_queue"

    "#{prefix}:#{node()}:#{Ecto.UUID.generate()}"
  end

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
