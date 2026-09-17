defmodule DoubleEntryLedger.LeaseFixtures do
  @moduledoc """
  Helpers for lease tests: a raw Postgrex "probe" connection outside the
  sandbox for real concurrency, and database-clock manipulation.
  """
  import Ecto.Query, only: [from: 2]
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias DoubleEntryLedger.CommandQueue.Lease.Grant
  alias DoubleEntryLedger.{CommandQueueLease, Repo}

  @prefix DoubleEntryLedger.Config.schema_prefix()

  @doc "Starts a Postgrex connection linked to the test process, outside the sandbox pool."
  def probe_connection do
    config = Application.fetch_env!(:double_entry_ledger, DoubleEntryLedger.Repo)
    port = config |> Keyword.fetch!(:port) |> to_string() |> String.to_integer()

    {:ok, probe} =
      Postgrex.start_link(
        hostname: Keyword.fetch!(config, :hostname),
        username: Keyword.fetch!(config, :username),
        password: Keyword.fetch!(config, :password),
        database: Keyword.fetch!(config, :database),
        port: port
      )

    probe
  end

  def lease_row(instance_id), do: Repo.get(CommandQueueLease, instance_id)

  @doc "Moves the lease's expiry one hour into the database's past."
  def expire_lease(instance_id) do
    {1, _} =
      from(l in CommandQueueLease,
        where: l.instance_id == ^instance_id,
        update: [
          set: [expires_at: fragment("timezone('UTC', clock_timestamp()) - interval '1 hour'")]
        ]
      )
      |> Repo.update_all([])

    :ok
  end

  @doc """
  Creates an instance and a lease row on `probe` and COMMITS them, so a second
  connection can contend for the row lock.

  The sandbox's own transaction runs at READ COMMITTED, so rows committed by
  the probe after it began are visible to `Repo`; rows inserted through `Repo`
  are *not* visible to the probe, which is why contention fixtures cannot use
  the sandbox. Registers an `on_exit` that deletes the instance (the lease row
  follows by `on_delete: :delete_all`) over a fresh connection.
  """
  def committed_lease(probe, owner_id, token) do
    instance_id = Ecto.UUID.generate()
    dumped = Ecto.UUID.dump!(instance_id)

    Postgrex.query!(
      probe,
      """
      INSERT INTO #{@prefix}.instances (id, address, description, config, inserted_at, updated_at)
      VALUES ($1, $2, 'lease probe instance', '{}',
        timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
      """,
      [dumped, "lease:probe:#{instance_id}"]
    )

    Postgrex.query!(
      probe,
      """
      INSERT INTO #{@prefix}.command_queue_leases
        (instance_id, owner_id, fencing_token, expires_at, acquired_at)
      VALUES ($1, $2, $3,
        timezone('UTC', clock_timestamp()) + interval '20 seconds',
        timezone('UTC', clock_timestamp()))
      """,
      [dumped, owner_id, token]
    )

    on_exit(fn -> delete_committed_instance(dumped) end)

    %Grant{instance_id: instance_id, owner_id: owner_id, fencing_token: token}
  end

  @doc """
  Opens a transaction on the probe and runs the owner update for `grant`,
  leaving the transaction open so the probe session holds the row lock.

  The rollback is registered as an `on_exit` rather than left to the test body,
  so it also runs when the test fails. `on_exit` callbacks run LIFO, so this one
  runs before `committed_lease/3`'s delete and the row lock is always gone
  before the parent instance is deleted. The probe is unlinked first: ExUnit
  ends the test process with `:shutdown`, which takes a linked probe down with
  it, and a query on a dying connection exits instead of rolling back.
  """
  def hold_lock_on_probe(probe, %Grant{} = grant) do
    Process.unlink(probe)

    on_exit(fn ->
      rollback_probe(probe)
      GenServer.stop(probe)
    end)

    Postgrex.query!(probe, "BEGIN", [])

    %Postgrex.Result{num_rows: 1} =
      Postgrex.query!(
        probe,
        """
        UPDATE #{@prefix}.command_queue_leases
        SET expires_at = timezone('UTC', clock_timestamp()) + interval '20 seconds',
            renewed_at = timezone('UTC', clock_timestamp())
        WHERE instance_id = $1 AND owner_id = $2 AND fencing_token = $3
          AND released_at IS NULL
        """,
        [Ecto.UUID.dump!(grant.instance_id), grant.owner_id, grant.fencing_token]
      )

    :ok
  end

  def commit_probe(probe) do
    Postgrex.query!(probe, "COMMIT", [])
    :ok
  end

  def rollback_probe(probe) do
    Postgrex.query!(probe, "ROLLBACK", [])
    :ok
  end

  @doc "Merges `overrides` into the :command_queue config for this test only."
  def put_queue_config(overrides) do
    original = Application.get_env(:double_entry_ledger, :command_queue, [])
    Application.put_env(:double_entry_ledger, :command_queue, Keyword.merge(original, overrides))
    on_exit(fn -> Application.put_env(:double_entry_ledger, :command_queue, original) end)
    :ok
  end

  defp delete_committed_instance(dumped_instance_id) do
    cleaner = probe_connection()
    # Belt and braces: `hold_lock_on_probe/2` releases the row lock first, but a
    # probe opened by a future test and left holding it would otherwise hang
    # this DELETE forever rather than failing the run.
    Postgrex.query!(cleaner, "SET lock_timeout = '5s'", [])

    Postgrex.query!(cleaner, "DELETE FROM #{@prefix}.instances WHERE id = $1", [
      dumped_instance_id
    ])

    GenServer.stop(cleaner)
    :ok
  end
end
