defmodule DoubleEntryLedger.Stores.InstanceStoreHelper do
  @moduledoc """
  Helper functions for Instance store queries
  """
  import Ecto.Query

  alias DoubleEntryLedger.Instance

  @spec build_get_by_address(String.t()) :: Ecto.Query.t()
  def build_get_by_address(address) do
    from(i in Instance,
      where: i.address == ^address
    )
  end

  @spec build_get_id_by_address(String.t()) :: Ecto.Query.t()
  def build_get_id_by_address(address) do
    from(i in Instance,
      where: i.address == ^address,
      select: i.id
    )
  end
end
