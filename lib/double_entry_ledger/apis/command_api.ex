defmodule DoubleEntryLedger.Apis.CommandApi do
  @moduledoc """

  The event_params should be as follows (Elixir does not allow string keys in the typespec
  so the generic type `%{required(String.t()) => term()}` is used)
  ```
  %{
    "action" => String.t(),
    "instance_address" => String.t(),
    "source" => String.t(),
    "source_idempk" => String.t(),
    "update_idempk" => String.t() | nil,
    "update_source" => String.t() | nil,
    "payload" => map()
  }
  ```
  """
  use DoubleEntryLedger.Logger

  import DoubleEntryLedger.Command.Helper, only: [actions: 1]

  alias DoubleEntryLedger.Command
  alias DoubleEntryLedger.Workers.CommandWorker
  alias DoubleEntryLedger.Command.{TransactionEventMap, AccountEventMap}
  alias DoubleEntryLedger.Stores.CommandStore

  @account_actions actions(:account) |> Enum.map(&Atom.to_string/1)
  @transaction_actions actions(:transaction) |> Enum.map(&Atom.to_string/1)

  @type event_params() :: %{required(String.t()) => term()}

  @type on_error() :: :retry | :fail

  @doc """
  Adds the event to the EventQueue with status `:pending` to be processed asynchronously. Enforce
  idempotency using the

  ## Parameters
    - `event_params`: Map containing event parameters including action and payload data

  ## Returns
    - `{:ok, event}`: If a transaction event was successfully processed
    - `{:error, changeset}`: If validation failed
    - `{:error, reason}`: If processing failed for other reasons

  ## Examples
    iex> alias DoubleEntryLedger.Repo
    iex> alias DoubleEntryLedger.Stores.InstanceStore
    iex> alias DoubleEntryLedger.Apis.CommandApi
    iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
    iex> account_data = %{address: "Cash:Account", type: :asset, currency: :USD, instance_address: instance.address}
    iex> {:ok, event} = CommandApi.create_from_params(%{
    ...>   "instance_address" => instance.address,
    ...>   "action" => "create_account",
    ...>   "source" => "frontend",
    ...>   "source_idempk" => "unique_id_123",
    ...>   "payload" => account_data
    ...> })
    iex> event.command_queue_item.status
    :pending
    iex> alias DoubleEntryLedger.Command.AccountEventMap
    iex> {:error, %Ecto.Changeset{data: %AccountEventMap{}}= changeset} = CommandApi.create_from_params(%{
    ...>   "instance_address" => instance.address,
    ...>   "action" => "create_account",
    ...>   "source" => "frontend",
    ...>   "source_idempk" => "unique_id_124",
    ...>   "payload" => %{}
    ...> })
    iex> changeset.valid?
    false

    iex> alias DoubleEntryLedger.Apis.CommandApi
    iex> CommandApi.create_from_params(%{"action" => "unsupported"})
    iex> {:error, :action_not_supported}

  """
  @spec create_from_params(event_params()) ::
          {:ok, Command.t()}
          | {:error,
             Ecto.Changeset.t(AccountEventMap.t() | TransactionEventMap.t())
             | :instance_not_found
             | :action_not_supported}
  def create_from_params(%{"action" => action} = event_params) when action in @account_actions do
    case AccountEventMap.create(event_params) do
      {:ok, event_map} -> CommandStore.create(event_map)
      error -> error
    end
  end

  def create_from_params(%{"action" => action} = event_params)
      when action in @transaction_actions do
    case TransactionEventMap.create(event_params) do
      {:ok, event_map} -> CommandStore.create(event_map)
      error -> error
    end
  end

  def create_from_params(_) do
    {:error, :action_not_supported}
  end

  @doc """
  Processes an event from provided parameters, handling the entire workflow.
  This only works for parameters that translate into a `TransactionEventMap`.

  This function creates a TransactionEventMap from the parameters, then processes it through
  the CommandWorker to create both an event record in the CommandStore and creates the necessary projections.

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

    iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
    iex> account_data = %{address: "Cash:Account", type: :asset, currency: :USD}
    iex> {:ok, asset_account} = AccountStore.create(instance.address, account_data, "unique_id_123")
    iex> {:ok, liability_account} = AccountStore.create(instance.address, %{account_data | address: "Liability:Account", type: :liability}, "unique_id_456")
    iex> {:ok, transaction, event} = CommandApi.process_from_params(%{
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
    iex> trx =  (event |> Repo.preload(:transaction)).transaction
    iex> trx.id == transaction.id
    true

    iex> {:ok, instance} = InstanceStore.create(%{address: "Sample:Instance"})
    iex> {:ok, _account, _event} = CommandApi.process_from_params(%{
    ...>   "instance_address" => instance.address,
    ...>   "action" => "create_account",
    ...>   "source" => "frontend",
    ...>   "source_idempk" => "unique_id_123",
    ...>   "payload" => %{
    ...>     type: :asset,
    ...>     address: "asset:owner:1",
    ...>     currency: :EUR
    ...>   }
    ...> }, [on_error: :fail])

    iex> alias DoubleEntryLedger.Apis.CommandApi
    iex> CommandApi.process_from_params(%{"action" => "unsupported"})
    iex> {:error, :action_not_supported}
  """
  @spec process_from_params(event_params(), on_error: on_error()) ::
          CommandWorker.success_tuple() | CommandWorker.error_tuple()
  def process_from_params(event_params, opts \\ [])

  def process_from_params(%{"action" => action} = event_params, opts)
      when action in @transaction_actions do
    on_error = Keyword.get(opts, :on_error, :retry)

    case TransactionEventMap.create(event_params) do
      {:ok, event_map} ->
        case on_error do
          :fail -> CommandWorker.process_new_event_no_save_on_error(event_map)
          _ -> CommandWorker.process_new_event(event_map)
        end

      {:error, event_map_changeset} ->
        warn("Invalid transaction event params", event_params, event_map_changeset)
        {:error, event_map_changeset}
    end
  end

  # currently the Account related actions do not implement retries
  def process_from_params(%{"action" => action} = event_params, _opts)
      when action in @account_actions do
    case AccountEventMap.create(event_params) do
      {:ok, event_map} ->
        CommandWorker.process_new_event_no_save_on_error(event_map)

      {:error, event_map_changeset} ->
        warn("Invalid account event params", event_params, event_map_changeset)
        {:error, event_map_changeset}
    end
  end

  def process_from_params(_, _) do
    {:error, :action_not_supported}
  end
end
