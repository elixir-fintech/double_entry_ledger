defmodule DoubleEntryLedger.BatchProcessorEquivalenceTest do
  @moduledoc """
  Equivalence tests for the multi-command batching work (plan Step 9 —
  Sections 10.4 and 10.5).

  Verifies that the two write paths produce identical DB state under
  diverse inputs:

    * Path A — `CreateTransactionCommand.process/2` with the
      `:insert_path = :insert_all` config flag (the per-command path).
    * Path B — `BatchProcessor.run_batch/2` (the batched orchestrator).

  Coverage:

    * Property — `StreamData`-generated corpora of 5..30 valid
      `:create_transaction` commands hitting a pool of 8 accounts.
    * Stress — 100 balanced commands all touching the same 2 accounts
      (high contention). Also asserts Path B is meaningfully faster.

  Implementation notes:

    * Tests are linear (no `if`/`case`/`cond`/recursion in the test
      bodies). Helper functions may branch.
    * Uses distinct `Instance` rows per path / per iteration (rather
      than `TRUNCATE`) so the test stays sandbox-friendly: each path
      runs against its own freshly-seeded instance and we compare
      state scoped to that `instance_id`, re-keyed by `account.address`
      (stable across instances) for the comparison.
    * `async: false` because Path A toggles
      `:double_entry_ledger, :insert_path` globally for the duration
      of the path-A invocation.
  """

  use DoubleEntryLedger.RepoCase, async: false
  use ExUnitProperties

  alias DoubleEntryLedger.{
    Account,
    Balance,
    BatchProcessor,
    Instance,
    Repo
  }

  alias DoubleEntryLedger.Command.TransactionCommandMap
  alias DoubleEntryLedger.Stores.CommandStore
  alias DoubleEntryLedger.Workers.CommandWorker.CreateTransactionCommand

  @num_accounts 8
  # Range of [1, 1000] per spec; used by the generator below.
  @amount_min 1
  @amount_max 1000
  @starting_balance 10_000_000

  setup do
    # Path A's `Telemetry.command_process_span/2` and the batch path
    # both emit a lot of info-level chatter under property iteration.
    # Squelch logger for the duration of the test (sandbox cleanup
    # restores any test-local on_exit hooks).
    prior_log_level = Logger.level()
    Logger.configure(level: :warning)

    prior_insert_path = Application.get_env(:double_entry_ledger, :insert_path, :legacy)

    on_exit(fn ->
      Application.put_env(:double_entry_ledger, :insert_path, prior_insert_path)
      Logger.configure(level: prior_log_level)
    end)

    :ok
  end

  # ─────────────────────────────────────────────────────────────────
  # A. Property test — paths are equivalent under random corpora.
  # ─────────────────────────────────────────────────────────────────

  describe "property: paths are equivalent" do
    property "random valid corpora produce identical state under both paths" do
      check all command_attrs_list <- corpus_generator(), max_runs: 20 do
        iteration = System.unique_integer([:positive])

        # ── Path A ────────────────────────────────────────────────
        {instance_a, _accounts_a} = seed_instance("eq_a_#{iteration}")
        commands_a = insert_commands(instance_a, command_attrs_list)

        prior = Application.get_env(:double_entry_ledger, :insert_path, :legacy)
        Application.put_env(:double_entry_ledger, :insert_path, :insert_all)

        try do
          run_path_a(commands_a)
        after
          Application.put_env(:double_entry_ledger, :insert_path, prior)
        end

        snapshot_a = snapshot(instance_a.id)

        # ── Path B ────────────────────────────────────────────────
        {instance_b, _accounts_b} = seed_instance("eq_b_#{iteration}")
        commands_b = insert_commands(instance_b, command_attrs_list)

        {:ok, _result} = BatchProcessor.run_batch(commands_b, Repo)

        snapshot_b = snapshot(instance_b.id)

        # ── Compare ───────────────────────────────────────────────
        assert_snapshots_equivalent!(snapshot_a, snapshot_b, command_attrs_list)
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # B. Stress test — high-contention, 100 cmds on 2 accounts.
  # ─────────────────────────────────────────────────────────────────

  describe "stress: high-contention" do
    test "100 commands on 2 accounts: paths produce identical state, batched is faster" do
      command_attrs_list = stress_corpus()

      # ── Path A ────────────────────────────────────────────────
      {instance_a, _accounts_a} = seed_instance_2acct("stress_a")
      commands_a = insert_commands(instance_a, command_attrs_list)

      prior = Application.get_env(:double_entry_ledger, :insert_path, :legacy)
      Application.put_env(:double_entry_ledger, :insert_path, :insert_all)

      {time_a_us, _} =
        :timer.tc(fn ->
          try do
            run_path_a(commands_a)
          after
            Application.put_env(:double_entry_ledger, :insert_path, prior)
          end
        end)

      snapshot_a = snapshot(instance_a.id)

      # ── Path B ────────────────────────────────────────────────
      {instance_b, _accounts_b} = seed_instance_2acct("stress_b")
      commands_b = insert_commands(instance_b, command_attrs_list)

      {time_b_us, batch_result} =
        :timer.tc(fn -> BatchProcessor.run_batch(commands_b, Repo) end)

      assert {:ok, _} = batch_result

      snapshot_b = snapshot(instance_b.id)

      # ── Asserts ───────────────────────────────────────────────
      assert_snapshots_equivalent!(snapshot_a, snapshot_b, command_attrs_list)

      ratio = time_b_us / time_a_us

      IO.puts(
        "\n[stress] Path A: #{Float.round(time_a_us / 1000, 1)} ms, " <>
          "Path B: #{Float.round(time_b_us / 1000, 1)} ms, " <>
          "ratio B/A: #{Float.round(ratio, 3)}"
      )

      # Path B must be at least 20% faster than Path A under
      # contention. A small safety margin (0.8 = 20% improvement) is
      # reasonable; the typical observed ratio is well below 0.5.
      assert time_b_us < time_a_us * 0.8,
             """
             expected batched path to be at least 20% faster
                 Path A: #{Float.round(time_a_us / 1000, 1)} ms
                 Path B: #{Float.round(time_b_us / 1000, 1)} ms
                 ratio (B/A): #{Float.round(ratio, 3)}
             """
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Generators
  # ─────────────────────────────────────────────────────────────────

  # Generates a list of 5..30 transaction-command attribute maps.
  # Each command:
  #   - has exactly 2 entries (one debit, one credit, balanced)
  #   - picks 2 distinct accounts from the pool of @num_accounts
  #   - random amount in [@amount_min, @amount_max]
  #   - status is :posted or :pending, ~50/50
  defp corpus_generator do
    addrs = Enum.map(1..@num_accounts, &account_address/1)

    StreamData.bind(
      StreamData.list_of(command_generator(addrs), min_length: 5, max_length: 30),
      fn raw_list ->
        # StreamData.list_of can shrink below min_length on rare paths;
        # filter+bind to constrain explicitly.
        if length(raw_list) >= 5 do
          StreamData.constant(stamp_unique_idempk(raw_list))
        else
          StreamData.constant(stamp_unique_idempk(raw_list ++ List.duplicate(hd(raw_list), 5 - length(raw_list))))
        end
      end
    )
  end

  defp command_generator(addrs) do
    StreamData.fixed_map(%{
      addr_pair: pair_of_distinct(addrs),
      amount: StreamData.integer(@amount_min..@amount_max),
      status: StreamData.member_of([:posted, :pending])
    })
    |> StreamData.map(fn %{addr_pair: [a, b], amount: amt, status: status} ->
      %{
        addr_a: a,
        addr_b: b,
        amount: amt,
        status: status
      }
    end)
  end

  defp pair_of_distinct(addrs) do
    StreamData.bind(StreamData.member_of(addrs), fn first ->
      others = Enum.reject(addrs, &(&1 == first))

      StreamData.map(StreamData.member_of(others), fn second ->
        [first, second]
      end)
    end)
  end

  defp stamp_unique_idempk(list) do
    list
    |> Enum.with_index(1)
    |> Enum.map(fn {cmd, idx} -> Map.put(cmd, :idempk_idx, idx) end)
  end

  # Stress corpus: 100 commands hitting the same 2 accounts.
  # Deterministic — uses :rand.uniform_s with a fixed seed instead of
  # StreamData so the workload doesn't shift across CI runs.
  defp stress_corpus do
    seed = :rand.seed_s(:exsplus, {7, 11, 13})

    {commands, _seed} =
      Enum.map_reduce(1..100, seed, fn idx, s ->
        {amount_pick, s} = :rand.uniform_s(@amount_max - @amount_min + 1, s)
        amount = amount_pick + @amount_min - 1
        {status_pick, s} = :rand.uniform_s(2, s)
        status = if status_pick == 1, do: :posted, else: :pending

        cmd = %{
          addr_a: stress_account_addr(1),
          addr_b: stress_account_addr(2),
          amount: amount,
          status: status,
          idempk_idx: idx
        }

        {cmd, s}
      end)

    commands
  end

  # ─────────────────────────────────────────────────────────────────
  # Seeding
  # ─────────────────────────────────────────────────────────────────

  defp seed_instance(suffix) do
    {:ok, instance} = Repo.insert(%Instance{address: "instance_#{suffix}"})

    accounts =
      Enum.map(1..@num_accounts, fn i ->
        seed_account(instance.id, account_address(i))
      end)

    {instance, accounts}
  end

  defp seed_instance_2acct(suffix) do
    {:ok, instance} = Repo.insert(%Instance{address: "instance_#{suffix}"})

    accounts = [
      seed_account(instance.id, stress_account_addr(1)),
      seed_account(instance.id, stress_account_addr(2))
    ]

    {instance, accounts}
  end

  defp seed_account(instance_id, address) do
    Repo.insert!(%Account{
      instance_id: instance_id,
      address: address,
      type: :asset,
      normal_balance: :debit,
      posted: %Balance{amount: @starting_balance, debit: @starting_balance, credit: 0},
      pending: %Balance{amount: 0, debit: 0, credit: 0},
      available: @starting_balance,
      negative_limit: 2_000_000_000,
      currency: :EUR
    })
  end

  defp account_address(i) do
    # The DB-level check constraint `address_format_chk` requires the
    # first segment to be `[A-Za-z0-9]+` (no underscores), so we put
    # the disambiguating index in a colon-separated second segment
    # where underscores ARE permitted.
    "acct:#{String.pad_leading(Integer.to_string(i), 4, "0")}"
  end

  defp stress_account_addr(i), do: "stress:acct_#{i}"

  # ─────────────────────────────────────────────────────────────────
  # Command insertion
  # ─────────────────────────────────────────────────────────────────

  # Given an instance and a list of raw command specs (output of the
  # generator), insert them as Commands via CommandStore.create/1 and
  # return them preloaded with :command_queue_item in the original
  # order. Order is significant — Path B's fold must see the same
  # claim order as Path A's serial loop.
  defp insert_commands(instance, command_attrs_list) do
    Enum.map(command_attrs_list, fn spec ->
      attrs = %TransactionCommandMap{
        action: :create_transaction,
        instance_address: instance.address,
        source: "equivalence_test",
        source_idempk: "idempk_#{spec.idempk_idx}",
        payload: %DoubleEntryLedger.Command.TransactionData{
          status: spec.status,
          entries: [
            %{account_address: spec.addr_a, amount: spec.amount, currency: :EUR},
            %{account_address: spec.addr_b, amount: -spec.amount, currency: :EUR}
          ]
        }
      }

      {:ok, command} = CommandStore.create(attrs)
      Repo.preload(command, [:command_queue_item], force: true)
    end)
  end

  # ─────────────────────────────────────────────────────────────────
  # Path runners
  # ─────────────────────────────────────────────────────────────────

  defp run_path_a(commands) do
    Enum.each(commands, fn cmd ->
      cmd_loaded = CommandStore.get_by_id(cmd.id)
      _ = CreateTransactionCommand.process(cmd_loaded)
    end)
  end

  # ─────────────────────────────────────────────────────────────────
  # Snapshots — copied/adapted from test/performance/batch_equivalence.exs.
  # Identical comparison criteria so the property test gives the same
  # signal as the standalone script.
  # ─────────────────────────────────────────────────────────────────

  defp snapshot(instance_id) do
    %{
      accounts: snapshot_accounts(instance_id),
      queue_items: snapshot_queue_items(instance_id),
      row_counts: snapshot_row_counts(instance_id),
      entry_sums: snapshot_entry_sums(instance_id)
    }
  end

  defp snapshot_accounts(instance_id) do
    import Ecto.Query, only: [from: 2]

    from(a in Account, where: a.instance_id == ^instance_id, order_by: a.address)
    |> Repo.all()
    |> Map.new(fn acc ->
      {acc.id,
       %{
         address: acc.address,
         posted: %{
           amount: acc.posted.amount,
           debit: acc.posted.debit,
           credit: acc.posted.credit
         },
         pending: %{
           amount: acc.pending.amount,
           debit: acc.pending.debit,
           credit: acc.pending.credit
         },
         available: acc.available,
         lock_version: acc.lock_version
       }}
    end)
  end

  defp snapshot_queue_items(instance_id) do
    import Ecto.Query, only: [from: 2]

    from(c in DoubleEntryLedger.Command,
      join: qi in DoubleEntryLedger.CommandQueueItem,
      on: qi.command_id == c.id,
      where: c.instance_id == ^instance_id,
      select: %{
        idempk: fragment("?->>'source_idempk'", c.command_map),
        status: qi.status,
        retry_count: qi.retry_count,
        errors: qi.errors,
        processor_id: qi.processor_id
      }
    )
    |> Repo.all()
    |> Map.new(fn row ->
      {row.idempk,
       %{
         status: row.status,
         retry_count: row.retry_count,
         errors_count: length(row.errors || []),
         processor_id_present: not is_nil(row.processor_id)
       }}
    end)
  end

  defp snapshot_row_counts(instance_id) do
    import Ecto.Query, only: [from: 2]

    %{
      transactions:
        Repo.one(
          from(t in DoubleEntryLedger.Transaction,
            where: t.instance_id == ^instance_id,
            select: count(t.id)
          )
        ),
      entries:
        Repo.one(
          from(e in DoubleEntryLedger.Entry,
            join: t in assoc(e, :transaction),
            where: t.instance_id == ^instance_id,
            select: count(e.id)
          )
        ),
      balance_history_entries:
        Repo.one(
          from(b in DoubleEntryLedger.BalanceHistoryEntry,
            join: a in assoc(b, :account),
            where: a.instance_id == ^instance_id,
            select: count(b.id)
          )
        ),
      journal_events:
        Repo.one(
          from(j in DoubleEntryLedger.JournalEvent,
            where: j.instance_id == ^instance_id,
            select: count(j.id)
          )
        ),
      pending_transaction_lookup:
        Repo.one(
          from(p in DoubleEntryLedger.PendingTransactionLookup,
            where: p.instance_id == ^instance_id,
            select: count(p.source_idempk)
          )
        )
    }
  end

  # Per (account_address, type) sum of entry.value.amount.
  # Computed in two queries — entries joined to their accounts (so we
  # can re-key by address, stable across instances), and grouped in
  # Elixir for clarity.
  defp snapshot_entry_sums(instance_id) do
    import Ecto.Query, only: [from: 2]

    from(e in DoubleEntryLedger.Entry,
      join: a in assoc(e, :account),
      where: a.instance_id == ^instance_id,
      group_by: [a.address, e.type],
      select: {a.address, e.type, sum(fragment("(?->>'amount')::bigint", e.value))}
    )
    |> Repo.all()
    |> Map.new(fn {addr, type, sum} -> {{addr, type}, sum} end)
  end

  # ─────────────────────────────────────────────────────────────────
  # Comparison
  # ─────────────────────────────────────────────────────────────────

  defp assert_snapshots_equivalent!(snap_a, snap_b, command_attrs_list) do
    account_mismatches = compare_accounts(snap_a, snap_b)
    queue_mismatches = compare_queue_items(snap_a, snap_b)
    row_count_mismatches = compare_row_counts(snap_a, snap_b)
    entry_sum_mismatches = compare_entry_sums(snap_a, snap_b)

    all_pass =
      account_mismatches == [] and queue_mismatches == [] and row_count_mismatches == [] and
        entry_sum_mismatches == []

    assert all_pass,
           build_diff_message(
             account_mismatches,
             queue_mismatches,
             row_count_mismatches,
             entry_sum_mismatches,
             command_attrs_list
           )
  end

  defp compare_accounts(snap_a, snap_b) do
    a_by_addr = re_key_by_address(snap_a.accounts)
    b_by_addr = re_key_by_address(snap_b.accounts)

    addrs = Enum.uniq(Enum.sort(Map.keys(a_by_addr) ++ Map.keys(b_by_addr)))

    Enum.reduce(addrs, [], fn addr, acc ->
      a = Map.get(a_by_addr, addr)
      b = Map.get(b_by_addr, addr)

      if a == b do
        acc
      else
        [{addr, a, b} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp re_key_by_address(map) do
    Map.new(map, fn {_id, v} -> {v.address, Map.delete(v, :address)} end)
  end

  defp compare_queue_items(snap_a, snap_b) do
    a = snap_a.queue_items
    b = snap_b.queue_items

    keys = Enum.uniq(Enum.sort(Map.keys(a) ++ Map.keys(b)))

    Enum.reduce(keys, [], fn k, acc ->
      if Map.get(a, k) == Map.get(b, k) do
        acc
      else
        [{k, Map.get(a, k), Map.get(b, k)} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp compare_row_counts(snap_a, snap_b) do
    a = snap_a.row_counts
    b = snap_b.row_counts

    Enum.reduce(Map.keys(a), [], fn k, acc ->
      if Map.get(a, k) == Map.get(b, k) do
        acc
      else
        [{k, Map.get(a, k), Map.get(b, k)} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp compare_entry_sums(snap_a, snap_b) do
    a = snap_a.entry_sums
    b = snap_b.entry_sums

    keys = Enum.uniq(Enum.sort(Map.keys(a) ++ Map.keys(b)))

    Enum.reduce(keys, [], fn k, acc ->
      if Map.get(a, k) == Map.get(b, k) do
        acc
      else
        [{k, Map.get(a, k), Map.get(b, k)} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp build_diff_message(
         account_mismatches,
         queue_mismatches,
         row_count_mismatches,
         entry_sum_mismatches,
         command_attrs_list
       ) do
    [
      "Path A vs Path B snapshots diverged.\n",
      "Corpus size: #{length(command_attrs_list)}\n",
      "First 3 commands: #{inspect(Enum.take(command_attrs_list, 3))}\n",
      section("account state", account_mismatches, fn {addr, a, b} ->
        "  #{addr}:\n    A=#{inspect(a)}\n    B=#{inspect(b)}"
      end),
      section("command queue", queue_mismatches, fn {idempk, a, b} ->
        "  #{idempk}: A=#{inspect(a)} B=#{inspect(b)}"
      end),
      section("row counts", row_count_mismatches, fn {table, a, b} ->
        "  #{table}: A=#{a} B=#{b}"
      end),
      section("entry sums", entry_sum_mismatches, fn {{addr, type}, a, b} ->
        "  #{addr}/#{type}: A=#{inspect(a)} B=#{inspect(b)}"
      end)
    ]
    |> Enum.join("\n")
  end

  defp section(_label, [], _fmt), do: ""

  defp section(label, mismatches, fmt) do
    header = "\n--- #{label} (#{length(mismatches)} mismatches) ---"
    body = mismatches |> Enum.take(5) |> Enum.map(fmt) |> Enum.join("\n")
    extra = if length(mismatches) > 5, do: "\n  ... (#{length(mismatches) - 5} more)", else: ""
    header <> "\n" <> body <> extra
  end
end
