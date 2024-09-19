defmodule DoubleEntryLedger.RepoCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use TransactionStore.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  alias DoubleEntryLedger.Repo
  alias Ecto.Adapters.SQL.Sandbox

  use ExUnit.CaseTemplate

  using do
    quote do
      alias DoubleEntryLedger.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import DoubleEntryLedger.RepoCase
      # and any other stuff
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
