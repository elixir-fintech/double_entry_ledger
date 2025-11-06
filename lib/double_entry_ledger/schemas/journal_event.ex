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
    JournalEventAccountLink,
    JournalEventCommandLink,
    EventTransactionLink
  }

  alias DoubleEntryLedger.Command.EventMap

  alias __MODULE__, as: JournalEvent

  @type t :: %JournalEvent{
          id: Ecto.UUID.t() | nil,
          event_map: map() | nil,
          instance: Instance.t() | Ecto.Association.NotLoaded.t(),
          instance_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          journal_event_command_link: JournalEventCommandLink.t() | Ecto.Association.NotLoaded.t() | nil,
          command: Command.t() | Ecto.Association.NotLoaded.t() | nil,
          journal_event_account_link: JournalEventAccountLink.t() | Ecto.Association.NotLoaded.t() | nil,
          account: Account.t() | Ecto.Association.NotLoaded.t() | nil,
          event_transaction_link: EventTransactionLink.t() | Ecto.Association.NotLoaded.t() | nil,
          account: Transaction.t() | Ecto.Association.NotLoaded.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @derive {Jason.Encoder, only: [:id, :event_map]}

  schema "journal_events" do
    field(:event_map, EventMap, skip_default_validation: true)

    belongs_to(:instance, Instance, type: Ecto.UUID)
    has_one(:journal_event_command_link, JournalEventCommandLink)
    has_one(:command, through: [:journal_event_command_link, :command])
    has_one(:journal_event_account_link, JournalEventAccountLink)
    has_one(:account, through: [:journal_event_account_link, :account])
    has_one(:event_transaction_link, EventTransactionLink)
    has_one(:transaction, through: [:event_transaction_link, :transaction])

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
      iex> event_map = %{
      ...>   action: :create_transaction,
      ...>   source: "api",
      ...>   source_idempk: "order-123",
      ...>   instance_address: "instance1",
      ...>   payload: %{status: :pending, entries: [
      ...>     %{account_address: "account1", amount: 100, currency: :USD},
      ...>     %{account_address: "account2", amount: 100, currency: :USD}
      ...>   ]}
      ...> }
      ...> attrs = %{instance_id: Ecto.UUID.generate(), event_map: event_map}
      iex> changeset = JournalEvent.changeset(%Command{}, attrs)
      iex> changeset.valid?
      true
  """
  @spec build_create(map()) :: Ecto.Changeset.t(JournalEvent.t())
  def build_create(attrs) do
    %JournalEvent{}
    |> cast(attrs, [
      :instance_id,
      :event_map
    ])
    |> validate_required([:instance_id, :event_map])
  end
end
