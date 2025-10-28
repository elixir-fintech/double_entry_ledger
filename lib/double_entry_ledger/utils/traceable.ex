defprotocol DoubleEntryLedger.Utils.Traceable do
  @spec metadata(t()) :: map()
  def metadata(schema)

  @spec metadata(t(), Ecto.Schema.t()) :: map()
  def metadata(schema, schema_or_error)

  @spec changeset_metadata(t(), Ecto.Changeset.t()) :: map()
  def changeset_metadata(schema, changeset)
end

defimpl DoubleEntryLedger.Utils.Traceable, for: DoubleEntryLedger.Command do
  alias DoubleEntryLedger.{Command, Account, Transaction}
  import DoubleEntryLedger.Utils.Changeset

  def metadata(%{event_queue_item: event_queue_item, event_map: event_map} = event) do
    %{
      event_id: event.id,
      instance_address: Map.get(event_map, :instance_address),
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

  @spec metadata(Command.t(), Transaction.t() | Account.t() | any()) :: map()
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

defimpl DoubleEntryLedger.Utils.Traceable, for: DoubleEntryLedger.Command.AccountEventMap do
  import DoubleEntryLedger.Utils.Changeset
  alias DoubleEntryLedger.Command.AccountEventMap

  @spec metadata(AccountEventMap.t()) :: map()
  def metadata(%AccountEventMap{} = event_map) do
    %{
      is_event_map: true,
      instance_address: Map.get(event_map, :instance_address),
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

defimpl DoubleEntryLedger.Utils.Traceable, for: DoubleEntryLedger.Command.TransactionEventMap do
  import DoubleEntryLedger.Utils.Changeset
  alias DoubleEntryLedger.Command.TransactionEventMap

  @spec metadata(TransactionEventMap.t()) :: map()
  def metadata(%TransactionEventMap{} = event_map) do
    %{
      is_event_map: true,
      instance_address: Map.get(event_map, :instance_address),
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

defimpl DoubleEntryLedger.Utils.Traceable, for: Map do
  import DoubleEntryLedger.Utils.Changeset

  @spec metadata(map()) :: map()
  def metadata(%{} = event_map) do
    %{
      is_map: true,
      instance_address:
        Map.get(event_map, :instance_address) || Map.get(event_map, "instance_address"),
      event_action: Map.get(event_map, :action) || Map.get(event_map, "action"),
      event_source: Map.get(event_map, :source) || Map.get(event_map, "source"),
      event_trace_id:
        [
          Map.get(event_map, :source) || Map.get(event_map, "source"),
          Map.get(event_map, :source_idempk) || Map.get(event_map, "source_idempk"),
          Map.get(event_map, :update_idempk) || Map.get(event_map, "update_idempk"),
          Map.get(event_map, :update_source) || Map.get(event_map, "update_idempk")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("-")
    }
  end

  @spec metadata(map(), any()) :: map()
  def metadata(event_map, error) do
    Map.put(metadata(event_map), :error, inspect(error))
  end

  @spec changeset_metadata(map(), any()) :: map()
  def changeset_metadata(event_map, %Ecto.Changeset{} = changeset) do
    Map.put(
      metadata(event_map),
      :changeset_errors,
      all_errors_with_opts(changeset)
    )
  end
end
