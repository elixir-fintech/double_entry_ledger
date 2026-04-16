defmodule DoubleEntryLedger.Utils.TraceableTest do
  @moduledoc """
  Tests for the Traceable protocol's trace_context propagation.
  """
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.CommandFixtures
  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.AccountFixtures

  alias DoubleEntryLedger.Utils.Traceable
  alias DoubleEntryLedger.Command.{TransactionCommandMap, AccountCommandMap}
  alias DoubleEntryLedger.Stores.CommandStore

  describe "Command trace_context propagation" do
    setup [:create_instance, :create_accounts]

    test "metadata includes trace_context when present on command", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(
          transaction_command_attrs(
            instance_address: instance.address,
            trace_context: %{"traceparent" => "00-abc123"}
          )
        )

      metadata = Traceable.metadata(command)
      assert metadata.trace_context == %{"traceparent" => "00-abc123"}
    end

    test "metadata omits trace_context when nil on command", %{instance: instance} do
      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      metadata = Traceable.metadata(command)
      assert metadata.trace_context == nil
    end
  end

  describe "TransactionCommandMap trace_context propagation" do
    test "metadata includes trace_context when present" do
      command_map =
        struct(TransactionCommandMap,
          action: :create_transaction,
          instance_address: "some:address",
          source: "test_source",
          source_idempk: "idempk1",
          trace_context: %{"traceparent" => "00-abc123"}
        )

      metadata = Traceable.metadata(command_map)
      assert metadata.trace_context == %{"traceparent" => "00-abc123"}
    end

    test "metadata omits trace_context when nil" do
      command_map =
        struct(TransactionCommandMap,
          action: :create_transaction,
          instance_address: "some:address",
          source: "test_source",
          source_idempk: "idempk1"
        )

      metadata = Traceable.metadata(command_map)
      assert metadata.trace_context == nil
    end
  end

  describe "AccountCommandMap trace_context propagation" do
    test "metadata includes trace_context when present" do
      command_map =
        struct(AccountCommandMap,
          action: :create_account,
          instance_address: "some:address",
          source: "test_source",
          trace_context: %{"traceparent" => "00-abc123"}
        )

      metadata = Traceable.metadata(command_map)
      assert metadata.trace_context == %{"traceparent" => "00-abc123"}
    end

    test "metadata omits trace_context when nil" do
      command_map =
        struct(AccountCommandMap,
          action: :create_account,
          instance_address: "some:address",
          source: "test_source"
        )

      metadata = Traceable.metadata(command_map)
      assert metadata.trace_context == nil
    end
  end
end
