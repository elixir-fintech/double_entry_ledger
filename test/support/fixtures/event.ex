defmodule DoubleEntryLedger.EventFixtures do
  @moduledoc """
  This module defines test helpers for creating
  event entities.
  """
  import DoubleEntryLedger.EventPayloadFixtures

  def event_attrs(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      event_type: :create,
      source: "source",
      source_id: "source_id",
      payload: pending_payload()
    })
  end
end
