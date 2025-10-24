defmodule DoubleEntryLedger.EventFixtures do
  @moduledoc """
  This module defines test helpers for creating
  event entities.
  """
  alias DoubleEntryLedger.Stores.EventStore

  alias DoubleEntryLedger.Event.{
    TransactionEventMap,
    TransactionData,
    AccountEventMap,
    AccountData
  }

  import DoubleEntryLedger.Event.TransactionDataFixtures
  import DoubleEntryLedger.Event.AccountDataFixtures

  def transaction_event_attrs(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      action: :create_transaction,
      source: "source",
      source_idempk: "source_idempk",
      payload: struct(TransactionData, pending_payload())
    })
    |> then(&struct(TransactionEventMap, &1))
  end

  def account_event_attrs(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      action: :create_account,
      source: "source",
      instance_address: "123",
      payload: account_data_attrs()
    })
    |> then(&struct(AccountEventMap, &1))
  end

  def new_create_transaction_event(
        %{instance: inst, accounts: [a1, a2, _, _]} = ctx,
        trx_status \\ :posted
      ) do
    {:ok, event} =
      EventStore.create(
        transaction_event_attrs(
          instance_address: inst.address,
          payload: %TransactionData{
            status: trx_status,
            entries: [
              %{
                account_address: a1.address,
                amount: 100,
                currency: "EUR"
              },
              %{
                account_address: a2.address,
                amount: 100,
                currency: "EUR"
              }
            ]
          }
        )
      )

    Map.put(ctx, :event, event)
  end

  def new_update_transaction_event(
        source,
        source_idempk,
        instance_address,
        trx_status,
        entries \\ []
      ) do
    transaction_event_attrs(%{
      action: :update_transaction,
      source: source,
      source_idempk: source_idempk,
      instance_address: instance_address,
      update_idempk: Ecto.UUID.generate(),
      payload: %TransactionData{
        status: trx_status,
        entries: entries
      }
    })
    |> EventStore.create()
  end

  def create_transaction_event_map(
        %{instance: %{address: address}, accounts: [a1, a2, _, _]},
        trx_status \\ :pending
      ) do
    %TransactionEventMap{
      action: :create_transaction,
      instance_address: address,
      source: "source",
      source_idempk: "source_idempk",
      update_idempk: nil,
      payload: %TransactionData{
        status: trx_status,
        entries: [
          %{account_address: a1.address, amount: 100, currency: "EUR"},
          %{account_address: a2.address, amount: 100, currency: "EUR"}
        ]
      }
    }
  end

  def update_transaction_event_map(
        %{instance: %{address: address}, accounts: [a1, a2, _, _]},
        %{event_map: event_map},
        trx_status \\ :posted
      ) do
    %TransactionEventMap{
      action: :update_transaction,
      instance_address: address,
      source: event_map.source,
      source_idempk: event_map.source_idempk,
      update_idempk: Ecto.UUID.generate(),
      payload: %TransactionData{
        status: trx_status,
        entries: [
          %{account_address: a1.address, amount: 50, currency: "EUR"},
          %{account_address: a2.address, amount: 50, currency: "EUR"}
        ]
      }
    }
  end

  def create_account_event_map(%{instance: %{address: address}}) do
    %AccountEventMap{
      action: :create_account,
      instance_address: address,
      source: "source",
      account_address: nil,
      payload: %AccountData{
        name: "Test Account",
        description: "Test Description",
        address: "account:main1",
        currency: "EUR",
        type: "asset"
      }
    }
  end
end
