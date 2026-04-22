defmodule DoubleEntryLedger.Config do
  @moduledoc """
  Runtime access to consumer-supplied configuration.

  Consumers point DoubleEntryLedger at their own Ecto repo:

      config :double_entry_ledger,
        repo: MyApp.Repo,
        idempotency_secret: System.get_env("DEL_IDEMPOTENCY_SECRET")

  When `:repo` is not set the library falls back to the shipped
  `DoubleEntryLedger.Repo` module (useful when running the library
  standalone for tests or demos). In that fallback mode consumers must
  configure `DoubleEntryLedger.Repo` per-env themselves.
  """

  @doc """
  Returns the configured Ecto repo module.

  Read at runtime (not compile time) so consumer apps can override via
  `config :double_entry_ledger, repo: MyApp.Repo` without forcing a
  recompile of this library. Mix's `compile_env` tracking does not reach
  into path/hex deps reliably, so runtime resolution is safer here.
  """
  @spec repo() :: module()
  def repo, do: Application.get_env(:double_entry_ledger, :repo, DoubleEntryLedger.Repo)
end
