defmodule DoubleEntryLedger.EventFixtures do
  @moduledoc """
  This module defines test helpers for creating
  event entities.
  """
  alias DoubleEntryLedger.Stores.CommandStore

  alias DoubleEntryLedger.Command.{
    TransactionCommandMap,
    TransactionData,
    AccountCommandMap,
    AccountData
  }

  import DoubleEntryLedger.Command.TransactionDataFixtures
  import DoubleEntryLedger.Command.AccountDataFixtures

  def transaction_event_attrs(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      action: :create_transaction,
      source: "source",
      source_idempk: "source_idempk",
      payload: struct(TransactionData, pending_payload())
    })
    |> then(&struct(TransactionCommandMap, &1))
  end

  def account_event_attrs(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      action: :create_account,
      source: "source",
      instance_address: "123",
      payload: account_data_attrs()
    })
    |> then(&struct(AccountCommandMap, &1))
  end

  def new_create_transaction_event(
        %{instance: inst, accounts: [a1, a2, _, _]} = ctx,
        trx_status \\ :posted
      ) do
    {:ok, event} =
      CommandStore.create(
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
    |> CommandStore.create()
  end

  def create_transaction_command_map(
        %{instance: %{address: address}, accounts: [a1, a2, _, _]},
        trx_status \\ :pending
      ) do
    %TransactionCommandMap{
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

  def update_transaction_command_map(
        %{instance: %{address: address}, accounts: [a1, a2, _, _]},
        %{command_map: command_map},
        trx_status \\ :posted
      ) do
    %TransactionCommandMap{
      action: :update_transaction,
      instance_address: address,
      source: command_map.source,
      source_idempk: command_map.source_idempk,
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

  def create_account_command_map(%{instance: %{address: address}}) do
    %AccountCommandMap{
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
