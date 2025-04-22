defmodule DoubleEntryLedger.AccountTest do
  @moduledoc """
  This module provides tests for the Account module.
  """

  use DoubleEntryLedger.RepoCase

  alias DoubleEntryLedger.{Account, Balance, Entry}

  import DoubleEntryLedger.AccountFixtures
  import DoubleEntryLedger.InstanceFixtures

  doctest Account

  describe "changeset/2" do
    setup [:create_instance]

    test "returns error changeset for missing fields", _ctx do
      assert %Ecto.Changeset{
               valid?: false,
               errors: [
                 type: {"invalid account type: ", []},
                 name: {"can't be blank", [validation: :required]},
                 currency: {"can't be blank", [validation: :required]},
                 instance_id: {"can't be blank", [validation: :required]},
                 type: {"can't be blank", [validation: :required]}
               ]
             } = Account.changeset(%Account{}, %{})
    end

    test "returns error changeset for invalid type and normal_balance", %{instance: %{id: id}} do
      assert %Ecto.Changeset{
               valid?: false,
               errors: [
                 type: {"invalid account type: ", []},
                 normal_balance: {"is invalid", _},
                 type: {"is invalid", _}
               ]
             } =
               Account.changeset(%Account{}, %{
                 name: "some name",
                 type: :debit,
                 currency: :EUR,
                 normal_balance: :asset,
                 instance_id: id
               })
    end

    test "sets the normal balance based on the account type", %{instance: %{id: id}} do
      assert %Ecto.Changeset{
               valid?: true,
               changes: %{type: :asset, normal_balance: :debit}
             } =
               Account.changeset(
                 %Account{},
                 %{name: "some name", type: :asset, instance_id: id, currency: :EUR}
               )

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{type: :liability, normal_balance: :credit}
             } =
               Account.changeset(%Account{}, %{
                 name: "some name",
                 type: :liability,
                 instance_id: id,
                 currency: :EUR
               })

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{type: :equity, normal_balance: :credit}
             } =
               Account.changeset(%Account{}, %{
                 name: "some name",
                 type: :equity,
                 instance_id: id,
                 currency: :EUR
               })

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{type: :expense, normal_balance: :debit}
             } =
               Account.changeset(%Account{}, %{
                 name: "some name",
                 type: :expense,
                 instance_id: id,
                 currency: :EUR
               })

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{type: :revenue, normal_balance: :credit}
             } =
               Account.changeset(%Account{}, %{
                 name: "some name",
                 type: :revenue,
                 instance_id: id,
                 currency: :EUR
               })
    end

    test "sets the normal balance if it was passed as an attribute", %{instance: %{id: id}} do
      assert %Ecto.Changeset{
               valid?: true,
               changes: %{type: :asset, normal_balance: :credit}
             } =
               Account.changeset(%Account{}, %{
                 name: "some name",
                 type: :asset,
                 normal_balance: :credit,
                 currency: :EUR,
                 instance_id: id
               })
    end

    test "fixture", %{instance: inst} do
      inst_id = inst.id

      assert %Account{
               name: "some name",
               description: "some description",
               currency: :EUR,
               type: :asset,
               normal_balance: :debit,
               context: %{},
               posted: %Balance{amount: 0, debit: 0, credit: 0},
               pending: %Balance{amount: 0, debit: 0, credit: 0},
               available: 0,
               instance_id: ^inst_id
             } = account_fixture(instance_id: inst.id, name: " some name ")
    end
  end

  describe "update balances debit account: trx = posted" do
    setup [:create_instance]

    test "debit entry", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :debit)

      entry = %Entry{
        account_id: account.id,
        value: %Money{amount: 100, currency: :EUR},
        type: :debit
      }

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 available: 100,
                 posted: %Ecto.Changeset{
                   valid?: true,
                   changes: %{amount: 100, debit: 100}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :posted})
    end

    test "credit entry", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :debit, allowed_negative: true)

      entry = %Entry{
        account_id: account.id,
        value: %Money{amount: 100, currency: :EUR},
        type: :credit
      }

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 posted: %Ecto.Changeset{
                   valid?: true,
                   changes: %{amount: -100, credit: 100}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :posted})
    end
  end

  describe "update balances debit account: trx = pending" do
    setup [:create_instance]

    test "debit entry", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :debit)

      entry = %Entry{
        account_id: account.id,
        value: %Money{amount: 100, currency: :EUR},
        type: :debit
      }

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 pending: %Ecto.Changeset{
                   valid?: true,
                   changes: %{amount: -100, debit: 100}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :pending})
    end

    test "credit entry", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :debit, allowed_negative: true)

      entry = %Entry{
        account_id: account.id,
        value: %Money{amount: 100, currency: :EUR},
        type: :credit
      }

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 pending: %Ecto.Changeset{
                   valid?: true,
                   changes: %{amount: 100, credit: 100}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :pending})
    end
  end

  describe "update balances debit account allowed_negative: false" do
    setup [:create_instance]

    test "credit entry trx: posted", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :debit, allowed_negative: false)

      entry = %Entry{
        account_id: account.id,
        value: %Money{amount: 100, currency: :EUR},
        type: :credit
      }

      assert %Ecto.Changeset{
               valid?: false,
               errors: [available: {"amount can't be negative", []}]
             } = Account.update_balances(account, %{entry: entry, trx: :posted})
    end

    test "credit entry trx: pending", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :debit, allowed_negative: false)

      entry = %Entry{
        account_id: account.id,
        value: %Money{amount: 100, currency: :EUR},
        type: :credit
      }

      assert %Ecto.Changeset{
               valid?: false,
               errors: [available: {"amount can't be negative", []}]
             } = Account.update_balances(account, %{entry: entry, trx: :pending})
    end
  end

  describe "update balances credit account: trx = posted" do
    setup [:create_instance]

    test "credit entry", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :credit)

      entry = %Entry{
        account_id: account.id,
        value: %Money{amount: 100, currency: :EUR},
        type: :credit
      }

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 available: 100,
                 posted: %Ecto.Changeset{
                   valid?: true,
                   changes: %{amount: 100, credit: 100}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :posted})
    end

    test "debit entry", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :credit, allowed_negative: true)

      entry = %Entry{
        account_id: account.id,
        value: %Money{amount: 100, currency: :EUR},
        type: :debit
      }

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 posted: %Ecto.Changeset{
                   valid?: true,
                   changes: %{amount: -100, debit: 100}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :posted})
    end
  end

  describe "update balances credit account: trx = pending" do
    setup [:create_instance]

    test "debit entry", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :credit, allowed_negative: true)

      entry = %Entry{
        account_id: account.id,
        value: %Money{amount: 100, currency: :EUR},
        type: :debit
      }

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 pending: %Ecto.Changeset{
                   valid?: true,
                   changes: %{amount: 100, debit: 100}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :pending})
    end

    test "credit entry", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :credit)

      entry = %Entry{
        account_id: account.id,
        value: %Money{amount: 100, currency: :EUR},
        type: :credit
      }

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{
                 pending: %Ecto.Changeset{
                   valid?: true,
                   changes: %{amount: -100, credit: 100}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :pending})
    end
  end

  describe "update balances credit account allowed_negative: false" do
    setup [:create_instance]

    test "credit entry trx: posted", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :credit, allowed_negative: false)

      entry = %Entry{
        account_id: account.id,
        value: %Money{amount: 100, currency: :EUR},
        type: :debit
      }

      assert %Ecto.Changeset{
               valid?: false,
               errors: [available: {"amount can't be negative", []}]
             } = Account.update_balances(account, %{entry: entry, trx: :posted})
    end

    test "credit entry trx: pending", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :credit, allowed_negative: false)

      entry = %Entry{
        account_id: account.id,
        value: %Money{amount: 100, currency: :EUR},
        type: :debit
      }

      assert %Ecto.Changeset{
               valid?: false,
               errors: [available: {"amount can't be negative", []}]
             } = Account.update_balances(account, %{entry: entry, trx: :pending})
    end
  end

  describe "validate_entry_changeset/2" do
    setup [:create_instance]

    test "returns error changeset for different currency", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, currency: :EUR)

      entry = %Entry{
        account_id: account.id,
        value: %Money{amount: 100, currency: :USD},
        type: :debit
      }

      assert %Ecto.Changeset{
               valid?: false,
               errors: [
                 currency: {"entry currency (USD) must be equal to account currency (EUR)", []}
               ]
             } = Account.update_balances(account, %{entry: entry, trx: :posted})
    end

    test "returns error changeset for different account", %{instance: %{id: id}} do
      fake_id = Ecto.UUID.generate()
      account = account_fixture(instance_id: id, currency: :EUR)

      entry = %Entry{
        account_id: fake_id,
        value: %Money{amount: 100, currency: :USD},
        type: :debit
      }

      error_string = "entry account_id (#{fake_id}) must be equal to account id (#{account.id})"

      assert %Ecto.Changeset{
               valid?: false,
               errors: [id: {^error_string, []}]
             } = Account.update_balances(account, %{entry: entry, trx: :posted})
    end

    test "returns error changeset for invalid entry changeset", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, currency: :EUR)
      entry = %Entry{value: %Money{amount: 100, currency: :USD}, type: :debit}

      assert %Ecto.Changeset{
               valid?: false,
               errors: [balance: {"can't apply an invalid entry changeset", []}]
             } = Account.update_balances(account, %{entry: entry, trx: :posted})
    end
  end

  describe "Optimistic concurrency control" do
    setup [:create_instance]

    test "throws stale update error when updates run concurrently", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :debit, allowed_negative: false)

      entry1 = %Entry{
        account_id: account.id,
        value: %Money{amount: 100, currency: :EUR},
        type: :debit
      }

      entry2 = %Entry{
        account_id: account.id,
        value: %Money{amount: 150, currency: :EUR},
        type: :debit
      }

      changeset1 = Account.update_balances(account, %{entry: entry1, trx: :posted})
      changeset2 = Account.update_balances(account, %{entry: entry2, trx: :posted})
      changeset1 |> Repo.update()

      assert_raise(Ecto.StaleEntryError, fn -> changeset2 |> Repo.update() end)
    end

    test "throws Ecto.Multi.failure() with stale_error_field: in a Multi scenario", %{
      instance: %{id: id}
    } do
      account = account_fixture(instance_id: id, normal_balance: :debit, allowed_negative: false)

      entry1 = %Entry{
        account_id: account.id,
        value: %Money{amount: 100, currency: :EUR},
        type: :debit
      }

      entry2 = %Entry{
        account_id: account.id,
        value: %Money{amount: 150, currency: :EUR},
        type: :debit
      }

      changeset1 = Account.update_balances(account, %{entry: entry1, trx: :posted})
      changeset2 = Account.update_balances(account, %{entry: entry2, trx: :posted})

      multi = Ecto.Multi.new()

      try do
        multi
        |> Ecto.Multi.update(:update1, changeset1)
        |> Ecto.Multi.update(:update2, changeset2)
        |> Repo.transaction()
      rescue
        e in Ecto.StaleEntryError ->
          {:error, e}
      end

      assert {:error, :update2, %Ecto.Changeset{errors: errors},
              %{update1: %DoubleEntryLedger.Account{available: 100}}} =
               Repo.transaction(
                 Ecto.Multi.new()
                 |> Ecto.Multi.update(:update1, changeset1)
                 |> Ecto.Multi.update(:update2, changeset2, stale_error_field: :lock_version)
               )

      assert {"is stale", [stale: true]} = errors[:lock_version]
    end
  end
end
