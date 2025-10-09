defmodule DoubleEntryLedger.Utils.Pagination do
  @moduledoc """
  Pagination
  """
  import Ecto.Query, only: [limit: 2, offset: 2]

  @spec paginate(Ecto.Query.t(), non_neg_integer(), non_neg_integer()) :: Ecto.Query.t()
  def paginate(query, page, per_page) do
    offset = (page - 1) * per_page

    query
    |> limit(^per_page)
    |> offset(^offset)
  end
end
