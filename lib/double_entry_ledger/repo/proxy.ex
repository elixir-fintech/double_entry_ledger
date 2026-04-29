defmodule DoubleEntryLedger.Repo.Proxy do
  @moduledoc """
  Repo dispatcher used by the library's internal modules.

  Library modules alias this as `Repo`:

      alias DoubleEntryLedger.Repo.Proxy, as: Repo

  Each call here forwards at runtime to whichever repo the consumer
  configured (`config :double_entry_ledger, repo: MyApp.Repo`), falling
  back to `DoubleEntryLedger.Repo` when no override is set.

  Runtime dispatch is required because Mix's `compile_env` tracking
  doesn't reach into path/hex deps reliably; compile-time aliases would
  freeze at the library's own default.

  Only the `Ecto.Repo` callbacks actually used by the library are
  defined. Add more here if internal code needs them.
  """

  alias DoubleEntryLedger.Config

  def insert(x), do: Config.repo().insert(x)
  def insert(x, opts), do: Config.repo().insert(x, opts)
  def insert!(x), do: Config.repo().insert!(x)
  def insert!(x, opts), do: Config.repo().insert!(x, opts)

  def insert_all(schema_or_source, entries),
    do: Config.repo().insert_all(schema_or_source, entries)

  def insert_all(schema_or_source, entries, opts),
    do: Config.repo().insert_all(schema_or_source, entries, opts)

  def update(x), do: Config.repo().update(x)
  def update(x, opts), do: Config.repo().update(x, opts)
  def update!(x), do: Config.repo().update!(x)
  def update!(x, opts), do: Config.repo().update!(x, opts)
  def delete(x), do: Config.repo().delete(x)
  def delete(x, opts), do: Config.repo().delete(x, opts)
  def get(q, id), do: Config.repo().get(q, id)
  def get(q, id, opts), do: Config.repo().get(q, id, opts)
  def all(q), do: Config.repo().all(q)
  def all(q, opts), do: Config.repo().all(q, opts)
  def one(q), do: Config.repo().one(q)
  def one(q, opts), do: Config.repo().one(q, opts)
  def preload(s, preloads), do: Config.repo().preload(s, preloads)
  def preload(s, preloads, opts), do: Config.repo().preload(s, preloads, opts)
  def transaction(f), do: Config.repo().transaction(f)
  def transaction(f, opts), do: Config.repo().transaction(f, opts)
end
