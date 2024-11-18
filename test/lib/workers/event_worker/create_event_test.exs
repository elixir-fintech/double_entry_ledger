defmodule DoubleEntryLedger.CreateEventTest do
  @moduledoc """
  This module tests the CreateEvent module.
  """
  use ExUnit.Case
  import Mox

  use DoubleEntryLedger.RepoCase

  import DoubleEntryLedger.EventFixtures
  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  import DoubleEntryLedger.EventWorker.EventTransformer,
    only: [transaction_data_to_transaction_map: 2]

  alias DoubleEntryLedger.EventWorker.CreateEvent

  doctest CreateEvent

  describe "process_create_event/1" do
    setup [:create_instance, :create_accounts]

    test "process create event successfully", ctx do
      %{event: event} = create_event(ctx)

      {:ok, {transaction, processed_event}} = CreateEvent.process_create_event(event)
      assert processed_event.status == :processed
      assert processed_event.processed_transaction_id == transaction.id
      assert processed_event.processed_at != nil
      assert transaction.status == :posted
    end
  end

  describe "process_create_event_with_retry/4" do
    setup [:create_instance, :create_accounts, :verify_on_exit!]

    test "create event with last retry that fails", ctx do
      %{event: %{transaction_data: transaction_data, instance_id: id} = event} = create_event(ctx)
      {:ok, transaction_map} = transaction_data_to_transaction_map(transaction_data, id)

      DoubleEntryLedger.MockRepo
      |> expect(:insert, fn _changeset ->
        # simulate a conflict when adding the transaction
        raise Ecto.StaleEntryError, action: :update, changeset: %Ecto.Changeset{}
      end)
      |> expect(:transaction, fn multi ->
        # the transaction has to be handled by the Repo
        Repo.transaction(multi)
      end)

      assert {:error, "OCC conflict: Max number of 5 retries reached"} =
               CreateEvent.process_create_event_with_retry(
                 event,
                 transaction_map,
                 1,
                 DoubleEntryLedger.MockRepo
               )
    end

    # test "when transaction can't be created for other reasons", ctx do
    # %{event: %{transaction_data: transaction_data, instance_id: id} = event} = create_event(ctx)
    # {:ok, transaction_map} = transaction_data_to_transaction_map(transaction_data, id)
    #
    # DoubleEntryLedger.MockRepo
    # |> expect(:insert, fn changeset ->
    ## simulate a conflict when adding the transaction
    # {:error, changeset}
    # end)
    # |> expect(:transaction, fn multi ->
    ## the transaction has to be handled by the Repo
    # Repo.transaction(multi)
    # end)
    #
    # assert {:error, "OCC conflict: Max number of 5 retries reached"} =
    # CreateEvent.create_event_with_retry(
    # event,
    # transaction_map,
    # 1,
    # DoubleEntryLedger.MockRepo
    # )
    # end
  end
end
