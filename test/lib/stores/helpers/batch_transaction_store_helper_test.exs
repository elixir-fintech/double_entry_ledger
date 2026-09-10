defmodule DoubleEntryLedger.Stores.BatchTransactionStoreHelperTest do
  @moduledoc """
  Integration tests for the success-CTE writer
  (`BatchTransactionStoreHelper.write_successes/3`).

  Each test:
    * Sets up a real persisted instance, accounts, and commands using the
      shared fixtures.
    * Builds a `write_plan` map (the `BatchProcessor.simulate_batch/2`
      output shape) by hand — we test the writer in isolation.
    * Calls `write_successes/3` (wrapped in `Repo.transaction/1` only
      where stale-version recovery is being asserted).
    * Asserts the resulting DB state row-for-row.

  All tests are linear (no `if`/`case`/`cond`/recursion).
  """

  use ExUnit.Case
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.{AccountFixtures, InstanceFixtures}

  # `Scheduling.calculate_retry_delay/1` for retry_count 0: base delay plus a
  # jitter of 1..(base/10 + 1) seconds.
  @base_retry_delay Application.compile_env(:double_entry_ledger, :command_queue, [])
                    |> Keyword.get(:base_retry_delay, 30)
  @first_retry_delay_range @base_retry_delay..(@base_retry_delay + div(@base_retry_delay, 10) + 1)

  alias DoubleEntryLedger.{
    Account,
    BalanceHistoryEntry,
    Command,
    CommandQueueItem,
    Entry,
    JournalEvent,
    PendingTransactionLookup,
    Repo,
    Transaction
  }

  alias DoubleEntryLedger.Stores.BatchTransactionStoreHelper
  alias DoubleEntryLedger.CommandQueue.{OwnershipError, Scheduling}

  # ── helpers ──────────────────────────────────────────────────────

  # Reload an account from the DB.
  defp reload_account(id), do: Repo.get!(Account, id)

  # Build a single fold-style success record from a persisted command and
  # the running in-memory accounts map. Returns
  # {success_record, advanced_accounts}.
  defp success_for(command, accounts, status, entries_spec) do
    transaction_id = Ecto.UUID.generate()

    {entries_with_snap, advanced} =
      Enum.reduce(entries_spec, {[], accounts}, fn {account_id, type, amount}, {acc, accs} ->
        account = Map.fetch!(accs, account_id)

        entry = %{
          id: Ecto.UUID.generate(),
          account_id: account_id,
          type: type,
          value: Money.new(amount, :EUR)
        }

        {:ok, change} = Account.compute_balance_changes(account, entry, status)
        next_account = Account.apply_balance_change(account, change)
        snap = Map.put(entry, :account_after, next_account)

        {[snap | acc], Map.put(accs, account_id, next_account)}
      end)

    success = %{
      command: command,
      action: :create_transaction,
      transaction_id: transaction_id,
      journal_event_id: Ecto.UUID.generate(),
      status: status,
      entries: Enum.reverse(entries_with_snap)
    }

    {success, advanced}
  end

  # Build a `merged_accounts` map matching what `BatchProcessor` produces:
  # only contains accounts whose lock_version advanced.
  defp merged_accounts(initial_accounts, advanced_accounts) do
    Enum.reduce(advanced_accounts, %{}, fn {id, advanced}, acc ->
      old_lv = Map.fetch!(initial_accounts, id).lock_version
      new_lv = advanced.lock_version

      Map.put(
        acc,
        id,
        %{
          posted: advanced.posted,
          pending: advanced.pending,
          available: advanced.available,
          old_lock_version: old_lv,
          new_lock_version: new_lv
        }
      )
      |> Map.reject(fn {_id, m} -> m.old_lock_version == m.new_lock_version end)
    end)
  end

  # Reload a command with `command_queue_item` preloaded (the writer
  # reads `command.command_queue_item.id`).
  defp reload_command_with_qi(id) do
    Command
    |> Repo.get!(id)
    |> Repo.preload(:command_queue_item)
  end

  defp accounts_map(accounts), do: Map.new(accounts, &{&1.id, &1})

  defp count(schema), do: Repo.aggregate(schema, :count)

  # Seed a pending transaction via write_successes (create path) so
  # subsequent B3 update tests have a real persisted tx + entries +
  # advanced accounts + lookup row to act on.
  #
  # Returns `{create_success, updated_accounts}` where `create_success`
  # carries the tx_id + entry ids needed to construct an update
  # success_record, and `updated_accounts` is a map from account_id to
  # the post-seed Account struct (with pending balance populated).
  defp seed_pending_transaction(ctx, entries_spec) do
    %{accounts: accounts} = ctx
    [command] = insert_commands(ctx, 1, :pending)

    account_ids = Enum.map(entries_spec, fn {id, _t, _a} -> id end)
    initial = accounts_map(Enum.filter(accounts, &(&1.id in account_ids)))

    {success, advanced} = success_for(command, initial, :pending, entries_spec)

    write_plan = %{
      successes: [success],
      failures: [],
      merged_accounts: merged_accounts(initial, advanced)
    }

    :ok = BatchTransactionStoreHelper.write_successes(write_plan, Repo, DateTime.utc_now())

    reloaded = Map.new(account_ids, &{&1, reload_account(&1)})
    {success, reloaded}
  end

  # Build a fold-style update success_record that references the
  # transaction_id + entry ids from a prior create_success. Mirrors what
  # `enrich_updates_with_existing/2` (B4) will produce.
  #
  # `entries_spec` = `[{account_id, type, new_amount, old_amount}]` in the
  # same order as `create_success.entries`. Each new entry reuses the
  # corresponding existing entry's id.
  defp update_success_for(
         create_success,
         update_command,
         transition,
         new_status,
         entries_spec,
         current_accounts
       ) do
    {entries_with_snap, advanced} =
      create_success.entries
      |> Enum.zip(entries_spec)
      |> Enum.reduce({[], current_accounts}, fn {orig_entry, {acc_id, type, new_amt, old_amt}},
                                                {acc, accs} ->
        account = Map.fetch!(accs, acc_id)

        entry = %{
          id: orig_entry.id,
          account_id: acc_id,
          type: type,
          value: Money.new(new_amt, :EUR),
          old_value: Money.new(old_amt, :EUR)
        }

        {:ok, change} = Account.compute_balance_changes(account, entry, transition)
        next_account = Account.apply_balance_change(account, change)
        snap = Map.put(entry, :account_after, next_account)

        {[snap | acc], Map.put(accs, acc_id, next_account)}
      end)

    success = %{
      command: update_command,
      action: :update_transaction,
      transaction_id: create_success.transaction_id,
      journal_event_id: Ecto.UUID.generate(),
      status: new_status,
      transition: transition,
      entries: Enum.reverse(entries_with_snap)
    }

    {success, advanced}
  end

  # Insert a single :update_transaction command (with command_queue_item
  # preloaded). Defaults `source` to "src" and `source_idempk` to a
  # unique string; the lookup-filter test overrides these via `opts` to
  # use the create's keys.
  defp insert_update_cmd_with_qi(ctx, status, amount, opts \\ []) do
    %{instance: inst, accounts: [a1, a2, _, _]} = ctx
    source = Keyword.get(opts, :source, "src")
    source_idempk = Keyword.get(opts, :source_idempk, "u-#{System.unique_integer([:positive])}")

    {:ok, cmd} =
      DoubleEntryLedger.CommandFixtures.new_update_transaction_command(
        source,
        source_idempk,
        inst.address,
        status,
        [
          %{account_address: a1.address, amount: amount, currency: "EUR"},
          %{account_address: a2.address, amount: amount, currency: "EUR"}
        ]
      )

    reload_command_with_qi(cmd.id)
  end

  # Insert exactly N create_transaction commands with unique idempotency
  # keys, returning a list in claim order.
  defp insert_commands(ctx, n, status) do
    %{instance: inst, accounts: [a1, a2, _, _]} = ctx

    Enum.map(1..n, fn i ->
      cmd_attrs =
        DoubleEntryLedger.CommandFixtures.transaction_command_attrs(
          instance_address: inst.address,
          source: "src",
          source_idempk: "idempk-#{i}-#{System.unique_integer([:positive])}",
          payload: %DoubleEntryLedger.Command.TransactionData{
            status: status,
            entries: [
              %{account_address: a1.address, amount: 100, currency: "EUR"},
              %{account_address: a2.address, amount: 100, currency: "EUR"}
            ]
          }
        )

      {:ok, command} = DoubleEntryLedger.Stores.CommandStore.create(cmd_attrs)
      reload_command_with_qi(command.id)
    end)
  end

  # ── 1. single-command :posted batch ──────────────────────────────

  describe "write_successes/3" do
    setup [:create_instance, :create_accounts]

    test "rejects a success written by a stale batch owner", %{accounts: [a1, a2, _, _]} = ctx do
      [command] = insert_commands(ctx, 1, :posted)

      [claimed_by_old_owner] =
        Scheduling.claim_batch_for_processing([command], "old-batch-owner")

      claimed_by_old_owner.command_queue_item
      |> Ecto.Changeset.change(processor_id: "new-batch-owner")
      |> Ecto.Changeset.optimistic_lock(:processor_version)
      |> Repo.update!()

      initial = accounts_map([a1, a2])

      {success, advanced} =
        success_for(claimed_by_old_owner, initial, :posted, [
          {a1.id, :debit, 100},
          {a2.id, :credit, 100}
        ])

      write_plan = %{
        successes: [success],
        failures: [],
        merged_accounts: merged_accounts(initial, advanced)
      }

      assert_raise OwnershipError, fn ->
        Repo.transaction(fn ->
          BatchTransactionStoreHelper.write_successes(write_plan, Repo, DateTime.utc_now())
        end)
      end

      current = reload_qi(command.command_queue_item.id)
      assert current.status == :processing
      assert current.processor_id == "new-batch-owner"
      assert reload_account(a1.id).available == a1.available
    end

    test "writes accounts.available + balance_history_entries.available above int4 range (post-v7 bigint regression)",
         %{instance: inst} do
      # 5_000_000_000 > INT_MAX (~2.14B). The accounts.available and
      # BHE.available columns were widened to bigint in migration v7
      # specifically to handle this range; before the fix the writer's
      # `::integer` casts truncated/erred. With `::bigint` the value
      # round-trips intact.
      big = 5_000_000_000

      a1 =
        DoubleEntryLedger.AccountFixtures.account_fixture(
          instance_id: inst.id,
          type: :asset,
          normal_balance: :debit,
          posted: %{amount: big, debit: big, credit: 0},
          available: big
        )

      a2 =
        DoubleEntryLedger.AccountFixtures.account_fixture(
          instance_id: inst.id,
          type: :liability,
          normal_balance: :credit,
          posted: %{amount: big, debit: 0, credit: big},
          available: big
        )

      [command] = insert_commands(%{instance: inst, accounts: [a1, a2, a1, a2]}, 1, :posted)
      now = DateTime.utc_now()
      initial_accounts = accounts_map([a1, a2])

      {success, advanced} =
        success_for(command, initial_accounts, :posted, [
          {a1.id, :debit, 10},
          {a2.id, :credit, 10}
        ])

      write_plan = %{
        successes: [success],
        failures: [],
        merged_accounts: merged_accounts(initial_accounts, advanced)
      }

      :ok = BatchTransactionStoreHelper.write_successes(write_plan, Repo, now)

      a1_after = reload_account(a1.id)
      assert a1_after.posted.amount == big + 10
      # available = posted.amount - pending.credit (debit-normal)
      assert a1_after.available == big + 10

      a2_after = reload_account(a2.id)
      assert a2_after.posted.amount == big + 10
      # available = posted.amount - pending.debit (credit-normal)
      assert a2_after.available == big + 10

      # BHE rows persisted with the bigint available
      bhe_avails =
        Repo.all(
          Ecto.Query.from(b in BalanceHistoryEntry,
            where: b.account_id in ^[a1.id, a2.id],
            select: b.available
          )
        )

      assert bhe_avails == [big + 10, big + 10]
    end

    test "single-command :posted batch persists tx, entries, BHEs, journal_event, account update, queue mark",
         %{instance: inst, accounts: [a1, a2, _, _]} = ctx do
      [command] = insert_commands(ctx, 1, :posted)
      now = DateTime.utc_now()

      initial_accounts = accounts_map([a1, a2])

      {success, advanced} =
        success_for(command, initial_accounts, :posted, [
          {a1.id, :debit, 100},
          {a2.id, :credit, 100}
        ])

      write_plan = %{
        successes: [success],
        failures: [],
        merged_accounts: merged_accounts(initial_accounts, advanced)
      }

      :ok = BatchTransactionStoreHelper.write_successes(write_plan, Repo, now)

      # Transaction inserted with the generated id
      tx = Repo.get!(Transaction, success.transaction_id)
      assert tx.status == :posted
      assert tx.instance_id == inst.id
      assert DateTime.compare(tx.posted_at, now) == :eq

      # Two entries persisted
      entries = Repo.all(Ecto.Query.from(e in Entry, where: e.transaction_id == ^tx.id))
      assert length(entries) == 2
      entry_ids = Enum.map(success.entries, & &1.id) |> Enum.sort()
      assert Enum.map(entries, & &1.id) |> Enum.sort() == entry_ids

      # Two BHEs (one per entry)
      bhe_count =
        Repo.aggregate(
          Ecto.Query.from(b in BalanceHistoryEntry, where: b.entry_id in ^entry_ids),
          :count,
          :id
        )

      assert bhe_count == 2

      # One journal_event with the right command_id and transaction_id
      [je] = Repo.all(Ecto.Query.from(j in JournalEvent, where: j.command_id == ^command.id))
      assert je.transaction_id == tx.id
      assert je.instance_id == inst.id

      # Accounts updated (lock_version bumped, balances reflect entry)
      a1_after = reload_account(a1.id)
      a2_after = reload_account(a2.id)
      assert a1_after.lock_version == 2
      assert a2_after.lock_version == 2
      assert a1_after.posted.amount == 100
      assert a2_after.posted.amount == 100

      # Queue item marked :processed and the ownership token advanced.
      qi = Repo.get!(CommandQueueItem, command.command_queue_item.id)
      assert qi.status == :processed
      assert qi.processing_completed_at != nil
      assert qi.processor_version == command.command_queue_item.processor_version + 1

      # No pending_transaction_lookup row created for :posted
      assert Repo.get_by(PendingTransactionLookup, command_id: command.id) == nil
    end

    # ── 2. three-command :posted batch, no overlap ─────────────────

    test "three-command :posted batch (no overlap) persists 3 txs, 6 entries, 6 BHEs, 3 journal_events, 3 queue marks",
         %{instance: inst} = ctx do
      # We need 6 distinct accounts for true no-overlap — fixtures give
      # us 4. Add 2 more.
      a1 = account_fixture(instance_id: inst.id, type: :asset, normal_balance: :debit)
      a2 = account_fixture(instance_id: inst.id, type: :liability, normal_balance: :credit)
      a3 = account_fixture(instance_id: inst.id, type: :asset, normal_balance: :debit)
      a4 = account_fixture(instance_id: inst.id, type: :liability, normal_balance: :credit)
      a5 = account_fixture(instance_id: inst.id, type: :asset, normal_balance: :debit)
      a6 = account_fixture(instance_id: inst.id, type: :liability, normal_balance: :credit)

      [c1, c2, c3] = insert_commands(ctx, 3, :posted)
      now = DateTime.utc_now()

      initial = accounts_map([a1, a2, a3, a4, a5, a6])

      {s1, accs1} =
        success_for(c1, initial, :posted, [{a1.id, :debit, 100}, {a2.id, :credit, 100}])

      {s2, accs2} =
        success_for(c2, accs1, :posted, [{a3.id, :debit, 75}, {a4.id, :credit, 75}])

      {s3, accs3} =
        success_for(c3, accs2, :posted, [{a5.id, :debit, 50}, {a6.id, :credit, 50}])

      write_plan = %{
        successes: [s1, s2, s3],
        failures: [],
        merged_accounts: merged_accounts(initial, accs3)
      }

      tx_count_before = count(Transaction)
      entry_count_before = count(Entry)
      bhe_count_before = count(BalanceHistoryEntry)
      je_count_before = count(JournalEvent)

      :ok = BatchTransactionStoreHelper.write_successes(write_plan, Repo, now)

      assert count(Transaction) - tx_count_before == 3
      assert count(Entry) - entry_count_before == 6
      assert count(BalanceHistoryEntry) - bhe_count_before == 6
      assert count(JournalEvent) - je_count_before == 3

      # Accounts updated
      Enum.each([a1, a2, a3, a4, a5, a6], fn a ->
        a_after = reload_account(a.id)
        assert a_after.lock_version == 2
      end)

      # Queue items marked
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
    end

    # ── 3. three-command :pending batch (lookup upsert) ──────────────

    test "three-command :pending batch upserts pending_transaction_lookup rows correctly",
         %{accounts: [a1, a2, _, _]} = ctx do
      [c1, c2, c3] = insert_commands(ctx, 3, :pending)
      now = DateTime.utc_now()

      initial = accounts_map([a1, a2])

      {s1, accs1} =
        success_for(c1, initial, :pending, [{a1.id, :debit, 100}, {a2.id, :credit, 100}])

      {s2, accs2} =
        success_for(c2, accs1, :pending, [{a1.id, :debit, 50}, {a2.id, :credit, 50}])

      {s3, accs3} =
        success_for(c3, accs2, :pending, [{a1.id, :debit, 25}, {a2.id, :credit, 25}])

      write_plan = %{
        successes: [s1, s2, s3],
        failures: [],
        merged_accounts: merged_accounts(initial, accs3)
      }

      :ok = BatchTransactionStoreHelper.write_successes(write_plan, Repo, now)

      # Each pending command's lookup row exists (CommandStore.create
      # already inserted them on enqueue); the writer's upsert filled in
      # transaction_id and journal_event_id.
      [lk1, lk2, lk3] =
        Enum.map([c1, c2, c3], fn c ->
          Repo.get_by!(PendingTransactionLookup, command_id: c.id)
        end)

      assert lk1.transaction_id == s1.transaction_id
      assert lk2.transaction_id == s2.transaction_id
      assert lk3.transaction_id == s3.transaction_id

      assert lk1.journal_event_id != nil
      assert lk2.journal_event_id != nil
      assert lk3.journal_event_id != nil

      # Pending balances should reflect cumulative effect (a1 ran 3
      # debits totaling 175 against pending).
      a1_after = reload_account(a1.id)
      assert a1_after.pending.debit == 175
      assert a1_after.lock_version == 4
    end

    # ── 4. two cmds touching same account ────────────────────────────

    test "two cmds touching same account: merged_accounts has new_lv = old + 2; per-entry BHE snapshots reflect intermediate states",
         %{accounts: [a1, a2, _, _]} = ctx do
      [c1, c2] = insert_commands(ctx, 2, :posted)
      now = DateTime.utc_now()

      initial = accounts_map([a1, a2])

      {s1, accs1} =
        success_for(c1, initial, :posted, [{a1.id, :debit, 60}, {a2.id, :credit, 60}])

      {s2, accs2} =
        success_for(c2, accs1, :posted, [{a1.id, :debit, 40}, {a2.id, :credit, 40}])

      mas = merged_accounts(initial, accs2)
      assert mas[a1.id].new_lock_version == initial[a1.id].lock_version + 2
      assert mas[a2.id].new_lock_version == initial[a2.id].lock_version + 2

      write_plan = %{
        successes: [s1, s2],
        failures: [],
        merged_accounts: mas
      }

      :ok = BatchTransactionStoreHelper.write_successes(write_plan, Repo, now)

      # Final account state matches post-batch values
      a1_after = reload_account(a1.id)
      a2_after = reload_account(a2.id)
      assert a1_after.posted.amount == 100
      assert a1_after.posted.debit == 100
      assert a2_after.posted.amount == 100
      assert a2_after.posted.credit == 100
      assert a1_after.lock_version == initial[a1.id].lock_version + 2

      # Per-entry BHE snapshots: 4 entries → 4 BHE rows. The first
      # BHE for a1 captures the post-cmd-1 state (debit=60,amount=60),
      # the second captures the post-cmd-2 state (debit=100,amount=100).
      a1_entry_ids =
        [s1.entries, s2.entries]
        |> List.flatten()
        |> Enum.filter(&(&1.account_id == a1.id))
        |> Enum.map(& &1.id)

      a1_bhes =
        Repo.all(
          Ecto.Query.from(b in BalanceHistoryEntry,
            where: b.entry_id in ^a1_entry_ids,
            order_by: [asc: b.inserted_at, asc: b.id]
          )
        )

      assert length(a1_bhes) == 2

      amounts =
        a1_bhes
        |> Enum.map(& &1.posted.amount)
        |> Enum.sort()

      assert amounts == [60, 100]
    end

    # ── 5. stale lock_version → raises Ecto.StaleEntryError ─────────

    test "stale lock_version raises Ecto.StaleEntryError and rolls back inside Repo.transaction/1",
         %{accounts: [a1, a2, _, _]} = ctx do
      [command] = insert_commands(ctx, 1, :posted)
      now = DateTime.utc_now()

      initial = accounts_map([a1, a2])

      {success, advanced} =
        success_for(command, initial, :posted, [
          {a1.id, :debit, 100},
          {a2.id, :credit, 100}
        ])

      mas = merged_accounts(initial, advanced)
      # Tamper: bump old_lock_version on a1 to a value that won't match
      # the actual DB row.
      tampered = put_in(mas[a1.id].old_lock_version, 999)

      write_plan = %{
        successes: [success],
        failures: [],
        merged_accounts: tampered
      }

      tx_before = count(Transaction)
      entry_before = count(Entry)
      bhe_before = count(BalanceHistoryEntry)
      je_before = count(JournalEvent)

      assert_raise Ecto.StaleEntryError, fn ->
        Repo.transaction(fn ->
          BatchTransactionStoreHelper.write_successes(write_plan, Repo, now)
        end)
      end

      # Nothing persisted: counts unchanged.
      assert count(Transaction) == tx_before
      assert count(Entry) == entry_before
      assert count(BalanceHistoryEntry) == bhe_before
      assert count(JournalEvent) == je_before

      # The accounts row hasn't been bumped either.
      assert reload_account(a1.id).lock_version == initial[a1.id].lock_version
    end

    # ── 6. empty successes returns :ok with no SQL ───────────────────

    test "empty successes returns :ok without raising or writing", _ctx do
      now = DateTime.utc_now()

      tx_before = count(Transaction)
      qi_before = count(CommandQueueItem)

      assert :ok ==
               BatchTransactionStoreHelper.write_successes(
                 %{successes: [], failures: [], merged_accounts: %{}},
                 Repo,
                 now
               )

      assert count(Transaction) == tx_before
      assert count(CommandQueueItem) == qi_before
    end

    # ── 7. all :posted: no pending_transaction_lookup rows written ───

    test "all-:posted batch leaves pending_transaction_lookup count unchanged",
         %{accounts: [a1, a2, _, _]} = ctx do
      [c1, c2] = insert_commands(ctx, 2, :posted)
      now = DateTime.utc_now()

      initial = accounts_map([a1, a2])

      {s1, accs1} =
        success_for(c1, initial, :posted, [{a1.id, :debit, 30}, {a2.id, :credit, 30}])

      {s2, accs2} =
        success_for(c2, accs1, :posted, [{a1.id, :debit, 20}, {a2.id, :credit, 20}])

      write_plan = %{
        successes: [s1, s2],
        failures: [],
        merged_accounts: merged_accounts(initial, accs2)
      }

      lookup_before = count(PendingTransactionLookup)

      :ok = BatchTransactionStoreHelper.write_successes(write_plan, Repo, now)

      assert count(PendingTransactionLookup) == lookup_before
    end

    # ── 8. processor_version advanced in success path ─────────────

    test "write_successes/3 advances processor_version",
         %{accounts: [a1, a2, _, _]} = ctx do
      [command] = insert_commands(ctx, 1, :posted)
      now = DateTime.utc_now()

      version_before = command.command_queue_item.processor_version

      initial = accounts_map([a1, a2])

      {success, advanced} =
        success_for(command, initial, :posted, [
          {a1.id, :debit, 100},
          {a2.id, :credit, 100}
        ])

      write_plan = %{
        successes: [success],
        failures: [],
        merged_accounts: merged_accounts(initial, advanced)
      }

      :ok = BatchTransactionStoreHelper.write_successes(write_plan, Repo, now)

      qi = reload_qi(command.command_queue_item.id)
      assert qi.processor_version == version_before + 1
    end

    # ── 9. fresh INSERT branch of pending_transaction_lookup upsert ───

    test "write_successes/3 inserts a fresh pending_transaction_lookup row when none exists (no-conflict INSERT branch)",
         %{accounts: [a1, a2, _, _]} = ctx do
      [command] = insert_commands(ctx, 1, :pending)
      now = DateTime.utc_now()

      # `CommandStore.create` already inserted a lookup row at enqueue
      # time; remove it so the writer's `INSERT ... ON CONFLICT DO UPDATE`
      # exercises the no-conflict INSERT branch.
      {1, _} =
        Repo.delete_all(
          Ecto.Query.from(l in PendingTransactionLookup, where: l.command_id == ^command.id)
        )

      lookup_before = count(PendingTransactionLookup)

      initial = accounts_map([a1, a2])

      {success, advanced} =
        success_for(command, initial, :pending, [
          {a1.id, :debit, 100},
          {a2.id, :credit, 100}
        ])

      write_plan = %{
        successes: [success],
        failures: [],
        merged_accounts: merged_accounts(initial, advanced)
      }

      :ok = BatchTransactionStoreHelper.write_successes(write_plan, Repo, now)

      assert count(PendingTransactionLookup) - lookup_before == 1

      # `journal_event_id` is now stamped by the orchestrator (Step 5)
      # before reaching the writer; the writer only persists it.
      lk = Repo.get_by!(PendingTransactionLookup, command_id: command.id)
      assert lk.transaction_id == success.transaction_id
      assert lk.journal_event_id == success.journal_event_id
    end

    # ── B3: update transitions ───────────────────────────────────────

    test ":pending_to_posted update transitions tx + applies posted balance",
         %{instance: inst, accounts: [a1, a2, _, _]} = ctx do
      {create_success, current_accounts} =
        seed_pending_transaction(ctx, [{a1.id, :debit, 100}, {a2.id, :credit, 100}])

      update_cmd = insert_update_cmd_with_qi(ctx, :posted, 100)

      {update_success, advanced} =
        update_success_for(
          create_success,
          update_cmd,
          :pending_to_posted,
          :posted,
          [
            {a1.id, :debit, 100, 100},
            {a2.id, :credit, 100, 100}
          ],
          current_accounts
        )

      now = DateTime.utc_now()

      write_plan = %{
        successes: [update_success],
        failures: [],
        merged_accounts: merged_accounts(current_accounts, advanced)
      }

      Repo.query!("SET LOCAL TIME ZONE 'Pacific/Auckland'")
      :ok = BatchTransactionStoreHelper.write_successes(write_plan, Repo, now)

      tx = Repo.get!(Transaction, create_success.transaction_id)
      assert tx.status == :posted
      assert DateTime.compare(tx.posted_at, now) == :eq
      assert tx.instance_id == inst.id

      final_a1 = reload_account(a1.id)
      assert final_a1.pending.amount == 0
      assert final_a1.pending.debit == 0
      assert final_a1.posted.amount == 100
      assert final_a1.posted.debit == 100

      final_a2 = reload_account(a2.id)
      assert final_a2.pending.amount == 0
      assert final_a2.pending.credit == 0
      assert final_a2.posted.amount == 100
      assert final_a2.posted.credit == 100

      # 2 fresh BHE rows for this update (one per entry)
      bhes =
        Repo.all(
          Ecto.Query.from(b in BalanceHistoryEntry,
            where: b.inserted_at == ^now,
            order_by: b.account_id
          )
        )

      assert length(bhes) == 2

      # 1 fresh journal_event for the update
      assert Repo.get!(JournalEvent, update_success.journal_event_id)

      # Update command's queue item marked :processed
      update_qi = reload_qi(update_cmd.command_queue_item.id)
      assert update_qi.status == :processed
    end

    test ":pending_to_pending update with value change adjusts entries + pending",
         %{accounts: [a1, a2, _, _]} = ctx do
      {create_success, current_accounts} =
        seed_pending_transaction(ctx, [{a1.id, :debit, 50}, {a2.id, :credit, 50}])

      update_cmd = insert_update_cmd_with_qi(ctx, :pending, 75)

      {update_success, advanced} =
        update_success_for(
          create_success,
          update_cmd,
          :pending_to_pending,
          :pending,
          [
            {a1.id, :debit, 75, 50},
            {a2.id, :credit, 75, 50}
          ],
          current_accounts
        )

      now = DateTime.utc_now()

      write_plan = %{
        successes: [update_success],
        failures: [],
        merged_accounts: merged_accounts(current_accounts, advanced)
      }

      :ok = BatchTransactionStoreHelper.write_successes(write_plan, Repo, now)

      tx = Repo.get!(Transaction, create_success.transaction_id)
      assert tx.status == :pending
      assert tx.posted_at == nil

      # Entries' values updated to 75
      entries =
        Repo.all(Ecto.Query.from(e in Entry, where: e.transaction_id == ^tx.id, order_by: e.id))

      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.value == Money.new(75, :EUR)))

      final_a1 = reload_account(a1.id)
      assert final_a1.pending.amount == 75
      assert final_a1.pending.debit == 75

      final_a2 = reload_account(a2.id)
      assert final_a2.pending.amount == 75
      assert final_a2.pending.credit == 75
    end

    test ":pending_to_archived update cancels pending + flips status to :archived",
         %{accounts: [a1, a2, _, _]} = ctx do
      {create_success, current_accounts} =
        seed_pending_transaction(ctx, [{a1.id, :debit, 100}, {a2.id, :credit, 100}])

      update_cmd = insert_update_cmd_with_qi(ctx, :archived, 100)

      {update_success, advanced} =
        update_success_for(
          create_success,
          update_cmd,
          :pending_to_archived,
          :archived,
          [
            {a1.id, :debit, 100, 100},
            {a2.id, :credit, 100, 100}
          ],
          current_accounts
        )

      now = DateTime.utc_now()

      write_plan = %{
        successes: [update_success],
        failures: [],
        merged_accounts: merged_accounts(current_accounts, advanced)
      }

      :ok = BatchTransactionStoreHelper.write_successes(write_plan, Repo, now)

      tx = Repo.get!(Transaction, create_success.transaction_id)
      assert tx.status == :archived
      assert tx.posted_at == nil

      final_a1 = reload_account(a1.id)
      assert final_a1.pending.amount == 0
      assert final_a1.pending.debit == 0
      assert final_a1.posted.amount == 0

      final_a2 = reload_account(a2.id)
      assert final_a2.pending.amount == 0
      assert final_a2.pending.credit == 0
    end

    test ":pending_to_posted update DELETEs the pending_transaction_lookup row",
         %{accounts: [a1, a2, _, _]} = ctx do
      {create_success, current_accounts} =
        seed_pending_transaction(ctx, [{a1.id, :debit, 100}, {a2.id, :credit, 100}])

      # Sanity: lookup row inserted by the seed.
      assert Repo.get_by(PendingTransactionLookup, command_id: create_success.command.id)

      update_cmd =
        insert_update_cmd_with_qi(ctx, :posted, 100,
          source: create_success.command.command_map.source,
          source_idempk: create_success.command.command_map.source_idempk
        )

      {update_success, advanced} =
        update_success_for(
          create_success,
          update_cmd,
          :pending_to_posted,
          :posted,
          [
            {a1.id, :debit, 100, 100},
            {a2.id, :credit, 100, 100}
          ],
          current_accounts
        )

      write_plan = %{
        successes: [update_success],
        failures: [],
        merged_accounts: merged_accounts(current_accounts, advanced)
      }

      :ok = BatchTransactionStoreHelper.write_successes(write_plan, Repo, DateTime.utc_now())

      # Lookup row gone — tx is now terminal :posted, the row's purpose
      # (finding the pending tx for update routing) no longer applies.
      refute Repo.get_by(PendingTransactionLookup, command_id: create_success.command.id)
    end

    test ":pending_to_archived update DELETEs the pending_transaction_lookup row",
         %{accounts: [a1, a2, _, _]} = ctx do
      {create_success, current_accounts} =
        seed_pending_transaction(ctx, [{a1.id, :debit, 100}, {a2.id, :credit, 100}])

      assert Repo.get_by(PendingTransactionLookup, command_id: create_success.command.id)

      update_cmd =
        insert_update_cmd_with_qi(ctx, :archived, 100,
          source: create_success.command.command_map.source,
          source_idempk: create_success.command.command_map.source_idempk
        )

      {update_success, advanced} =
        update_success_for(
          create_success,
          update_cmd,
          :pending_to_archived,
          :archived,
          [
            {a1.id, :debit, 100, 100},
            {a2.id, :credit, 100, 100}
          ],
          current_accounts
        )

      write_plan = %{
        successes: [update_success],
        failures: [],
        merged_accounts: merged_accounts(current_accounts, advanced)
      }

      :ok = BatchTransactionStoreHelper.write_successes(write_plan, Repo, DateTime.utc_now())

      refute Repo.get_by(PendingTransactionLookup, command_id: create_success.command.id)
    end

    test ":pending_to_pending update leaves pending_transaction_lookup row untouched",
         %{accounts: [a1, a2, _, _]} = ctx do
      {create_success, current_accounts} =
        seed_pending_transaction(ctx, [{a1.id, :debit, 50}, {a2.id, :credit, 50}])

      lookup_before =
        Repo.get_by!(PendingTransactionLookup, command_id: create_success.command.id)

      lookup_count_before = count(PendingTransactionLookup)

      # Update command uses the SAME source/source_idempk as the create.
      # Two protections:
      #   1. inserted_lookups CTE filter excludes updates entirely (B3),
      #      so the update can't re-INSERT a row over the create's.
      #   2. deleted_lookups CTE only fires for terminal transitions
      #      (:posted / :archived) — :pending_to_pending isn't terminal,
      #      so the row stays.
      update_cmd =
        insert_update_cmd_with_qi(ctx, :pending, 60,
          source: create_success.command.command_map.source,
          source_idempk: create_success.command.command_map.source_idempk
        )

      {update_success, advanced} =
        update_success_for(
          create_success,
          update_cmd,
          :pending_to_pending,
          :pending,
          [
            {a1.id, :debit, 60, 50},
            {a2.id, :credit, 60, 50}
          ],
          current_accounts
        )

      write_plan = %{
        successes: [update_success],
        failures: [],
        merged_accounts: merged_accounts(current_accounts, advanced)
      }

      :ok = BatchTransactionStoreHelper.write_successes(write_plan, Repo, DateTime.utc_now())

      # Row count unchanged.
      assert count(PendingTransactionLookup) == lookup_count_before

      # Row contents unchanged (still points at the create's journal,
      # not the update's).
      lookup_after =
        Repo.get_by!(PendingTransactionLookup, command_id: create_success.command.id)

      assert lookup_after.command_id == lookup_before.command_id
      assert lookup_after.journal_event_id == lookup_before.journal_event_id
      assert lookup_after.transaction_id == lookup_before.transaction_id
    end

    test "TOCTOU: tx.status flipped externally between read and write raises StaleEntryError",
         %{accounts: [a1, a2, _, _]} = ctx do
      {create_success, current_accounts} =
        seed_pending_transaction(ctx, [{a1.id, :debit, 100}, {a2.id, :credit, 100}])

      # Simulate a concurrent direct-API write that transitions the
      # transaction to :posted between the orchestrator's read and the
      # CTE commit. The `WHERE t.status = 'pending'` predicate on the
      # updated_transactions CTE will then exclude this row, count
      # comes back as 0 (< expected 1), and write_successes raises.
      Repo.get!(Transaction, create_success.transaction_id)
      |> Ecto.Changeset.change(status: :posted)
      |> Repo.update!()

      update_cmd = insert_update_cmd_with_qi(ctx, :posted, 100)

      {update_success, advanced} =
        update_success_for(
          create_success,
          update_cmd,
          :pending_to_posted,
          :posted,
          [
            {a1.id, :debit, 100, 100},
            {a2.id, :credit, 100, 100}
          ],
          current_accounts
        )

      write_plan = %{
        successes: [update_success],
        failures: [],
        merged_accounts: merged_accounts(current_accounts, advanced)
      }

      assert_raise Ecto.StaleEntryError, fn ->
        BatchTransactionStoreHelper.write_successes(write_plan, Repo, DateTime.utc_now())
      end
    end

    test "mixed batch: 1 create + 1 update on independent txs both succeed",
         %{instance: inst, accounts: [a1, a2, a3, a4]} = ctx do
      # Seed a pending tx on a1/a2 — this is the update's target.
      {create_success_seed, accounts_after_seed} =
        seed_pending_transaction(ctx, [{a1.id, :debit, 100}, {a2.id, :credit, 100}])

      # Build a brand-new CREATE on a3/a4 that lives in the same batch.
      reloaded_a3 = reload_account(a3.id)
      reloaded_a4 = reload_account(a4.id)
      initial_a34 = accounts_map([reloaded_a3, reloaded_a4])

      new_create_attrs =
        DoubleEntryLedger.CommandFixtures.transaction_command_attrs(
          instance_address: inst.address,
          source: "src",
          source_idempk: "create-mixed-#{System.unique_integer([:positive])}",
          payload: %DoubleEntryLedger.Command.TransactionData{
            status: :posted,
            entries: [
              %{account_address: a3.address, amount: 30, currency: "EUR"},
              %{account_address: a4.address, amount: 30, currency: "EUR"}
            ]
          }
        )

      {:ok, new_create_cmd} = DoubleEntryLedger.Stores.CommandStore.create(new_create_attrs)
      new_create_cmd = reload_command_with_qi(new_create_cmd.id)

      {new_create_success, advanced_a34} =
        success_for(new_create_cmd, initial_a34, :posted, [
          {a3.id, :debit, 30},
          {a4.id, :credit, 30}
        ])

      # Build the update on a1/a2.
      update_cmd = insert_update_cmd_with_qi(ctx, :posted, 100)

      {update_success, advanced_a12} =
        update_success_for(
          create_success_seed,
          update_cmd,
          :pending_to_posted,
          :posted,
          [
            {a1.id, :debit, 100, 100},
            {a2.id, :credit, 100, 100}
          ],
          accounts_after_seed
        )

      # Combine the two account maps for merged_accounts. Initial state
      # was the post-seed state for a1/a2 and pre-seed for a3/a4.
      combined_initial = Map.merge(accounts_after_seed, initial_a34)
      combined_advanced = Map.merge(advanced_a12, advanced_a34)

      now = DateTime.utc_now()

      write_plan = %{
        successes: [new_create_success, update_success],
        failures: [],
        merged_accounts: merged_accounts(combined_initial, combined_advanced)
      }

      :ok = BatchTransactionStoreHelper.write_successes(write_plan, Repo, now)

      # Create side: new tx inserted, a3/a4 advanced
      created_tx = Repo.get!(Transaction, new_create_success.transaction_id)
      assert created_tx.status == :posted

      assert reload_account(a3.id).posted.amount == 30
      assert reload_account(a4.id).posted.amount == 30

      # Update side: original tx settled
      updated_tx = Repo.get!(Transaction, create_success_seed.transaction_id)
      assert updated_tx.status == :posted
      assert reload_account(a1.id).pending.amount == 0
      assert reload_account(a1.id).posted.amount == 100
      assert reload_account(a2.id).pending.amount == 0
      assert reload_account(a2.id).posted.amount == 100
    end
  end

  # ── write_failures/3 ────────────────────────────────────────────────

  # Reload a queue item directly from the DB.
  defp reload_qi(id), do: Repo.get!(CommandQueueItem, id)

  # Seed a queue row's `errors` JSONB array with a pre-existing entry,
  # so we can assert the failure UPDATE *appends* rather than replaces.
  defp seed_existing_error(qi_id, message) do
    qi = Repo.get!(CommandQueueItem, qi_id)

    qi
    |> Ecto.Changeset.change(
      errors: [%{"message" => message, "inserted_at" => "2026-01-01T00:00:00Z"}]
    )
    |> Repo.update!()
  end

  describe "write_failures/3" do
    setup [:create_instance, :create_accounts]

    test "rejects a failure written by a stale batch owner", ctx do
      [command] = insert_commands(ctx, 1, :posted)
      telemetry_ref = attach_telemetry([:double_entry_ledger, :command, :retry])

      [claimed_by_old_owner] =
        Scheduling.claim_batch_for_processing([command], "old-batch-owner")

      claimed_by_old_owner.command_queue_item
      |> Ecto.Changeset.change(processor_id: "new-batch-owner")
      |> Ecto.Changeset.optimistic_lock(:processor_version)
      |> Repo.update!()

      failure = %{command: claimed_by_old_owner, reason: {:unbalanced}}

      assert_raise OwnershipError, fn ->
        BatchTransactionStoreHelper.write_failures([failure], Repo, DateTime.utc_now())
      end

      current = reload_qi(command.command_queue_item.id)
      assert current.status == :processing
      assert current.processor_id == "new-batch-owner"
      refute_received {:telemetry_event, ^telemetry_ref, _event, _measurements, _metadata}
    end

    # ── 1. empty failures returns :ok with no SQL ─────────────────────

    test "empty failures returns :ok without raising or writing", _ctx do
      now = DateTime.utc_now()
      qi_before = count(CommandQueueItem)

      assert [] == BatchTransactionStoreHelper.write_failures([], Repo, now)

      assert count(CommandQueueItem) == qi_before
    end

    # ── 2. single :unbalanced failure ─────────────────────────────────

    test "single :unbalanced failure marks queue row :failed, leaves retry_count untouched, sets future next_retry_after, appends one error",
         ctx do
      [command] = insert_commands(ctx, 1, :posted)
      now = DateTime.utc_now()

      failure = %{command: command, reason: {:unbalanced}}

      [_plan] = BatchTransactionStoreHelper.write_failures([failure], Repo, now)

      qi = reload_qi(command.command_queue_item.id)

      assert qi.status == :failed
      # Legacy `schedule_retry_changeset/4` does NOT touch retry_count;
      # the bump happens at claim time via `retry_count_by_status/1`.
      assert qi.retry_count == command.command_queue_item.retry_count
      assert qi.processor_version == command.command_queue_item.processor_version + 1
      assert qi.processing_completed_at != nil
      assert qi.next_retry_after != nil
      assert DateTime.compare(qi.next_retry_after, now) == :gt

      assert length(qi.errors) == 1
      [%{"message" => message, "inserted_at" => _}] = qi.errors
      assert is_binary(message)
      assert String.contains?(message, "balance")
    end

    test "retry branch lets the database compute next_retry_after from the delay", ctx do
      [command] = insert_commands(ctx, 1, :posted)

      failure = %{command: command, reason: {:unbalanced}}

      [plan] = BatchTransactionStoreHelper.write_failures([failure], Repo, DateTime.utc_now())

      # The plan carries a delay instruction, not an application timestamp.
      assert plan.status == :failed
      assert plan.next_retry_after == nil
      assert plan.retry_delay_seconds in @first_retry_delay_range

      qi = reload_qi(command.command_queue_item.id)

      # The trigger consumed the delay and stamped both timestamps from the
      # same database clock reading.
      assert qi.retry_delay_seconds == nil

      assert DateTime.diff(qi.next_retry_after, qi.processing_completed_at, :second) ==
               plan.retry_delay_seconds
    end

    test "dependency wait without a create retry time is retried one database second later",
         ctx do
      [command] = insert_commands(ctx, 1, :posted)

      failure = %{command: command, reason: :create_command_not_processed}

      [plan] = BatchTransactionStoreHelper.write_failures([failure], Repo, DateTime.utc_now())

      assert plan.status == :pending
      assert plan.next_retry_after == nil
      assert plan.retry_delay_seconds == 1

      qi = reload_qi(command.command_queue_item.id)

      assert qi.status == :pending
      assert qi.retry_delay_seconds == nil
      # `:pending` is not a completion state, so `updated_at` is the trigger's
      # clock reading for this write.
      assert DateTime.diff(qi.next_retry_after, qi.updated_at, :second) == 1
    end

    test "dependency wait keeps the create command's explicit retry time", ctx do
      [command] = insert_commands(ctx, 1, :posted)
      create_next_retry_after = ~U[2030-01-01 12:00:00.000000Z]

      failure = %{
        command: command,
        reason: :create_command_not_processed,
        next_retry_after: create_next_retry_after
      }

      [plan] = BatchTransactionStoreHelper.write_failures([failure], Repo, DateTime.utc_now())

      assert plan.status == :pending
      assert plan.next_retry_after == create_next_retry_after
      assert plan.retry_delay_seconds == nil

      qi = reload_qi(command.command_queue_item.id)

      assert qi.status == :pending
      assert qi.retry_delay_seconds == nil
      assert qi.next_retry_after == create_next_retry_after
    end

    # ── 3. single :balance_change_error failure ──────────────────────

    test "single :balance_change_error failure produces an error map carrying field+message",
         ctx do
      [command] = insert_commands(ctx, 1, :posted)
      now = DateTime.utc_now()

      failure = %{
        command: command,
        reason: {:balance_change_error, :available, "amount can't be negative"}
      }

      [_plan] = BatchTransactionStoreHelper.write_failures([failure], Repo, now)

      qi = reload_qi(command.command_queue_item.id)

      assert qi.status == :failed
      # Legacy: failure mark does NOT bump retry_count.
      assert qi.retry_count == command.command_queue_item.retry_count

      assert length(qi.errors) == 1
      [%{"message" => message}] = qi.errors
      assert String.contains?(message, "available")
      assert String.contains?(message, "negative")
    end

    # ── 4. command at/over max retries gets dead-lettered ────────────

    test "command with retry_count >= max retries gets marked :dead_letter with next_retry_after = nil",
         ctx do
      [command] = insert_commands(ctx, 1, :posted)
      now = DateTime.utc_now()

      max_retries = Application.get_env(:double_entry_ledger, :command_queue)[:max_retries] || 5

      # Bump retry_count to max so the legacy `Scheduling` helper
      # produces a `dead_letter_changeset` instead of a retry.
      command.command_queue_item
      |> Ecto.Changeset.change(%{retry_count: max_retries})
      |> Repo.update!()

      # Reload so the writer sees the bumped retry_count.
      command = reload_command_with_qi(command.id)

      failure = %{command: command, reason: {:unbalanced}}

      [_plan] = BatchTransactionStoreHelper.write_failures([failure], Repo, now)

      qi = reload_qi(command.command_queue_item.id)

      assert qi.status == :dead_letter
      assert qi.next_retry_after == nil
      # Legacy `dead_letter_changeset/2` does NOT touch retry_count;
      # it stays at whatever the most recent claim wrote.
      assert qi.retry_count == max_retries
      assert qi.processor_version == command.command_queue_item.processor_version + 1
      assert qi.processing_completed_at != nil

      # Dead-letter still records the failure in the errors array.
      assert length(qi.errors) == 1
      [%{"message" => message}] = qi.errors
      assert is_binary(message)
    end

    # ── 5. multiple failures, one with pre-existing errors ───────────

    test "multiple failures: each row updated; pre-existing errors entry preserved alongside new",
         ctx do
      [c1, c2, c3] = insert_commands(ctx, 3, :posted)
      now = DateTime.utc_now()

      # Seed c2's queue row with a pre-existing error to verify list-preservation.
      pre_existing_message = "earlier failure"
      seed_existing_error(c2.command_queue_item.id, pre_existing_message)

      failures = [
        %{command: c1, reason: {:unbalanced}},
        %{
          command: c2,
          reason: {:balance_change_error, :available, "amount can't be negative"}
        },
        %{command: c3, reason: {:account_not_found, Ecto.UUID.generate()}}
      ]

      [_plan1, _plan2, _plan3] =
        BatchTransactionStoreHelper.write_failures(failures, Repo, now)

      qi1 = reload_qi(c1.command_queue_item.id)
      qi2 = reload_qi(c2.command_queue_item.id)
      qi3 = reload_qi(c3.command_queue_item.id)

      assert qi1.status == :failed
      assert qi2.status == :failed
      assert qi3.status == :failed

      # Legacy: failure mark does NOT bump retry_count for any row.
      assert qi1.retry_count == c1.command_queue_item.retry_count
      assert qi2.retry_count == c2.command_queue_item.retry_count
      assert qi3.retry_count == c3.command_queue_item.retry_count

      # Each row has a future next_retry_after.
      assert DateTime.compare(qi1.next_retry_after, now) == :gt
      assert DateTime.compare(qi2.next_retry_after, now) == :gt
      assert DateTime.compare(qi3.next_retry_after, now) == :gt

      # qi1 / qi3 had no pre-existing errors → exactly one new entry.
      assert length(qi1.errors) == 1
      assert length(qi3.errors) == 1

      # qi2 had one pre-existing error → now has two; old one preserved.
      assert length(qi2.errors) == 2
      messages = Enum.map(qi2.errors, & &1["message"])
      assert pre_existing_message in messages
      assert Enum.any?(messages, &String.contains?(&1, "available"))
      assert String.contains?(hd(messages), "available")
      assert List.last(messages) == pre_existing_message

      # Correct error content per row.
      [%{"message" => m1}] = qi1.errors
      assert String.contains?(m1, "balance")

      [%{"message" => m3}] = qi3.errors
      assert String.contains?(m3, "account not found")
    end

    # ── 6. processor_version advanced in failure path ─────────────

    test "write_failures/3 advances processor_version",
         ctx do
      [command] = insert_commands(ctx, 1, :posted)
      now = DateTime.utc_now()

      version_before = command.command_queue_item.processor_version

      [_plan] =
        BatchTransactionStoreHelper.write_failures(
          [%{command: command, reason: {:unbalanced}}],
          Repo,
          now
        )

      qi = reload_qi(command.command_queue_item.id)
      assert qi.processor_version == version_before + 1
    end

    # ── 7. processor_id cleared on :failed (matches schedule_retry_changeset) ─

    test "write_failures/3 clears processor_id on :failed branch (mirrors schedule_retry_changeset)",
         ctx do
      [command] = insert_commands(ctx, 1, :posted)
      now = DateTime.utc_now()

      # Seed a known processor_id so we can detect that the writer cleared it.
      command.command_queue_item
      |> Ecto.Changeset.change(processor_id: "test-processor")
      |> Repo.update!()

      command = reload_command_with_qi(command.id)
      assert command.command_queue_item.processor_id == "test-processor"

      [_plan] =
        BatchTransactionStoreHelper.write_failures(
          [%{command: command, reason: {:unbalanced}}],
          Repo,
          now
        )

      qi = reload_qi(command.command_queue_item.id)
      assert qi.status == :failed
      assert qi.processor_id == nil
    end

    # ── 8. processor_id preserved on :dead_letter (matches dead_letter_changeset) ─

    test "write_failures/3 preserves processor_id on :dead_letter branch (mirrors dead_letter_changeset)",
         ctx do
      [command] = insert_commands(ctx, 1, :posted)
      now = DateTime.utc_now()

      max_retries = Application.get_env(:double_entry_ledger, :command_queue)[:max_retries] || 5

      # Push retry_count to max so legacy dispatches to dead_letter, and
      # seed a processor_id we can detect is preserved unchanged.
      command.command_queue_item
      |> Ecto.Changeset.change(retry_count: max_retries, processor_id: "test-processor")
      |> Repo.update!()

      command = reload_command_with_qi(command.id)
      assert command.command_queue_item.processor_id == "test-processor"
      assert command.command_queue_item.retry_count == max_retries

      [_plan] =
        BatchTransactionStoreHelper.write_failures(
          [%{command: command, reason: {:unbalanced}}],
          Repo,
          now
        )

      qi = reload_qi(command.command_queue_item.id)
      assert qi.status == :dead_letter
      assert qi.processor_id == "test-processor"
    end
  end
end
