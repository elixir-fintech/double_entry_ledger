defmodule DoubleEntryLedger.Event do
  @moduledoc """
  This module defines the Event schema.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias DoubleEntryLedger.{Transaction, Instance}
  alias DoubleEntryLedger.Event.TransactionData

  @states [:pending, :processed, :failed, :occ_timeout]
  @actions [:create, :update]
  @type state ::
          unquote(
            Enum.reduce(@states, fn state, acc -> quote do: unquote(state) | unquote(acc) end)
          )
  @type action ::
          unquote(
            Enum.reduce(@actions, fn state, acc -> quote do: unquote(state) | unquote(acc) end)
          )

  alias __MODULE__, as: Event

  @type t :: %Event{
          id: Ecto.UUID.t(),
          status: state(),
          action: action(),
          source: String.t(),
          source_data: map(),
          source_idempk: String.t(),
          update_idempk: String.t() | nil,
          tries: integer(),
          processed_at: DateTime.t() | nil,
          transaction_data: TransactionData.t() | nil,
          instance: Instance.t() | Ecto.Association.NotLoaded.t(),
          instance_id: Ecto.UUID.t() | nil,
          processed_transaction: Transaction.t() | Ecto.Association.NotLoaded.t(),
          processed_transaction_id: Ecto.UUID.t() | nil,
          errors: list(map()) | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @type event_map() :: %{
          action: action(),
          instance_id: Ecto.UUID.t() | nil,
          source: String.t(),
          source_data: map(),
          source_idempk: String.t(),
          update_idempk: String.t() | nil,
          transaction_data: TransactionData.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "events" do
    field(:status, Ecto.Enum, values: @states, default: :pending)
    field(:action, Ecto.Enum, values: @actions)
    field(:source, :string)
    field(:source_data, :map, default: %{})
    field(:source_idempk, :string)
    field(:update_idempk, :string)
    field(:tries, :integer, default: 0)
    field(:processed_at, :utc_datetime_usec)
    field(:errors, {:array, :map}, default: [])

    belongs_to(:instance, Instance, type: Ecto.UUID)
    belongs_to(:processed_transaction, Transaction, type: Ecto.UUID)
    embeds_one(:transaction_data, DoubleEntryLedger.Event.TransactionData)

    timestamps(type: :utc_datetime_usec)
  end

  def actions(), do: @actions

  @doc false
  def changeset(event, %{action: :update, transaction_data: %{status: :pending}} = attrs) do
    event
    |> base_changeset(attrs)
    |> update_changeset()
    |> cast_embed(:transaction_data, with: &TransactionData.changeset/2, required: true)
  end

  def changeset(event, %{action: :update} = attrs) do
    event
    |> base_changeset(attrs)
    |> update_changeset()
    |> cast_embed(:transaction_data,
      with: &TransactionData.update_event_changeset/2,
      required: true
    )
  end

  def changeset(event, attrs) do
    event
    |> base_changeset(attrs)
    |> cast_embed(:transaction_data, with: &TransactionData.changeset/2, required: true)
  end

  defp base_changeset(event, attrs) do
    event
    |> cast(attrs, [:action, :source, :source_data, :source_idempk, :instance_id, :update_idempk])
    |> validate_required([:action, :source, :source_idempk, :instance_id])
    |> validate_inclusion(:action, @actions)
    |> unique_constraint(:source_idempk,
      name: "unique_instance_source_source_idempk",
      message: "already exists for this instance"
    )
  end

  defp update_changeset(changeset) do
    changeset
    |> validate_required([:update_idempk])
    |> unique_constraint(:update_idempk,
      name: "unique_instance_source_source_idempk_update_idempk",
      message: "already exists for this source_idempk"
    )
  end
end
