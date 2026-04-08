defmodule DoubleEntryLedger.Workers.Oban.JournalEventLinksTest do
  @moduledoc """
  Tests for the JournalEventLinks Oban worker.

  Verifies that both the transaction-link and account-link perform/1 clauses
  correctly insert the appropriate link records into the database.
  """
  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.InstanceFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.CommandFixtures

  alias DoubleEntryLedger.{
    JournalEvent,
    JournalEventTransactionLink,
    JournalEventAccountLink,
    JournalEventCommandLink,
    Repo
  }

  alias DoubleEntryLedger.Command.{TransactionCommandMap, TransactionData}
  alias DoubleEntryLedger.Stores.CommandStore
  alias DoubleEntryLedger.Workers.Oban.JournalEventLinks

  setup [:create_instance, :create_accounts]

  defp create_transaction_via_api(ctx) do
    %{instance: inst, accounts: [a1, a2 | _]} = ctx

    {:ok, transaction, _command} =
      DoubleEntryLedger.Apis.CommandApi.process_from_params(
        %{
          "instance_address" => inst.address,
          "action" => "create_transaction",
          "source" => "test",
          "source_idempk" => "journal_links_test_#{System.unique_integer([:positive])}",
          "payload" => %{
            "status" => "posted",
            "entries" => [
              %{
                "account_address" => a1.address,
                "amount" => 100,
                "currency" => "EUR"
              },
              %{
                "account_address" => a2.address,
                "amount" => 100,
                "currency" => "EUR"
              }
            ]
          }
        },
        on_error: :fail
      )

    transaction
  end

  defp create_unlinked_command(%{instance: inst}) do
    {:ok, command} =
      CommandStore.create(
        transaction_command_attrs(
          instance_address: inst.address,
          source_idempk: "unlinked_#{System.unique_integer([:positive])}"
        )
      )

    command
  end

  defp create_journal_event(%{instance: inst}) do
    command_map = %TransactionCommandMap{
      action: :create_transaction,
      source: "test",
      source_idempk: "je_test_#{System.unique_integer([:positive])}",
      instance_address: inst.address,
      payload: %TransactionData{status: :posted, entries: []}
    }

    {:ok, journal_event} =
      JournalEvent.build_create(%{command_map: command_map, instance_id: inst.id})
      |> Repo.insert()

    journal_event
  end

  describe "perform/1 with transaction link args" do
    test "creates transaction and command links", ctx do
      transaction = create_transaction_via_api(ctx)
      command = create_unlinked_command(ctx)
      journal_event = create_journal_event(ctx)

      args = %{
        "command_id" => command.id,
        "transaction_id" => transaction.id,
        "journal_event_id" => journal_event.id
      }

      assert {:ok, %{transaction_link: trx_link, command_link: cmd_link}} =
               JournalEventLinks.perform(%Oban.Job{args: args})

      assert trx_link.transaction_id == transaction.id
      assert trx_link.journal_event_id == journal_event.id
      assert cmd_link.command_id == command.id
      assert cmd_link.journal_event_id == journal_event.id

      # Verify records persist in DB
      assert Repo.get(JournalEventTransactionLink, trx_link.id)
      assert Repo.get(JournalEventCommandLink, cmd_link.id)
    end
  end

  describe "perform/1 with account link args" do
    test "creates account and command links", ctx do
      %{accounts: [a1 | _]} = ctx
      command = create_unlinked_command(ctx)
      journal_event = create_journal_event(ctx)

      args = %{
        "command_id" => command.id,
        "account_id" => a1.id,
        "journal_event_id" => journal_event.id
      }

      assert {:ok, %{account_link: acc_link, command_link: cmd_link}} =
               JournalEventLinks.perform(%Oban.Job{args: args})

      assert acc_link.account_id == a1.id
      assert acc_link.journal_event_id == journal_event.id
      assert cmd_link.command_id == command.id
      assert cmd_link.journal_event_id == journal_event.id

      # Verify records persist in DB
      assert Repo.get(JournalEventAccountLink, acc_link.id)
      assert Repo.get(JournalEventCommandLink, cmd_link.id)
    end
  end
end
