defmodule DoubleEntryLedger.BatchProcessorRunBatchTest do
  @moduledoc """
  Integration tests for `BatchProcessor.run_batch/2` (Step 5 orchestrator).

  These tests cover the orchestrator's responsibilities:

    * Empty input fast-path (no DB activity)
    * Filter unsupported actions, surface as failures
    * Run the transformer to extract entries; transformer errors → failures
    * Preload accounts in one SELECT
    * Call the pure fold (`simulate_batch/2`)
    * Persist successes via the success-CTE writer + failures via the
      failure-UPDATE writer, both inside `Repo.transaction/1`
    * Retry on `Ecto.StaleEntryError` with bounded retries
    * Split-on-exhaustion (skipped — see notes)

  Each test is linear (no `if`/`case`/`cond`/recursion in test code).
  """

  use ExUnit.Case
  use DoubleEntryLedger.RepoCase
  import Mox

  import DoubleEntryLedger.{AccountFixtures, InstanceFixtures}

  alias DoubleEntryLedger.{
    BatchProcessor,
    Command,
    CommandQueueItem,
    Entry,
    JournalEvent,
    Repo,
    Transaction
  }

  alias DoubleEntryLedger.Command.TransactionData
  alias DoubleEntryLedger.Stores.CommandStore

  # ── helpers ──────────────────────────────────────────────────────

  defp count(schema), do: Repo.aggregate(schema, :count)

  defp reload_command_with_qi(id) do
    Command
    |> Repo.get!(id)
    |> Repo.preload(:command_queue_item)
  end

  # Build a balanced :create_transaction command on `(a1, a2)` with
  # the requested status. Uses unique idempotency keys so multiple
  # commands can be inserted in the same test.
  defp insert_balanced_command(inst, a1, a2, status, amount \\ 100) do
    attrs =
      DoubleEntryLedger.CommandFixtures.transaction_command_attrs(
        instance_address: inst.address,
        source: "src",
        source_idempk: "idempk-#{System.unique_integer([:positive])}",
        payload: %TransactionData{
          status: status,
          entries: [
            %{account_address: a1.address, amount: amount, currency: "EUR"},
            %{account_address: a2.address, amount: amount, currency: "EUR"}
          ]
        }
      )

    {:ok, command} = CommandStore.create(attrs)
    reload_command_with_qi(command.id)
  end

  # Build a command whose payload references an account address that
  # doesn't exist on the instance — the transformer will reject it
  # with `:no_accounts_found` or `:some_accounts_not_found`.
  defp insert_unknown_account_command(inst) do
    attrs =
      DoubleEntryLedger.CommandFixtures.transaction_command_attrs(
        instance_address: inst.address,
        source: "src",
        source_idempk: "idempk-bad-#{System.unique_integer([:positive])}",
        payload: %TransactionData{
          status: :posted,
          entries: [
            %{account_address: "account:nope_1", amount: 100, currency: "EUR"},
            %{account_address: "account:nope_2", amount: 100, currency: "EUR"}
          ]
        }
      )

    {:ok, command} = CommandStore.create(attrs)
    reload_command_with_qi(command.id)
  end

  # Build a command whose entries WILL be extracted but WILL fail the
  # fold's per-account validation: passing negative amounts on accounts
  # whose `negative_limit: 0` causes `compute_balance_changes/3` to
  # return `{:error, :available, _}`. The result is a failure with
  # reason `{:balance_change_error, :available, _}`.
  defp insert_overdraft_command(inst, a3, a4) do
    attrs =
      DoubleEntryLedger.CommandFixtures.transaction_command_attrs(
        instance_address: inst.address,
        source: "src",
        source_idempk: "idempk-overdraft-#{System.unique_integer([:positive])}",
        payload: %TransactionData{
          status: :posted,
          entries: [
            # a3 is debit-normal, negative_limit: 0 — `amount: -100`
            # triggers the credit-on-asset branch in the transformer,
            # which decreases its balance below zero and fails the fold.
            %{account_address: a3.address, amount: -100, currency: "EUR"},
            %{account_address: a4.address, amount: -100, currency: "EUR"}
          ]
        }
      )

    {:ok, command} = CommandStore.create(attrs)
    reload_command_with_qi(command.id)
  end

  # ── 1. empty input ───────────────────────────────────────────────

  test "empty input returns empty result with no DB activity" do
    tx_before = count(Transaction)
    je_before = count(JournalEvent)
    qi_before = count(CommandQueueItem)

    assert {:ok, %{successes: [], failures: []}} = BatchProcessor.run_batch([])

    assert count(Transaction) == tx_before
    assert count(JournalEvent) == je_before
    assert count(CommandQueueItem) == qi_before
  end

  describe "with persisted instance + accounts" do
    setup [:create_instance, :create_accounts]

    # ── 2. single successful :posted command ──────────────────────

    test "single successful :posted command persists tx, queue marked :processed, accounts updated",
         %{instance: inst, accounts: [a1, a2, _, _]} do
      command = insert_balanced_command(inst, a1, a2, :posted)

      assert {:ok, %{successes: [success], failures: []}} =
               BatchProcessor.run_batch([command])

      assert success.command_id == command.id

      tx = Repo.get!(Transaction, success.transaction_id)
      assert tx.status == :posted
      assert tx.instance_id == inst.id

      [je] = Repo.all(Ecto.Query.from(j in JournalEvent, where: j.command_id == ^command.id))
      assert je.transaction_id == tx.id

      qi = Repo.get!(CommandQueueItem, command.command_queue_item.id)
      assert qi.status == :processed
      assert qi.processing_completed_at != nil

      a1_after = Repo.get!(DoubleEntryLedger.Account, a1.id)
      a2_after = Repo.get!(DoubleEntryLedger.Account, a2.id)
      assert a1_after.posted.amount == 100
      assert a2_after.posted.amount == 100
      assert a1_after.lock_version == 2
      assert a2_after.lock_version == 2
    end

    # ── 3. three successful commands ──────────────────────────────

    test "three successful :posted commands persist three txs, mark three queue rows :processed",
         %{instance: inst, accounts: [a1, a2, _, _]} do
      c1 = insert_balanced_command(inst, a1, a2, :posted, 30)
      c2 = insert_balanced_command(inst, a1, a2, :posted, 40)
      c3 = insert_balanced_command(inst, a1, a2, :posted, 20)

      tx_before = count(Transaction)
      je_before = count(JournalEvent)

      assert {:ok, %{successes: successes, failures: []}} =
               BatchProcessor.run_batch([c1, c2, c3])

      assert length(successes) == 3
      assert count(Transaction) - tx_before == 3
      assert count(JournalEvent) - je_before == 3

      command_ids_returned = Enum.map(successes, & &1.command_id) |> Enum.sort()
      command_ids_input = Enum.map([c1, c2, c3], & &1.id) |> Enum.sort()
      assert command_ids_returned == command_ids_input

      qi_ids = Enum.map([c1, c2, c3], & &1.command_queue_item.id)

      processed_count =
        Repo.aggregate(
          Ecto.Query.from(q in CommandQueueItem,
            where: q.id in ^qi_ids and q.status == :processed
          ),
          :count,
          :id
        )

      assert processed_count == 3

      # Cumulative balances reflect all three commands.
      a1_after = Repo.get!(DoubleEntryLedger.Account, a1.id)
      assert a1_after.posted.amount == 90
      assert a1_after.lock_version == 4
    end

    # ── 4. mixed: one good, one bad-fold (overdraft) ──────────────

    test "two cmds, one fails fold (overdraft): 1 success persisted, 1 failure marked :failed",
         %{instance: inst, accounts: [a1, a2, a3, a4]} do
      good = insert_balanced_command(inst, a1, a2, :posted)
      bad = insert_overdraft_command(inst, a3, a4)

      retry_count_before = bad.command_queue_item.retry_count

      assert {:ok, %{successes: [success], failures: [failure]}} =
               BatchProcessor.run_batch([good, bad])

      assert success.command_id == good.id
      assert failure.command_id == bad.id

      # Reason carries the field+message from `compute_balance_changes`.
      assert {:balance_change_error, _field, _msg} = failure.reason

      # Good cmd persisted.
      tx = Repo.get!(Transaction, success.transaction_id)
      assert tx.status == :posted

      good_qi = Repo.get!(CommandQueueItem, good.command_queue_item.id)
      assert good_qi.status == :processed

      # Bad cmd: queue row :failed, retry_count UNCHANGED (legacy
      # semantics — the bump happens at claim time, not on failure).
      bad_qi = Repo.get!(CommandQueueItem, bad.command_queue_item.id)
      assert bad_qi.status == :failed
      assert bad_qi.retry_count == retry_count_before
      assert bad_qi.next_retry_after != nil

      # Failure error appended to errors array.
      assert length(bad_qi.errors) == 1
    end

    # ── 7. unsupported action ─────────────────────────────────────

    test "command with unsupported action yields {:unsupported_action, action} failure; siblings still process",
         %{instance: inst, accounts: [a1, a2, _, _]} do
      good = insert_balanced_command(inst, a1, a2, :posted)
      bogus = insert_balanced_command(inst, a1, a2, :posted, 50)

      # Mutate the in-memory struct so the orchestrator sees a
      # non-batchable action. The persisted DB row is left alone
      # (it's still :create_transaction in the DB) — the orchestrator
      # only inspects the in-memory struct passed to it. `:create_account`
      # is intentionally not batched (account commands stay on the
      # legacy single-cmd path) so it hits the catch-all clause.
      tampered =
        Map.put(
          bogus,
          :command_map,
          Map.put(bogus.command_map, :action, :create_account)
        )

      assert {:ok, %{successes: [success], failures: [failure]}} =
               BatchProcessor.run_batch([good, tampered])

      assert success.command_id == good.id
      assert failure.command_id == bogus.id
      assert failure.reason == {:unsupported_action, :create_account}

      # Good cmd persisted.
      tx = Repo.get!(Transaction, success.transaction_id)
      assert tx.status == :posted

      good_qi = Repo.get!(CommandQueueItem, good.command_queue_item.id)
      assert good_qi.status == :processed

      # The tampered cmd's queue row has been marked :failed by the
      # failure UPDATE writer (the orchestrator pushes
      # unsupported-action into the same failures pipeline).
      bogus_qi = Repo.get!(CommandQueueItem, bogus.command_queue_item.id)
      assert bogus_qi.status == :failed
      assert length(bogus_qi.errors) == 1
    end

    # ── 8. transformer error: unknown account ─────────────────────

    test "command referencing an unknown account yields {:transformer_error, _} failure; siblings still process",
         %{instance: inst, accounts: [a1, a2, _, _]} do
      good = insert_balanced_command(inst, a1, a2, :posted)
      bad = insert_unknown_account_command(inst)

      assert {:ok, %{successes: [success], failures: [failure]}} =
               BatchProcessor.run_batch([good, bad])

      assert success.command_id == good.id
      assert failure.command_id == bad.id
      assert {:transformer_error, reason} = failure.reason
      # AccountStore.get_accounts_by_instance_id returns one of these
      # for an unknown-address lookup.
      assert reason in [:no_accounts_found, :some_accounts_not_found]

      # Good cmd persisted.
      tx = Repo.get!(Transaction, success.transaction_id)
      assert tx.status == :posted

      good_qi = Repo.get!(CommandQueueItem, good.command_queue_item.id)
      assert good_qi.status == :processed

      # Bad cmd: queue row marked :failed.
      bad_qi = Repo.get!(CommandQueueItem, bad.command_queue_item.id)
      assert bad_qi.status == :failed
      assert length(bad_qi.errors) == 1
    end

    # ── empty entry-extraction edge: all-fail batch persists nothing ─

    test "all commands fail extraction: no transactions persisted, all queue rows :failed",
         %{instance: inst} do
      bad1 = insert_unknown_account_command(inst)
      bad2 = insert_unknown_account_command(inst)

      tx_before = count(Transaction)
      entry_before = count(Entry)

      assert {:ok, %{successes: [], failures: failures}} =
               BatchProcessor.run_batch([bad1, bad2])

      assert length(failures) == 2

      # No transactions or entries persisted.
      assert count(Transaction) == tx_before
      assert count(Entry) == entry_before

      # Both queue rows are :failed.
      qi1 = Repo.get!(CommandQueueItem, bad1.command_queue_item.id)
      qi2 = Repo.get!(CommandQueueItem, bad2.command_queue_item.id)
      assert qi1.status == :failed
      assert qi2.status == :failed
    end
  end

  # ── retry-path tests via MockRepo ───────────────────────────────────
  #
  # These tests inject `Ecto.StaleEntryError` by bumping account
  # `lock_version` rows out-of-band BEFORE the writer's accounts-UPDATE
  # CTE runs. The writer's row-count check then fails and raises
  # `Ecto.StaleEntryError`, which the orchestrator handles via retry +
  # split.
  #
  # `MockRepo` (Mox-defined for `RepoBehaviour`) is the repo argument
  # passed to `run_batch/2`. Stubs delegate every callback to the real
  # `Repo` by default; the `:all` stub for the account-preload SELECT
  # bumps lock_versions on a per-call counter held in an `Agent`.

  describe "retry path with MockRepo-injected stale lock_version" do
    setup [:create_instance, :create_accounts, :verify_on_exit!]

    # Default-stub MockRepo to delegate every behaviour callback to the
    # real Repo. Per-test overrides install side-effects on `:all` to
    # bump `lock_version` and force `Ecto.StaleEntryError`.
    setup do
      stub(DoubleEntryLedger.MockRepo, :transaction, fn fun ->
        Repo.transaction(fun)
      end)

      stub(DoubleEntryLedger.MockRepo, :all, fn query ->
        Repo.all(query)
      end)

      stub(DoubleEntryLedger.MockRepo, :query!, fn sql, params ->
        Repo.query!(sql, params)
      end)

      :ok
    end

    # Bump `lock_version` on each account in `accounts` by +1 in the
    # DB, *without* going through the standard `update_balances/2`
    # changeset. We just need a row-version mismatch — the rest of the
    # account state is irrelevant for the row-count check.
    defp bump_lock_versions!(accounts) do
      Enum.each(accounts, fn account ->
        account
        |> Ecto.Changeset.change(lock_version: account.lock_version + 1)
        |> Repo.update!()
      end)
    end

    # Install a `MockRepo.all` stub that, on each call, calls the real
    # `Repo.all`, then — if the call count is < `bump_until` — bumps
    # the `lock_version` of every returned account so the next write
    # path sees a stale row. The Agent persists the counter across
    # retries and across recursive `run_batch/2` calls.
    #
    # The orchestrator's only `repo.all` callsite is the account
    # preload (`from a in Account, where: a.id in ^ids`), so the
    # stub assumes the result is a list of `Account` structs.
    defp stub_all_with_bumps(agent, bump_until) do
      stub(DoubleEntryLedger.MockRepo, :all, fn query ->
        accounts = Repo.all(query)
        n = Agent.get_and_update(agent, fn c -> {c, c + 1} end)
        maybe_bump(accounts, n, bump_until)
        accounts
      end)
    end

    # Bump-or-skip dispatch via guard — keeps test stub-helpers free
    # of `if`/`case`/`cond`.
    defp maybe_bump(accounts, n, bump_until) when n < bump_until,
      do: bump_lock_versions!(accounts)

    defp maybe_bump(_accounts, _n, _bump_until), do: :ok

    # ── Scenario 1: stale resolved on first retry ──────────────────

    test "stale on first attempt, resolved on retry: batch succeeds with retry_count=1",
         %{instance: inst, accounts: [a1, a2, _, _]} do
      command = insert_balanced_command(inst, a1, a2, :posted)

      {:ok, agent} = Agent.start(fn -> 0 end)
      on_exit(fn -> Agent.stop(agent) end)

      # Bump only on the first preload call. Retry's preload call will
      # see the post-bump row, so the writer's CTE matches and succeeds.
      stub_all_with_bumps(agent, 1)

      # Capture the [:double_entry_ledger, :batch, :processed] event.
      ref = make_ref()
      handler_id = "stale-first-retry-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:double_entry_ledger, :batch, :processed],
        &__MODULE__.forward_telemetry/4,
        %{test_pid: self(), ref: ref}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %{successes: [success], failures: []}} =
               BatchProcessor.run_batch([command], DoubleEntryLedger.MockRepo)

      assert success.command_id == command.id

      # Telemetry confirms one retry happened.
      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :batch, :processed],
                      %{retry_count: 1, success_count: 1, failure_count: 0}, _meta}

      # DB state reflects the successful retry.
      tx = Repo.get!(Transaction, success.transaction_id)
      assert tx.status == :posted

      qi = Repo.get!(CommandQueueItem, command.command_queue_item.id)
      assert qi.status == :processed

      # Two preload calls expected: initial attempt + one retry.
      assert Agent.get(agent, & &1) == 2
    end

    # ── Scenario 2: persistent stale → retries exhaust → split ─────

    test "persistent stale exhausts retries on a 4-cmd batch: splits, halves succeed",
         %{instance: inst, accounts: [a1, a2, _, _]} do
      max_retries = Application.get_env(:double_entry_ledger, :max_batch_retries, 3)
      # Initial attempt + N retries on the original batch all see stale.
      bump_until = max_retries + 1

      c1 = insert_balanced_command(inst, a1, a2, :posted, 10)
      c2 = insert_balanced_command(inst, a1, a2, :posted, 20)
      c3 = insert_balanced_command(inst, a1, a2, :posted, 30)
      c4 = insert_balanced_command(inst, a1, a2, :posted, 40)

      {:ok, agent} = Agent.start(fn -> 0 end)
      on_exit(fn -> Agent.stop(agent) end)

      stub_all_with_bumps(agent, bump_until)

      tx_before = count(Transaction)

      assert {:ok, %{successes: successes, failures: []}} =
               BatchProcessor.run_batch([c1, c2, c3, c4], DoubleEntryLedger.MockRepo)

      assert length(successes) == 4
      assert count(Transaction) - tx_before == 4

      # The four commands must all be persisted regardless of order.
      command_ids_returned = Enum.map(successes, & &1.command_id) |> Enum.sort()
      command_ids_input = Enum.map([c1, c2, c3, c4], & &1.id) |> Enum.sort()
      assert command_ids_returned == command_ids_input

      # Total preload calls = `bump_until` (failed initial + retries on
      # the 4-cmd batch) + at least 2 more (one per split half). The
      # halves themselves may further split or retry, but the floor is
      # bump_until + 2.
      total_calls = Agent.get(agent, & &1)
      assert total_calls >= bump_until + 2

      qi_ids = Enum.map([c1, c2, c3, c4], & &1.command_queue_item.id)

      processed_count =
        Repo.aggregate(
          Ecto.Query.from(q in CommandQueueItem,
            where: q.id in ^qi_ids and q.status == :processed
          ),
          :count,
          :id
        )

      assert processed_count == 4
    end

    # ── Scenario 3: single cmd, persistent stale, propagates ───────

    test "persistent stale on a single-cmd batch propagates {:error, %Ecto.StaleEntryError{}}",
         %{instance: inst, accounts: [a1, a2, _, _]} do
      max_retries = Application.get_env(:double_entry_ledger, :max_batch_retries, 3)

      command = insert_balanced_command(inst, a1, a2, :posted)

      {:ok, agent} = Agent.start(fn -> 0 end)
      on_exit(fn -> Agent.stop(agent) end)

      # Always bump — every preload sees stale, every write fails,
      # retries exhaust, and split-or-give-up gives up (length 1).
      stub_all_with_bumps(agent, 1_000_000)

      tx_before = count(Transaction)
      entry_before = count(Entry)

      assert {:error, %Ecto.StaleEntryError{}} =
               BatchProcessor.run_batch([command], DoubleEntryLedger.MockRepo)

      # Initial attempt + max_retries retries = max_retries + 1 calls.
      assert Agent.get(agent, & &1) == max_retries + 1

      # No DB rows persisted: every write rolled back.
      assert count(Transaction) == tx_before
      assert count(Entry) == entry_before

      # Queue row still :pending (the initial state) — the failure-UPDATE
      # writer never ran because the success-CTE raised first inside the
      # transaction, rolling back any failures writes.
      qi = Repo.get!(CommandQueueItem, command.command_queue_item.id)
      assert qi.status == :pending
    end
  end

  # Telemetry forwarder — module function (not anonymous) to avoid the
  # `:telemetry.attach/4` performance-penalty warning.
  @doc false
  def forward_telemetry(event, measurements, metadata, %{test_pid: pid, ref: ref}) do
    send(pid, {:telemetry_event, ref, event, measurements, metadata})
  end

end
