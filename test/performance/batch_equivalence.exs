# Equivalence script for the multi-command batching work (Step 6).
#
# Generates N random valid `:create_transaction` commands, runs them
# through:
#   - Path A: legacy single-command worker
#     `CreateTransactionCommand.process/2` with
#     `:insert_path = :insert_all`.
#   - Path B: orchestrator `BatchProcessor.run_batch/2`.
# After each path, snapshots the relevant DB state, then diffs the two
# snapshots. Exits 0 on equivalence, non-zero on divergence.
#
# Run with:
#   MIX_ENV=equiv mix run --no-start test/performance/batch_equivalence.exs
#
# The dedicated `:equiv` Mix env uses its own database
# (`double_entry_ledger_repo_equivalence`) so leftover rows from the
# script's runs never pollute the `:test` DB. The script creates and
# migrates the database on first run; subsequent runs reuse it (the
# script truncates between paths regardless). `--no-start` ensures the
# app boots AFTER the DB is ready, avoiding noisy connect-failure logs
# on the first run.
#
# Configurable via env var:
#   BATCH_EQ_N — number of commands to generate (default 200).

require Logger
import Ecto.Query, only: [from: 2]

alias DoubleEntryLedger.{
  Account,
  Balance,
  BatchProcessor,
  Command,
  Config,
  Instance,
  Repo
}

alias DoubleEntryLedger.Stores.CommandStore
alias DoubleEntryLedger.Workers.CommandWorker.CreateTransactionCommand
alias DoubleEntryLedger.Workers.CommandWorker.UpdateTransactionCommand

# ── boot setup ────────────────────────────────────────────────────────

# Refuse to run under the wrong env. Running this script with
# `MIX_ENV=test` (the previous default) silently pollutes the test DB
# with leftover instances — that's what introduced the
# `instance:eq:b` ghost row that broke `instance_store_test` until it
# was hand-truncated.
if Mix.env() != :equiv do
  Mix.raise("""
  batch_equivalence.exs must run under MIX_ENV=equiv to keep its
  output out of the test / dev / perf databases.

      MIX_ENV=equiv mix run --no-start test/performance/batch_equivalence.exs

  Current MIX_ENV=#{Mix.env()}.
  """)
end

# `mix run --no-start` skipped starting the app. First make sure the
# DB exists and is migrated, THEN start the app — this avoids Repo and
# Oban's noisy connect-failure logs on the first run.
Mix.Task.run("ecto.create", ["--quiet"])
Mix.Task.run("ecto.migrate", ["--quiet"])
Mix.Task.run("app.start", [])

# Squelch the per-batch processed log lines from CreateTransactionCommand
# during Path A — the repeated "Processed successfully" warnings would
# bury the actual report. We restore the level on exit.
prior_log_level = Logger.level()
Logger.configure(level: :critical)

schema_prefix = Config.schema_prefix()

# Tables we touch. Truncate together with RESTART IDENTITY CASCADE so
# we get a clean slate before each path runs.
truncate_tables = [
  "transactions",
  "entries",
  "accounts",
  "balance_history_entries",
  "journal_events",
  "pending_transaction_lookup",
  "commands",
  "command_queue_items",
  "instances"
]

prior_insert_path = Application.get_env(:double_entry_ledger, :insert_path, :legacy)

# ── deterministic RNG ─────────────────────────────────────────────────

n =
  case System.get_env("BATCH_EQ_N") do
    nil -> 200
    str -> String.to_integer(str)
  end

seed = {1, 2, 3}
:rand.seed(:exsplus, seed)

# ── helpers ───────────────────────────────────────────────────────────

defmodule BatchEquivalence do
  @moduledoc false

  alias DoubleEntryLedger.{
    Account,
    Balance,
    Command,
    Instance,
    Repo
  }

  alias DoubleEntryLedger.Stores.CommandStore

  @num_accounts 10

  # Truncate all the listed tables in one statement. Using a single
  # TRUNCATE ... RESTART IDENTITY CASCADE keeps it atomic.
  def truncate!(tables, prefix) do
    qualified =
      tables
      |> Enum.map(fn t -> ~s("#{prefix}".#{t}) end)
      |> Enum.join(", ")

    sql = "TRUNCATE #{qualified} RESTART IDENTITY CASCADE"
    Ecto.Adapters.SQL.query!(Repo, sql, [])
    :ok
  end

  # Seed an instance + N accounts. Uses the supplied RNG state so the
  # generated addresses (and hence account ordering / preload state)
  # are deterministic across runs.
  #
  # Returns {instance, ordered_accounts}.
  def seed_instance_and_accounts(instance_address) do
    {:ok, instance} = Repo.insert(%Instance{address: instance_address})

    # Half the accounts have :debit normal_balance (asset), half :credit
    # (liability). Each starts with a non-zero balance so transactions
    # can hit any pair without underflow at small amounts.
    # All accounts are asset / debit-normal so that the simple "N-1
    # positive amounts + one negative balancer" generator below
    # produces balanced entries regardless of which accounts get
    # picked. Using mixed normal_balance would make the balance check
    # depend on which accounts the RNG happened to choose for each
    # entry, which adds combinatoric complexity without adding
    # equivalence coverage at this stage.
    accounts =
      Enum.map(1..@num_accounts, fn i ->
        starting = 10_000_000

        %Account{
          instance_id: instance.id,
          address: "acct:#{String.pad_leading(Integer.to_string(i), 4, "0")}",
          type: :asset,
          normal_balance: :debit,
          posted: %Balance{amount: starting, debit: starting, credit: 0},
          pending: %Balance{amount: 0, debit: 0, credit: 0},
          available: starting,
          # Keep negative_limit large enough that amounts in our small
          # range never trip a validation failure (PG int32 cap is
          # ~2.1B). Equivalence verifies success cases here, not
          # failure handling.
          negative_limit: 2_000_000_000,
          currency: :EUR
        }
        |> Repo.insert!()
      end)

    {instance, accounts}
  end

  # Generate a deterministic mixed corpus: N create commands plus a
  # subset of update commands targeting :pending creates. Returns
  # `%{creates: [create_attrs], updates: [update_attrs]}`.
  #
  # Each create:
  #   - has 2..5 entries (random within bounds)
  #   - is balanced per currency (single currency = :EUR for simplicity)
  #   - alternates between :posted and :pending status (~50/50)
  #   - has a unique source_idempk
  #
  # Each update:
  #   - targets a :pending create's source_idempk
  #   - new_status uniformly :posted / :pending / :archived
  #   - payload entries mirror the create's accounts (so non-archived
  #     transitions exercise the entry-update path; for :archived the
  #     schema strips entries anyway)
  #   - At most one update per create.
  def generate_command_attrs(n, instance, accounts) do
    addrs = Enum.map(accounts, & &1.address)

    creates =
      Enum.map(1..n, fn i ->
        entry_count = 2 + :rand.uniform(4) - 1
        status = if :rand.uniform(2) == 1, do: :posted, else: :pending

        amounts_head =
          Enum.map(1..(entry_count - 1), fn _ -> 10 + :rand.uniform(491) end)

        total = Enum.sum(amounts_head)
        amounts = amounts_head ++ [-total]
        shuffled = Enum.take_random(addrs, entry_count)

        entries =
          Enum.zip(shuffled, amounts)
          |> Enum.map(fn {addr, amt} ->
            %{account_address: addr, amount: amt, currency: :EUR}
          end)

        %{
          action: :create_transaction,
          instance_address: instance.address,
          source: "equivalence",
          source_idempk: "idempk-#{i}",
          payload: %{status: status, entries: entries}
        }
      end)

    # Pick a random subset (~50%) of :pending creates and emit an update
    # for each. Update entries mirror the create's accounts/amounts so
    # validation passes on the batched path (type preservation).
    updates =
      creates
      |> Enum.filter(&(&1.payload.status == :pending))
      |> Enum.filter(fn _ -> :rand.uniform(2) == 1 end)
      |> Enum.map(fn create ->
        new_status = Enum.random([:posted, :pending, :archived])
        new_amounts = regenerate_amounts(length(create.payload.entries))

        new_entries =
          Enum.zip(
            Enum.map(create.payload.entries, & &1.account_address),
            new_amounts
          )
          |> Enum.map(fn {addr, amt} ->
            %{account_address: addr, amount: amt, currency: :EUR}
          end)

        %{
          action: :update_transaction,
          instance_address: instance.address,
          source: create.source,
          source_idempk: create.source_idempk,
          update_idempk: "upd-#{create.source_idempk}",
          payload: %{status: new_status, entries: new_entries}
        }
      end)

    %{creates: creates, updates: updates}
  end

  defp regenerate_amounts(n) when n >= 2 do
    head = Enum.map(1..(n - 1), fn _ -> 10 + :rand.uniform(491) end)
    total = Enum.sum(head)
    head ++ [-total]
  end

  # Insert one batch of commands (creates OR updates). Returns commands
  # preloaded with :command_queue_item, in the original order.
  def insert_commands(command_attrs) do
    Enum.map(command_attrs, fn attrs ->
      {:ok, cmd_map} = DoubleEntryLedger.Command.TransactionCommandMap.create(attrs)
      {:ok, command} = CommandStore.create(cmd_map)

      command
      |> Repo.preload([:command_queue_item], force: true)
    end)
  end

  # Run Path A creates: per-command CreateTransactionCommand.process/2.
  # Returns {success_count, failure_count}.
  def run_path_a_creates(command_ids) do
    Enum.reduce(command_ids, {0, 0}, fn cid, {ok, err} ->
      command = CommandStore.get_by_id(cid)

      case CreateTransactionCommand.process(command) do
        {:ok, _txn, _cmd} -> {ok + 1, err}
        {:error, _} -> {ok, err + 1}
      end
    end)
  end

  # Run Path A updates: per-command UpdateTransactionCommand.process/2.
  # Each update sees its target create's tx already committed.
  def run_path_a_updates(command_ids) do
    Enum.reduce(command_ids, {0, 0}, fn cid, {ok, err} ->
      command = CommandStore.get_by_id(cid)

      case UpdateTransactionCommand.process(command) do
        {:ok, _txn, _cmd} -> {ok + 1, err}
        {:error, _} -> {ok, err + 1}
      end
    end)
  end

  # Run Path B: orchestrator. Chunks `commands` into batches of
  # `batch_size` (configurable via BATCH_SIZE env var, default 100) to
  # mirror production's `InstanceProcessor.batch_size/0` chunking
  # before calling `run_batch/2`. Without chunking, large N hits
  # Postgres' 65535 SQL parameter ceiling — the InstanceProcessor
  # never sends a 50k-command batch to a single CTE bundle in
  # production, so neither should the equivalence test.
  #
  # Returns {:ok, success_count, failure_count} aggregated across all
  # sub-batches, or the first {:error, reason}.
  def run_path_b(commands) do
    chunks = Enum.chunk_every(commands, batch_size())

    Enum.reduce_while(chunks, {:ok, 0, 0}, fn chunk, {:ok, ok_acc, err_acc} ->
      case BatchProcessor.run_batch(chunk, Repo) do
        {:ok, %{successes: s, failures: f}} ->
          {:cont, {:ok, ok_acc + length(s), err_acc + length(f)}}

        {:error, _reason} = err ->
          {:halt, err}
      end
    end)
  end

  defp batch_size do
    case System.get_env("BATCH_SIZE") do
      nil -> 100
      str -> String.to_integer(str)
    end
  end

  # ── snapshot helpers ────────────────────────────────────────────────

  def snapshot(instance_id) do
    %{
      accounts: snapshot_accounts(instance_id),
      queue_items: snapshot_queue_items(instance_id),
      row_counts: snapshot_row_counts(instance_id),
      entry_sums: snapshot_entry_sums(instance_id)
    }
  end

  defp snapshot_accounts(instance_id) do
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

  # Key by (action, source_idempk, update_idempk) so creates and
  # updates sharing a source_idempk are distinguished in the snapshot.
  defp snapshot_queue_items(instance_id) do
    from(c in DoubleEntryLedger.Command,
      join: qi in DoubleEntryLedger.CommandQueueItem,
      on: qi.command_id == c.id,
      where: c.instance_id == ^instance_id,
      select: %{
        action: fragment("?->>'action'", c.command_map),
        idempk: fragment("?->>'source_idempk'", c.command_map),
        update_idempk: fragment("?->>'update_idempk'", c.command_map),
        status: qi.status,
        retry_count: qi.retry_count,
        errors: qi.errors,
        processor_id: qi.processor_id
      }
    )
    |> Repo.all()
    |> Map.new(fn row ->
      {{row.action, row.idempk, row.update_idempk},
       %{
         status: row.status,
         retry_count: row.retry_count,
         errors_count: length(row.errors || []),
         processor_id_present: not is_nil(row.processor_id)
       }}
    end)
  end

  defp snapshot_row_counts(instance_id) do
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

  # Sum of entry.value.amount per (account_id, type) — independent of
  # transaction id / entry id, so it survives the differing UUIDs
  # generated by each path.
  defp snapshot_entry_sums(instance_id) do
    from(e in DoubleEntryLedger.Entry,
      join: a in assoc(e, :account),
      where: a.instance_id == ^instance_id,
      group_by: [e.account_id, e.type],
      select: {e.account_id, e.type, sum(fragment("(?->>'amount')::bigint", e.value))}
    )
    |> Repo.all()
    |> Map.new(fn {acc_id, type, sum} -> {{acc_id, type}, sum} end)
  end
end

# ── run path A ────────────────────────────────────────────────────────

IO.puts("=== batch_equivalence: N=#{n}, seed=#{inspect(seed)} ===")

BatchEquivalence.truncate!(truncate_tables, schema_prefix)

instance_address_a = "instance:eq:a"
{instance_a, accounts_a} = BatchEquivalence.seed_instance_and_accounts(instance_address_a)
:rand.seed(:exsplus, seed)
%{creates: create_attrs_a, updates: update_attrs_a} =
  BatchEquivalence.generate_command_attrs(n, instance_a, accounts_a)

create_cmds_a = BatchEquivalence.insert_commands(create_attrs_a)
update_cmds_a = BatchEquivalence.insert_commands(update_attrs_a)
create_ids_a = Enum.map(create_cmds_a, & &1.id)
update_ids_a = Enum.map(update_cmds_a, & &1.id)

Application.put_env(:double_entry_ledger, :insert_path, :insert_all)

IO.puts("=== Path A (insert_all) ===")
IO.puts(
  "N creates: #{length(create_attrs_a)}, N updates: #{length(update_attrs_a)}"
)

t0_a = System.monotonic_time()
{ok_creates_a, err_creates_a} = BatchEquivalence.run_path_a_creates(create_ids_a)
{ok_updates_a, err_updates_a} = BatchEquivalence.run_path_a_updates(update_ids_a)
elapsed_a = System.convert_time_unit(System.monotonic_time() - t0_a, :native, :millisecond)

IO.puts("Path A duration: #{Float.round(elapsed_a / 1000, 3)}s")
IO.puts("Path A creates:  successes=#{ok_creates_a}, failures=#{err_creates_a}")
IO.puts("Path A updates:  successes=#{ok_updates_a}, failures=#{err_updates_a}")

snapshot_a = BatchEquivalence.snapshot(instance_a.id)

# ── run path B ────────────────────────────────────────────────────────

BatchEquivalence.truncate!(truncate_tables, schema_prefix)

instance_address_b = "instance:eq:b"
{instance_b, accounts_b} = BatchEquivalence.seed_instance_and_accounts(instance_address_b)
:rand.seed(:exsplus, seed)
%{creates: create_attrs_b, updates: update_attrs_b} =
  BatchEquivalence.generate_command_attrs(n, instance_b, accounts_b)

create_cmds_b = BatchEquivalence.insert_commands(create_attrs_b)
update_cmds_b = BatchEquivalence.insert_commands(update_attrs_b)

IO.puts("\n=== Path B (run_batch) ===")
IO.puts(
  "N creates: #{length(create_attrs_b)}, N updates: #{length(update_attrs_b)}"
)

t0_b = System.monotonic_time()
create_result_b = BatchEquivalence.run_path_b(create_cmds_b)
update_result_b = BatchEquivalence.run_path_b(update_cmds_b)
elapsed_b = System.convert_time_unit(System.monotonic_time() - t0_b, :native, :millisecond)

IO.puts("Path B duration: #{Float.round(elapsed_b / 1000, 3)}s")

case {create_result_b, update_result_b} do
  {{:ok, ok_c, err_c}, {:ok, ok_u, err_u}} ->
    IO.puts("Path B creates: successes=#{ok_c}, failures=#{err_c}")
    IO.puts("Path B updates: successes=#{ok_u}, failures=#{err_u}")

  {_, _} ->
    IO.puts("Path B errored: creates=#{inspect(create_result_b)} updates=#{inspect(update_result_b)}")
    Application.put_env(:double_entry_ledger, :insert_path, prior_insert_path)
    Logger.configure(level: prior_log_level)
    System.halt(1)
end

snapshot_b = BatchEquivalence.snapshot(instance_b.id)

# Restore config now — we have the snapshots, the rest is pure compare.
Application.put_env(:double_entry_ledger, :insert_path, prior_insert_path)
Logger.configure(level: prior_log_level)

# ── compare ───────────────────────────────────────────────────────────

defmodule BatchEquivalence.Compare do
  @moduledoc false

  # Account snapshots are keyed by id (different per run). Re-key by
  # the human-stable address before comparing.
  def compare_accounts(snap_a, snap_b) do
    a_by_addr = re_key_by_address(snap_a.accounts)
    b_by_addr = re_key_by_address(snap_b.accounts)

    addrs = Enum.sort(Map.keys(a_by_addr) ++ Map.keys(b_by_addr)) |> Enum.uniq()

    {matches, mismatches} =
      Enum.reduce(addrs, {0, []}, fn addr, {ok, bad} ->
        a = Map.get(a_by_addr, addr)
        b = Map.get(b_by_addr, addr)

        if compare_account_state(a, b) do
          {ok + 1, bad}
        else
          {ok, [{addr, a, b} | bad]}
        end
      end)

    {matches, length(addrs), Enum.reverse(mismatches)}
  end

  defp re_key_by_address(map) do
    Map.new(map, fn {_id, v} -> {v.address, Map.delete(v, :address)} end)
  end

  defp compare_account_state(nil, nil), do: true
  defp compare_account_state(nil, _), do: false
  defp compare_account_state(_, nil), do: false

  defp compare_account_state(a, b) do
    a.posted == b.posted and
      a.pending == b.pending and
      a.available == b.available and
      a.lock_version == b.lock_version
  end

  # Queue items are keyed by (action, source_idempk, update_idempk) —
  # stable across runs and distinguishes creates vs updates sharing
  # a source_idempk. See snapshot_queue_items.
  def compare_queue_items(snap_a, snap_b) do
    a = snap_a.queue_items
    b = snap_b.queue_items

    keys = Enum.sort(Map.keys(a) ++ Map.keys(b)) |> Enum.uniq()

    {matches, mismatches} =
      Enum.reduce(keys, {0, []}, fn k, {ok, bad} ->
        if Map.get(a, k) == Map.get(b, k) do
          {ok + 1, bad}
        else
          {ok, [{k, Map.get(a, k), Map.get(b, k)} | bad]}
        end
      end)

    {matches, length(keys), Enum.reverse(mismatches)}
  end

  def compare_row_counts(snap_a, snap_b) do
    a = snap_a.row_counts
    b = snap_b.row_counts

    keys = Map.keys(a)

    {matches, mismatches} =
      Enum.reduce(keys, {0, []}, fn k, {ok, bad} ->
        if Map.get(a, k) == Map.get(b, k) do
          {ok + 1, bad}
        else
          {ok, [{k, Map.get(a, k), Map.get(b, k)} | bad]}
        end
      end)

    {matches, length(keys), Enum.reverse(mismatches)}
  end

  # Entry sums are keyed by (account_id, type) — account_id differs
  # between runs, so re-key by (account_address, type) using the
  # account snapshot to translate.
  def compare_entry_sums(snap_a, snap_b) do
    a = re_key_sums(snap_a)
    b = re_key_sums(snap_b)

    keys = Enum.sort(Map.keys(a) ++ Map.keys(b)) |> Enum.uniq()

    {matches, mismatches} =
      Enum.reduce(keys, {0, []}, fn k, {ok, bad} ->
        if Map.get(a, k) == Map.get(b, k) do
          {ok + 1, bad}
        else
          {ok, [{k, Map.get(a, k), Map.get(b, k)} | bad]}
        end
      end)

    {matches, length(keys), Enum.reverse(mismatches)}
  end

  defp re_key_sums(snapshot) do
    addr_by_id = Map.new(snapshot.accounts, fn {id, v} -> {id, v.address} end)

    Map.new(snapshot.entry_sums, fn {{acc_id, type}, sum} ->
      {{Map.fetch!(addr_by_id, acc_id), type}, sum}
    end)
  end
end

defmodule BatchEquivalence.Report do
  @moduledoc false

  def line(label, matches, total, mismatches, sample_fmt) do
    status = if mismatches == [], do: "PASS", else: "FAIL"
    IO.puts("[#{status}] #{label}: #{matches}/#{total} identical")

    if mismatches != [] do
      mismatches
      |> Enum.take(5)
      |> Enum.each(fn entry -> IO.puts("    " <> sample_fmt.(entry)) end)

      if length(mismatches) > 5 do
        IO.puts("    ... (#{length(mismatches) - 5} more)")
      end
    end
  end
end

IO.puts("\n=== Equivalence checks ===")

{a_match, a_total, a_mis} = BatchEquivalence.Compare.compare_accounts(snapshot_a, snapshot_b)

BatchEquivalence.Report.line(
  "account final state",
  a_match,
  a_total,
  a_mis,
  fn {addr, a, b} -> "#{addr}: A=#{inspect(a)}  B=#{inspect(b)}" end
)

{q_match, q_total, q_mis} = BatchEquivalence.Compare.compare_queue_items(snapshot_a, snapshot_b)

BatchEquivalence.Report.line(
  "command queue state",
  q_match,
  q_total,
  q_mis,
  fn {k, a, b} -> "#{k}: A=#{inspect(a)}  B=#{inspect(b)}" end
)

{r_match, r_total, r_mis} = BatchEquivalence.Compare.compare_row_counts(snapshot_a, snapshot_b)

BatchEquivalence.Report.line(
  "total row counts",
  r_match,
  r_total,
  r_mis,
  fn {k, a, b} -> "#{k}: A=#{a}  B=#{b}" end
)

{s_match, s_total, s_mis} = BatchEquivalence.Compare.compare_entry_sums(snapshot_a, snapshot_b)

BatchEquivalence.Report.line(
  "per-account entry sums",
  s_match,
  s_total,
  s_mis,
  fn {{addr, type}, a, b} -> "#{addr}/#{type}: A=#{inspect(a)}  B=#{inspect(b)}" end
)

all_pass = a_mis == [] and q_mis == [] and r_mis == [] and s_mis == []

if all_pass do
  IO.puts("\n=== RESULT: EQUIVALENT ===")
  System.halt(0)
else
  IO.puts("\n=== RESULT: DIVERGED ===")
  System.halt(1)
end
