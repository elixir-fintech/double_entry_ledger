defmodule DoubleEntryLedger.Stores.JournalEventStoreTest do
  @moduledoc """
  This module tests the EventStore module.
  """
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Stores.{
    JournalEventStore,
    JournalEventStoreHelper
  }

  doctest JournalEventStoreHelper
  doctest JournalEventStore
end
