defmodule DoubleEntryLedger.Event.ErrorMap do
  @moduledoc"""
  This module defines the ErrorMap schema for the Event.
  """


  defstruct errors: [],
            steps_so_far: %{},
            retries: 0

  alias DoubleEntryLedger.Event
  alias DoubleEntryLedger.Event.EventMap
  alias __MODULE__, as: ErrorMap

  @type error() :: %{
          message: String.t(),
          inserted_at: DateTime.t()
        }

  @type t :: %ErrorMap{
          errors: list(error()) | [],
          steps_so_far: map(),
          retries: integer()
        }

  @spec build_errors(String.t(), list(error())) :: list(error())
  def build_errors(error_message, errors) do
    [build_error(error_message) | errors]
  end

  @spec build_error(String.t()) :: error()
  def build_error(error) do
    %{
      message: error,
      inserted_at: DateTime.utc_now(:microsecond)
    }
  end

  @spec create_error_map(Event.t() | EventMap.t()) :: t()
  def create_error_map(event) do
    %ErrorMap{
      errors: Map.get(event, :errors, []),
      steps_so_far: %{},
      retries: 0
    }
  end
end
