defmodule DoubleEntryLedger.TransactionFixtures do
  @moduledoc """
  This module defines test helpers for creating
  transaction entities.
  """

  def transaction_attr(attrs) do
    attrs
    |> Enum.into(%{
      effective_at: ~U[2023-11-18 17:49:00.000000Z],
      event_id: "some event_id",
      metadata: %{},
      posted_at: ~U[2023-11-18 17:49:00.000000Z],
      status: :pending,
    })
  end
end
