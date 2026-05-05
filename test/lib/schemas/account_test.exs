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
                 address: {"can't be blank", [validation: :required]},
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
                 address: "account:main1",
                 type: :debit,
                 currency: :EUR,
                 normal_balance: :asset,
                 instance_id: id
               })
    end

    test "test returns error for invalid address", %{instance: %{id: id}} do
      assert %Ecto.Changeset{
               valid?: false,
               errors: [
                 address: {"is not a valid address", [validation: :format]}
               ]
             } =
               Account.changeset(%Account{}, %{
                 name: "some name",
                 address: "main ",
                 type: :asset,
                 currency: :EUR,
                 instance_id: id
               })
    end

    test "returns error for invalid currency", %{instance: %{id: id}} do
      assert %Ecto.Changeset{
               valid?: false,
               errors: [
                 currency: {"is invalid", _}
               ]
             } =
               Account.changeset(%Account{}, %{
                 name: "some name",
                 address: "account:main1",
                 type: :asset,
                 currency: "EURO",
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
                 %{
                   name: "some name",
                   address: "account:main1",
                   type: :asset,
                   instance_id: id,
                   currency: :EUR
                 }
               )

      assert %Ecto.Changeset{
               valid?: true,
               changes: %{type: :liability, normal_balance: :credit}
             } =
               Account.changeset(%Account{}, %{
                 name: "some name",
                 address: "account:main1",
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
                 address: "account:main1",
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
                 address: "account:main1",
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
                 address: "account:main1",
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
                 address: "account:main1",
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
               address: "account:main1",
               description: "some description",
               currency: :EUR,
               type: :asset,
               normal_balance: :debit,
               context: %{},
               posted: %Balance{amount: 0, debit: 0, credit: 0},
               pending: %Balance{amount: 0, debit: 0, credit: 0},
               available: 0,
               instance_id: ^inst_id
             } =
               account_fixture(
                 instance_id: inst.id,
                 name: " some name ",
                 address: "account:main1"
               )
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
      account =
        account_fixture(instance_id: id, normal_balance: :debit, negative_limit: 2_147_483_647)

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
                   changes: %{amount: 100, debit: 100}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :pending})
    end

    test "credit entry", %{instance: %{id: id}} do
      account =
        account_fixture(instance_id: id, normal_balance: :debit, negative_limit: 2_147_483_647)

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

  describe "update balances debit account negative_limit: 0" do
    setup [:create_instance]

    test "credit entry trx: posted", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :debit, negative_limit: 0)

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
      account = account_fixture(instance_id: id, normal_balance: :debit, negative_limit: 0)

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
      account =
        account_fixture(instance_id: id, normal_balance: :credit, negative_limit: 2_147_483_647)

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
      account =
        account_fixture(instance_id: id, normal_balance: :credit, negative_limit: 2_147_483_647)

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
                   changes: %{amount: 100, credit: 100}
                 }
               }
             } = Account.update_balances(account, %{entry: entry, trx: :pending})
    end
  end

  describe "update balances credit account negative_limit: 0" do
    setup [:create_instance]

    test "credit entry trx: posted", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :credit, negative_limit: 0)

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
      account = account_fixture(instance_id: id, normal_balance: :credit, negative_limit: 0)

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
      account = account_fixture(instance_id: id, normal_balance: :debit, negative_limit: 0)

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
      account = account_fixture(instance_id: id, normal_balance: :debit, negative_limit: 0)

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

  describe "update_available/1 with negative_limit" do
    setup [:create_instance]

    test "negative_limit 0 rejects negative available", %{instance: inst} do
      account = account_fixture(instance_id: inst.id, negative_limit: 0, normal_balance: :debit)

      entry = %Entry{
        account_id: account.id,
        value: %Money{amount: 100, currency: :EUR},
        type: :credit
      }

      changeset = Account.update_balances(account, %{entry: entry, trx: :posted})

      assert %Ecto.Changeset{
               valid?: false,
               errors: [available: {"amount can't be negative", []}]
             } = changeset
    end

    test "negative_limit allows available down to negative limit", %{instance: inst} do
      account =
        account_fixture(instance_id: inst.id, negative_limit: 200, normal_balance: :debit)

      entry = %Entry{
        account_id: account.id,
        value: %Money{amount: 100, currency: :EUR},
        type: :credit
      }

      changeset = Account.update_balances(account, %{entry: entry, trx: :posted})

      assert %Ecto.Changeset{valid?: true} = changeset
      assert Ecto.Changeset.get_change(changeset, :available) == -100
    end

    test "negative_limit rejects when available exceeds limit", %{instance: inst} do
      account =
        account_fixture(instance_id: inst.id, negative_limit: 50, normal_balance: :debit)

      entry = %Entry{
        account_id: account.id,
        value: %Money{amount: 100, currency: :EUR},
        type: :credit
      }

      changeset = Account.update_balances(account, %{entry: entry, trx: :posted})

      assert %Ecto.Changeset{
               valid?: false,
               errors: [
                 available: {"amount can't be below negative limit of -50", []}
               ]
             } = changeset
    end

    test "available reflects true balance, not clamped to 0", %{instance: inst} do
      account =
        account_fixture(instance_id: inst.id, negative_limit: 500, normal_balance: :debit)

      entry = %Entry{
        account_id: account.id,
        value: %Money{amount: 100, currency: :EUR},
        type: :credit
      }

      changeset = Account.update_balances(account, %{entry: entry, trx: :posted})

      assert %Ecto.Changeset{valid?: true} = changeset
      assert Ecto.Changeset.get_change(changeset, :available) == -100
    end
  end

  # The pure path mirrors update_balances/2's arithmetic but returns a
  # plain map. These equivalence tests assert that for a given input,
  # `compute_balance_changes/3` produces the same persisted state as
  # `update_balances/2 |> apply_changes/1` would.
  describe "compute_balance_changes/3 (pure) vs update_balances/2 (legacy)" do
    setup [:create_instance]

    test "debit account, debit entry, posted", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :debit)
      entry_struct = %Entry{account_id: account.id, value: %Money{amount: 100, currency: :EUR}, type: :debit}
      entry_map = entry_to_map(entry_struct)

      assert_equivalent(account, entry_struct, entry_map, :posted)
    end

    test "debit account, credit entry, posted (within negative_limit)", %{instance: %{id: id}} do
      account =
        account_fixture(instance_id: id, normal_balance: :debit, negative_limit: 2_147_483_647)

      entry_struct = %Entry{account_id: account.id, value: %Money{amount: 100, currency: :EUR}, type: :credit}
      entry_map = entry_to_map(entry_struct)

      assert_equivalent(account, entry_struct, entry_map, :posted)
    end

    test "debit account, debit entry, pending", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :debit)
      entry_struct = %Entry{account_id: account.id, value: %Money{amount: 100, currency: :EUR}, type: :debit}
      entry_map = entry_to_map(entry_struct)

      assert_equivalent(account, entry_struct, entry_map, :pending)
    end

    test "credit account, credit entry, posted", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :credit)
      entry_struct = %Entry{account_id: account.id, value: %Money{amount: 100, currency: :EUR}, type: :credit}
      entry_map = entry_to_map(entry_struct)

      assert_equivalent(account, entry_struct, entry_map, :posted)
    end

    test "negative_limit = 0 rejects credit posting on debit account", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :debit, negative_limit: 0)
      entry_map = %{account_id: account.id, value: %{amount: 100, currency: :EUR}, type: :credit}

      assert {:error, :available, "amount can't be negative"} =
               Account.compute_balance_changes(account, entry_map, :posted)
    end

    test "negative_limit > 0 rejects below-limit credit posting", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :debit, negative_limit: 50)
      entry_map = %{account_id: account.id, value: %{amount: 100, currency: :EUR}, type: :credit}

      assert {:error, :available, _} =
               Account.compute_balance_changes(account, entry_map, :posted)
    end

    test "currency mismatch returns :currency error", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :debit, currency: :EUR)
      entry_map = %{account_id: account.id, value: %{amount: 100, currency: :USD}, type: :debit}

      assert {:error, :currency, _} =
               Account.compute_balance_changes(account, entry_map, :posted)
    end

    test "account_id mismatch returns :id error", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :debit)
      entry_map = %{account_id: Ecto.UUID.generate(), value: %{amount: 100, currency: :EUR}, type: :debit}

      assert {:error, :id, _} =
               Account.compute_balance_changes(account, entry_map, :posted)
    end

    test "unsupported transition returns :entry error", %{instance: %{id: id}} do
      account = account_fixture(instance_id: id, normal_balance: :debit)
      entry_map = %{account_id: account.id, value: %{amount: 100, currency: :EUR}, type: :debit}

      assert {:error, :entry, "invalid transition: pending_to_posted"} =
               Account.compute_balance_changes(account, entry_map, :pending_to_posted)
    end

    defp entry_to_map(%Entry{account_id: aid, type: t, value: %Money{amount: a, currency: c}}) do
      %{account_id: aid, type: t, value: %{amount: a, currency: c}}
    end

    defp assert_equivalent(account, entry_struct, entry_map, trx) do
      legacy_cs = Account.update_balances(account, %{entry: entry_struct, trx: trx})
      assert legacy_cs.valid?, "legacy changeset must be valid: #{inspect(legacy_cs.errors)}"
      legacy_account = Ecto.Changeset.apply_changes(legacy_cs)

      assert {:ok, %{posted: po, pending: pe, available: avail, lock_version: lv}} =
               Account.compute_balance_changes(account, entry_map, trx)

      assert po == legacy_account.posted, "posted balance mismatch"
      assert pe == legacy_account.pending, "pending balance mismatch"
      assert avail == legacy_account.available, "available mismatch"
      # apply_changes/1 doesn't run optimistic_lock's increment — Repo does
      # that on the actual UPDATE. Compare against the post-Repo value.
      assert lv == legacy_account.lock_version + 1, "lock_version mismatch"
    end
  end
end
