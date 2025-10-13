defmodule DoubleEntryLedger.Workers.EventWorker.UpdateAccountEvent do
  @moduledoc """
  UpdateAccountEvent
  """
  use DoubleEntryLedger.Logger

  import DoubleEntryLedger.EventQueue.Scheduling,
    only: [
      build_mark_as_processed: 1,
      build_create_account_event_account_link: 2,
      build_revert_to_pending: 2,
      build_schedule_update_retry: 2,
      build_mark_as_dead_letter: 2,
      mark_as_dead_letter: 2,
      schedule_retry_with_reason: 3
    ]

  alias Ecto.{Changeset, Multi}
  alias DoubleEntryLedger.Workers.EventWorker.UpdateEventError
  alias DoubleEntryLedger.Event.AccountEventMap
  alias DoubleEntryLedger.{Event, Repo}
  alias DoubleEntryLedger.Stores.{AccountStoreHelper, EventStoreHelper}

  @spec process(Event.t()) :: {:ok, Account.t(), Event.t()} | {:error, Event.t() | Changeset.t()}
  def process(%Event{action: :update_account} = event) do
    build_update_account(event)
    |> handle_build_update_account(event)
    |> Repo.transaction()
    |> case do
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

  @spec build_update_account(Event.t()) :: Ecto.Multi.t()
  defp build_update_account(%Event{event_map: event_map} = event) do
    account_data =
      %AccountEventMap{}
      |> AccountEventMap.changeset(event_map)
      |> Ecto.Changeset.get_embed(:payload, :struct)

    Multi.new()
    |> EventStoreHelper.build_get_create_account_event_account(
      :get_account,
      event
    )
    |> Multi.merge(fn
      %{get_account: {:error, %UpdateEventError{} = exception}} ->
        Multi.put(Multi.new(), :get_create_account_event_error, exception)

      %{get_account: account} ->
        Multi.update(Multi.new(), :account, AccountStoreHelper.build_update(account, account_data))
    end)
  end

  @spec handle_build_update_account(
          Ecto.Multi.t(),
          Event.t()
        ) :: Ecto.Multi.t()
  defp handle_build_update_account(multi, %Event{} = event) do
    Multi.merge(multi, fn
      %{account: account} ->
        Multi.update(Multi.new(), :event_success, fn _ ->
          build_mark_as_processed(event)
        end)
        |> Multi.insert(:create_account_link, fn %{event_success: event} ->
          build_create_account_event_account_link(event, account)
        end)

      %{
        get_create_account_event_error: %{reason: :create_event_not_processed} = exception
      } ->
        Multi.update(Multi.new(), :event_failure, fn _ ->
          build_revert_to_pending(event, exception.message)
        end)

      %{
        get_create_account_event_error: %{reason: :create_event_failed} = exception
      } ->
        Multi.update(Multi.new(), :event_failure, fn _ ->
          build_schedule_update_retry(event, exception)
        end)

      %{get_create_account_event_error: exception} ->
        Multi.update(Multi.new(), :event_failure, fn _ ->
          build_mark_as_dead_letter(event, exception.message)
        end)
    end)
  end
end
