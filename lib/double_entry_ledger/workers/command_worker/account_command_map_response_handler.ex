defmodule DoubleEntryLedger.Workers.CommandWorker.AccountCommandMapResponseHandler do
  @moduledoc """
  Response handler for account-related event processing operations.

  This module provides standardized response handling for AccountCommandMap processing
  operations, including success and error scenarios. It handles the translation of
  database transaction results into appropriate response formats and performs
  comprehensive logging for audit and debugging purposes.

  ## Key Features

  * **Response Translation**: Converts Ecto.Multi transaction results into standardized responses
  * **Error Mapping**: Maps validation errors from Events and Accounts back to AccountCommandMap changesets
  * **Comprehensive Logging**: Provides detailed logging for success and failure scenarios
  * **Changeset Propagation**: Ensures validation errors are properly propagated to calling code

  ## Usage

  This module is typically used by CommandWorker modules that process AccountCommandMap
  structures, providing a consistent interface for handling transaction results.

  ## Error Handling

  The module handles several types of errors:
  - Command validation errors (mapped to event-level changeset errors)
  - Account validation errors (mapped to payload-level changeset errors)
  - Multi step failures (logged and returned as string errors)
  """

  use DoubleEntryLedger.Logger

  import DoubleEntryLedger.Command.TransferErrors,
    only: [
      from_event_to_command_map: 2,
      from_account_to_command_map_payload: 2
    ]

  alias Ecto.Changeset
  alias DoubleEntryLedger.Command.AccountCommandMap
  alias DoubleEntryLedger.{Command, Account}

  @typedoc """
  Success response tuple containing the processed account and associated event.
  """
  @type success_tuple :: {:ok, Account.t(), Command.t()}

  @typedoc """
  Error response containing either a changeset with validation errors or a string error message.
  """
  @type error_response :: {:error, Changeset.t(AccountCommandMap.t()) | String.t()}

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
  * `command_map` - The original AccountCommandMap that was being processed
  * `module_name` - String identifier of the calling module for logging purposes

  ## Returns

  * `{:ok, Account.t(), Command.t()}` - Success with the created/updated account and event
  * `{:error, Changeset.t(AccountCommandMap.t())}` - Validation error with changeset
  * `{:error, String.t()}` - System error with descriptive message

  ## Error Handling

  - `:new_command` errors: Command validation failures mapped to event-level changeset errors
  - `:account` errors: Account validation failures mapped to payload-level changeset errors
  - Other step failures: Logged and returned as descriptive string errors

  ## Examples

      iex> account = %Account{}
      iex> event = %Command{command_queue_item: %{status: :processed}, command_map: %{}}
      iex> response = {:ok, %{account: account, event_success: event}}
      iex> {:ok, ^account, ^event} = AccountCommandMapResponseHandler.default_response_handler(response, %AccountCommandMap{})

      iex> changeset = %Ecto.Changeset{}
      iex> response = {:error, :account, changeset, %{}}
      iex> command_map = %AccountCommandMap{payload: %AccountData{}}
      iex> {:error, %Ecto.Changeset{} = _changeset} = AccountCommandMapResponseHandler.default_response_handler(response, command_map)
  """
  @spec default_response_handler(
          {:ok, %{account: Account.t(), event_success: Command.t()}}
          | {:error, :atom, any(), map()},
          AccountCommandMap.t()
        ) ::
          response()
  def default_response_handler(response, %AccountCommandMap{} = command_map) do
    case response do
      {:ok, %{account: account, event_success: event}} ->
        info("Processed successfully", event, account)

        {:ok, account, event}

      {:error, :new_command, changeset, _changes} ->
        warn("Command changeset failed", command_map, changeset)

        {:error, from_event_to_command_map(command_map, changeset)}

      {:error, :account, changeset, _changes} ->
        warn("Account changeset failed", command_map, changeset)

        {:error, from_account_to_command_map_payload(command_map, changeset)}

      {:error, step, error, _steps_so_far} ->
        {:ok, message} = error("Step :#{step} failed.", command_map, error)

        {:error, "#{message} #{inspect(error)}"}
    end
  end
end
