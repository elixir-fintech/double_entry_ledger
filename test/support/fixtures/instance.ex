defmodule DoubleEntryLedger.InstanceFixtures do
  @moduledoc """
  This module defines test helpers for creating
  instance entities.
  """

  alias DoubleEntryLedger.{Instance, Repo}

  @spec instance_fixture(any()) :: Instance.t()
  @spec instance_fixture() :: Instance.t()
  @doc """
  Generate a instance.
  """
  def instance_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{
        config: %{},
        description: "some description",
        metadata: %{},
        name: "some name"
      })

    {:ok, instance} =
      %Instance{}
      |> Instance.changeset(attrs)
      |> Repo.insert()

    instance
  end

  def create_instance(_ctx \\ %{}) do
    %{instance: instance_fixture()}
  end
end
