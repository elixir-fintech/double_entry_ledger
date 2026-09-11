defmodule DoubleEntryLedger.BatchProcessorTest do
  @moduledoc """
  Pure unit tests for `DoubleEntryLedger.BatchProcessor.simulate_batch/2`.

  No DB. All `Account` and `Balance` structs are constructed manually.
  Each test is linear (no `if`/`case`/`cond`/recursion in test code).

  Covers all eight scenarios from plan section 10.1:

    1. 1 cmd, 2 entries, success
    2. 3 cmds, all success, no overlap
    3. 3 cmds, middle fails validation
    4. 2 cmds touching same account
    5. 2 cmds touching same account, second fails
    6. All cmds fail
    7. Empty input
    8. Cmd references unknown account
  """

  use ExUnit.Case, async: true

  alias DoubleEntryLedger.{Account, Balance, BatchProcessor, Command}

  # ── helpers ──────────────────────────────────────────────────────

  # Build an asset (debit-normal) account with the requested negative_limit.
  defp asset_account(id, opts \\ []) do
    %Account{
      id: id,
      currency: :USD,
      type: :asset,
      normal_balance: :debit,
      negative_limit: Keyword.get(opts, :negative_limit, 0),
      posted: %Balance{amount: 0, debit: 0, credit: 0},
      pending: %Balance{amount: 0, debit: 0, credit: 0},
      available: 0,
      lock_version: Keyword.get(opts, :lock_version, 1),
      instance_id: "11111111-1111-1111-1111-111111111111"
    }
  end

  # Build a liability (credit-normal) account.
  defp liability_account(id, opts \\ []) do
    %Account{
      id: id,
      currency: :USD,
      type: :liability,
      normal_balance: :credit,
      negative_limit: Keyword.get(opts, :negative_limit, 0),
      posted: %Balance{amount: 0, debit: 0, credit: 0},
      pending: %Balance{amount: 0, debit: 0, credit: 0},
      available: 0,
      lock_version: Keyword.get(opts, :lock_version, 1),
      instance_id: "11111111-1111-1111-1111-111111111111"
    }
  end

  defp money(amount), do: Money.new(amount, :USD)

  defp entry(account_id, type, amount) do
    %{account_id: account_id, type: type, value: money(amount)}
  end

  # Build a balanced two-entry input: debit one account, credit another.
  defp input(opts) do
    %{
      command: %Command{id: Keyword.fetch!(opts, :command_id)},
      transaction_id: Keyword.get(opts, :transaction_id, Ecto.UUID.generate()),
      status: Keyword.get(opts, :status, :posted),
      entries: Keyword.fetch!(opts, :entries)
    }
  end

  # Asset (debit-normal) account with a non-zero pending debit balance —
  # the setup the update transitions reverse from.
  defp pre_pending_asset_account(id, pending_debit) do
    %Account{
      id: id,
      currency: :USD,
      type: :asset,
      normal_balance: :debit,
      negative_limit: 0,
      posted: %Balance{amount: 0, debit: 0, credit: 0},
      pending: %Balance{amount: pending_debit, debit: pending_debit, credit: 0},
      available: 0,
      lock_version: 1,
      instance_id: "11111111-1111-1111-1111-111111111111"
    }
  end

  # Liability (credit-normal) account with a non-zero pending credit balance.
  defp pre_pending_liability_account(id, pending_credit) do
    %Account{
      id: id,
      currency: :USD,
      type: :liability,
      normal_balance: :credit,
      negative_limit: 0,
      posted: %Balance{amount: 0, debit: 0, credit: 0},
      pending: %Balance{amount: pending_credit, debit: 0, credit: pending_credit},
      available: 0,
      lock_version: 1,
      instance_id: "11111111-1111-1111-1111-111111111111"
    }
  end

  defp update_entry(account_id, type, new_amount, old_amount) do
    %{
      id: Ecto.UUID.generate(),
      account_id: account_id,
      type: type,
      value: money(new_amount),
      old_value: money(old_amount)
    }
  end

  # Synthetic Stage 2 update command_input — mimics what
  # `enrich_updates_with_existing/2` (B4) will produce. Includes
  # `:transaction_id`, `:transition`, and per-entry `:id`/`:old_value`
  # that B2's `extract_one/1` deliberately omits.
  defp update_input(opts) do
    %{
      command: %Command{id: Keyword.fetch!(opts, :command_id)},
      action: :update_transaction,
      transaction_id: Keyword.get(opts, :transaction_id, Ecto.UUID.generate()),
      journal_event_id: Keyword.get(opts, :journal_event_id, Ecto.UUID.generate()),
      status: Keyword.fetch!(opts, :status),
      transition: Keyword.fetch!(opts, :transition),
      entries: Keyword.fetch!(opts, :entries)
    }
  end

  # ── 1. 1 cmd, 2 entries, success ─────────────────────────────────

  test "1 cmd, 2 entries, success" do
    a_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    b_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    accounts = %{
      a_id => asset_account(a_id),
      b_id => liability_account(b_id)
    }

    inputs = [
      input(
        command_id: "cmd-1",
        entries: [
          entry(a_id, :debit, 100),
          entry(b_id, :credit, 100)
        ]
      )
    ]

    result = BatchProcessor.simulate_batch(inputs, accounts)

    assert length(result.successes) == 1
    assert result.failures == []
    assert map_size(result.merged_accounts) == 2

    a_merged = result.merged_accounts[a_id]
    b_merged = result.merged_accounts[b_id]

    assert a_merged.old_lock_version == 1
    assert a_merged.new_lock_version == 2
    assert a_merged.posted.amount == 100
    assert a_merged.posted.debit == 100

    assert b_merged.old_lock_version == 1
    assert b_merged.new_lock_version == 2
    assert b_merged.posted.amount == 100
    assert b_merged.posted.credit == 100

    [success] = result.successes
    assert success.command.id == "cmd-1"
    assert length(success.entries) == 2

    # Entries carry per-entry account_after snapshots in the order they
    # were applied. Because each entry is the only one hitting its
    # account, the snapshot equals the merged final state for that
    # account.
    [first_snap, second_snap] = success.entries
    assert first_snap.account_after.id == a_id
    assert first_snap.account_after.posted.amount == 100
    assert first_snap.account_after.lock_version == 2
    assert second_snap.account_after.id == b_id
    assert second_snap.account_after.posted.amount == 100
    assert second_snap.account_after.lock_version == 2
  end

  # ── 2. 3 cmds, all success, no overlap ───────────────────────────

  test "3 cmds, all success, no overlap" do
    a_id = "11111111-1111-1111-1111-aaaaaaaaaaaa"
    b_id = "11111111-1111-1111-1111-bbbbbbbbbbbb"
    c_id = "11111111-1111-1111-1111-cccccccccccc"
    d_id = "11111111-1111-1111-1111-dddddddddddd"
    e_id = "11111111-1111-1111-1111-eeeeeeeeeeee"
    f_id = "11111111-1111-1111-1111-ffffffffffff"

    accounts = %{
      a_id => asset_account(a_id),
      b_id => liability_account(b_id),
      c_id => asset_account(c_id),
      d_id => liability_account(d_id),
      e_id => asset_account(e_id),
      f_id => liability_account(f_id)
    }

    inputs = [
      input(
        command_id: "cmd-1",
        entries: [entry(a_id, :debit, 50), entry(b_id, :credit, 50)]
      ),
      input(
        command_id: "cmd-2",
        entries: [entry(c_id, :debit, 75), entry(d_id, :credit, 75)]
      ),
      input(
        command_id: "cmd-3",
        entries: [entry(e_id, :debit, 200), entry(f_id, :credit, 200)]
      )
    ]

    result = BatchProcessor.simulate_batch(inputs, accounts)

    assert length(result.successes) == 3
    assert result.failures == []
    assert map_size(result.merged_accounts) == 6

    Enum.each([a_id, b_id, c_id, d_id, e_id, f_id], fn id ->
      assert result.merged_accounts[id].old_lock_version == 1
      assert result.merged_accounts[id].new_lock_version == 2
    end)

    # claim order preserved
    assert Enum.map(result.successes, & &1.command.id) == ["cmd-1", "cmd-2", "cmd-3"]
  end

  # ── 3. 3 cmds, middle fails validation ───────────────────────────

  test "3 cmds, middle fails validation (negative_limit)" do
    a_id = "22222222-2222-2222-2222-aaaaaaaaaaaa"
    b_id = "22222222-2222-2222-2222-bbbbbbbbbbbb"
    c_id = "22222222-2222-2222-2222-cccccccccccc"
    # `c` is an asset with negative_limit=0; cmd-2 tries to credit it
    # while it has zero balance, so available goes negative — fails.
    d_id = "22222222-2222-2222-2222-dddddddddddd"

    accounts = %{
      a_id => asset_account(a_id),
      b_id => liability_account(b_id),
      c_id => asset_account(c_id, negative_limit: 0),
      d_id => liability_account(d_id)
    }

    inputs = [
      input(
        command_id: "cmd-1",
        entries: [entry(a_id, :debit, 100), entry(b_id, :credit, 100)]
      ),
      input(
        command_id: "cmd-2",
        entries: [entry(c_id, :credit, 50), entry(d_id, :debit, 50)]
      ),
      input(
        command_id: "cmd-3",
        entries: [entry(a_id, :debit, 25), entry(b_id, :credit, 25)]
      )
    ]

    result = BatchProcessor.simulate_batch(inputs, accounts)

    assert length(result.successes) == 2
    assert length(result.failures) == 1

    [s1, s2] = result.successes
    assert s1.command.id == "cmd-1"
    assert s2.command.id == "cmd-3"

    [failure] = result.failures
    assert failure.command.id == "cmd-2"
    assert {:balance_change_error, :available, _msg} = failure.reason

    # account `a` is touched by cmd-1 and cmd-3 → 2 lock bumps
    assert result.merged_accounts[a_id].old_lock_version == 1
    assert result.merged_accounts[a_id].new_lock_version == 3
    assert result.merged_accounts[a_id].posted.amount == 125

    # `b` likewise
    assert result.merged_accounts[b_id].new_lock_version == 3

    # `c` and `d` were not touched by any successful entry — must be
    # absent from merged_accounts (failed cmd-2 must not advance state)
    refute Map.has_key?(result.merged_accounts, c_id)
    refute Map.has_key?(result.merged_accounts, d_id)
  end

  # ── 4. 2 cmds touching same account ──────────────────────────────

  test "2 cmds touching same account, both succeed" do
    a_id = "33333333-3333-3333-3333-aaaaaaaaaaaa"
    b_id = "33333333-3333-3333-3333-bbbbbbbbbbbb"

    accounts = %{
      a_id => asset_account(a_id),
      b_id => liability_account(b_id)
    }

    inputs = [
      input(
        command_id: "cmd-1",
        entries: [entry(a_id, :debit, 100), entry(b_id, :credit, 100)]
      ),
      input(
        command_id: "cmd-2",
        entries: [entry(a_id, :debit, 50), entry(b_id, :credit, 50)]
      )
    ]

    result = BatchProcessor.simulate_batch(inputs, accounts)

    assert length(result.successes) == 2
    assert result.failures == []

    # Each successful entry to A bumps the lock_version once.
    # Two cmds × 1 entry each touching A = +2.
    assert result.merged_accounts[a_id].old_lock_version == 1
    assert result.merged_accounts[a_id].new_lock_version == 3
    assert result.merged_accounts[a_id].posted.amount == 150
    assert result.merged_accounts[a_id].posted.debit == 150

    assert result.merged_accounts[b_id].new_lock_version == 3
    assert result.merged_accounts[b_id].posted.amount == 150
    assert result.merged_accounts[b_id].posted.credit == 150

    # Per-entry snapshots reflect intermediate states. cmd-1's A entry
    # sees A at posted.amount=100, cmd-2's A entry sees A at 150.
    [s1, s2] = result.successes
    [s1_a_snap, _s1_b_snap] = s1.entries
    [s2_a_snap, _s2_b_snap] = s2.entries

    assert s1_a_snap.account_after.posted.amount == 100
    assert s1_a_snap.account_after.lock_version == 2
    assert s2_a_snap.account_after.posted.amount == 150
    assert s2_a_snap.account_after.lock_version == 3
  end

  # ── 5. 2 cmds touching same account, second fails ────────────────

  test "2 cmds touching same account, second fails" do
    a_id = "44444444-4444-4444-4444-aaaaaaaaaaaa"
    b_id = "44444444-4444-4444-4444-bbbbbbbbbbbb"

    # `a` is an asset (debit-normal). cmd-1 debits 100 → posted.amount=100.
    # cmd-2 credits 200 against a freshly-debited 100 → would push
    # available to -100, which violates negative_limit=0.
    accounts = %{
      a_id => asset_account(a_id, negative_limit: 0),
      b_id => liability_account(b_id)
    }

    inputs = [
      input(
        command_id: "cmd-1",
        entries: [entry(a_id, :debit, 100), entry(b_id, :credit, 100)]
      ),
      input(
        command_id: "cmd-2",
        entries: [entry(a_id, :credit, 200), entry(b_id, :debit, 200)]
      )
    ]

    result = BatchProcessor.simulate_batch(inputs, accounts)

    assert length(result.successes) == 1
    assert length(result.failures) == 1

    [success] = result.successes
    assert success.command.id == "cmd-1"

    [failure] = result.failures
    assert failure.command.id == "cmd-2"
    assert {:balance_change_error, :available, _} = failure.reason

    # Only cmd-1 advanced state: 1 lock bump on each account.
    assert result.merged_accounts[a_id].new_lock_version == 2
    assert result.merged_accounts[a_id].posted.amount == 100
    assert result.merged_accounts[b_id].new_lock_version == 2
    assert result.merged_accounts[b_id].posted.amount == 100
  end

  # ── 6. All cmds fail ─────────────────────────────────────────────

  test "all cmds fail (unbalanced entries)" do
    a_id = "55555555-5555-5555-5555-aaaaaaaaaaaa"
    b_id = "55555555-5555-5555-5555-bbbbbbbbbbbb"

    accounts = %{
      a_id => asset_account(a_id),
      b_id => liability_account(b_id)
    }

    # Both commands have unbalanced debit/credit — fail at assert_balanced.
    inputs = [
      input(
        command_id: "cmd-1",
        entries: [entry(a_id, :debit, 100), entry(b_id, :credit, 90)]
      ),
      input(
        command_id: "cmd-2",
        entries: [entry(a_id, :debit, 50), entry(b_id, :credit, 25)]
      )
    ]

    result = BatchProcessor.simulate_batch(inputs, accounts)

    assert result.successes == []
    assert length(result.failures) == 2
    assert result.merged_accounts == %{}

    Enum.each(result.failures, fn f ->
      assert f.reason == {:unbalanced}
    end)
  end

  # ── 7. Empty input ───────────────────────────────────────────────

  test "empty input" do
    result = BatchProcessor.simulate_batch([], %{})
    assert result == %{successes: [], failures: [], merged_accounts: %{}}
  end

  test "empty input with preloaded but unused accounts" do
    a_id = "66666666-6666-6666-6666-aaaaaaaaaaaa"
    accounts = %{a_id => asset_account(a_id)}

    result = BatchProcessor.simulate_batch([], accounts)
    # No commands ran → no account was touched → merged_accounts empty.
    assert result == %{successes: [], failures: [], merged_accounts: %{}}
  end

  # ── 8. Cmd references unknown account ────────────────────────────

  test "cmd references unknown account → failure record, batch continues" do
    a_id = "77777777-7777-7777-7777-aaaaaaaaaaaa"
    b_id = "77777777-7777-7777-7777-bbbbbbbbbbbb"
    unknown = "77777777-7777-7777-7777-ffffffffffff"

    # Only `a` and `b` are in the preloaded accounts map. cmd-1
    # references the unknown account and must fail without crashing.
    accounts = %{
      a_id => asset_account(a_id),
      b_id => liability_account(b_id)
    }

    inputs = [
      input(
        command_id: "cmd-1",
        entries: [entry(a_id, :debit, 50), entry(unknown, :credit, 50)]
      ),
      input(
        command_id: "cmd-2",
        entries: [entry(a_id, :debit, 30), entry(b_id, :credit, 30)]
      )
    ]

    result = BatchProcessor.simulate_batch(inputs, accounts)

    assert length(result.successes) == 1
    assert length(result.failures) == 1

    [success] = result.successes
    assert success.command.id == "cmd-2"

    [failure] = result.failures
    assert failure.command.id == "cmd-1"
    assert failure.reason == {:account_not_found, unknown}

    # cmd-1's partial application of the `a` debit must NOT have
    # advanced state — only cmd-2 touched a/b.
    assert result.merged_accounts[a_id].new_lock_version == 2
    assert result.merged_accounts[a_id].posted.amount == 30
    assert result.merged_accounts[b_id].new_lock_version == 2
    assert result.merged_accounts[b_id].posted.amount == 30
  end

  # ── B2: create success_record carries :action :create_transaction ─

  test "create success_record carries action: :create_transaction" do
    a_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    b_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    accounts = %{
      a_id => asset_account(a_id),
      b_id => liability_account(b_id)
    }

    inputs = [
      input(
        command_id: "cmd-1",
        entries: [
          entry(a_id, :debit, 100),
          entry(b_id, :credit, 100)
        ]
      )
    ]

    result = BatchProcessor.simulate_batch(inputs, accounts)

    [success] = result.successes
    assert success.action == :create_transaction
    refute Map.has_key?(success, :transition)
  end

  # ── B2: update transitions through the fold ──────────────────────

  test "update :pending_to_posted moves pending balance into posted" do
    a_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    b_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    accounts = %{
      a_id => pre_pending_asset_account(a_id, 100),
      b_id => pre_pending_liability_account(b_id, 100)
    }

    inputs = [
      update_input(
        command_id: "cmd-u1",
        status: :posted,
        transition: :pending_to_posted,
        entries: [
          update_entry(a_id, :debit, 100, 100),
          update_entry(b_id, :credit, 100, 100)
        ]
      )
    ]

    result = BatchProcessor.simulate_batch(inputs, accounts)

    assert result.failures == []
    [success] = result.successes
    assert success.action == :update_transaction
    assert success.status == :posted
    assert success.transition == :pending_to_posted
    assert length(success.entries) == 2

    a_merged = result.merged_accounts[a_id]
    assert a_merged.pending.amount == 0
    assert a_merged.pending.debit == 0
    assert a_merged.posted.amount == 100
    assert a_merged.posted.debit == 100
    assert a_merged.new_lock_version == 2

    b_merged = result.merged_accounts[b_id]
    assert b_merged.pending.amount == 0
    assert b_merged.pending.credit == 0
    assert b_merged.posted.amount == 100
    assert b_merged.posted.credit == 100
    assert b_merged.new_lock_version == 2
  end

  test "update :pending_to_pending with value change 100→150 adjusts pending" do
    a_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    b_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    accounts = %{
      a_id => pre_pending_asset_account(a_id, 100),
      b_id => pre_pending_liability_account(b_id, 100)
    }

    inputs = [
      update_input(
        command_id: "cmd-u2",
        status: :pending,
        transition: :pending_to_pending,
        entries: [
          update_entry(a_id, :debit, 150, 100),
          update_entry(b_id, :credit, 150, 100)
        ]
      )
    ]

    result = BatchProcessor.simulate_batch(inputs, accounts)

    assert result.failures == []
    [success] = result.successes
    assert success.action == :update_transaction
    assert success.transition == :pending_to_pending

    a_merged = result.merged_accounts[a_id]
    assert a_merged.pending.amount == 150
    assert a_merged.pending.debit == 150
    assert a_merged.posted.amount == 0

    b_merged = result.merged_accounts[b_id]
    assert b_merged.pending.amount == 150
    assert b_merged.pending.credit == 150
    assert b_merged.posted.amount == 0
  end

  test "update :pending_to_archived cancels the pending balance" do
    a_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    b_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    accounts = %{
      a_id => pre_pending_asset_account(a_id, 100),
      b_id => pre_pending_liability_account(b_id, 100)
    }

    inputs = [
      update_input(
        command_id: "cmd-u3",
        status: :archived,
        transition: :pending_to_archived,
        entries: [
          update_entry(a_id, :debit, 100, 100),
          update_entry(b_id, :credit, 100, 100)
        ]
      )
    ]

    result = BatchProcessor.simulate_batch(inputs, accounts)

    assert result.failures == []
    [success] = result.successes
    assert success.action == :update_transaction
    assert success.status == :archived
    assert success.transition == :pending_to_archived

    a_merged = result.merged_accounts[a_id]
    assert a_merged.pending.amount == 0
    assert a_merged.pending.debit == 0
    assert a_merged.posted.amount == 0

    b_merged = result.merged_accounts[b_id]
    assert b_merged.pending.amount == 0
    assert b_merged.pending.credit == 0
    assert b_merged.posted.amount == 0
  end

  test "mixed batch (1 create + 1 update) — both succeed" do
    # Two unrelated pairs so the create and update touch disjoint accounts.
    a_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1"
    b_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb1"
    c_id = "cccccccc-cccc-cccc-cccc-cccccccccc01"
    d_id = "dddddddd-dddd-dddd-dddd-ddddddddddd1"

    accounts = %{
      a_id => asset_account(a_id),
      b_id => liability_account(b_id),
      c_id => pre_pending_asset_account(c_id, 50),
      d_id => pre_pending_liability_account(d_id, 50)
    }

    inputs = [
      input(
        command_id: "cmd-c1",
        entries: [
          entry(a_id, :debit, 30),
          entry(b_id, :credit, 30)
        ]
      ),
      update_input(
        command_id: "cmd-u1",
        status: :posted,
        transition: :pending_to_posted,
        entries: [
          update_entry(c_id, :debit, 50, 50),
          update_entry(d_id, :credit, 50, 50)
        ]
      )
    ]

    result = BatchProcessor.simulate_batch(inputs, accounts)

    assert result.failures == []
    assert length(result.successes) == 2

    [create_success, update_success] = result.successes
    assert create_success.action == :create_transaction
    assert update_success.action == :update_transaction
    assert update_success.transition == :pending_to_posted

    assert result.merged_accounts[a_id].posted.amount == 30
    assert result.merged_accounts[c_id].pending.amount == 0
    assert result.merged_accounts[c_id].posted.amount == 50
  end

  test "update fails when entry's old_value exceeds current pending" do
    # Account has pending=20 but we ask to reverse 100 → underflow.
    a_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    b_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    accounts = %{
      a_id => pre_pending_asset_account(a_id, 20),
      b_id => pre_pending_liability_account(b_id, 20)
    }

    inputs = [
      update_input(
        command_id: "cmd-u-fail",
        status: :archived,
        transition: :pending_to_archived,
        entries: [
          update_entry(a_id, :debit, 100, 100),
          update_entry(b_id, :credit, 100, 100)
        ]
      )
    ]

    result = BatchProcessor.simulate_batch(inputs, accounts)

    assert result.successes == []
    [failure] = result.failures
    assert failure.command.id == "cmd-u-fail"
    assert {:balance_change_error, :debit, _} = failure.reason

    # No accounts advanced — the failed command leaves state untouched.
    assert result.merged_accounts == %{}
  end
end
