defmodule DoubleEntryLedger.InstanceStore do
  @moduledoc """
  This module contains functions to interact with the instance store.
  """
  alias DoubleEntryLedger.{Instance, Repo}

  @spec create(map()) :: {:ok, Instance.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Instance{}
    |> Instance.changeset(attrs)
    |> Repo.insert()
  end

  @spec get_by_id(Ecto.UUID.t()) :: Instance.t() | nil
  def get_by_id(id) do
    Repo.get(Instance, id)
  end

  @spec update(Ecto.UUID.t(), map()) :: {:ok, Instance.t()} | {:error, Ecto.Changeset.t()}
  def update(id, attrs) do
    get_by_id(id)
    |> Instance.changeset(attrs)
    |> Repo.update()
  end

  @spec delete(Ecto.UUID.t()) :: {:ok, Instance.t()} | {:error, Ecto.Changeset.t()}
  def delete(id) do
    get_by_id(id)
    |> Instance.delete_changeset()
    |> Repo.delete()
  end
end
