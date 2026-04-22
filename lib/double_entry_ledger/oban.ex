defmodule DoubleEntryLedger.Oban do
  @moduledoc """
  Helper for DoubleEntryLedger's dedicated Oban instance.

  The library runs a **named** Oban supervisor registered under the atom
  `DoubleEntryLedger.Oban`, separate from any Oban the consumer app runs
  for its own background jobs. This avoids colliding with the default
  unnamed `Oban` instance and makes the library drop-in: consumers don't
  need to know DEL's queue names.

  Call sites inside the library enqueue through `insert/3`, which
  preserves the `Ecto.Multi` pipeline shape while targeting DEL's named
  instance.
  """

  @doc """
  Pipeline-friendly `Oban.insert/4` for DEL's named instance.

      multi |> DoubleEntryLedger.Oban.insert(:step_name, fn _ -> ... end)
  """
  @spec insert(Ecto.Multi.t(), atom(), Ecto.Changeset.t() | (map() -> Ecto.Changeset.t())) ::
          Ecto.Multi.t()
  def insert(multi, multi_name, changeset_or_fun) do
    Oban.insert(__MODULE__, multi, multi_name, changeset_or_fun)
  end
end
