defmodule DoubleEntryLedger.TelemetryTest do
  @moduledoc """
  Tests for telemetry event emissions.

  Each test attaches a telemetry handler, triggers the event, and asserts
  on the event name, measurements, and metadata.
  """
  use ExUnit.Case, async: true
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.CommandFixtures
  import DoubleEntryLedger.LeaseFixtures, only: [test_grant: 1]

  alias DoubleEntryLedger.Apis.CommandApi
  alias DoubleEntryLedger.CommandQueue.Scheduling
  alias DoubleEntryLedger.Stores.{CommandStore, InstanceStore}
  alias DoubleEntryLedger.Telemetry, as: LedgerTelemetry

  describe "command_enqueue" do
    setup [:create_instance, :create_accounts]

    test "emits [:double_entry_ledger, :command, :enqueue]", %{instance: instance} do
      ref = attach_telemetry([:double_entry_ledger, :command, :enqueue])

      {:ok, _command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :command, :enqueue],
                      %{system_time: _}, %{action: _, instance_id: _, source: _}}
    end
  end

  describe "command_claim" do
    setup [:create_instance, :create_accounts]

    test "emits [:double_entry_ledger, :command, :claim]", %{instance: instance} do
      ref = attach_telemetry([:double_entry_ledger, :command, :claim])

      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      grant = test_grant(instance.id)
      owner_id = grant.owner_id

      {:ok, _claimed} = Scheduling.claim_command_for_processing(command.id, grant)

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :command, :claim],
                      %{system_time: _},
                      %{command_id: _, instance_id: _, processor_id: ^owner_id}}
    end
  end

  describe "command_retry" do
    setup [:create_instance, :create_accounts]

    test "emits [:double_entry_ledger, :command, :retry]", %{instance: instance} do
      ref = attach_telemetry([:double_entry_ledger, :command, :retry])

      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      assert {:error, _updated_command} =
               Scheduling.schedule_retry_with_reason(
                 command,
                 "test error",
                 :failed
               )

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :command, :retry],
                      %{system_time: _},
                      %{command_id: _, instance_id: _, status: :failed, retry_count: _}}
    end
  end

  describe "command_dead_letter" do
    setup [:create_instance, :create_accounts]

    test "emits [:double_entry_ledger, :command, :dead_letter]", %{instance: instance} do
      ref = attach_telemetry([:double_entry_ledger, :command, :dead_letter])

      {:ok, command} =
        CommandStore.create(transaction_command_attrs(instance_address: instance.address))

      assert {:error, _updated_command} =
               Scheduling.mark_as_dead_letter(
                 command,
                 "terminal error"
               )

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :command, :dead_letter],
                      %{system_time: _},
                      %{command_id: _, instance_id: _, error: "terminal error"}}
    end
  end

  describe "occ_retry" do
    test "emits [:double_entry_ledger, :occ, :retry]" do
      ref = attach_telemetry([:double_entry_ledger, :occ, :retry])

      LedgerTelemetry.occ_retry(%{
        module: SomeModule,
        attempts_remaining: 3,
        command_id: nil,
        instance_id: Ecto.UUID.generate(),
        action: :create_transaction,
        source: "test",
        source_idempk: "key1"
      })

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :occ, :retry],
                      %{system_time: _}, %{module: SomeModule, attempts_remaining: 3}}
    end
  end

  describe "transaction lifecycle" do
    test "emits [:double_entry_ledger, :transaction, :created]" do
      ref = attach_telemetry([:double_entry_ledger, :transaction, :created])

      LedgerTelemetry.transaction_created(%{
        transaction_id: Ecto.UUID.generate(),
        instance_id: Ecto.UUID.generate(),
        status: :posted
      })

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :transaction, :created],
                      %{system_time: _}, %{transaction_id: _, instance_id: _, status: :posted}}
    end

    test "emits [:double_entry_ledger, :transaction, :posted]" do
      ref = attach_telemetry([:double_entry_ledger, :transaction, :posted])

      LedgerTelemetry.transaction_posted(%{
        transaction_id: Ecto.UUID.generate(),
        instance_id: Ecto.UUID.generate()
      })

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :transaction, :posted],
                      %{system_time: _}, %{transaction_id: _, instance_id: _}}
    end

    test "emits [:double_entry_ledger, :transaction, :archived]" do
      ref = attach_telemetry([:double_entry_ledger, :transaction, :archived])

      LedgerTelemetry.transaction_archived(%{
        transaction_id: Ecto.UUID.generate(),
        instance_id: Ecto.UUID.generate()
      })

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :transaction, :archived],
                      %{system_time: _}, %{transaction_id: _, instance_id: _}}
    end
  end

  describe "account lifecycle" do
    test "emits [:double_entry_ledger, :account, :created]" do
      ref = attach_telemetry([:double_entry_ledger, :account, :created])

      LedgerTelemetry.account_created(%{
        account_address: "cash:main",
        instance_id: Ecto.UUID.generate(),
        type: :asset,
        currency: :USD
      })

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :account, :created],
                      %{system_time: _},
                      %{account_address: "cash:main", type: :asset, currency: :USD}}
    end

    test "emits [:double_entry_ledger, :account, :updated]" do
      ref = attach_telemetry([:double_entry_ledger, :account, :updated])

      LedgerTelemetry.account_updated(%{
        account_address: "cash:main",
        instance_id: Ecto.UUID.generate()
      })

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :account, :updated],
                      %{system_time: _}, %{account_address: "cash:main", instance_id: _}}
    end
  end

  describe "instance lifecycle" do
    test "emits [:double_entry_ledger, :instance, :created]" do
      ref = attach_telemetry([:double_entry_ledger, :instance, :created])

      {:ok, instance} = InstanceStore.create(%{address: "telemetry:test:instance"})
      instance_id = instance.id

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :instance, :created],
                      %{system_time: _}, %{instance_id: ^instance_id}}
    end
  end

  describe "instance_processor lifecycle" do
    test "emits [:double_entry_ledger, :instance_processor, :start]" do
      ref = attach_telemetry([:double_entry_ledger, :instance_processor, :start])

      instance_id = Ecto.UUID.generate()
      LedgerTelemetry.instance_processor_start(%{instance_id: instance_id})

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :instance_processor, :start],
                      %{system_time: _}, %{instance_id: ^instance_id}}
    end

    test "emits [:double_entry_ledger, :instance_processor, :stop]" do
      ref = attach_telemetry([:double_entry_ledger, :instance_processor, :stop])

      instance_id = Ecto.UUID.generate()
      LedgerTelemetry.instance_processor_stop(%{instance_id: instance_id})

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :instance_processor, :stop],
                      %{system_time: _}, %{instance_id: ^instance_id}}
    end
  end

  describe "command_process span integration" do
    setup [:create_instance, :create_accounts]

    test "emits span events when processing a command", %{instance: instance} do
      start_ref = attach_telemetry([:double_entry_ledger, :command, :process, :start])
      stop_ref = attach_telemetry([:double_entry_ledger, :command, :process, :stop])

      CommandApi.process_from_params(
        %{
          "instance_address" => instance.address,
          "action" => "create_account",
          "source" => "telemetry_test",
          "source_idempk" => "span_test_123",
          "payload" => %{
            "type" => "asset",
            "address" => "span:test:account",
            "currency" => "EUR"
          }
        },
        on_error: :fail
      )

      assert_receive {:telemetry_event, ^start_ref,
                      [:double_entry_ledger, :command, :process, :start], _,
                      %{action: :create_account, source: "telemetry_test"}}

      assert_receive {:telemetry_event, ^stop_ref,
                      [:double_entry_ledger, :command, :process, :stop], %{duration: _},
                      %{action: :create_account, source: "telemetry_test"}}
    end
  end

  describe "command_process span" do
    test "emits start and stop events" do
      start_ref = attach_telemetry([:double_entry_ledger, :command, :process, :start])
      stop_ref = attach_telemetry([:double_entry_ledger, :command, :process, :stop])

      metadata = %{
        action: :create_transaction,
        instance_id: Ecto.UUID.generate(),
        source: "test",
        trace_context: %{"traceparent" => "00-abc"}
      }

      result = LedgerTelemetry.command_process_span(metadata, fn -> {:ok, :done} end)
      assert result == {:ok, :done}

      assert_receive {:telemetry_event, ^start_ref,
                      [:double_entry_ledger, :command, :process, :start],
                      %{system_time: _, monotonic_time: _},
                      %{action: :create_transaction, source: "test"}}

      assert_receive {:telemetry_event, ^stop_ref,
                      [:double_entry_ledger, :command, :process, :stop], %{duration: _},
                      %{action: :create_transaction, source: "test"}}
    end

    test "emits start and exception events on raise" do
      start_ref = attach_telemetry([:double_entry_ledger, :command, :process, :start])
      exception_ref = attach_telemetry([:double_entry_ledger, :command, :process, :exception])

      metadata = %{
        action: :create_transaction,
        instance_id: Ecto.UUID.generate(),
        source: "test",
        trace_context: nil
      }

      assert_raise RuntimeError, fn ->
        LedgerTelemetry.command_process_span(metadata, fn -> raise "boom" end)
      end

      assert_receive {:telemetry_event, ^start_ref,
                      [:double_entry_ledger, :command, :process, :start], _, _}

      assert_receive {:telemetry_event, ^exception_ref,
                      [:double_entry_ledger, :command, :process, :exception], %{duration: _},
                      %{kind: _, reason: _, stacktrace: _}}
    end
  end

  describe "command_idempotency_hit" do
    test "emits [:double_entry_ledger, :command, :idempotency_hit]" do
      ref = attach_telemetry([:double_entry_ledger, :command, :idempotency_hit])

      LedgerTelemetry.command_idempotency_hit(%{
        action: :create_transaction,
        instance_id: Ecto.UUID.generate(),
        source: "test",
        source_idempk: "key1"
      })

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :command, :idempotency_hit],
                      %{system_time: _},
                      %{action: :create_transaction, source: "test", source_idempk: "key1"}}
    end
  end

  describe "lease events" do
    test "lease_acquired/1 emits with metadata" do
      ref = attach_telemetry([:double_entry_ledger, :lease, :acquired])

      LedgerTelemetry.lease_acquired(%{
        instance_id: "i",
        owner_id: "o",
        fencing_token: 1,
        takeover: false,
        previous_owner_id: nil,
        orphans: 0
      })

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :lease, :acquired],
                      %{system_time: _}, %{owner_id: "o", fencing_token: 1, takeover: false}}
    end

    test "lease_renewed/1 emits with owner and token" do
      ref = attach_telemetry([:double_entry_ledger, :lease, :renewed])
      LedgerTelemetry.lease_renewed(%{instance_id: "i", owner_id: "o", fencing_token: 1})

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :lease, :renewed],
                      %{system_time: _}, %{owner_id: "o", fencing_token: 1}}
    end

    test "lease_lost/1 emits with source" do
      ref = attach_telemetry([:double_entry_ledger, :lease, :lost])

      LedgerTelemetry.lease_lost(%{
        instance_id: "i",
        owner_id: "o",
        fencing_token: 1,
        source: :renewal
      })

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :lease, :lost],
                      %{system_time: _}, %{source: :renewal}}
    end

    test "lease_released/1 emits with reason" do
      ref = attach_telemetry([:double_entry_ledger, :lease, :released])

      LedgerTelemetry.lease_released(%{
        instance_id: "i",
        owner_id: "o",
        fencing_token: 1,
        reason: :drained
      })

      assert_receive {:telemetry_event, ^ref, [:double_entry_ledger, :lease, :released],
                      %{system_time: _}, %{reason: :drained}}
    end

    test "dashboard_metrics/0 counts the four lease events" do
      names = Enum.map(LedgerTelemetry.dashboard_metrics(), & &1.name)

      assert [:double_entry_ledger, :lease, :acquired, :system_time] in names
      assert [:double_entry_ledger, :lease, :renewed, :system_time] in names
      assert [:double_entry_ledger, :lease, :lost, :system_time] in names
      assert [:double_entry_ledger, :lease, :released, :system_time] in names
    end

    test "dashboard_metrics/0 tags the four lease counters" do
      metrics = LedgerTelemetry.dashboard_metrics()

      acquired =
        Enum.find(metrics, &(&1.name == [:double_entry_ledger, :lease, :acquired, :system_time]))

      renewed =
        Enum.find(metrics, &(&1.name == [:double_entry_ledger, :lease, :renewed, :system_time]))

      lost = Enum.find(metrics, &(&1.name == [:double_entry_ledger, :lease, :lost, :system_time]))

      released =
        Enum.find(metrics, &(&1.name == [:double_entry_ledger, :lease, :released, :system_time]))

      assert acquired.tags == [:takeover]
      assert renewed.tags == []
      assert lost.tags == [:source]
      assert released.tags == [:reason]
    end
  end

  describe "defensive error handling" do
    test "emit_transaction swallows exceptions on malformed input" do
      # Missing required fields on the struct should not crash
      assert :ok == LedgerTelemetry.emit_transaction(%{not_a_transaction: true}, nil)
    end

    test "emit_transaction handles unknown status" do
      # Unknown status should not crash
      transaction = %{
        id: Ecto.UUID.generate(),
        instance_id: Ecto.UUID.generate(),
        status: :unknown_status,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert :ok == LedgerTelemetry.emit_transaction(transaction, nil)
    end

    test "emit_account swallows exceptions on malformed input" do
      assert :ok == LedgerTelemetry.emit_account(%{not_an_account: true}, nil)
    end
  end

  if Code.ensure_loaded?(Telemetry.Metrics) do
    describe "dashboard_metrics/0" do
      test "exposes a metric for every documented ledger event" do
        names = Enum.map(LedgerTelemetry.dashboard_metrics(), & &1.name)

        expected = [
          [:double_entry_ledger, :command, :process, :stop, :duration],
          [:double_entry_ledger, :command, :enqueue, :system_time],
          [:double_entry_ledger, :command, :claim, :system_time],
          [:double_entry_ledger, :command, :retry, :system_time],
          [:double_entry_ledger, :command, :dead_letter, :system_time],
          [:double_entry_ledger, :command, :recovered, :system_time],
          [:double_entry_ledger, :command, :idempotency_hit, :system_time],
          [:double_entry_ledger, :occ, :retry, :system_time],
          [:double_entry_ledger, :transaction, :created, :system_time],
          [:double_entry_ledger, :transaction, :posted, :system_time],
          [:double_entry_ledger, :transaction, :archived, :system_time],
          [:double_entry_ledger, :account, :created, :system_time],
          [:double_entry_ledger, :account, :updated, :system_time],
          [:double_entry_ledger, :instance, :created, :system_time]
        ]

        assert [] == expected -- names
      end

      test "builds only counter and summary metrics" do
        kinds =
          LedgerTelemetry.dashboard_metrics()
          |> Enum.map(& &1.__struct__)
          |> Enum.uniq()
          |> Enum.sort()

        assert kinds == [Telemetry.Metrics.Counter, Telemetry.Metrics.Summary]
      end

      test "reports command processing duration as a millisecond summary" do
        duration =
          Enum.find(
            LedgerTelemetry.dashboard_metrics(),
            &(&1.name == [:double_entry_ledger, :command, :process, :stop, :duration])
          )

        assert duration.unit == :millisecond
        assert duration.tags == [:action, :source]
        assert duration.event_name == [:double_entry_ledger, :command, :process, :stop]
      end
    end
  end
end
