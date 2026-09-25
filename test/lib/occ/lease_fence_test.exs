defmodule DoubleEntryLedger.Occ.LeaseFenceTest do
  @moduledoc """
  The lease fence around the *work*: the processing Multi, and the failure
  writes that happen after it rolled back.

  `Occ.Processor.build_multi/3` prepends `:lease_lock` and appends
  `:lease_refresh` to a transaction it does not own — the business Multi
  already exists and has named steps. That is deliberately NOT the shape the
  claim uses: `Scheduling.claim_batch_for_processing/3` owns its transaction
  through `Lease.with_grant/3`, which raises inside a caller's transaction so
  that no caller can nest it and break the lock-first rule.
  """
  use DoubleEntryLedger.RepoCase, async: false

  import ExUnit.CaptureLog
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.Command.AccountDataFixtures
  import DoubleEntryLedger.CommandFixtures
  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.LeaseFixtures

  alias DoubleEntryLedger.{Account, Command, CommandQueueItem, Repo, Transaction}
  alias DoubleEntryLedger.Command.AccountData
  alias DoubleEntryLedger.Command.ErrorMap
  alias DoubleEntryLedger.CommandQueue.{Lease, Scheduling}
  alias DoubleEntryLedger.Stores.CommandStore
  alias DoubleEntryLedger.Workers.CommandWorker

  alias DoubleEntryLedger.Workers.CommandWorker.{
    CreateAccountCommand,
    CreateTransactionCommand,
    UpdateAccountCommand
  }

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Association.NotLoaded

  defmodule RollingBackRepo do
    @moduledoc false
    # Real repo, except the final lease refresh fails, so the transaction
    # rolls back after the retry row was written inside it.
    alias DoubleEntryLedger.Repo

    def in_transaction?, do: Repo.in_transaction?()
    def transaction(fun), do: Repo.transaction(fun)
    def query!(sql, params), do: Repo.query!(sql, params)
    def update(changeset), do: Repo.update(changeset)

    def update_all(query, updates) do
      # Every owner update is the same statement; the first is lock!, the
      # second is refresh_locked!. Fail the second.
      calls = Process.get({__MODULE__, :calls}, 0)
      Process.put({__MODULE__, :calls}, calls + 1)
      fail_second(calls, query, updates)
    end

    # A hand-built Postgrex.Error needs the SQLSTATE *string* plus a severity:
    # `Postgrex.Error.exception/1` maps the string to the `:code` atom, and
    # `message/1` reads both. An atom leaves `:code` nil and raises when the
    # exception is formatted.
    defp fail_second(1, _query, _updates) do
      raise Postgrex.Error,
        postgres: %{code: "XX000", severity: "ERROR", message: "refresh failed"}
    end

    defp fail_second(_n, query, updates), do: Repo.update_all(query, updates)
  end

  setup [:create_instance, :create_accounts]

  describe "build_multi/3" do
    test "a command without a grant builds no lease step", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))

      multi = CreateTransactionCommand.build_multi(CreateTransactionCommand, command, Repo)

      refute Keyword.has_key?(Ecto.Multi.to_list(multi), :lease_lock)
      refute Keyword.has_key?(Ecto.Multi.to_list(multi), :lease_refresh)
    end

    # `Ecto.Multi.to_list/1` collapses every merged step into one `:merge`
    # entry, so only the first and last names are meaningful here — and they
    # are exactly what the fence is about.
    test "a command with a grant builds lease_lock first and lease_refresh last", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))
      grant = test_grant(ctx.instance.id)

      multi =
        CreateTransactionCommand.build_multi(
          CreateTransactionCommand,
          %{command | lease_grant: grant},
          Repo
        )

      names = Keyword.keys(Ecto.Multi.to_list(multi))

      assert List.first(names) == :lease_lock
      assert List.last(names) == :lease_refresh
    end

    # `Lease.lock_step/2` and `refresh_step/2` match `%Grant{}` and `nil` and
    # nothing else. A catch-all would turn the fence off for a malformed grant,
    # or for a processor id left behind by a pre-lease call site, and the
    # transaction would look fenced while writing unprotected.
    test "a lease_grant that is neither a grant nor nil raises", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))

      assert_raise FunctionClauseError, ~r/lock_step/, fn ->
        CreateTransactionCommand.build_multi(
          CreateTransactionCommand,
          %{command | lease_grant: "pre-lease-processor-id"},
          Repo
        )
      end
    end
  end

  # `nil` in `lease_grant` used to mean two different things: "never claimed"
  # and "claimed, but the grant was lost on the way to the write". The queue
  # row tells them apart — only `Scheduling.claim_batch_for_processing/3` puts
  # a row in `:processing`, and it only runs under a grant — so a `:processing`
  # command with no grant is a dropped fence and raises at every fence site.
  # Removing `InstanceMonitor`'s stale sweep left the synchronous command-map
  # path as the only legitimate unfenced writer, and it never claims.
  describe "a claimed command that lost its grant" do
    test "grant_for/1 raises for a :processing command with no grant", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))
      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, grant)

      assert_raise ArgumentError, ~r/must carry the grant/, fn ->
        Lease.grant_for(%{claimed | lease_grant: nil})
      end
    end

    test "grant_for/1 returns nil for an unclaimed command", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))

      assert Lease.grant_for(command) == nil
    end

    test "grant_for/1 returns the grant a claimed command carries", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))
      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, grant)

      assert Lease.grant_for(claimed) == grant
    end

    test "the processing Multi refuses to run and writes nothing", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))
      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, grant)

      assert_raise ArgumentError, ~r/must carry the grant/, fn ->
        CreateTransactionCommand.process(%{claimed | lease_grant: nil})
      end

      assert Repo.aggregate(Transaction, :count) == 0
    end

    test "a create_account command refuses to run and writes no account", ctx do
      {:ok, command} =
        CommandStore.create(account_command_attrs(%{instance_address: ctx.instance.address}))

      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, grant)

      assert_raise ArgumentError, ~r/must carry the grant/, fn ->
        CreateAccountCommand.process(%{claimed | lease_grant: nil})
      end

      refute Repo.get_by(Account, address: "account:1")
    end

    test "a failure write refuses to run and leaves the row :processing", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))
      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, grant)

      assert_raise ArgumentError, ~r/must carry the grant/, fn ->
        Scheduling.schedule_retry_with_reason(%{claimed | lease_grant: nil}, "boom", :failed)
      end

      assert Repo.get_by(CommandQueueItem, command_id: command.id).status == :processing
    end

    test "a batch write refuses to run and writes nothing", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))
      grant = test_grant(ctx.instance.id)
      [claimed] = Scheduling.claim_batch_for_processing([command], grant)

      assert_raise ArgumentError, ~r/must carry the grant/, fn ->
        DoubleEntryLedger.BatchProcessor.run_batch([%{claimed | lease_grant: nil}])
      end

      assert Repo.aggregate(Transaction, :count) == 0
    end

    # The final-timeout write is a queue-row writer of its own, reached only
    # after the OCC pipeline exhausts its retries, which makes it the site most
    # likely to be reworked by someone who does not know the rule is there.
    test "the OCC final-timeout write refuses to run and leaves the row :processing", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))
      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, grant)

      assert_raise ArgumentError, ~r/must carry the grant/, fn ->
        CreateTransactionCommand.retry(
          CreateTransactionCommand,
          %{claimed | lease_grant: nil},
          ErrorMap.create_error_map(claimed),
          0,
          Repo
        )
      end

      assert Repo.get_by(CommandQueueItem, command_id: command.id).status == :processing
    end

    test "an update_account command refuses to run and leaves the account alone", ctx do
      {:ok, create_command} =
        CommandStore.create(
          account_command_attrs(%{
            instance_address: ctx.instance.address,
            payload: account_data_attrs(%{name: "Old Name"})
          })
        )

      {:ok, _account, _} = CreateAccountCommand.process(create_command)
      {:ok, update_command} = CommandStore.create(update_account_attrs(ctx))
      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(update_command.id, grant)

      assert_raise ArgumentError, ~r/must carry the grant/, fn ->
        UpdateAccountCommand.process(%{claimed | lease_grant: nil})
      end

      assert Repo.get_by(Account, address: "account:1").name == "Old Name"
    end

    # The preload is what makes the rule decidable. Without it `grant_for/1`
    # cannot tell a claimed command from an unclaimed one, and a fence is not
    # something to skip on a "cannot tell".
    test "grant_for/1 raises when the queue item is not loaded", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))

      assert_raise ArgumentError, ~r/must carry the grant/, fn ->
        Lease.grant_for(%{command | lease_grant: nil, command_queue_item: %NotLoaded{}})
      end
    end

    test "an unclaimed command still processes unfenced", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))

      assert {:ok, %Transaction{}, _} = CreateTransactionCommand.process(command)

      assert Repo.get_by(CommandQueueItem, command_id: command.id).status == :processed
    end
  end

  describe "processing under a grant" do
    test "a claimed command processes under its grant", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))
      grant = test_grant(ctx.instance.id)

      assert {:ok, %Transaction{}, _} = CommandWorker.process_command_with_id(command.id, grant)

      assert Repo.get_by(CommandQueueItem, command_id: command.id).status == :processed
    end

    # Measured from a row read AFTER the claim: the claim refreshes the lease
    # too, so comparing against the row as `test_grant/1` left it would pass
    # even with no lease step in the processing Multi at all. `lock!` refreshes
    # as well, so this pins that the processing transaction touched the lease
    # at all; that `:lease_refresh` is the LAST step is pinned structurally by
    # the `build_multi/3` test above.
    test "the processing transaction updates the lease row", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))
      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, grant)
      before = lease_row(ctx.instance.id)

      assert {:ok, %Transaction{}, _} = CreateTransactionCommand.process(claimed)

      assert DateTime.compare(lease_row(ctx.instance.id).renewed_at, before.renewed_at) == :gt
    end

    test "a claimed command whose ledger moved raises LostError and writes nothing", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))
      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, grant)
      expire_lease(ctx.instance.id)
      _successor = test_grant(ctx.instance.id)

      assert_raise Lease.LostError, fn -> CreateTransactionCommand.process(claimed) end

      assert Repo.aggregate(Transaction, :count) == 0
    end

    # The takeover happens on the `[:command, :claim]` event, which fires after
    # the claim transaction committed and before processing starts — the only
    # deterministic way to lose the lease between the two.
    test "a lease lost between claim and write is reported as {:error, :lease_lost}", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))
      grant = test_grant(ctx.instance.id)
      take_over_ledger_on_claim(ctx.instance.id)

      assert {:error, :lease_lost} = CommandWorker.process_command_with_id(command.id, grant)

      assert Repo.aggregate(Transaction, :count) == 0
    end

    # The successor moved the lease before this grant could re-claim, so the
    # claim's own `lock!` loses and the worker never reaches the write.
    test "a lease already lost at claim time yields {:error, :lease_lost}", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))
      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, grant)
      expire_lease(ctx.instance.id)
      _successor = test_grant(ctx.instance.id)

      assert {:error, :lease_lost} = CommandWorker.process_command_with_id(claimed.id, grant)

      assert Repo.aggregate(Transaction, :count) == 0
    end
  end

  # The two account-command modules do not `use Occ.Processor` — they open
  # their own transaction, each containing a queue-row write — so they fence
  # through `Lease.lock_step/2` and `Lease.refresh_step/2` directly. Without
  # that, a node that had lost its ledger would still stamp `:processed` on
  # two of the four claimable actions.
  #
  # The "ledger moved" tests below prove the fence is present; they cannot
  # prove where it sits, because the transaction rolls back whatever the
  # order. Position is pinned by `write_sequence/2`, which is why each module
  # has both.
  describe "account commands under a grant" do
    test "a claimed create_account command whose ledger moved writes no account", ctx do
      {:ok, command} =
        CommandStore.create(account_command_attrs(%{instance_address: ctx.instance.address}))

      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, grant)
      expire_lease(ctx.instance.id)
      _successor = test_grant(ctx.instance.id)

      assert_raise Lease.LostError, fn -> CreateAccountCommand.process(claimed) end

      refute Repo.get_by(Account, address: "account:1")
    end

    test "a claimed update_account command whose ledger moved leaves the account alone", ctx do
      {:ok, create_command} =
        CommandStore.create(
          account_command_attrs(%{
            instance_address: ctx.instance.address,
            payload: account_data_attrs(%{name: "Old Name"})
          })
        )

      {:ok, _account, _} = CreateAccountCommand.process(create_command)
      {:ok, update_command} = CommandStore.create(update_account_attrs(ctx))
      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(update_command.id, grant)
      expire_lease(ctx.instance.id)
      _successor = test_grant(ctx.instance.id)

      assert_raise Lease.LostError, fn -> UpdateAccountCommand.process(claimed) end

      assert Repo.get_by(Account, address: "account:1").name == "Old Name"
    end

    test "a claimed create_account command under a live grant processes", ctx do
      {:ok, command} =
        CommandStore.create(account_command_attrs(%{instance_address: ctx.instance.address}))

      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, grant)

      assert {:ok, %Account{}, _} = CreateAccountCommand.process(claimed)

      assert Repo.get_by(CommandQueueItem, command_id: command.id).status == :processed
    end

    test "create_account locks the lease before its writes and refreshes it after", ctx do
      {:ok, command} =
        CommandStore.create(account_command_attrs(%{instance_address: ctx.instance.address}))

      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, grant)
      ref = attach_telemetry([:double_entry_ledger, :repo, :query])

      assert {:ok, %Account{}, _} = CreateAccountCommand.process(claimed)

      sequence = write_sequence(ref)
      assert List.first(sequence) == :lease
      assert List.last(sequence) == :lease
      assert lease_update_count(sequence) == 2
      assert {:write, "command_queue_items"} in sequence
    end

    test "update_account locks the lease before its writes and refreshes it after", ctx do
      {:ok, create_command} =
        CommandStore.create(account_command_attrs(%{instance_address: ctx.instance.address}))

      {:ok, _account, _} = CreateAccountCommand.process(create_command)
      {:ok, update_command} = CommandStore.create(update_account_attrs(ctx))
      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(update_command.id, grant)
      ref = attach_telemetry([:double_entry_ledger, :repo, :query])

      assert {:ok, %Account{}, _} = UpdateAccountCommand.process(claimed)

      sequence = write_sequence(ref)
      assert List.first(sequence) == :lease
      assert List.last(sequence) == :lease
      assert lease_update_count(sequence) == 2
      assert {:write, "command_queue_items"} in sequence
    end
  end

  # `retry/5` at zero attempts bypasses `build_multi/3` and writes the queue
  # row (`:occ_timeout`, plus whatever `handle_occ_final_timeout/2` adds) in a
  # transaction of its own, so it carries the fence separately. Called
  # directly because driving the OCC pipeline to exhaustion would say nothing
  # extra about the fence.
  describe "the OCC final-timeout write" do
    test "is fenced on the grant", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))
      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, grant)
      expire_lease(ctx.instance.id)
      _successor = test_grant(ctx.instance.id)

      assert_raise Lease.LostError, fn ->
        CreateTransactionCommand.retry(
          CreateTransactionCommand,
          claimed,
          ErrorMap.create_error_map(claimed),
          0,
          Repo
        )
      end

      # The successor's acquisition rescheduled the row; the timed-out write
      # never landed on top of it.
      assert Repo.get_by(CommandQueueItem, command_id: command.id).status == :failed
    end

    test "still lands under a live grant", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))
      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, grant)

      assert {:ok, _changes} =
               CreateTransactionCommand.retry(
                 CreateTransactionCommand,
                 claimed,
                 ErrorMap.create_error_map(claimed),
                 0,
                 Repo
               )

      assert Repo.get_by(CommandQueueItem, command_id: command.id).status == :occ_timeout
    end

    test "locks the lease before its writes and refreshes it after", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))
      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, grant)
      ref = attach_telemetry([:double_entry_ledger, :repo, :query])

      assert {:ok, _changes} =
               CreateTransactionCommand.retry(
                 CreateTransactionCommand,
                 claimed,
                 ErrorMap.create_error_map(claimed),
                 0,
                 Repo
               )

      sequence = write_sequence(ref)
      assert List.first(sequence) == :lease
      assert List.last(sequence) == :lease
      assert lease_update_count(sequence) == 2
      assert {:write, "command_queue_items"} in sequence
    end
  end

  describe "failure writes after a rollback" do
    # The third of the three fences that must fail loudly, beside
    # `Lease.lock_step/2` and `BatchProcessor.batch_grant/1`.
    test "a lease_grant that is neither a grant nor nil raises", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))
      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, grant)

      assert_raise FunctionClauseError, ~r/fenced_update/, fn ->
        Scheduling.schedule_retry_with_reason(
          %{claimed | lease_grant: "pre-lease-processor-id"},
          "boom",
          :failed
        )
      end
    end

    test "a retry write after a takeover is fenced out and does not overwrite the successor",
         ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))
      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, grant)
      expire_lease(ctx.instance.id)
      _successor = test_grant(ctx.instance.id)

      assert_raise Lease.LostError, fn ->
        Scheduling.schedule_retry_with_reason(claimed, "boom", :failed)
      end

      item = Repo.get_by(CommandQueueItem, command_id: command.id)
      assert item.status == :failed
      # Reloaded rows carry the error list as raw maps, not embedded structs.
      assert Map.fetch!(hd(item.errors), "message") =~ "orphaned"
    end

    test "a fenced retry write that rolls back emits no telemetry", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))
      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, grant)
      retry = attach_telemetry([:double_entry_ledger, :command, :retry])

      assert_raise Postgrex.Error, fn ->
        Scheduling.schedule_retry_with_reason(claimed, "boom", :failed, RollingBackRepo)
      end

      refute_receive {:telemetry_event, ^retry, _, _, _}, 100
      assert Repo.get_by(CommandQueueItem, command_id: command.id).status == :processing
    end

    test "a retry write after a rollback under a live grant lands", ctx do
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))
      grant = test_grant(ctx.instance.id)
      {:ok, claimed} = Scheduling.claim_command_for_processing(command.id, grant)

      assert {:error, %Command{}} =
               Scheduling.schedule_retry_with_reason(claimed, "boom", :failed)

      assert Repo.get_by(CommandQueueItem, command_id: command.id).status == :failed
    end
  end

  # Contention, as opposed to loss. The lease row lives outside the sandbox so
  # a second connection can hold it, and the worker call runs unboxed so its
  # claim really commits and releases the lease row lock — inside the sandbox
  # that lock would be held by the test's own connection for the rest of the
  # test and nothing could ever contend with it.
  describe "lease contention during the write" do
    test "a probe taking the lease row after the claim yields {:error, :lease_busy}" do
      put_queue_config(lease_lock_timeout_ms: 200)
      probe = probe_connection()
      grant = committed_lease(probe, "holder", 1)
      command_id = committed_command(probe, grant.instance_id)
      hold_lease_row_on_claim(probe, grant)

      assert {:error, :lease_busy} =
               Sandbox.unboxed_run(Repo, fn ->
                 CommandWorker.process_command_with_id(command_id, grant)
               end)
    end
  end

  # `CommandWorker.process_command_with_id/2`'s manual path is the first caller
  # of `emit_acquisition_events/3`, so the two properties it needs hold here.
  describe "emit_acquisition_events/3" do
    test "raises ArgumentError inside a caller's transaction", ctx do
      grant = test_grant(ctx.instance.id)
      info = %{previous_owner_id: nil, takeover: false, orphans: []}

      assert_raise ArgumentError, fn ->
        Repo.transaction(fn -> Lease.emit_acquisition_events(grant, info) end)
      end
    end

    # Runs AFTER the acquisition committed: a raise here would abort the caller
    # while the database already records it as the owner, stranding the ledger
    # for a full TTL. An orphan with no recorded error is enough to raise
    # inside the loop.
    test "a raise while reporting is swallowed and the acquired event still lands", ctx do
      ref = attach_telemetry([:double_entry_ledger, :lease, :acquired])
      grant = test_grant(ctx.instance.id)
      {:ok, command} = CommandStore.create(create_transaction_command_map(ctx, :posted))
      orphan = %{command | command_queue_item: %{command.command_queue_item | errors: []}}
      info = %{previous_owner_id: nil, takeover: false, orphans: [orphan]}

      log = capture_log(fn -> assert :ok = Lease.emit_acquisition_events(grant, info) end)

      assert log =~ "the lease is held and processing continues"
      assert_receive {:telemetry_event, ^ref, _, _, _}
    end
  end

  defp update_account_attrs(%{instance: instance}) do
    account_command_attrs(%{
      action: :update_account,
      instance_address: instance.address,
      account_address: "account:1",
      source: "lease-fence",
      payload: %AccountData{name: "New Name"}
    })
  end

  defp hold_lease_row_on_claim(probe, grant) do
    handler_id = "lease-fence-hold-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:double_entry_ledger, :command, :claim],
      &__MODULE__.hold_lease_row/4,
      {probe, grant}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  @doc false
  def hold_lease_row(_event, _measurements, _metadata, {probe, grant}) do
    hold_lock_on_probe(probe, grant)
  end

  defp take_over_ledger_on_claim(instance_id) do
    handler_id = "lease-fence-takeover-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:double_entry_ledger, :command, :claim],
      &__MODULE__.take_over_ledger/4,
      instance_id
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  @doc false
  def take_over_ledger(_event, _measurements, _metadata, instance_id) do
    expire_lease(instance_id)
    {:ok, _grant, _info} = Lease.acquire(instance_id, "successor:" <> Ecto.UUID.generate())
    :ok
  end
end
