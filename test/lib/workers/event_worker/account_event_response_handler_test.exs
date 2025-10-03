defmodule DoubleEntryLedger.Workers.EventWorker.AccountEventResponseHandlerTest do
  @moduledoc """
    Tests for the AccountEventResponseHandler
  """
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Workers.EventWorker.AccountEventResponseHandler

  doctest AccountEventResponseHandler
end
