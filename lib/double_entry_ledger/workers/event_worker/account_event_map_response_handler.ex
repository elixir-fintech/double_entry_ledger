defmodule DoubleEntryLedger.Workers.EventWorker.AccountEventMapResponseHandler do
  @moduledoc """
  Response handler for account-related event processing operations.

  This module provides standardized response handling for AccountEventMap processing
  operations, including success and error scenarios. It handles the translation of
  database transaction results into appropriate response formats and performs
  comprehensive logging for audit and debugging purposes.

  ## Key Features

  * **Response Translation**: Converts Ecto.Multi transaction results into standardized responses
  * **Error Mapping**: Maps validation errors from Events and Accounts back to AccountEventMap changesets
  * **Comprehensive Logging**: Provides detailed logging for success and failure scenarios
  * **Changeset Propagation**: Ensures validation errors are properly propagated to calling code

  ## Usage

  This module is typically used by EventWorker modules that process AccountEventMap
  structures, providing a consistent interface for handling transaction results.

  ## Error Handling

  The module handles several types of errors:
  - Event validation errors (mapped to event-level changeset errors)
  - Account validation errors (mapped to payload-level changeset errors)
  - Multi step failures (logged and returned as string errors)
  """

  use DoubleEntryLedger.Logger

  import DoubleEntryLedger.Event.TransferErrors,
    only: [
      from_event_to_event_map: 2,
      from_account_to_event_map_payload: 2
    ]

  alias Ecto.Changeset
  alias DoubleEntryLedger.Event.AccountEventMap
  alias DoubleEntryLedger.{Event, Account}

  @typedoc """
  Success response tuple containing the processed account and associated event.
  """
  @type success_tuple :: {:ok, Account.t(), Event.t()}

  @typedoc """
  Error response containing either a changeset with validation errors or a string error message.
  """
  @type error_response :: {:error, Changeset.t(AccountEventMap.t()) | String.t()}

  @typedoc """
  Complete response type for event processing operations.
  """
  @type response :: success_tuple() | error_response()

  @doc """
  Handles responses from account event processing operations.

  This function processes the results of Ecto.Multi transactions for account operations,
  providing standardized response formatting, error handling, and logging. It translates
  database transaction results into appropriate response formats for client consumption.

  ## Parameters

  * `response` - The result from an Ecto.Multi transaction (success or error tuple)
  * `event_map` - The original AccountEventMap that was being processed
  * `module_name` - String identifier of the calling module for logging purposes

  ## Returns

  * `{:ok, Account.t(), Event.t()}` - Success with the created/updated account and event
  * `{:error, Changeset.t(AccountEventMap.t())}` - Validation error with changeset
  * `{:error, String.t()}` - System error with descriptive message

  ## Error Handling

  - `:new_event` errors: Event validation failures mapped to event-level changeset errors
  - `:account` errors: Account validation failures mapped to payload-level changeset errors
  - Other step failures: Logged and returned as descriptive string errors

  ## Examples

      iex> alias DoubleEntryLedger.{Account, Event}
      iex> alias DoubleEntryLedger.Event.AccountEventMap
      iex> account = %Account{}
      iex> event = %Event{event_queue_item: %{status: :processed}, event_map: %{}}
      iex> response = {:ok, %{account: account, event_success: event}}
      iex> {:ok, ^account, ^event} = AccountEventMapResponseHandler.default_response_handler(response, %AccountEventMap{})

      iex> alias DoubleEntryLedger.Event.{AccountEventMap, AccountData}
      iex> changeset = %Ecto.Changeset{}
      iex> response = {:error, :account, changeset, %{}}
      iex> event_map = %AccountEventMap{payload: %AccountData{}}
      iex> {:error, %Ecto.Changeset{} = _changeset} = AccountEventMapResponseHandler.default_response_handler(response, event_map)
  """
  @spec default_response_handler(
          {:ok, %{account: Account.t(), event_success: Event.t()}}
          | {:error, :atom, any(), map()},
          AccountEventMap.t()
        ) ::
          response()
  def default_response_handler(response, %AccountEventMap{} = event_map) do
    case response do
      {:ok, %{account: account, event_success: event}} ->
        info("Processed successfully", event, account)

        {:ok, account, event}

      {:error, :new_event, changeset, _changes} ->
        warn("Event changeset failed", event_map, changeset)

        {:error, from_event_to_event_map(event_map, changeset)}

      {:error, :account, changeset, _changes} ->
        warn("Account changeset failed", event_map, changeset)

        {:error, from_account_to_event_map_payload(event_map, changeset)}

      {:error, step, error, _steps_so_far} ->
        {:ok, message} = error("Step :#{step} failed.", event_map, error)

        {:error, "#{message} #{inspect(error)}"}
    end
  end
end
