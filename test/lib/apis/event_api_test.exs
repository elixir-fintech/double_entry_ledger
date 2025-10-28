defmodule DoubleEntryLedger.Apis.EventApiTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.Repo
  alias DoubleEntryLedger.Stores.{AccountStore, InstanceStore}
  alias DoubleEntryLedger.Apis.EventApi

  doctest EventApi
end
