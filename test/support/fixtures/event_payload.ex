defmodule DoubleEntryLedger.EventPayloadFixtures do
  @moduledoc """
  This module defines test helpers for creating
  event payload entities.
  """
  def create_2_entries do
    [
      %{
        account_id: Ecto.UUID.generate(),
        amount: 100,
        currency: :EUR
      },
      %{
        account_id: Ecto.UUID.generate(),
        amount: -100,
        currency: :EUR
      }
    ]
  end

  def pending_payload do
    %{
      instance_id: Ecto.UUID.generate(),
      transaction: %{
        effective_at: DateTime.utc_now(),
        status: :pending,
        entries: create_2_entries()
      }
    }
  end
end
