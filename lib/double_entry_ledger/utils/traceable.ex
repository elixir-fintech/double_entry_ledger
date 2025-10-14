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

  def metadata(%{event_queue_item: event_queue_item} = event) do
    %{
      event_id: event.id,
      event_status: event_queue_item.status,
      event_action: event.action,
      event_source: event.source,
      event_trace_id:
        [event.source, event.source_idempk, event.update_idempk, event.update_source]
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
