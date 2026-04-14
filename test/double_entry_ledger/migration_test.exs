defmodule DoubleEntryLedger.MigrationTest do
  use ExUnit.Case, async: true

  alias DoubleEntryLedger.Migration

  describe "latest_version/0" do
    test "returns 2" do
      assert Migration.latest_version() == 2
    end
  end
end
