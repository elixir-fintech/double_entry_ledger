defmodule DoubleEntryLedger.CommandQueue.LeaseTest do
  use DoubleEntryLedger.RepoCase, async: false

  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.LeaseFixtures

  alias DoubleEntryLedger.CommandQueue.Lease
  alias DoubleEntryLedger.CommandQueue.Lease.Grant
  alias DoubleEntryLedger.Instance
  alias DoubleEntryLedger.Repo
  alias Ecto.Adapters.SQL

  @prefix DoubleEntryLedger.Config.schema_prefix()

  setup [:create_instance]

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
  # release test can prove the event fires after the commit rather than inside
  # it. Attached by name, not as a closure, to avoid telemetry's warning.
  def forward_release_event(event, measurements, metadata, %{test_pid: pid, ref: ref}) do
    payload = Map.put(metadata, :in_transaction, Repo.in_transaction?())
    send(pid, {:telemetry_event, ref, event, measurements, payload})
  end

  defp attach_release_telemetry do
    ref = make_ref()
    handler_id = "lease-released-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:double_entry_ledger, :lease, :released],
      &__MODULE__.forward_release_event/4,
      %{test_pid: self(), ref: ref}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
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
