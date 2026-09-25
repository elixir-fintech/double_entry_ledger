defmodule DoubleEntryLedger.CommandQueue.LeaseTest do
  use DoubleEntryLedger.RepoCase, async: false

  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.CommandFixtures
  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.LeaseFixtures

  alias DoubleEntryLedger.CommandQueue.Lease
  alias DoubleEntryLedger.CommandQueue.Lease.Grant
  alias DoubleEntryLedger.CommandQueue.Scheduling
  alias DoubleEntryLedger.CommandQueueItem
  alias DoubleEntryLedger.Instance
  alias DoubleEntryLedger.Repo
  alias DoubleEntryLedger.Stores.CommandStore
  alias Ecto.Adapters.SQL

  @prefix DoubleEntryLedger.Config.schema_prefix()

  # `Scheduling.build_schedule_retry_with_reason/4` dead-letters instead of
  # rescheduling once a queue row has reached this retry count.
  @max_retries Application.compile_env(:double_entry_ledger, :command_queue, [])
               |> Keyword.get(:max_retries, 5)

  setup [:create_instance]

  defmodule FailingOrphanRepo do
    @moduledoc false
    # Real repo except `update!/1`, which fails the orphan reschedule so the
    # whole acquisition must roll back (spec §1 step 4, R2.4).
    alias DoubleEntryLedger.Repo

    def in_transaction?, do: Repo.in_transaction?()
    def transaction(fun), do: Repo.transaction(fun)
    def rollback(v), do: Repo.rollback(v)
    def query!(sql, params), do: Repo.query!(sql, params)
    def all(q), do: Repo.all(q)
    def insert_all(src, entries, opts), do: Repo.insert_all(src, entries, opts)
    def one!(q), do: Repo.one!(q)
    def update_all(q, u), do: Repo.update_all(q, u)

    # SQLSTATE 23514 is check_violation. `Postgrex.Error.exception/1` resolves
    # the name from the code string, so a code atom here would leave
    # `:code` nil and the error would not be classified at all.
    def update!(_changeset) do
      raise Postgrex.Error,
        postgres: %{
          code: "23514",
          severity: "ERROR",
          message: "simulated failure while rescheduling an orphan"
        }
    end
  end

  defmodule SerializationFailureRepo do
    @moduledoc false
    # Real repo except the `SELECT ... FOR UPDATE`, which raises a
    # serialization failure. Pins down that `acquire/4` treats every transient
    # condition as `:busy` (the `renew/3` and `release/3` rule), rather than
    # `lock!/3`'s narrower `:lock_not_available`.
    alias DoubleEntryLedger.Repo

    def in_transaction?, do: Repo.in_transaction?()
    def transaction(fun), do: Repo.transaction(fun)
    def rollback(v), do: Repo.rollback(v)
    def query!(sql, params), do: Repo.query!(sql, params)
    def all(q), do: Repo.all(q)
    def insert_all(src, entries, opts), do: Repo.insert_all(src, entries, opts)
    def update_all(q, u), do: Repo.update_all(q, u)
    def update!(c), do: Repo.update!(c)

    # SQLSTATE 40001 is serialization_failure.
    def one!(_query) do
      raise Postgrex.Error,
        postgres: %{
          code: "40001",
          severity: "ERROR",
          message: "simulated serialization failure on the lease row"
        }
    end
  end

  defmodule SlowOrphanRepo do
    @moduledoc false
    # Real repo except that the orphan reschedule takes about 300 ms, which is
    # long enough to tell "expiry measured before the orphan work" from
    # "expiry measured after it" on the database clock.
    alias DoubleEntryLedger.Repo

    def in_transaction?, do: Repo.in_transaction?()
    def transaction(fun), do: Repo.transaction(fun)
    def rollback(v), do: Repo.rollback(v)
    def query!(sql, params), do: Repo.query!(sql, params)
    def all(q), do: Repo.all(q)
    def insert_all(src, entries, opts), do: Repo.insert_all(src, entries, opts)
    def one!(q), do: Repo.one!(q)
    def update_all(q, u), do: Repo.update_all(q, u)

    def update!(changeset) do
      Process.sleep(300)
      Repo.update!(changeset)
    end
  end

  defmodule SelectPausingRepo do
    @moduledoc false
    # Real repo, except that `one!/1` pauses after the `SELECT ... FOR UPDATE`
    # has run and hands control back to the test, which is the only way to
    # observe acquire/4 mid-transaction: the window between reading the lease
    # row and writing it is exactly what the row lock has to close.
    alias DoubleEntryLedger.Repo

    def in_transaction?, do: Repo.in_transaction?()
    def transaction(fun), do: Repo.transaction(fun)
    def rollback(v), do: Repo.rollback(v)
    def query!(sql, params), do: Repo.query!(sql, params)
    def all(q), do: Repo.all(q)
    def insert_all(src, entries, opts), do: Repo.insert_all(src, entries, opts)
    def update_all(q, u), do: Repo.update_all(q, u)
    def update!(c), do: Repo.update!(c)

    def one!(query) do
      result = Repo.one!(query)
      send(Process.get(:lease_test_pid), {:selected, self()})

      # The only branch in this file, and it cannot mask a failure: every
      # assertion runs before the test sends `:continue`, so the timeout is
      # reached only when the test has already failed and will never send. It
      # exists so that such a failure reports itself instead of hanging the
      # suite with the sandbox connection stuck inside this transaction.
      receive do
        :continue -> result
      after
        10_000 -> result
      end
    end
  end

  # Inserts a lease row directly so owner-side operations are testable before
  # acquire/4 exists (Task 6 adds acquire-based tests).
  defp insert_lease(instance_id, owner_id, token) do
    %Postgrex.Result{num_rows: 1} =
      Repo.query!(
        """
        INSERT INTO #{@prefix}.command_queue_leases
          (instance_id, owner_id, fencing_token, expires_at, acquired_at)
        VALUES ($1, $2, $3,
          timezone('UTC', clock_timestamp()) + interval '20 seconds',
          timezone('UTC', clock_timestamp()))
        """,
        [Ecto.UUID.dump!(instance_id), owner_id, token]
      )

    %Grant{instance_id: instance_id, owner_id: owner_id, fencing_token: token}
  end

  # Keeps the rescue out of the test body so the test stays branch-free.
  defp lock_expecting_loss(grant) do
    Lease.lock!(%{grant | fencing_token: 0}, Repo)
  rescue
    Lease.LostError -> :lost
  end

  defp take_over(instance_id) do
    %Postgrex.Result{num_rows: 1} =
      Repo.query!(
        """
        UPDATE #{@prefix}.command_queue_leases
        SET owner_id = 'b', fencing_token = 2
        WHERE instance_id = $1
        """,
        [Ecto.UUID.dump!(instance_id)]
      )

    :ok
  end

  # Records whether the emitting process was inside a transaction, so the
  # release and acquisition tests can prove the event fires after the commit
  # rather than inside it. Attached by name, not as a closure, to avoid
  # telemetry's warning.
  def forward_lease_event(event, measurements, metadata, %{test_pid: pid, ref: ref}) do
    payload = Map.put(metadata, :in_transaction, Repo.in_transaction?())
    send(pid, {:telemetry_event, ref, event, measurements, payload})
  end

  defp attach_lease_telemetry(event) do
    ref = make_ref()
    handler_id = "lease-test-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      event,
      &__MODULE__.forward_lease_event/4,
      %{test_pid: self(), ref: ref}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  defp attach_release_telemetry,
    do: attach_lease_telemetry([:double_entry_ledger, :lease, :released])

  # Every event `emit_acquisition_events/3` can produce, under ONE handler and
  # ONE ref, so a test observes the real emission order instead of picking
  # events out of the mailbox by pattern.
  @acquisition_events [
    [:double_entry_ledger, :lease, :acquired],
    [:double_entry_ledger, :command, :recovered],
    [:double_entry_ledger, :command, :retry],
    [:double_entry_ledger, :command, :dead_letter]
  ]

  defp attach_acquisition_telemetry do
    ref = make_ref()
    handler_id = "lease-acquisition-#{inspect(ref)}"

    :telemetry.attach_many(
      handler_id,
      @acquisition_events,
      &__MODULE__.forward_lease_event/4,
      %{test_pid: self(), ref: ref}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  # Takes the next `count` events in arrival order. Ordinary `assert_receive`
  # patterns would scan past the earlier ones, which is exactly what must not
  # be allowed here.
  defp next_events(ref, count) do
    Enum.map(1..count, fn _ ->
      assert_receive {:telemetry_event, ^ref, event, _measurements, metadata}, 500
      {event, metadata}
    end)
  end

  # Sets the time zone of the connection the sandbox runs this test on. SET
  # LOCAL survives the sandbox's per-statement savepoint (RELEASE does not undo
  # it) and dies with the sandbox transaction at the end of the test.
  defp set_repo_time_zone(zone) do
    Repo.query!("SET LOCAL TIME ZONE '#{zone}'", [])
    :ok
  end

  # Stamps a queue row as claimed by a processor that has since vanished.
  defp mark_processing(command, processor_id, retry_count \\ 0) do
    {1, _} =
      Repo.update_all(
        from(q in CommandQueueItem, where: q.command_id == ^command.id),
        set: [status: :processing, processor_id: processor_id, retry_count: retry_count]
      )

    :ok
  end

  describe "acquire/4" do
    setup [:create_accounts]

    test "fresh: token 1, not a takeover, no previous owner", %{instance: instance} do
      assert {:ok, %Grant{fencing_token: 1, owner_id: "a"}, info} =
               Lease.acquire(instance.id, "a")

      assert info == %{previous_owner_id: nil, takeover: false, orphans: []}
      assert lease_row(instance.id).owner_id == "a"
    end

    test "on a live lease returns :held", %{instance: instance} do
      {:ok, _, _} = Lease.acquire(instance.id, "a")
      assert Lease.acquire(instance.id, "b") == :held
    end

    test "same owner on its own live lease returns :held, token unchanged", %{instance: instance} do
      {:ok, _, _} = Lease.acquire(instance.id, "a")
      assert Lease.acquire(instance.id, "a") == :held
      assert lease_row(instance.id).fencing_token == 1
    end

    test "on an expired lease: token +1, takeover true, previous owner set", %{instance: instance} do
      {:ok, _, _} = Lease.acquire(instance.id, "a")
      expire_lease(instance.id)

      assert {:ok, %Grant{fencing_token: 2}, %{takeover: true, previous_owner_id: "a"}} =
               Lease.acquire(instance.id, "b")

      refute lease_row(instance.id).released_at
    end

    test "after a graceful release: token +1, takeover false", %{instance: instance} do
      {:ok, grant, _} = Lease.acquire(instance.id, "a")
      :ok = Lease.release(grant, :drained)

      assert {:ok, %Grant{fencing_token: 2}, %{takeover: false, previous_owner_id: "a"}} =
               Lease.acquire(instance.id, "b")
    end

    test "stores the configured coordination strategy on the grant", %{instance: instance} do
      assert {:ok, %Grant{coordination: :database_polling}, _} = Lease.acquire(instance.id, "a")
    end

    test "stores an explicit coordination option on the grant", %{instance: instance} do
      assert {:ok, %Grant{coordination: :manual}, _} =
               Lease.acquire(instance.id, "a", Repo, coordination: :manual)
    end

    test "raises inside a transaction", %{instance: instance} do
      assert_raise ArgumentError, ~r/transaction/, fn ->
        Repo.transaction(fn -> Lease.acquire(instance.id, "a") end)
      end
    end

    test "old owner's lock! raises after a takeover", %{instance: instance} do
      {:ok, old, _} = Lease.acquire(instance.id, "a")
      expire_lease(instance.id)
      {:ok, _new, _} = Lease.acquire(instance.id, "b")

      assert_raise Lease.LostError, fn -> Repo.transaction(fn -> Lease.lock!(old, Repo) end) end
    end

    test "reschedules :processing orphans with zero delay, ordered by position", %{
      instance: instance
    } do
      {:ok, first} =
        CommandStore.create(
          transaction_command_attrs(instance_address: instance.address, source_idempk: "one")
        )

      {:ok, second} =
        CommandStore.create(
          transaction_command_attrs(instance_address: instance.address, source_idempk: "two")
        )

      :ok = mark_processing(first, "legacy")

      assert {:ok, _grant, %{orphans: [{orphan, previous}]}} = Lease.acquire(instance.id, "b")
      assert orphan.id == first.id
      assert previous == "legacy"
      assert orphan.command_queue_item.status == :failed
      assert Repo.all(Scheduling.next_command_ids_query(instance.id, 10)) == [first.id, second.id]
    end

    test "a non-transient orphan reschedule failure rolls the acquisition back and propagates", %{
      instance: instance
    } do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      acquired = attach_lease_telemetry([:double_entry_ledger, :lease, :acquired])
      :ok = mark_processing(command, "legacy")

      assert_raise Postgrex.Error, ~r/simulated/, fn ->
        Lease.acquire(instance.id, "b", FailingOrphanRepo)
      end

      assert lease_row(instance.id) == nil
      assert Repo.get_by(CommandQueueItem, command_id: command.id).status == :processing
      refute_receive {:telemetry_event, ^acquired, _, _, _}, 100
    end

    test "a transient failure anywhere in the transaction returns :busy", %{instance: instance} do
      {:ok, _, _} = Lease.acquire(instance.id, "a")
      expire_lease(instance.id)

      assert Lease.acquire(instance.id, "b", SerializationFailureRepo) == :busy
      assert lease_row(instance.id).owner_id == "a"
    end

    test "expires_at is measured at commit, after orphan work", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      :ok = mark_processing(command, "legacy")

      {:ok, _grant, %{orphans: [_one]}} =
        Lease.acquire(instance.id, "a", SlowOrphanRepo, ttl: 30)

      row = lease_row(instance.id)

      # The reschedule took ~300 ms, so a refresh that ran before it would leave
      # renewed_at level with acquired_at and hand the new owner a TTL already
      # part spent.
      assert DateTime.diff(row.renewed_at, row.acquired_at, :millisecond) >= 250
      assert_in_delta DateTime.diff(row.expires_at, row.renewed_at, :millisecond), 30_000, 1_000
    end
  end

  describe "acquire/4 against a probe connection" do
    test "waits behind a held lock, then :held once the holder refreshed and committed" do
      put_queue_config(lease_lock_timeout_ms: 5_000)
      probe = probe_connection()
      grant = committed_lease(probe, "a", 1)
      expire_lease_on_probe(probe, grant)
      hold_lock_on_probe(probe, grant)

      task = Task.async(fn -> Lease.acquire(grant.instance_id, "b") end)

      assert Task.yield(task, 300) == nil
      commit_probe(probe)
      assert Task.await(task, 5_000) == :held
    end

    test "waits behind a held lock, then succeeds when the holder rolled back" do
      put_queue_config(lease_lock_timeout_ms: 5_000)
      probe = probe_connection()
      grant = committed_lease(probe, "a", 1)
      expire_lease_on_probe(probe, grant)
      hold_lock_on_probe(probe, grant)

      task = Task.async(fn -> Lease.acquire(grant.instance_id, "b") end)

      assert Task.yield(task, 300) == nil
      rollback_probe(probe)
      assert {:ok, %Grant{owner_id: "b", fencing_token: 2}, _} = Task.await(task, 5_000)
    end

    test "returns :busy when the lock is held past the timeout, row unchanged" do
      put_queue_config(lease_lock_timeout_ms: 200)
      probe = probe_connection()
      grant = committed_lease(probe, "a", 1)
      expire_lease_on_probe(probe, grant)
      hold_lock_on_probe(probe, grant)

      assert Lease.acquire(grant.instance_id, "b") == :busy
      assert lease_row(grant.instance_id).owner_id == "a"
    end

    test "a release committed after acquire started is read from the locked row" do
      put_queue_config(lease_lock_timeout_ms: 5_000)
      probe = probe_connection()
      grant = committed_lease(probe, "a", 1)
      hold_lock_on_probe(probe, grant)

      task = Task.async(fn -> Lease.acquire(grant.instance_id, "b") end)
      assert Task.yield(task, 300) == nil

      Postgrex.query!(
        probe,
        """
        UPDATE #{@prefix}.command_queue_leases
        SET released_at = timezone('UTC', clock_timestamp()),
            expires_at = timezone('UTC', clock_timestamp())
        WHERE instance_id = $1
        """,
        [Ecto.UUID.dump!(grant.instance_id)]
      )

      commit_probe(probe)

      assert {:ok, _, %{takeover: false, previous_owner_id: "a"}} = Task.await(task, 5_000)
    end

    test "renew that waited writes an expiry measured after the wait" do
      put_queue_config(lease_lock_timeout_ms: 5_000)
      probe = probe_connection()
      grant = committed_lease(probe, "a", 1)
      hold_lock_on_probe(probe, grant)

      task = Task.async(fn -> Lease.renew(grant, Repo, 30) end)
      assert Task.yield(task, 400) == nil
      released_at_ms = System.system_time(:millisecond)
      commit_probe(probe)
      assert Task.await(task, 5_000) == :ok

      row = lease_row(grant.instance_id)
      assert DateTime.to_unix(row.expires_at, :millisecond) >= released_at_ms + 30_000 - 1_000
    end

    test "holds the row lock from the read until the commit, locking out other writers" do
      probe = probe_connection()
      grant = committed_lease(probe, "a", 1)
      expire_lease_on_probe(probe, grant)
      test_pid = self()

      task =
        Task.async(fn ->
          Process.put(:lease_test_pid, test_pid)
          Lease.acquire(grant.instance_id, "b", SelectPausingRepo)
        end)

      assert_receive {:selected, acquirer}, 5_000
      Postgrex.query!(probe, "SET lock_timeout = '200ms'", [])

      assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} =
               Postgrex.query(
                 probe,
                 "UPDATE #{@prefix}.command_queue_leases SET owner_id = 'c' WHERE instance_id = $1",
                 [Ecto.UUID.dump!(grant.instance_id)]
               )

      send(acquirer, :continue)

      assert {:ok, %Grant{owner_id: "b", fencing_token: 2}, _} = Task.await(task, 5_000)
    end

    test "stamps UTC when the acquiring session's own time zone is not UTC", %{
      instance: instance
    } do
      # Read the true instant over a second session, whose time zone this test
      # never touches. The expression converts explicitly, so it is UTC either
      # way; the point is that it is not the session doing the acquiring.
      probe = probe_connection()

      %{rows: [[db_now]]} =
        Postgrex.query!(probe, "SELECT timezone('UTC', clock_timestamp())", [])

      # The lease columns are `timestamp without time zone`, so a lease
      # statement that dropped the explicit UTC conversion would be stamped
      # through THIS session's time zone. SET LOCAL is scoped to the sandbox's
      # transaction and so ends with the test.
      set_repo_time_zone("America/New_York")

      {:ok, _grant, _} = Lease.acquire(instance.id, "a", Repo, ttl: 60)
      row = lease_row(instance.id)
      db_now = DateTime.from_naive!(db_now, "Etc/UTC")

      assert DateTime.diff(row.acquired_at, db_now, :second) in -5..5
      assert DateTime.diff(row.expires_at, db_now, :second) in 55..65
    end
  end

  describe "emit_acquisition_events/3" do
    setup [:create_accounts]

    test "emits acquired, then recovered and retry for a rescued orphan, in that order", %{
      instance: instance
    } do
      ref = attach_acquisition_telemetry()

      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      :ok = mark_processing(command, "legacy")

      {:ok, grant, %{orphans: [{orphan, _previous}]} = info} = Lease.acquire(instance.id, "a")
      assert orphan.command_queue_item.status == :failed
      refute_received {:telemetry_event, ^ref, _, _, _}

      :ok = Lease.emit_acquisition_events(grant, info)

      assert [
               {[:double_entry_ledger, :lease, :acquired],
                %{
                  orphans: 1,
                  owner_id: "a",
                  takeover: false,
                  coordination: :database_polling,
                  in_transaction: false
                }},
               {[:double_entry_ledger, :command, :recovered],
                %{
                  reason: :takeover,
                  command_id: recovered_id,
                  previous_processor_id: "legacy",
                  in_transaction: false
                }},
               {[:double_entry_ledger, :command, :retry],
                %{status: :failed, command_id: retry_id, in_transaction: false}}
             ] = next_events(ref, 3)

      assert recovered_id == command.id
      assert retry_id == command.id
      refute_receive {:telemetry_event, ^ref, _, _, _}, 100
    end

    test "emits acquired, then recovered and dead_letter for an orphan at the retry limit", %{
      instance: instance
    } do
      ref = attach_acquisition_telemetry()

      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      :ok = mark_processing(command, "legacy", @max_retries)

      {:ok, grant, %{orphans: [{orphan, _previous}]} = info} = Lease.acquire(instance.id, "a")
      assert orphan.command_queue_item.status == :dead_letter
      refute_received {:telemetry_event, ^ref, _, _, _}

      :ok = Lease.emit_acquisition_events(grant, info)

      # The id is carried beside the command by
      # `Scheduling.reschedule_orphaned_processing!/2`, so it survives the
      # dead-letter path rewriting the persisted message.
      assert [
               {[:double_entry_ledger, :lease, :acquired], %{orphans: 1, in_transaction: false}},
               {[:double_entry_ledger, :command, :recovered],
                %{
                  reason: :takeover,
                  command_id: recovered_id,
                  previous_processor_id: "legacy",
                  in_transaction: false
                }},
               {[:double_entry_ledger, :command, :dead_letter],
                %{command_id: dead_id, in_transaction: false}}
             ] = next_events(ref, 3)

      assert recovered_id == command.id
      assert dead_id == command.id
      refute_receive {:telemetry_event, ^ref, _, _, _}, 100
    end
  end

  describe "owner_id/0" do
    test "is unique across calls" do
      refute Lease.owner_id() == Lease.owner_id()
    end

    test "carries the processor_name prefix and the node" do
      put_queue_config(processor_name: "px")
      assert Lease.owner_id() =~ ~r/^px:#{node()}:[0-9a-f-]{36}$/
    end
  end

  describe "lock!/3 and refresh_locked!/3" do
    test "lock! moves expires_at forward and sets renewed_at", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)
      before = lease_row(instance.id)

      {:ok, :ok} = Repo.transaction(fn -> Lease.lock!(grant, Repo, 60) end)

      row = lease_row(instance.id)
      assert DateTime.compare(row.expires_at, before.expires_at) == :gt
      assert row.renewed_at
    end

    test "lock! renews a lapsed lease nobody has taken over", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)
      expire_lease(instance.id)

      {:ok, :ok} = Repo.transaction(fn -> Lease.lock!(grant, Repo) end)

      assert DateTime.compare(lease_row(instance.id).expires_at, DateTime.utc_now()) == :gt
    end

    test "lock! with a stale token raises LostError", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)

      assert_raise Lease.LostError, fn ->
        Repo.transaction(fn -> Lease.lock!(%{grant | fencing_token: 0}, Repo) end)
      end
    end

    test "lock! raises outside a transaction", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)
      assert_raise ArgumentError, ~r/transaction/, fn -> Lease.lock!(grant, Repo) end
    end

    test "lock! restores the previous lock_timeout", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)
      put_queue_config(lease_lock_timeout_ms: 750)

      {:ok, value} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '4321ms'")
          Lease.lock!(grant, Repo)
          %{rows: [[v]]} = Repo.query!("SELECT current_setting('lock_timeout')")
          v
        end)

      assert value == "4321ms"
    end

    test "lock! restores the previous lock_timeout after a LostError", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)
      put_queue_config(lease_lock_timeout_ms: 750)

      {:ok, value} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '4321ms'")
          :lost = lock_expecting_loss(grant)
          %{rows: [[v]]} = Repo.query!("SELECT current_setting('lock_timeout')")
          v
        end)

      assert value == "4321ms"
    end

    test "lock! raises BusyError when the probe holds the row past the timeout" do
      put_queue_config(lease_lock_timeout_ms: 200)
      probe = probe_connection()
      grant = committed_lease(probe, "a", 1)
      hold_lock_on_probe(probe, grant)

      assert_raise Lease.BusyError, fn ->
        Repo.transaction(fn -> Lease.lock!(grant, Repo) end)
      end
    end

    test "refresh_locked! succeeds after the TTL elapsed inside a held transaction", %{
      instance: instance
    } do
      grant = insert_lease(instance.id, "a", 1)

      {:ok, :ok} =
        Repo.transaction(fn ->
          Lease.lock!(grant, Repo, 1)
          expire_lease(instance.id)
          Lease.refresh_locked!(grant, Repo, 60)
        end)

      assert DateTime.compare(lease_row(instance.id).expires_at, DateTime.utc_now()) == :gt
    end

    test "refresh_locked! raises outside a transaction", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)
      assert_raise ArgumentError, fn -> Lease.refresh_locked!(grant, Repo) end
    end

    test "refresh_locked! after a release raises LostError", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)
      :ok = Lease.release(grant, :drained, Repo)

      assert_raise Lease.LostError, fn ->
        Repo.transaction(fn -> Lease.refresh_locked!(grant, Repo) end)
      end
    end
  end

  describe "renew/3" do
    test "returns :ok for the owner", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)
      assert Lease.renew(grant, Repo) == :ok
    end

    test "returns :ok for a lapsed lease nobody took over", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)
      expire_lease(instance.id)
      assert Lease.renew(grant, Repo) == :ok
    end

    test "returns :lost for a stale token", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)
      assert Lease.renew(%{grant | fencing_token: 0}, Repo) == :lost
    end

    test "returns :busy when the probe holds the row past the timeout" do
      put_queue_config(lease_lock_timeout_ms: 200)
      probe = probe_connection()
      grant = committed_lease(probe, "a", 1)
      hold_lock_on_probe(probe, grant)

      assert Lease.renew(grant, Repo) == :busy
    end

    test "raises inside a transaction", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)

      assert_raise ArgumentError, ~r/transaction/, fn ->
        Repo.transaction(fn -> Lease.renew(grant, Repo) end)
      end
    end

    # Exercises the `repo \\ Repo` default, i.e. DoubleEntryLedger.Repo.Proxy.
    # The Proxy dispatches at runtime, so a missing delegation there produces no
    # compile warning and would first surface in production.
    test "renews through the Repo.Proxy default when no repo is given", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)
      assert Lease.renew(grant) == :ok
    end
  end

  describe "release/3" do
    test "marks expired, sets released_at, keeps the row, emits after commit", %{
      instance: instance
    } do
      grant = insert_lease(instance.id, "a", 1)
      ref = attach_release_telemetry()

      assert Lease.release(grant, :drained, Repo) == :ok

      row = lease_row(instance.id)
      assert row.released_at
      assert DateTime.compare(row.expires_at, DateTime.utc_now()) in [:lt, :eq]

      assert_receive {:telemetry_event, ^ref, _, _,
                      %{reason: :drained, owner_id: "a", in_transaction: false}}
    end

    test "a second release is a :noop and emits nothing", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)
      :ok = Lease.release(grant, :drained, Repo)
      ref = attach_release_telemetry()

      assert Lease.release(grant, :drained, Repo) == :noop
      refute_receive {:telemetry_event, ^ref, _, _, _}, 100
    end

    test "after release, lock! raises LostError and renew returns :lost", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)
      :ok = Lease.release(grant, :drained, Repo)

      assert Lease.renew(grant, Repo) == :lost

      assert_raise Lease.LostError, fn ->
        Repo.transaction(fn -> Lease.lock!(grant, Repo) end)
      end
    end

    test "release with a stale token is a :noop", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)
      assert Lease.release(%{grant | fencing_token: 0}, :drained, Repo) == :noop
      refute lease_row(instance.id).released_at
    end

    test "raises inside a transaction", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)

      assert_raise ArgumentError, fn ->
        Repo.transaction(fn -> Lease.release(grant, :drained, Repo) end)
      end
    end

    test "returns :busy when the probe holds the row past the timeout" do
      put_queue_config(lease_lock_timeout_ms: 200)
      probe = probe_connection()
      grant = committed_lease(probe, "a", 1)
      hold_lock_on_probe(probe, grant)
      ref = attach_release_telemetry()

      assert Lease.release(grant, :drained, Repo) == :busy

      refute_receive {:telemetry_event, ^ref, _, _, _}, 100
      refute lease_row(grant.instance_id).released_at
    end

    test "release after a takeover is a :noop", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)
      :ok = take_over(instance.id)

      assert Lease.release(grant, :drained, Repo) == :noop
      refute lease_row(instance.id).released_at
    end

    test "release of an expired but unreleased lease still releases it", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)
      :ok = expire_lease(instance.id)

      assert Lease.release(grant, :drained, Repo) == :ok
      assert lease_row(instance.id).released_at
    end

    # Exercises the `repo \\ Repo` default, i.e. DoubleEntryLedger.Repo.Proxy.
    test "releases through the Repo.Proxy default when no repo is given", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)

      assert Lease.release(grant, :drained) == :ok
      assert lease_row(instance.id).released_at
    end
  end

  describe "with_grant/3" do
    test "runs the fun under the lock and returns its result", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)

      assert Lease.with_grant(grant, Repo, fn repo -> repo.in_transaction?() end) == true
    end

    test "a takeover during the body makes the final refresh raise and rolls the write back",
         %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)

      assert_raise Lease.LostError, fn ->
        Lease.with_grant(grant, Repo, fn repo ->
          repo.query!(
            """
            UPDATE #{@prefix}.command_queue_leases
            SET owner_id = 'b', fencing_token = 2
            WHERE instance_id = $1
            """,
            [Ecto.UUID.dump!(instance.id)]
          )

          repo.query!(
            "UPDATE #{@prefix}.instances SET description = 'written under the grant' WHERE id = $1",
            [Ecto.UUID.dump!(instance.id)]
          )
        end)
      end

      assert Repo.get!(Instance, instance.id).description == "some description"
      assert lease_row(instance.id).owner_id == "a"
    end

    test "raises BusyError while a probe holds the row past the timeout" do
      put_queue_config(lease_lock_timeout_ms: 200)
      probe = probe_connection()
      grant = committed_lease(probe, "a", 1)
      hold_lock_on_probe(probe, grant)

      assert_raise Lease.BusyError, fn -> Lease.with_grant(grant, Repo, fn _ -> :ok end) end
    end

    test "raises inside a caller's transaction", %{instance: instance} do
      grant = insert_lease(instance.id, "a", 1)

      assert_raise ArgumentError, fn ->
        Repo.transaction(fn -> Lease.with_grant(grant, Repo, fn _ -> :ok end) end)
      end
    end
  end

  describe "owner_update_query/2" do
    test "binds no application timestamp and uses clock_timestamp", %{instance: instance} do
      grant = %Grant{instance_id: instance.id, owner_id: "a", fencing_token: 1}

      {sql, params} =
        SQL.to_sql(:update_all, Repo, Lease.owner_update_query(grant, 20))

      assert sql =~ "clock_timestamp()"
      assert sql =~ ~s("released_at" IS NULL)
      refute Enum.any?(params, &match?(%DateTime{}, &1))
    end
  end

  describe "instance deletion" do
    test "deleting an instance deletes its lease row", %{instance: instance} do
      insert_lease(instance.id, "a", 1)
      assert lease_row(instance.id)

      {:ok, _deleted} = Repo.delete(instance)

      refute lease_row(instance.id)
    end
  end
end
