defmodule DoubleEntryLedger.LeaseFixtures do
  @moduledoc """
  Helpers for lease tests: a raw Postgrex "probe" connection outside the
  sandbox for real concurrency, and database-clock manipulation.
  """
  import Ecto.Query, only: [from: 2]
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias DoubleEntryLedger.CommandFixtures
  alias DoubleEntryLedger.CommandQueue.Lease
  alias DoubleEntryLedger.CommandQueue.Lease.Grant
  alias DoubleEntryLedger.{CommandQueueLeaseRow, Instance, Repo}
  alias DoubleEntryLedger.Stores.CommandStore

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

  def lease_row(instance_id), do: Repo.get(CommandQueueLeaseRow, instance_id)

  @doc """
  Acquires a lease under a unique test owner and returns the grant.

  Beware: acquisition rescues orphans, so this REWRITES the queue. Every
  `:processing` row on `instance_id`, whatever its `processor_id`, is
  rescheduled to `:failed` (or `:dead_letter` at the retry limit) with an
  "orphaned by lease acquisition" error, by
  `Lease.acquire/4` -> `Scheduling.reschedule_orphaned_processing!/2`. A test
  that marks a row `:processing` and then calls this will find its fixture
  silently rewritten; acquire first, then set up the row.
  """
  def test_grant(instance_id) do
    {:ok, grant, _info} = Lease.acquire(instance_id, "test:" <> Ecto.UUID.generate())
    grant
  end

  @doc "Creates a pending `:create_transaction` command on `instance_id`."
  def create_command_on(instance_id) do
    CommandStore.create(
      CommandFixtures.transaction_command_attrs(
        instance_address: Repo.get!(Instance, instance_id).address,
        source_idempk: "lease-#{System.unique_integer([:positive])}"
      )
    )
  end

  @doc """
  A command committed over `probe`, so the probe's own transaction can write
  its queue row: rows created through `Repo` live in the sandbox transaction
  and the probe cannot see them. Returns the command's id.

  `command_map` is copied from a real command so the row still loads through
  `Command`'s custom type: `Repo.query!` hands the column back already decoded,
  so it is re-encoded and inserted through a `text` parameter
  (`$3::text::jsonb`). Binding it to a `jsonb` parameter instead would let the
  driver encode the JSON a second time and store a JSON *string*, which reads
  back fine over raw SQL but fails to load as a `Command`. `on_exit` is LIFO, so registering the DELETE here
  and `discard_sandbox_writes/0` after it gives: probe lock released, sandbox
  writes discarded (releasing any lock on these rows), command deleted, then
  `committed_lease/3` deletes the instance the `commands` foreign key points
  at.
  """
  def committed_command(probe, instance_id) do
    {:ok, template} = create_command_on(instance_id)

    %{rows: [[command_map]]} =
      Repo.query!("SELECT command_map FROM #{@prefix}.commands WHERE id = $1", [
        Ecto.UUID.dump!(template.id)
      ])

    command_id = Ecto.UUID.generate()
    dumped_command = Ecto.UUID.dump!(command_id)
    dumped_instance = Ecto.UUID.dump!(instance_id)

    Postgrex.query!(
      probe,
      """
      INSERT INTO #{@prefix}.commands (id, instance_id, command_map, updated_at)
      VALUES ($1, $2, $3::text::jsonb, timezone('UTC', clock_timestamp()))
      """,
      [dumped_command, dumped_instance, Jason.encode!(command_map)]
    )

    Postgrex.query!(
      probe,
      """
      INSERT INTO #{@prefix}.command_queue_items (id, command_id, instance_id, status)
      VALUES ($1, $2, $3, 'pending')
      """,
      [Ecto.UUID.dump!(Ecto.UUID.generate()), dumped_command, dumped_instance]
    )

    on_exit(fn -> delete_committed_command(dumped_command) end)
    discard_sandbox_writes()

    command_id
  end

  defp delete_committed_command(dumped_command_id) do
    cleaner = probe_connection()
    Postgrex.query!(cleaner, "SET lock_timeout = '5s'", [])

    Postgrex.query!(cleaner, "DELETE FROM #{@prefix}.commands WHERE id = $1", [dumped_command_id])

    GenServer.stop(cleaner)
    :ok
  end

  @doc "Moves the lease's expiry one hour into the database's past."
  def expire_lease(instance_id) do
    {1, _} =
      from(l in CommandQueueLeaseRow,
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
  follows by `on_delete: :delete_all`) over a fresh connection, then calls
  `discard_sandbox_writes/0` so that delete is never blocked by a lock the
  sandbox is still holding on the row.
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
    discard_sandbox_writes()

    %Grant{instance_id: instance_id, owner_id: owner_id, fencing_token: token}
  end

  @doc """
  Discards, at teardown, every write the sandbox connection makes from here on.

  Called by `committed_lease/3`, which is the only caller it needs: a
  `committed_lease/3` row lives outside the sandbox, so a `Repo` write to it
  holds a row lock until the sandbox transaction ends — and ExUnit ends it only
  after the last `on_exit` has run, so `committed_lease/3`'s own DELETE would
  block on that lock until its `lock_timeout` fired. Rolling back to the
  savepoint releases those locks first.

  `on_exit` is LIFO, so this is registered after `committed_lease/3`'s delete
  and before anything a test registers later, such as `hold_lock_on_probe/2`'s
  rollback: probe lock released, then sandbox writes discarded, then the row
  deleted. `sandbox_subtransaction: false` is required: the sandbox otherwise
  wraps every statement outside an Ecto transaction in a savepoint of its own
  and releases it afterwards, which would discard this one the moment it was
  created.
  """
  def discard_sandbox_writes do
    savepoint = "lease_fixture_#{System.unique_integer([:positive])}"
    Repo.query!("SAVEPOINT #{savepoint}", [], sandbox_subtransaction: false)

    on_exit(fn ->
      Repo.query!("ROLLBACK TO SAVEPOINT #{savepoint}", [], sandbox_subtransaction: false)
    end)

    :ok
  end

  @doc """
  Expires a `committed_lease/3` row over the probe's own connection, which
  autocommits.

  `expire_lease/1` cannot be used for it: that runs through `Repo`, whose
  sandbox transaction would then hold the row lock for the rest of the test and
  block `hold_lock_on_probe/2` forever.
  """
  def expire_lease_on_probe(probe, %Grant{instance_id: instance_id}) do
    %Postgrex.Result{num_rows: 1} =
      Postgrex.query!(
        probe,
        """
        UPDATE #{@prefix}.command_queue_leases
        SET expires_at = timezone('UTC', clock_timestamp()) - interval '1 hour'
        WHERE instance_id = $1
        """,
        [Ecto.UUID.dump!(instance_id)]
      )

    :ok
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

  @doc """
  Drains the repo-query telemetry mailbox for `ref` and returns one tag per
  write, in the order the connection issued it: `:lease` for an UPDATE against
  the lease row, `{:write, source}` for any other INSERT, UPDATE, DELETE or
  CTE. `source` is `nil` for a statement issued through `repo.query!/2`, such
  as the batch writers. Reads, savepoints and `SET` statements are dropped.

  This is how a fenced transaction is pinned by POSITION rather than by effect.
  `lock!/3` and `refresh_locked!/3` run the same owner UPDATE, so `renewed_at`
  cannot tell the closing refresh from the opening lock, and a count cannot see
  where either one sits. A "ledger moved" test cannot see it either: the whole
  transaction rolls back whatever the order, so it passes with the lock
  anywhere. What a fully fenced transaction looks like is `:lease` first, the
  business writes, `:lease` last — the expiry measured at commit rather than at
  the start of a transaction that may run for a while.

  Attach with `RepoCase.attach_telemetry([:double_entry_ledger, :repo, :query])`
  immediately before the call under test.

  Recursive, and deliberately kept out of test bodies. Draining rather than a
  sequence of `assert_receive` is the point: a selective receive scans past
  messages that do not match, so it can neither count nor pin an order.
  """
  def write_sequence(ref, acc \\ []) do
    receive do
      {:telemetry_event, ^ref, _event, _measurements, metadata} ->
        write_sequence(ref, prepend_write(metadata, acc))
    after
      50 -> Enum.reverse(acc)
    end
  end

  # `WITH` counts because the batch writers are CTEs issued through
  # `repo.query!/2`, which carry no `source` at all and would otherwise be
  # invisible. No read-only CTE is issued anywhere in this library.
  @write_prefixes ~w(INSERT UPDATE DELETE WITH)

  defp prepend_write(%{source: "command_queue_leases", query: "UPDATE" <> _}, acc),
    do: [:lease | acc]

  defp prepend_write(%{source: source, query: query}, acc),
    do: prepend_if_write(String.starts_with?(query, @write_prefixes), source, acc)

  defp prepend_write(_metadata, acc), do: acc

  defp prepend_if_write(true, source, acc), do: [{:write, source} | acc]
  defp prepend_if_write(false, _source, acc), do: acc

  @doc "How many lease-row updates `write_sequence/2` recorded."
  def lease_update_count(sequence), do: Enum.count(sequence, &(&1 == :lease))

  @doc """
  Drains the repo-query telemetry mailbox for `ref` and returns EVERY statement
  the connection issued, in order, tagged by its first two words.

  The broad counterpart to `write_sequence/2`, which keeps only writes. Some
  costs are not writes: `SELECT current_setting('lock_timeout')` and the two
  `set_config` calls around a fenced transaction are round trips that no
  write count and no row state can see, so removing one is invisible to
  `lease_update_count/1` and visible only here.

  Attach with `RepoCase.attach_telemetry([:double_entry_ledger, :repo, :query])`
  immediately before the call under test. Recursive, and deliberately kept out
  of test bodies.
  """
  def query_sequence(ref, acc \\ []) do
    receive do
      {:telemetry_event, ^ref, _event, _measurements, metadata} ->
        query_sequence(ref, [statement_tag(metadata) | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp statement_tag(%{query: query}) do
    query |> String.split(" ", trim: true) |> Enum.take(2) |> Enum.join(" ")
  end

  defp statement_tag(_metadata), do: "unknown"

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
