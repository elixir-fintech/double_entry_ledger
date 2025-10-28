defmodule DoubleEntryLedger.Workers.CommandWorker.AccountEventMapResponseHandlerTest do
  @moduledoc """
    Tests for the AccountEventResponseHandler
  """
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Workers.CommandWorker.AccountEventMapResponseHandler
  alias DoubleEntryLedger.{Account, Command}
  alias DoubleEntryLedger.Command.{AccountEventMap, AccountData}

  doctest AccountEventMapResponseHandler
end
