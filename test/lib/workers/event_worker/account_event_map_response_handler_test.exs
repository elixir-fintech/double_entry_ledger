defmodule DoubleEntryLedger.Workers.EventWorker.AccountEventMapResponseHandlerTest do
  @moduledoc """
    Tests for the AccountEventResponseHandler
  """
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Workers.EventWorker.AccountEventMapResponseHandler

  doctest AccountEventMapResponseHandler
end
