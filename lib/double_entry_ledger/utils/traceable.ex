defprotocol DoubleEntryLedger.Utils.Traceable do
  @spec metadata(t()) :: map()
  def metadata(schema)

  @spec metadata(t(), Ecto.Schema.t()) :: map()
  def metadata(schema, schema_or_error)

  @spec changeset_metadata(t(), Ecto.Changeset.t()) :: map()
  def changeset_metadata(schema, changeset)
end

defimpl DoubleEntryLedger.Utils.Traceable, for: DoubleEntryLedger.Event do
  alias DoubleEntryLedger.{Event, Account, Transaction}
  import DoubleEntryLedger.Utils.Changeset

  def metadata(%{event_queue_item: event_queue_item, event_map: event_map} = event) do
    %{
      event_id: event.id,
      event_status: event_queue_item.status,
      event_action: Map.get(event_map, :action),
      event_source: Map.get(event_map, :source),
      event_trace_id:
        [
          Map.get(event_map, :source),
          Map.get(event_map, :source_idempk),
          Map.get(event_map, :update_idempk),
          Map.get(event_map, :update_source)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("-")
    }
  end

  @spec metadata(Event.t(), Transaction.t() | Account.t() | any()) :: map()
  def metadata(event, %Transaction{} = transaction) do
    Map.put(
      metadata(event),
      :transaction_id,
      transaction.id
    )
  end

  def metadata(event, %Account{} = account) do
    Map.merge(
      metadata(event),
      %{
        account_id: account.id,
        account_address: account.address
      }
    )
  end

  def metadata(event, error) do
    Map.put(
      metadata(event),
      :error,
      inspect(error)
    )
  end

  def changeset_metadata(event, %Ecto.Changeset{} = changeset) do
    Map.put(
      metadata(event),
      :changeset_errors,
      all_errors(changeset)
    )
  end
end

defimpl DoubleEntryLedger.Utils.Traceable, for: DoubleEntryLedger.Event.AccountEventMap do
  import DoubleEntryLedger.Utils.Changeset
  alias DoubleEntryLedger.Event.AccountEventMap

  @spec metadata(AccountEventMap.t()) :: map()
  def metadata(%AccountEventMap{} = event_map) do
    %{
      is_event_map: true,
      event_action: Map.get(event_map, :action),
      event_source: Map.get(event_map, :source),
      event_trace_id:
        [
          Map.get(event_map, :source),
          Map.get(event_map, :source_idempk),
          Map.get(event_map, :update_idempk),
          Map.get(event_map, :update_source)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("-")
    }
  end

  @spec metadata(AccountEventMap.t(), any()) :: map()
  def metadata(event_map, error) do
    Map.put(metadata(event_map), :error, inspect(error))
  end

  @spec changeset_metadata(AccountEventMap.t(), any()) :: map()
  def changeset_metadata(event_map, %Ecto.Changeset{} = changeset) do
    Map.put(
      metadata(event_map),
      :changeset_errors,
      all_errors_with_opts(changeset)
    )
  end
end

defimpl DoubleEntryLedger.Utils.Traceable, for: DoubleEntryLedger.Event.TransactionEventMap do
  import DoubleEntryLedger.Utils.Changeset
  alias DoubleEntryLedger.Event.TransactionEventMap

  @spec metadata(TransactionEventMap.t()) :: map()
  def metadata(%TransactionEventMap{} = event_map) do
    %{
      is_event_map: true,
      event_action: Map.get(event_map, :action),
      event_source: Map.get(event_map, :source),
      event_trace_id:
        [
          Map.get(event_map, :source),
          Map.get(event_map, :source_idempk),
          Map.get(event_map, :update_idempk),
          Map.get(event_map, :update_source)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("-")
    }
  end

  @spec metadata(TransactionEventMap.t(), any()) :: map()
  def metadata(event_map, error) do
    Map.put(metadata(event_map), :error, inspect(error))
  end

  @spec changeset_metadata(TransactionEventMap.t(), any()) :: map()
  def changeset_metadata(event_map, %Ecto.Changeset{} = changeset) do
    Map.put(
      metadata(event_map),
      :changeset_errors,
      all_errors_with_opts(changeset)
    )
  end
end
