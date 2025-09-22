defmodule DoubleEntryLedger.Event.TransferErrorsTest do
  use ExUnit.Case, async: true

  alias DoubleEntryLedger.Event.TransferErrors

  alias DoubleEntryLedger.Event.{
    AccountEventMap,
    AccountData,
    TransactionEventMap,
    TransactionData
  }

  alias DoubleEntryLedger.{Event, Account, Transaction}

  doctest TransferErrors

  describe "from_account_to_event_map_payload/2" do
    test "transfers errors from account changeset to event map" do
      account_changeset = Account.changeset(%Account{}, %{})

      event_map = %AccountEventMap{payload: %AccountData{}}

      %{changes: %{payload: %{errors: errors}}} =
        TransferErrors.from_account_to_event_map_payload(event_map, account_changeset)

      assert Keyword.equal?(errors,
               currency: {"can't be blank", [validation: :required]},
               name: {"can't be blank", [validation: :required]},
               address: {"can't be blank", [validation: :required]},
               type: {"invalid account type: ", []},
               type: {"can't be blank", [validation: :required]}
             )
    end

    test "transfers errors for allowed_negative and normal_balance" do
      account_changeset =
        Account.changeset(%Account{}, %{name: "A", type: :asset, currency: "USD", allowed_negative: "xx", normal_balance: "yy"})

      event_map = %AccountEventMap{payload: %AccountData{name: "A", type: :asset, currency: "USD", allowed_negative: "xx", normal_balance: "yy"}}

      %{changes: %{payload: %{errors: errors}}} =
        TransferErrors.from_account_to_event_map_payload(event_map, account_changeset)

      assert Keyword.has_key?(errors, :allowed_negative)
      assert Keyword.has_key?(errors, :normal_balance)
    end

    test "does not transfer errors when account changeset is valid" do
      account_changeset = Account.changeset(%Account{}, %{name: "Valid Name", type: :asset, currency: "USD", address: "account:main"})

      event_map = %AccountEventMap{payload: %AccountData{name: "Valid Name", type: :asset, currency: "USD", address: "account:main"}}

      %{changes: %{payload: %{errors: errors}}} =
        TransferErrors.from_account_to_event_map_payload(event_map, account_changeset)

      assert errors == []
    end
  end

  describe "from_event_to_event_map/2" do
    test "transfers errors from event changeset to event map" do
      expected_errors = [
        action: {"invalid in this context", [value: ""]},
        action: {"can't be blank", [validation: :required]},
        instance_address: {"can't be blank", [validation: :required]},
        source: {"can't be blank", [validation: :required]},
        source_idempk: {"can't be blank", [validation: :required]}
      ]

      event_changeset = Event.changeset(%Event{}, %{})

      %{data: %AccountEventMap{}, errors: errors} =
        TransferErrors.from_event_to_event_map(%AccountEventMap{}, event_changeset)

      assert Keyword.equal?(errors, expected_errors)

      %{data: %TransactionEventMap{}, errors: errors} =
        TransferErrors.from_event_to_event_map(%TransactionEventMap{}, event_changeset)

      assert Keyword.equal?(errors, expected_errors)
    end

    # Add tests for this function
  end

  describe "from_transaction_to_event_map_payload/2" do
    test "transfers errors from transaction changeset to event map" do
      transaction_changeset =
        Ecto.Changeset.change(%Transaction{}, %{})
        |> Ecto.Changeset.add_error(:status, "some error message")

      event_map = %TransactionEventMap{payload: %TransactionData{}}

      %{changes: %{payload: %{errors: errors}}} =
        TransferErrors.from_transaction_to_event_map_payload(event_map, transaction_changeset)

      assert Keyword.has_key?(errors, :status)
      assert Keyword.get(errors, :status) == {"some error message", []}
    end
  end

  describe "get_all_errors_with_opts/1" do
    test "returns all errors with options" do
      changeset =
        AccountEventMap.changeset(%AccountEventMap{}, %{action: :create_account, payload: %{}})

      assert Map.equal?(
               TransferErrors.get_all_errors_with_opts(changeset),
               %{
                 instance_address: [{"can't be blank", [validation: :required]}],
                 source: [{"can't be blank", [validation: :required]}],
                 source_idempk: [{"can't be blank", [validation: :required]}],
                 payload: %{
                   currency: [{"can't be blank", [validation: :required]}],
                   name: [{"can't be blank", [validation: :required]}],
                   type: [{"can't be blank", [validation: :required]}],
                   address: [{"can't be blank", [validation: :required]}]
                 }
               }
             )
    end
  end
end
