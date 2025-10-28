defmodule DoubleEntryLedger.Command.EventMap do
  @moduledoc """
    This is an Ecto.ParameterizedType
  """

  use Ecto.ParameterizedType

  import DoubleEntryLedger.Command.Helper, only: [action_to_mod: 1]

  alias DoubleEntryLedger.Command.{AccountEventMap, TransactionEventMap}

  @impl true
  @spec init(any()) :: %{}
  def init(_ops), do: %{}

  @impl true
  @spec type(any()) :: :map
  def type(_), do: :map

  @impl true
  @spec cast(map() | AccountEventMap.t() | TransactionEventMap.t() | nil, map()) ::
          {:ok, AccountEventMap.t() | TransactionEventMap.t()} | :error
  def cast(%AccountEventMap{} = struct, _params), do: {:ok, struct}
  def cast(%TransactionEventMap{} = struct, _params), do: {:ok, struct}

  def cast(%{} = map, _params) do
    with {:ok, mod} <- action_to_mod(map),
         {:ok, struct} <- mod.create(map) do
      {:ok, struct}
    else
      _ -> :error
    end
  end

  def cast(nil, _), do: {:ok, nil}
  def cast(_, _), do: :error

  @impl true
  @spec dump(AccountEventMap.t() | TransactionEventMap.t() | nil, any(), any()) ::
          {:ok, map()} | :error
  def dump(%AccountEventMap{} = struct, _, _), do: {:ok, AccountEventMap.to_map(struct)}
  def dump(%TransactionEventMap{} = struct, _, _), do: {:ok, TransactionEventMap.to_map(struct)}
  def dump(nil, _, _), do: nil
  def dump(_, _, _), do: :error

  @impl true
  def load(%{} = map, _loader, params) do
    cast(map, params)
  end

  def load(nil, _, _), do: nil
  def load(_, _, _), do: :error

  @impl true
  def equal?(a, b, _params), do: a == b

  @impl true
  def embed_as(_format, _params), do: :self
end
