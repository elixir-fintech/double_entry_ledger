defmodule DoubleEntryLedger.Apis.CommandApi do
  @moduledoc """
  Public boundary for submitting ledger commands.

  All requests are regular Elixir maps (typically with string keys coming from JSON) that
  describe which action to run, which instance to target, and the payload for either account
  or transaction work. The common wire format looks like:

  ```
  %{
    "instance_address" => String.t(),
    "action" => "create_transaction" | "update_transaction" | "create_account" | "update_account",
    "source" => String.t(),
    "source_idempk" => String.t(),
    "update_idempk" => String.t() | nil,
    "update_source" => String.t() | nil,
    "payload" => map()
  }
  ```

  Use `create_from_params/1` to enqueue commands for asynchronous processing or
  `process_from_params/2` to run the full worker pipeline synchronously.
  """
  use DoubleEntryLedger.Logger

  import DoubleEntryLedger.Command.Helper, only: [actions: 1]

  alias DoubleEntryLedger.Command
  alias DoubleEntryLedger.Workers.CommandWorker
  alias DoubleEntryLedger.Command.{TransactionCommandMap, AccountCommandMap}
  alias DoubleEntryLedger.Stores.CommandStore

  @account_actions actions(:account) |> Enum.map(&Atom.to_string/1)
  @transaction_actions actions(:transaction) |> Enum.map(&Atom.to_string/1)

  @type command_params() :: %{required(String.t()) => term()}

  @type on_error() :: :retry | :fail

  @doc """
  Creates an immutable `Command` from external params and queues it for background processing.

  This function validates the payload using the appropriate `AccountCommandMap` or
  `TransactionCommandMap`, resolves the instance, and persists a `Command` with an attached
  `CommandQueueItem` in the `:pending` state. `InstanceMonitor` will later claim and process
  the command; callers only need to inspect the returned struct to track progress.

  ## Parameters
    - `command_params`: Map containing string keys for `"instance_address"`, `"action"`,
      idempotency keys, and the `"payload"`.

  ## Returns
    - `{:ok, command}`: On success with the queued command (status `:pending`)
    - `{:error, changeset}`: When the payload could not be cast into a command map
    - `{:error, :instance_not_found | :action_not_supported}`: When the instance or action is invalid

  ## Examples
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
    iex> {:error, %Ecto.Changeset{data: %AccountCommandMap{}}= changeset} = CommandApi.create_from_params(%{
    ...>   "instance_address" => instance.address,
    ...>   "action" => "create_account",
    ...>   "source" => "frontend",
    ...>   "source_idempk" => "unique_id_124",
    ...>   "payload" => %{}
    ...> })
    iex> changeset.valid?
    false

    iex> CommandApi.create_from_params(%{"action" => "unsupported"})
    iex> {:error, :action_not_supported}
  """
  @spec create_from_params(command_params()) ::
          {:ok, Command.t()}
          | {:error,
             Ecto.Changeset.t(AccountCommandMap.t() | TransactionCommandMap.t())
             | :instance_not_found
             | :action_not_supported}
  def create_from_params(%{"action" => action} = command_params) when action in @account_actions do
    case AccountCommandMap.create(command_params) do
      {:ok, command_map} -> CommandStore.create(command_map)
      error -> error
    end
  end

  def create_from_params(%{"action" => action} = command_params)
      when action in @transaction_actions do
    case TransactionCommandMap.create(command_params) do
      {:ok, command_map} -> CommandStore.create(command_map)
      error -> error
    end
  end

  def create_from_params(_) do
    {:error, :action_not_supported}
  end

  @doc """
  Validates the params and runs the command worker immediately.

  Transaction actions (`"create_transaction"` / `"update_transaction"`) support retries;
  pass `[on_error: :fail]` to surface validation errors without storing the command when you
  want the caller to handle failures directly. Account actions run through the same worker
  stack but currently skip retries and only support the no-save-on-error path.

  ## Parameters
    - `command_params`: Map describing the action, instance, idempotency keys, and payload.
    - `opts`: Keyword list (currently `on_error: :retry | :fail` for transaction commands).

  ## Returns
    - `{:ok, transaction | account, command}` on success with the created/updated projection.
    - `{:error, command}` when the worker persisted an error state (queued for retry).
    - `{:error, changeset}` when payload validation fails.
    - `{:error, reason}` for other failures (e.g., `:action_not_supported`).

  ## Examples

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

    iex> CommandApi.process_from_params(%{"action" => "unsupported"})
    iex> {:error, :action_not_supported}
  """
  @spec process_from_params(command_params(), on_error: on_error()) ::
          CommandWorker.success_tuple() | CommandWorker.error_tuple()
  def process_from_params(command_params, opts \\ [])

  def process_from_params(%{"action" => action} = command_params, opts)
      when action in @transaction_actions do
    on_error = Keyword.get(opts, :on_error, :retry)

    case TransactionCommandMap.create(command_params) do
      {:ok, command_map} ->
        case on_error do
          :fail -> CommandWorker.process_new_command_no_save_on_error(command_map)
          _ -> CommandWorker.process_new_command(command_map)
        end

      {:error, command_map_changeset} ->
        warn("Invalid transaction command params", command_params, command_map_changeset)
        {:error, command_map_changeset}
    end
  end

  # currently the Account related actions do not implement retries
  def process_from_params(%{"action" => action} = command_params, _opts)
      when action in @account_actions do
    case AccountCommandMap.create(command_params) do
      {:ok, command_map} ->
        CommandWorker.process_new_command_no_save_on_error(command_map)

      {:error, command_map_changeset} ->
        warn("Invalid account command params", command_params, command_map_changeset)
        {:error, command_map_changeset}
    end
  end

  def process_from_params(_, _) do
    {:error, :action_not_supported}
  end
end
