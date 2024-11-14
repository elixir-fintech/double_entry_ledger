defmodule DoubleEntryLedger.RepoBehaviour do
  @moduledoc """
  Defines the behaviour for the DoubleEntryLedger Repo.
  This module should be used in the test environment to ensure that the Repo
  module implements the required functions.
  """
  @callback transaction(fun :: (() -> any())) :: any()
end
