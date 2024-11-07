defmodule DoubleEntryLedger.Event.TransactionDataFixtures do
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
      status: :pending,
      entries: create_2_entries()
    }
  end

  def pending_payload_with_valid_accounts(%{accounts: [a1, a2, _, _]}) do
    %{
      status: :pending,
      entries: [
        %{
          account_id: a1.id,
          amount: 100,
          currency: :EUR
        },
        %{
          account_id: a2.id,
          amount: 100,
          currency: :EUR
        }
      ]
    }
  end
end
