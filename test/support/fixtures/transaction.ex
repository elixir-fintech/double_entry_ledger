defmodule DoubleEntryLedger.TransactionFixtures do
  @moduledoc """
  This module defines test helpers for creating
  transaction entities.
  """

  alias DoubleEntryLedger.Apis.EventApi

  def transaction_attr(attrs) do
    attrs
    |> Enum.into(%{
      event_id: "some event_id",
      metadata: %{},
      posted_at: ~U[2023-11-18 17:49:00.000000Z],
      status: :pending
    })
  end

  def create_transaction(
        %{instance: instance, accounts: [acc1, acc2, _, _]} = ctx,
        status \\ :pending
      ) do
    event =
      %{
        "action" => "create_transaction",
        "source" => "transaction",
        "source_idempk" => Ecto.UUID.generate(),
        "instance_address" => instance.address,
        "payload" => %{
          "status" => status,
          "entries" => [
            %{"currency" => "EUR", "amount" => 100, "account_address" => acc1.address},
            %{"currency" => "EUR", "amount" => 100, "account_address" => acc2.address}
          ]
        }
      }

    {:ok, transaction, _event} = EventApi.process_from_params(event)
    Map.put(ctx, :transaction, transaction)
  end

  def create_pending_transaction(ctx), do: create_transaction(ctx, "pending")
  def create_posted_transaction(ctx), do: create_transaction(ctx, "posted")
end
