defmodule DoubleEntryLedger.Apis.EventApiTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Apis.CommandApi
  alias DoubleEntryLedger.Command.AccountCommandMap
  alias DoubleEntryLedger.Repo
  alias DoubleEntryLedger.Stores.{AccountStore, InstanceStore}

  doctest CommandApi
end
