defmodule DoubleEntryLedger.Event.Helper do
  @moduledoc """
    Helper functions
  """
  alias DoubleEntryLedger.Event.{AccountEventMap, TransactionEventMap}

  @transaction_actions [:create_transaction, :update_transaction]
  @account_actions [:create_account, :update_account]

  def action_to_mod(event_map) do
    case fetch_action(event_map) do
      a when a in @transaction_actions -> {:ok, TransactionEventMap}
      a when a in @account_actions -> {:ok, AccountEventMap}
      _ -> :error
    end
  end

  @doc """
  Fetches and normalizes the action value from a map.

  Accepts both atom and string keys ("action" and :action). When the action is a string,
  it is converted using `String.to_existing_atom/1`. Returns `nil` when no action is present.

  This function is useful for handling incoming data that may have string or atom keys,
  which is common when dealing with external APIs or JSON data.

  ## Parameters

  * `attrs` - Map containing potential action data

  ## Returns

  * `atom()` - The normalized action as an atom
  * `nil` - When no action is found

  ## Examples

      iex> alias DoubleEntryLedger.Event.Helper
      iex> # Ensure atoms exist for to_existing_atom/1
      iex> :create_transaction
      :create_transaction
      iex> :update_transaction
      :update_transaction
      iex> Helper.fetch_action(%{"action" => "create_transaction"})
      :create_transaction
      iex> Helper.fetch_action(%{action: :update_transaction})
      :update_transaction
      iex> Helper.fetch_action(%{})
      nil
      iex> Helper.fetch_action(%{"other_key" => "value"})
      nil
  """
  @spec fetch_action(map()) :: atom() | nil
  def fetch_action(attrs), do: normalize(Map.get(attrs, "action") || Map.get(attrs, :action))

  @spec normalize(atom() | String.t() | nil) :: atom() | nil
  defp normalize(action) when is_binary(action), do: String.to_existing_atom(action)
  defp normalize(action) when is_atom(action), do: action
  defp normalize(nil), do: nil
end
