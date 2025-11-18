defmodule DoubleEntryLedger.Workers.CommandWorker.AccountCommandMapResponseHandlerTest do
  @moduledoc """
    Tests for the AccountCommandResponseHandler
  """
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Workers.CommandWorker.AccountCommandMapResponseHandler
  alias DoubleEntryLedger.{Account, Command}
  alias DoubleEntryLedger.Command.{AccountCommandMap, AccountData}

  doctest AccountCommandMapResponseHandler
end
