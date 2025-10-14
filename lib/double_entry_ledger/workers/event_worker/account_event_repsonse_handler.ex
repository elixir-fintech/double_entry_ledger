defmodule DoubleEntryLedger.Workers.EventWorker.AccountEventResponseHandler do
  @moduledoc """
  Response handler for account-related event processing operations.

  This module provides standardized response handling for Event processing
  operations, including success and error scenarios. It handles the translation of
  database transaction results into appropriate response formats and performs
  comprehensive logging for audit and debugging purposes.

  ## Key Features

  * **Response Translation**: Converts Ecto.Multi transaction results into standardized responses
  * **Error Mapping**: Maps validation errors from Events and Accounts back to AccountEventMap changesets
  * **Comprehensive Logging**: Provides detailed logging for success and failure scenarios

  ## Usage

  This module is typically used by EventWorker modules that process Event
  structures, providing a consistent interface for handling transaction results.

  ## Error Handling

  The module handles several types of errors:
  - Event validation errors (mapped to event-level changeset errors)
  - Account validation errors (mapped to payload-level changeset errors)
  - Multi step failures (logged and returned as string errors)
  """

  use DoubleEntryLedger.Logger

  import DoubleEntryLedger.EventQueue.Scheduling, only: [
    mark_as_dead_letter: 2,
    schedule_retry_with_reason: 3
  ]

  alias Ecto.Changeset
  alias DoubleEntryLedger.{Event, Account}

  @typedoc """
  Success response tuple containing the processed account and associated event.
  """
  @type success_tuple :: {:ok, Account.t(), Event.t()}

  @typedoc """
  Error response containing either a changeset with validation errors or a string error message.
  """
  @type error_response :: {:error, Event.t() | Changeset.t(Event.t())}

  @typedoc """
  Complete response type for event processing operations.
  """
  @type response :: success_tuple() | error_response()

  @doc """
  Handles responses from account event processing operations.
  """
  @spec default_response_handler(
          {:ok, %{account: Account.t(), event_success: Event.t()}}
          | {:error, :atom, any(), map()},
          Event.t()
        ) ::
          response()
  def default_response_handler(response, %Event{} = event) do
    case response do
      {:ok, %{account: account, event_success: event}} ->
        info("Processed successfully", event, account)

        {:ok, account, event}

      {:ok, %{event_failure: %{event_queue_item: %{errors: [last_error | _]}} = event}} ->
        warn(last_error.message, event)

        {:error, event}

      {:error, :account, changeset, _changes} ->
        {:ok, message} = error("Account changeset failed:", event, changeset)
        mark_as_dead_letter(event, message)

      {:error, step, error, _steps_so_far} ->
        {:ok, message} = error("Step :#{step} failed.", event, error)
        schedule_retry_with_reason(event, message, :failed)
    end
  end
end
