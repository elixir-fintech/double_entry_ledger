defmodule DoubleEntryLedger.CommandQueue.KnownKeysTest do
  @moduledoc """
  Source-level guard for `CommandQueue.Config.known_keys/0`.

  `Config.warn_stale_config/0` warns about any `:command_queue` key that is not
  in `known_keys/0`, so a key that some module reads but nobody registered
  would make the library warn about correct configuration — worse than the
  silence the warning replaces. These tests derive the reader set from `lib/`
  instead of trusting the list.

  Two syntactic forms read a key out of the list today, and the scan covers
  both: a `compile_env` key path (`[:command_queue, :key]`) and a keyword
  access on the fetched list (`get_env(..., :command_queue, [])[:key]`). A
  third form would slip past the key scan, which is what the reader-file test
  is for: it fails when any file other than the three known readers reaches
  for the list at all, in whatever shape. `get_all_env` counts as reaching
  for the list, since it returns it.
  """
  use ExUnit.Case, async: true

  alias DoubleEntryLedger.CommandQueue.Config

  # Any Application.*_env call whose argument list mentions the queue key, or
  # any `get_all_env` call at all: that one returns the whole environment, the
  # list included, without ever naming `:command_queue` in its arguments.
  # `[^)]` matches newlines, so a formatter-wrapped call still matches.
  @reader ~r/Application\.(?:(?:get_env|compile_env!?|fetch_env!?)\([^)]*:command_queue\b|get_all_env\()/
  @key_path ~r/\[:command_queue,\s*:([a-z_]+)\]/
  @keyword_access ~r/:command_queue,\s*\[\]\)\[:([a-z_]+)\]/

  # `Config` itself reads through `get/1` against `@defaults`, so it names no
  # key literally; it is a reader of the list all the same.
  @reader_files [
    "lib/double_entry_ledger/command_queue/config.ex",
    "lib/double_entry_ledger/command_queue/lease.ex",
    "lib/double_entry_ledger/command_queue/scheduling.ex"
  ]

  defp lib_files, do: Path.wildcard("lib/**/*.ex")

  defp keys_read_in(file) do
    content = File.read!(file)

    Regex.scan(@key_path, content, capture: :all_but_first) ++
      Regex.scan(@keyword_access, content, capture: :all_but_first)
  end

  defp keys_read_in_lib do
    lib_files()
    |> Enum.flat_map(&keys_read_in/1)
    |> List.flatten()
    |> Enum.map(&String.to_existing_atom/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  test "the wildcard actually reads the library source" do
    assert "lib/double_entry_ledger/command_queue/config.ex" in lib_files()
  end

  test "the scan finds the keys read outside Config" do
    assert keys_read_in_lib() == [
             :base_retry_delay,
             :max_retries,
             :max_retry_delay,
             :processor_name
           ]
  end

  test "every key lib/ reads out of the list is a known key" do
    assert keys_read_in_lib() -- Config.known_keys() == []
  end

  # The tripwire is only as good as the forms it recognises; one test per form.
  test "the reader regex matches get_env on the list" do
    assert Regex.match?(@reader, "Application.get_env(:double_entry_ledger, :command_queue, [])")
  end

  test "the reader regex matches fetch_env! on the list" do
    assert Regex.match?(@reader, "Application.fetch_env!(:double_entry_ledger, :command_queue)")
  end

  test "the reader regex matches compile_env on a key path" do
    assert Regex.match?(
             @reader,
             "Application.compile_env(:double_entry_ledger, [:command_queue, :max_retries], 5)"
           )
  end

  test "the reader regex matches compile_env! on the list" do
    assert Regex.match?(@reader, "Application.compile_env!(:double_entry_ledger, :command_queue)")
  end

  test "the reader regex matches get_all_env, which never names the list" do
    assert Regex.match?(@reader, "Application.get_all_env(:double_entry_ledger)[:command_queue]")
  end

  test "the reader regex ignores a get_env call on another key" do
    refute Regex.match?(@reader, "Application.get_env(:double_entry_ledger, :serialize_enqueue)")
  end

  test "only the three known modules reach for the :command_queue list" do
    readers = Enum.filter(lib_files(), &Regex.match?(@reader, File.read!(&1)))

    assert Enum.sort(readers) == @reader_files
  end

  test "known_keys is the nine Config owns plus the four read elsewhere" do
    assert Enum.sort(Config.known_keys()) == [
             :base_retry_delay,
             :batch_enabled,
             :batch_size,
             :coordination_strategy,
             :lease_lock_timeout_ms,
             :lease_ttl,
             :max_concurrent_acquisitions,
             :max_leases_per_node,
             :max_retries,
             :max_retry_delay,
             :pending_fetch_limit,
             :poll_interval,
             :processor_name
           ]
  end

  test "known_keys has no duplicates" do
    assert Enum.uniq(Config.known_keys()) == Config.known_keys()
  end
end
