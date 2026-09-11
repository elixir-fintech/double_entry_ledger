defmodule DoubleEntryLedger.CommandQueue.OwnershipError do
  @moduledoc """
  Raised when a fenced batch queue update cannot update every command in the batch.
  """

  defexception [:batch_command_ids, message: "command queue ownership changed"]
end
