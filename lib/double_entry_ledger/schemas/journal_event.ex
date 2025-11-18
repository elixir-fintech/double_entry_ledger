defmodule DoubleEntryLedger.JournalEvent do
  @moduledoc """
  Defines and manages JournalEvents in the Double Entry Ledger system.

  JournalEvents are immutable facts of the ledger. Replaying these JournalEvents
  will recreate the ledger.
  """

  use DoubleEntryLedger.BaseSchema

  alias DoubleEntryLedger.{
    Instance,
    Account,
    Command,
    Transaction,
    JournalEventAccountLink,
    JournalEventCommandLink,
    JournalEventTransactionLink
  }

  alias DoubleEntryLedger.Command.CommandMap

  alias __MODULE__, as: JournalEvent

  @type t :: %JournalEvent{
          id: Ecto.UUID.t() | nil,
          command_map: map() | nil,
          instance: Instance.t() | Ecto.Association.NotLoaded.t(),
          instance_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          journal_event_command_link:
            JournalEventCommandLink.t() | Ecto.Association.NotLoaded.t() | nil,
          command: Command.t() | Ecto.Association.NotLoaded.t() | nil,
          journal_event_account_link:
            JournalEventAccountLink.t() | Ecto.Association.NotLoaded.t() | nil,
          account: Account.t() | Ecto.Association.NotLoaded.t() | nil,
          journal_event_transaction_link:
            JournalEventTransactionLink.t() | Ecto.Association.NotLoaded.t() | nil,
          transaction: Transaction.t() | Ecto.Association.NotLoaded.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @derive {Jason.Encoder, only: [:id, :command_map]}

  schema "journal_events" do
    field(:command_map, CommandMap, skip_default_validation: true)

    belongs_to(:instance, Instance, type: Ecto.UUID)
    has_one(:journal_event_command_link, JournalEventCommandLink)
    has_one(:command, through: [:journal_event_command_link, :command])
    has_one(:journal_event_account_link, JournalEventAccountLink)
    has_one(:account, through: [:journal_event_account_link, :account])
    has_one(:journal_event_transaction_link, JournalEventTransactionLink)
    has_one(:transaction, through: [:journal_event_transaction_link, :transaction])

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a changeset for validating and creating JournalEvents.

  ## Parameters

  * `event` - The Command struct to create a changeset for
  * `attrs` - Map of attributes to apply to the event

  ## Returns

  * An Ecto.Changeset with validations applied

  ## Examples

      # Create event changeset
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
      iex> changeset = JournalEvent.changeset(%Command{}, attrs)
      iex> changeset.valid?
      true
  """
  @spec build_create(map()) :: Ecto.Changeset.t(JournalEvent.t())
  def build_create(attrs) do
    %JournalEvent{}
    |> cast(attrs, [
      :instance_id,
      :command_map
    ])
    |> validate_required([:instance_id, :command_map])
  end
end
