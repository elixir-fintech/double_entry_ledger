defmodule DoubleEntryLedger.Apis.EventApi do
  @moduledoc """

  """

  alias DoubleEntryLedger.Event
  alias DoubleEntryLedger.Workers.EventWorker
  alias DoubleEntryLedger.Event.{TransactionEventMap, AccountEventMap}

  @account_actions Event.actions(:account) |> Enum.map(&Atom.to_string/1)
  @transaction_actions Event.actions(:transaction) |> Enum.map(&Atom.to_string/1)

  @doc """
  Processes an event from provided parameters, handling the entire workflow.
  This only works for parameters that translate into a `TransactionEventMap`.

  This function creates a TransactionEventMap from the parameters, then processes it through
  the EventWorker to create both an event record in the EventStore and creates the necessary projections.

  If the processing fails, it will return an error tuple with details about the failure.
  The event is saved to the EventQueue and then retried later.

  ## Supported Actions

  ### Transaction Actions
  - `"create_transaction"` - Creates new double-entry transactions with balanced entries
  - `"update_transaction"` - Updates existing pending transactions

  ## Parameters
    - `event_params`: Map containing event parameters including action and payload data

  ## Returns
    - `{:ok, transaction, event}`: If a transaction event was successfully processed
    - `{:error, event}`: If the event processing failed
    - `{:error, changeset}`: If validation failed
    - `{:error, reason}`: If processing failed for other reasons

  ### Examples

    iex> alias DoubleEntryLedger.Repo
    iex> alias DoubleEntryLedger.Stores.{AccountStore, InstanceStore}
    iex> alias DoubleEntryLedger.Apis.EventApi
    iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
    iex> account_data = %{address: "Cash:Account", type: :asset, currency: :USD, instance_address: instance.address}
    iex> {:ok, asset_account} = AccountStore.create(account_data, "unique_id_123")
    iex> {:ok, liability_account} = AccountStore.create(%{account_data | address: "Liability:Account", type: :liability}, "unique_id_456")
    iex> {:ok, transaction, event} = EventApi.process_from_event_params(%{
    ...>   "instance_address" => instance.address,
    ...>   "action" => "create_transaction",
    ...>   "source" => "frontend",
    ...>   "source_idempk" => "unique_id_123",
    ...>   "payload" => %{
    ...>     status: :posted,
    ...>     entries: [
    ...>       %{account_address: asset_account.address, amount: 100, currency: :USD},
    ...>       %{account_address: liability_account.address, amount: 100, currency: :USD}
    ...>     ]
    ...>   }
    ...> })
    iex> [trx | _] =  (event |> Repo.preload(:transactions)).transactions
    iex> trx.id == transaction.id
    true
  """
  @spec process_from_event_params(map()) ::
          EventWorker.success_tuple() | EventWorker.error_tuple()
  def process_from_event_params(%{"action" => action} = event_params)
      when action in @transaction_actions do
    case TransactionEventMap.create(event_params) do
      {:ok, event_map} ->
        EventWorker.process_new_event(event_map)

      {:error, event_map_changeset} ->
        {:error, event_map_changeset}
    end
  end

  @doc """
  Same as `process_from_event_params/1`, but does not save the event on error.

  This function provides an alternative processing strategy for scenarios where you want
  to validate and process events but avoid an automated retry. You will need to keep track
  of failed events for audit purposes.

  ## Supported Actions

  Same as `process_from_event_params/1` - supports both transaction and account actions.

  ## Parameters
    - `event_params`: Map containing event parameters including action and payload data

  ## Returns
    - `{:ok, transaction, event}`: If a transaction event was successfully processed
    - `{:ok, account, event}`: If an account event was successfully processed
    - `{:error, changeset}`: If validation failed
    - `{:error, reason}`: If processing failed for other reasons

  ### Examples

    iex> alias DoubleEntryLedger.Repo
    iex> alias DoubleEntryLedger.Stores.InstanceStore
    iex> alias DoubleEntryLedger.Apis.EventApi
    iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
    iex> {:ok, account, event} = EventApi.process_from_event_params_no_save_on_error(%{
    ...>   "instance_address" => instance.address,
    ...>   "action" => "create_account",
    ...>   "source" => "frontend",
    ...>   "source_idempk" => "unique_id_123",
    ...>   "payload" => %{
    ...>     type: :asset,
    ...>     address: "asset:owner:1",
    ...>     currency: :EUR
    ...>   }
    ...> })
    iex> (event |> Repo.preload(:account)).account.id == account.id
    true

  """
  @spec process_from_event_params_no_save_on_error(map()) ::
          EventWorker.success_tuple() | {:error, Ecto.Changeset.t() | String.t()}
  def process_from_event_params_no_save_on_error(%{"action" => action} = event_params)
      when action in @account_actions do
    case AccountEventMap.create(event_params) do
      {:ok, event_map} ->
        EventWorker.process_new_event_no_save_on_error(event_map)

      {:error, event_map_changeset} ->
        {:error, event_map_changeset}
    end
  end

  def process_from_event_params_no_save_on_error(%{"action" => action} = event_params)
      when action in @transaction_actions do
    case TransactionEventMap.create(event_params) do
      {:ok, event_map} ->
        EventWorker.process_new_event_no_save_on_error(event_map)

      {:error, event_map_changeset} ->
        {:error, event_map_changeset}
    end
  end
end
