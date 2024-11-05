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
      source_id: "source_id",
      transaction_data: pending_payload()
    })
  end

  def create_event(%{instance: inst, accounts: [a1, a2, _, _] } = ctx, trx_status \\ :posted) do
    {:ok, event} = EventStore.insert_event(event_attrs(
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
    ))

    Map.put(ctx, :event, event)
  end
end
