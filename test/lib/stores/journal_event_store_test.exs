defmodule DoubleEntryLedger.Stores.JournalEventStoreTest do
  @moduledoc """
  This module tests the CommandStore module.
  """
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Stores.{
    AccountStore,
    InstanceStore,
    JournalEventStore,
    JournalEventStoreHelper,
    TransactionStore
  }

  doctest JournalEventStoreHelper
  doctest JournalEventStore
end
