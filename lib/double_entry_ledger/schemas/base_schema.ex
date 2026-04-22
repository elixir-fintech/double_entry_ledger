defmodule DoubleEntryLedger.BaseSchema do
  @moduledoc """
  The `DoubleEntryLedger.BaseSchema` module provides a base schema configuration for all schemas in the DoubleEntryLedger project.

  This module sets up common schema attributes such as primary key, foreign key type, and schema prefix.
  It is intended to be used with the `use` macro in other schema modules to ensure consistency.

  ## Usage

  To use the `BaseSchema` in your schema module, simply add `use DoubleEntryLedger.BaseSchema`:

  ```elixir
  defmodule DoubleEntryLedger.SomeSchema do
    use DoubleEntryLedger.BaseSchema

    schema "some_table" do
      field :name, :string
      # ... other fields ...
    end
  end
  ```

  This will automatically set up the primary key, foreign key type, and schema prefix for the `SomeSchema` module.
  """
  defmacro __using__(_) do
    quote do
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id

      @schema_prefix "double_entry_ledger"
    end
  end
end
