defmodule DoubleEntryLedger.EventWorker.UpdateAccountEventMapNoSaveOnError do
  @moduledoc """
  Processes `AccountEventMap` structures for atomic update of events and their associated accounts in the Double Entry Ledger system, without saving on error.

  Implements the Optimistic Concurrency Control (OCC) pattern to ensure safe concurrent processing of update events, providing robust error handling, retry logic, and transactional guarantees. This module ensures that update operations are performed atomically and consistently, and that all error and retry scenarios are handled transparently. Unlike the standard update event map processor, this variant does not persist changes on error, but instead returns changesets with error details for client handling.

  ## Features

    * Account Processing: Handles update of accounts based on the event map's action.
    * Atomic Operations: Ensures all event and account changes are performed in a single database transaction.
    * Error Handling: Maps validation and dependency errors to the appropriate changeset or event state, but does not persist on error.
    * Retry Logic: Retries OCC conflicts and schedules retries for dependency errors.
    * OCC Integration: Integrates with the OCC processor behavior for safe, idempotent event processing.

  ## Main Functions

    * `process/2` — Entry point for processing update event maps with error handling and OCC.
    * `build_account/3` — Constructs Ecto.Multi operations for update actions.
    * `handle_build_account/3` — Adds event update or error handling steps to the Multi.
    * `handle_account_map_error/3` — Returns a changeset with error details, does not persist.
    * `handle_occ_final_timeout/2` — Handles OCC retry exhaustion, does not persist.

  This module ensures that update events are processed exactly once, even in high-concurrency environments, and that all error and retry scenarios are handled transparently and returned to the caller for further handling.
  """
  import DoubleEntryLedger.EventQueue.Scheduling,
    only: [build_mark_as_processed: 1, build_create_account_event_account_link: 2]

  import DoubleEntryLedger.EventWorker.AccountEventResponseHandler,
    only: [default_event_map_response_handler: 3]

  alias Ecto.{Changeset, Multi}
  alias DoubleEntryLedger.EventWorker.UpdateEventError
  alias DoubleEntryLedger.Event.AccountEventMap
  alias DoubleEntryLedger.{Account, Event, Repo, EventStoreHelper, AccountStoreHelper}

  @module_name __MODULE__ |> Module.split() |> List.last()

  @spec process(AccountEventMap.t()) ::
          {:ok, Account.t(), Event.t()} | {:error, Changeset.t(AccountEventMap.t()) | String.t()}
  def process(%AccountEventMap{action: :update_account} = event_map) do
    build_update_account(event_map)
    |> handle_build_update_account(event_map)
    |> Repo.transaction()
    |> default_event_map_response_handler(event_map, @module_name)
  end

  # TODO update accordingly; check out UpdateTransactionEventMapNoSaveOnError for reference
  @spec build_update_account(AccountEventMap.t()) :: Ecto.Multi.t()
  def build_update_account(%AccountEventMap{payload: payload} = event_map) do
    Multi.new()
    |> Multi.insert(:new_event, EventStoreHelper.build_create(event_map))
    |> EventStoreHelper.build_get_create_account_event_account(
      :get_account,
      :new_event
    )
    |> Multi.merge(fn
      %{get_account: {:error, %UpdateEventError{} = exception}} ->
        Multi.put(Multi.new(), :get_create_account_event_error, exception)

      %{get_account: account} ->
        Multi.update(Multi.new(), :account, AccountStoreHelper.build_update(account, payload))
    end)
  end

  @spec handle_build_update_account(
          Ecto.Multi.t(),
          AccountEventMap.t()
        ) :: Ecto.Multi.t()
  def handle_build_update_account(multi, %AccountEventMap{} = event_map) do
    Multi.merge(multi, fn
      %{account: account, new_event: event} ->
        Multi.update(Multi.new(), :event_success, fn _ ->
          build_mark_as_processed(event)
        end)
        |> Multi.insert(:create_account_link, fn _ ->
          build_create_account_event_account_link(event, account)
        end)

      %{get_create_account_event_error: %{reason: reason}, new_event: _event} ->
        event_map_changeset =
          event_map
          |> AccountEventMap.changeset(%{})
          |> Changeset.add_error(:create_account_event_error, to_string(reason))

        Multi.error(Multi.new(), :create_account_event_error, event_map_changeset)
    end)
  end
end
