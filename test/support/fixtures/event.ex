defmodule DoubleEntryLedger.EventFixtures do
  @moduledoc """
  This module defines test helpers for creating
  event entities.
  """
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
end
