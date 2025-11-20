defmodule DoubleEntryLedger.Command do
  @moduledoc """
  Defines and manages commands in the Double Entry Ledger system.

  The Command schema represents a request to create or update ledger data. Commands drive the
  asynchronous processing pipeline (queueing, retries, idempotency) and link to journal events
  once they have been processed.
  """

  use DoubleEntryLedger.BaseSchema

  alias DoubleEntryLedger.{
    Account,
    Transaction,
    Instance,
    JournalEvent,
    JournalEventCommandLink,
    CommandQueueItem
  }

  alias DoubleEntryLedger.Command.CommandMap
  import DoubleEntryLedger.Command.Helper, only: [action_to_mod: 1]

  alias __MODULE__, as: Command

  @typedoc """
  Represents a command in the Double Entry Ledger system.

  A command encapsulates a request to create or update a transaction, along with metadata about
  the processing state, source, and queue management information.

  ## Fields

  * `id`: UUID primary key
  * `command_map`: map containing the command payload
  * `instance`: Association to the ledger instance
  * `instance_id`: Foreign key to the ledger instance
  * `inserted_at`: Creation timestamp
  * `updated_at`: Last update timestamp
  """
  @type t :: %Command{
          id: Ecto.UUID.t() | nil,
          command_map: map() | nil,
          instance: Instance.t() | Ecto.Association.NotLoaded.t(),
          instance_id: Ecto.UUID.t() | nil,
          journal_event_command_link:
            JournalEventCommandLink.t() | Ecto.Association.NotLoaded.t(),
          journal_event: JournalEvent.t() | Ecto.Association.NotLoaded.t(),
          transaction: Transaction.t() | Ecto.Association.NotLoaded.t(),
          account: Account.t() | Ecto.Association.NotLoaded.t(),
          command_queue_item: CommandQueueItem.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @derive {Jason.Encoder, only: [:id, :command_map, :command_queue_item]}

  schema "commands" do
    field(:command_map, CommandMap, skip_default_validation: true)

    belongs_to(:instance, Instance, type: Ecto.UUID)
    has_one(:journal_event_command_link, JournalEventCommandLink)
    has_one(:journal_event, through: [:journal_event_command_link, :journal_event])
    has_one(:transaction, through: [:journal_event, :transaction])
    has_one(:account, through: [:journal_event, :account])
    has_one(:command_queue_item, DoubleEntryLedger.CommandQueueItem)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a changeset for validating and creating/updating a Command.

  This function builds an Ecto changeset for a command with appropriate validations and handling
  based on the action type and transaction data provided.

  ## Parameters

  * `command` - The Command struct to create a changeset for
  * `attrs` - Map of attributes to apply to the command

  ## Returns

  * An Ecto.Changeset with validations applied

  ## Examples

      # Create command changeset
      iex> command_map = %{
      ...>   action: :create_transaction,
      ...>   source: "api",
      ...>   source_idempk: "order-123",
      ...>   instance_address: "instance1",
      ...>   payload: %{status: :pending, entries: [
      ...>     %{account_address: "account1", amount: 100, currency: :USD},
      ...>     %{account_address: "account2", amount: 100, currency: :USD}
      ...>   ]}
      ...> }
      ...> attrs = %{instance_id: Ecto.UUID.generate(), command_map: command_map}
      iex> changeset = Command.changeset(%Command{}, attrs)
      iex> changeset.valid?
      true

      # Error changeset is added
      iex> command_map = %{
      ...>   action: :create_account,
      ...>   source: "api",
      ...>   source_idempk: "order-123",
      ...>   instance_address: "instance1",
      ...>   payload: %{type: :wrong, address: "wrong format"}
      ...> }
      ...> attrs = %{instance_id: Ecto.UUID.generate(), command_map: command_map}
      iex> changeset = Command.changeset(%Command{}, attrs)
      iex> changeset.valid?
      false
      iex> Map.has_key?(changeset, :command_map_changeset)
      true
      iex> changeset.command_map_changeset.valid?
      false
  """
  @spec changeset(Command.t(), map()) :: Ecto.Changeset.t()
  def changeset(command, attrs) do
    command
    |> base_changeset(attrs)
  end

  @doc """
  Creates a changeset for marking a command as being processed.

  This function prepares a changeset that updates a command to the :processing state, assigns a
  processor, and updates processing metadata such as start time and retry count.

  ## Parameters

  * `command` - The Command struct to update
  * `processor_id` - String identifier for the processor handling the command

  ## Returns

  * An Ecto.Changeset with processing status updates and optimistic locking

  ## Fields Updated

  * `status`: Set to :processing
  * `processor_id`: Set to the provided processor_id
  * `processing_started_at`: Set to current UTC datetime
  * `processing_completed_at`: Set to nil
  * `retry_count`: Incremented by 1
  * `next_retry_after`: Set to nil
  * `processor_version`: Used for optimistic locking

  """
  @spec processing_start_changeset(Command.t(), String.t(), non_neg_integer()) ::
          Ecto.Changeset.t()
  def processing_start_changeset(
        %{command_queue_item: command_queue_item} = command,
        processor_id,
        retry_count
      ) do
    queue_changeset =
      command_queue_item
      |> CommandQueueItem.processing_start_changeset(processor_id, retry_count)

    command
    |> change(%{})
    |> put_assoc(:command_queue_item, queue_changeset)
  end

  @spec base_changeset(Command.t() | Ecto.Changeset.t(Command.t()), map()) :: Ecto.Changeset.t()
  defp base_changeset(command, attrs) do
    attrs = Map.put_new(attrs, :command_queue_item, %{})

    command
    |> cast(attrs, [
      :instance_id,
      :command_map
    ])
    |> validate_required([:instance_id, :command_map])
    |> cast_assoc(:command_queue_item, with: &CommandQueueItem.changeset/2, required: true)
    |> validate_command_map(attrs)
  end

  defp validate_command_map(changeset, attrs) do
    case Map.get(attrs, :command_map) || Map.get(attrs, "command_map") do
      %{} = command_map ->
        with {:ok, mod} <- action_to_mod(command_map),
             inner_cs <- mod.changeset(struct(mod), command_map),
             false <- inner_cs.valid? do
          Map.put(changeset, :command_map_changeset, inner_cs)
        else
          _ -> changeset
        end

      _ ->
        changeset
    end
  end
end
