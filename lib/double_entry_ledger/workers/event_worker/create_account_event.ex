defmodule DoubleEntryLedger.Workers.EventWorker.CreateAccountEvent do
  @moduledoc """
   Processes :create_account actions
  """
  require Logger

  import DoubleEntryLedger.EventQueue.Scheduling,
    only: [
      build_mark_as_processed: 1,
      build_create_account_event_account_link: 2,
      schedule_retry_with_reason: 3,
      mark_as_dead_letter: 2
    ]

  alias DoubleEntryLedger.Event.AccountEventMap
  alias Ecto.Multi
  alias DoubleEntryLedger.{Event, Repo}
  alias DoubleEntryLedger.Stores.AccountStoreHelper

  @module_name __MODULE__ |> Module.split() |> List.last()

  @spec process(Event.t()) :: {:ok, Account.t(), Event.t()} | {:error, Event.t()}
  def process(%Event{action: :create_account} = event) do
    build_create_account(event)
    |> Repo.transaction()
    |> case do
      {:ok, %{account: account, event_success: event}} ->
        Logger.info(
          "#{@module_name}: processed successfully",
          Event.log_trace(event, account)
        )

        {:ok, account, event}

      {:error, :account, changeset, _changes} ->
        message = "#{@module_name}: Account changeset failed"
        Logger.warning(message, Event.log_trace(event, changeset.errors))
        mark_as_dead_letter(event, message)

      {:error, step, error, _steps_so_far} ->
        message = "#{@module_name}: Step :#{step} failed."
        Logger.error(message, Event.log_trace(event, error))
        schedule_retry_with_reason(event, message, :failed)
    end
  end

  @spec build_create_account(Event.t()) :: Ecto.Multi.t()
  defp build_create_account(%Event{event_map: event_map, instance_id: instance_id} = event) do
    account_data =
      %AccountEventMap{}
      |> AccountEventMap.changeset(event_map)
      |> Ecto.Changeset.get_embed(:payload, :struct)

    Multi.new()
    |> Multi.insert(:account, AccountStoreHelper.build_create(account_data, instance_id))
    |> Multi.update(:event_success, build_mark_as_processed(event))
    |> Multi.insert(:create_account_link, fn %{event_success: event, account: account} ->
      build_create_account_event_account_link(event, account)
    end)
  end
end
