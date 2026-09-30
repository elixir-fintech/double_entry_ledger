defmodule DoubleEntryLedger.CommandQueue.UnifiedFencingTest do
  @moduledoc """
  Compile-level guard: the ledger lease is the only ownership mechanism.

  Migration modules are excluded — V1 creates `processor_version` and V6 drops
  it, so they describe history rather than a live fence.
  """
  use ExUnit.Case, async: true

  @removed ~w(
    processor_version
    OwnershipError
    command_ownership_lost
    command_already_claimed
    stale_processing_after
    stale_processing
    processing_age_seconds
  )

  test "no removed ownership mechanism is referenced in lib/" do
    hits =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, "/migration/"))
      |> Enum.flat_map(fn file ->
        content = File.read!(file)
        @removed |> Enum.filter(&String.contains?(content, &1)) |> Enum.map(&{file, &1})
      end)

    assert hits == []
  end

  test "the wildcard actually reads the library source" do
    files = "lib/**/*.ex" |> Path.wildcard() |> Enum.reject(&String.contains?(&1, "/migration/"))

    assert "lib/double_entry_ledger/command_queue/lease.ex" in files
  end

  test "CommandQueueItem has no processor_version field" do
    refute :processor_version in DoubleEntryLedger.CommandQueueItem.__schema__(:fields)
  end
end
