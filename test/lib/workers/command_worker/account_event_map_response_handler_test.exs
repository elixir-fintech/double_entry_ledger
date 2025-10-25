defmodule DoubleEntryLedger.Workers.CommandWorker.AccountEventMapResponseHandlerTest do
  @moduledoc """
    Tests for the AccountEventResponseHandler
  """
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Workers.CommandWorker.AccountEventMapResponseHandler
  alias DoubleEntryLedger.{Account, Event}
  alias DoubleEntryLedger.Event.{AccountEventMap, AccountData}

  doctest AccountEventMapResponseHandler
end
