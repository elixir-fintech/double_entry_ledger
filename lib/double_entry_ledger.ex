defmodule DoubleEntryLedger do
  @moduledoc """
  Entry point for the DoubleEntryLedger library.

  Most functionality lives under `DoubleEntryLedger.Apis.*` and
  `DoubleEntryLedger.Stores.*`. This module exposes the integration
  helpers consumers need when embedding the library.
  """

  @doc """
  Child specs to add to a consumer application's supervisor in BYO-repo mode.

  Place this after the consumer's repo so the command queue sees a started
  repo:

      # lib/my_app/application.ex
      children = [
        MyApp.Repo,
        # ... other children ...
      ] ++ DoubleEntryLedger.children()

  In standalone mode (no `:repo` configured) the library supervises these
  itself and consumers do not need to call this.
  """
  @spec children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children, do: DoubleEntryLedger.Application.managed_children()
end
