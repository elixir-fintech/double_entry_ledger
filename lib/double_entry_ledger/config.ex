defmodule DoubleEntryLedger.Config do
  @moduledoc """
  Access to consumer-supplied configuration.

  Consumers typically set:

      config :double_entry_ledger,
        repo: MyApp.Repo,
        schema_prefix: "my_ledger",
        idempotency_secret: System.get_env("DEL_IDEMPOTENCY_SECRET")

  When `:repo` is not set the library falls back to the shipped
  `DoubleEntryLedger.Repo` module (useful when running the library
  standalone for tests or demos). In that fallback mode consumers must
  configure `DoubleEntryLedger.Repo` per-env themselves.

  `:schema_prefix` controls the Postgres schema in which DEL's tables
  live. It defaults to `"double_entry_ledger"`.
  """

  @schema_prefix Application.compile_env(
                   :double_entry_ledger,
                   :schema_prefix,
                   "double_entry_ledger"
                 )

  @doc """
  Returns the configured Ecto repo module.

  Read at runtime (not compile time) so consumer apps can override via
  `config :double_entry_ledger, repo: MyApp.Repo` without forcing a
  recompile of this library. Mix's `compile_env` tracking does not reach
  into path/hex deps reliably, so runtime resolution is safer here.
  """
  @spec repo() :: module()
  def repo, do: Application.get_env(:double_entry_ledger, :repo, DoubleEntryLedger.Repo)

  @doc """
  Returns the Postgres schema prefix used by DEL's tables.

  Baked in at compile time because Ecto's `@schema_prefix` must be a
  literal. Consumers overriding `:schema_prefix` must force a recompile
  of this library (`mix deps.compile double_entry_ledger --force`) for
  the change to take effect in the schema modules.
  """
  @spec schema_prefix() :: String.t()
  def schema_prefix, do: @schema_prefix
end
