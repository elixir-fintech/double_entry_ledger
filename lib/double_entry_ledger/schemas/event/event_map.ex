defmodule DoubleEntryLedger.Event.EventMap do
  @moduledoc """
    This is an Ecto.ParameterizedType
  """

  use Ecto.ParameterizedType

  import DoubleEntryLedger.Event.Helper, only: [fetch_action: 1]

  alias DoubleEntryLedger.Event.{AccountEventMap, TransactionEventMap}

  @impl true
  @spec init(any()) :: %{action_to_mod: map()}
  def init(_ops) do
    %{
      action_to_mod:
        Map.new(TransactionEventMap.actions(), &{&1, TransactionEventMap})
        |> Map.merge(Map.new(AccountEventMap.actions(), &{&1, AccountEventMap}))
    }
  end

  @impl true
  @spec type(any()) :: :map
  def type(_), do: :map

  @impl true
  @spec cast(map() | AccountEventMap.t() | TransactionEventMap.t() | nil, map()) ::
          {:ok, AccountEventMap.t() | TransactionEventMap.t()} | :error
  def cast(%AccountEventMap{} = struct, _params), do: {:ok, struct}
  def cast(%TransactionEventMap{} = struct, _params), do: {:ok, struct}

  def cast(%{} = map, %{action_to_mod: index}) do
    with action <- fetch_action(map),
         {:ok, mod} <- Map.fetch(index, action),
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
    case cast(map, params) do
      {:ok, struct} -> {:ok, struct}
      :error -> :error
    end
  end

  def load(nil, _, _), do: nil
  def load(_, _, _), do: :error

  @impl true
  def equal?(a, b, _params), do: a == b

  @impl true
  def embed_as(_format, _params), do: :self
end
