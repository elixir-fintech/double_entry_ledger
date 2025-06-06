defmodule DoubleEntryLedger.EventFixtures do
  @moduledoc """
  This module defines test helpers for creating
  event entities.
  """
  alias DoubleEntryLedger.EventStore
  import DoubleEntryLedger.Event.TransactionDataFixtures

  def event_attrs(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      action: :create,
      source: "source",
      source_idempk: "source_idempk",
      transaction_data: pending_payload()
    })
  end

  def create_event(%{instance: inst, accounts: [a1, a2, _, _]} = ctx, trx_status \\ :posted) do
    {:ok, event} =
      EventStore.create(
        event_attrs(
          instance_id: inst.id,
          transaction_data: %{
            status: trx_status,
            entries: [
              %{
                account_id: a1.id,
                amount: 100,
                currency: "EUR"
              },
              %{
                account_id: a2.id,
                amount: 100,
                currency: "EUR"
              }
            ]
          }
        )
      )

    Map.put(ctx, :event, event)
  end

  def create_update_event(source, source_idempk, instance_id, trx_status, entries \\ []) do
    event_attrs(%{
      action: :update,
      source: source,
      source_idempk: source_idempk,
      instance_id: instance_id,
      update_idempk: Ecto.UUID.generate(),
      transaction_data: %{
        status: trx_status,
        entries: entries
      }
    })
    |> EventStore.create()
  end

  def event_map(%{instance: %{id: id}, accounts: [a1, a2, _, _]}, trx_status \\ :pending) do
    %{
      action: :create,
      instance_id: id,
      source: "source",
      source_data: %{},
      source_idempk: "source_idempk",
      update_idempk: nil,
      transaction_data: %{
        status: trx_status,
        entries: [
          %{account_id: a1.id, amount: 100, currency: "EUR"},
          %{account_id: a2.id, amount: 100, currency: "EUR"}
        ]
      }
    }
  end

  def update_event_map(
        %{instance: %{id: id}, accounts: [a1, a2, _, _]},
        create_event,
        trx_status \\ :posted
      ) do
    %{
      action: :update,
      instance_id: id,
      source: create_event.source,
      source_data: %{},
      source_idempk: create_event.source_idempk,
      update_idempk: Ecto.UUID.generate(),
      transaction_data: %{
        status: trx_status,
        entries: [
          %{account_id: a1.id, amount: 50, currency: "EUR"},
          %{account_id: a2.id, amount: 50, currency: "EUR"}
        ]
      }
    }
  end
end
