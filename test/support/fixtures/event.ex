defmodule DoubleEntryLedger.EventFixtures do
  @moduledoc """
  This module defines test helpers for creating
  event entities.
  """
  import DoubleEntryLedger.EventPayloadFixtures

  def event_attrs(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      action: :create,
      source: "source",
      source_id: "source_id",
      payload: pending_payload()
    })
  end
end
