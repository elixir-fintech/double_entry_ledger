defmodule DoubleEntryLedger.TransactionFixtures do
  @moduledoc """
  This module defines test helpers for creating
  transaction entities.
  """

  alias DoubleEntryLedger.TransactionStore

  def transaction_attr(attrs) do
    attrs
    |> Enum.into(%{
      event_id: "some event_id",
      metadata: %{},
      posted_at: ~U[2023-11-18 17:49:00.000000Z],
      status: :pending,
    })
  end

  def create_transaction(%{instance: instance, accounts: [acc1, acc2, _, _]} = ctx, status \\ :pending) do
    transaction = transaction_attr(
      instance_id: instance.id,
      status: status,
      entries: [
      %{type: :debit, value: Money.new(100, :EUR), account_id:  acc1.id},
      %{type: :credit, value: Money.new(100, :EUR), account_id:  acc2.id}
    ])
    {:ok, transaction} = TransactionStore.create(transaction)
    Map.put(ctx, :transaction, transaction)
  end


  def create_pending_transaction(ctx), do: create_transaction(ctx, :pending)
  def create_posted_transaction(ctx), do: create_transaction(ctx, :posted)
end
