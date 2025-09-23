defmodule DoubleEntryLedger.Event.TransactionDataFixtures do
  @moduledoc """
  This module defines test helpers for creating
  event payload entities.
  """
  def create_2_entries do
    [
      %{
        account_address: "cash:account",
        amount: 100,
        currency: :EUR
      },
      %{
        account_address: "asset:account",
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
          account_address: a1.address,
          amount: 100,
          currency: :EUR
        },
        %{
          account_address: a2.address,
          amount: 100,
          currency: :EUR
        }
      ]
    }
  end
end
