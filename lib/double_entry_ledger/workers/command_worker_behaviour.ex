defmodule DoubleEntryLedger.Workers.CommandWorkerBehaviour do
  @moduledoc """
  Behaviour for command worker implementations.

  Defines the contract for processing commands by ID, allowing
  alternative implementations for testing (e.g., mocking crashes).
  """

  @callback process_command_with_id(Ecto.UUID.t(), String.t()) ::
              {:ok, term(), term()} | {:error, term()}
end
