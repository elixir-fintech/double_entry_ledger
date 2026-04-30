defmodule DoubleEntryLedger.JournalEvent do
  @moduledoc """
  Defines and manages JournalEvents in the Double Entry Ledger system.

  JournalEvents are immutable facts of the ledger. Replaying these JournalEvents
  will recreate the ledger.
  """

  use DoubleEntryLedger.BaseSchema

  alias DoubleEntryLedger.{Instance, Account, Command, Transaction}

  alias DoubleEntryLedger.Command.CommandMap

  alias __MODULE__, as: JournalEvent

  @type t :: %JournalEvent{
          id: Ecto.UUID.t() | nil,
          command_map: map() | nil,
          instance: Instance.t() | Ecto.Association.NotLoaded.t(),
          instance_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          command: Command.t() | Ecto.Association.NotLoaded.t() | nil,
          command_id: Ecto.UUID.t() | nil,
          account: Account.t() | Ecto.Association.NotLoaded.t() | nil,
          account_id: Ecto.UUID.t() | nil,
          transaction: Transaction.t() | Ecto.Association.NotLoaded.t() | nil,
          transaction_id: Ecto.UUID.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @derive {Jason.Encoder, only: [:id, :command_map]}

  @derive {
    Flop.Schema,
    filterable: [],
    sortable: [:inserted_at, :id],
    default_limit: 40,
    max_limit: 200,
    default_order: %{
      order_by: [:inserted_at, :id],
      order_directions: [:desc, :desc]
    }
  }

  schema "journal_events" do
    field(:command_map, CommandMap, skip_default_validation: true)

    belongs_to(:instance, Instance, type: Ecto.UUID)
    # Direct FKs replace the previous journal_event_*_link join tables (v5).
    # `transaction_id` and `account_id` are mutually exclusive at write time
    # (enforced by changeset and a CHECK constraint); both can be NULL after
    # the source command/account is deleted (`on_delete: :nilify_all`).
    belongs_to(:command, Command)
    belongs_to(:transaction, Transaction)
    belongs_to(:account, Account)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a changeset for validating and creating a JournalEvent.

  ## Parameters

  * `attrs` - Map containing `:instance_id` and `:command_map`

  ## Returns

  * An Ecto.Changeset with validations applied

  ## Examples

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
      iex> attrs = %{instance_id: Ecto.UUID.generate(), command_map: command_map}
      iex> changeset = JournalEvent.build_create(attrs)
      iex> changeset.valid?
      true
  """
  @spec build_create(map()) :: Ecto.Changeset.t(JournalEvent.t())
  def build_create(attrs) do
    %JournalEvent{}
    |> cast(attrs, [
      :instance_id,
      :command_map,
      :command_id,
      :transaction_id,
      :account_id
    ])
    |> validate_required([:instance_id, :command_map, :command_id])
    |> validate_transaction_xor_account()
    |> check_constraint(:transaction_id,
      name: :transaction_xor_account,
      message: "transaction_id and account_id are mutually exclusive"
    )
  end

  # At write time, exactly one of (transaction_id, account_id) must be set.
  # The DB CHECK constraint allows the (NULL, NULL) post-deletion state but
  # not on insert — so we enforce "exactly one" at the application layer and
  # let the constraint guard against accidental "both set" states.
  defp validate_transaction_xor_account(changeset) do
    tid = get_field(changeset, :transaction_id)
    aid = get_field(changeset, :account_id)

    cond do
      is_nil(tid) and is_nil(aid) ->
        add_error(
          changeset,
          :transaction_id,
          "exactly one of transaction_id or account_id must be set"
        )

      not is_nil(tid) and not is_nil(aid) ->
        add_error(
          changeset,
          :transaction_id,
          "transaction_id and account_id are mutually exclusive"
        )

      true ->
        changeset
    end
  end
end
