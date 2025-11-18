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

  def metadata(%{command_queue_item: command_queue_item, command_map: command_map} = event) do
    %{
      event_id: event.id,
      instance_address: Map.get(command_map, :instance_address),
      event_status: command_queue_item.status,
      event_action: Map.get(command_map, :action),
      event_source: Map.get(command_map, :source),
      event_trace_id:
        [
          Map.get(command_map, :source),
          Map.get(command_map, :source_idempk),
          Map.get(command_map, :update_idempk),
          Map.get(command_map, :update_source)
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

defimpl DoubleEntryLedger.Utils.Traceable, for: DoubleEntryLedger.Command.AccountCommandMap do
  import DoubleEntryLedger.Utils.Changeset
  alias DoubleEntryLedger.Command.AccountCommandMap

  @spec metadata(AccountCommandMap.t()) :: map()
  def metadata(%AccountCommandMap{} = command_map) do
    %{
      is_command_map: true,
      instance_address: Map.get(command_map, :instance_address),
      event_action: Map.get(command_map, :action),
      event_source: Map.get(command_map, :source),
      event_trace_id:
        [
          Map.get(command_map, :source),
          Map.get(command_map, :source_idempk),
          Map.get(command_map, :update_idempk),
          Map.get(command_map, :update_source)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("-")
    }
  end

  @spec metadata(AccountCommandMap.t(), any()) :: map()
  def metadata(command_map, error) do
    Map.put(metadata(command_map), :error, inspect(error))
  end

  @spec changeset_metadata(AccountCommandMap.t(), any()) :: map()
  def changeset_metadata(command_map, %Ecto.Changeset{} = changeset) do
    Map.put(
      metadata(command_map),
      :changeset_errors,
      all_errors_with_opts(changeset)
    )
  end
end

defimpl DoubleEntryLedger.Utils.Traceable, for: DoubleEntryLedger.Command.TransactionCommandMap do
  import DoubleEntryLedger.Utils.Changeset
  alias DoubleEntryLedger.Command.TransactionCommandMap

  @spec metadata(TransactionCommandMap.t()) :: map()
  def metadata(%TransactionCommandMap{} = command_map) do
    %{
      is_command_map: true,
      instance_address: Map.get(command_map, :instance_address),
      event_action: Map.get(command_map, :action),
      event_source: Map.get(command_map, :source),
      event_trace_id:
        [
          Map.get(command_map, :source),
          Map.get(command_map, :source_idempk),
          Map.get(command_map, :update_idempk),
          Map.get(command_map, :update_source)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("-")
    }
  end

  @spec metadata(TransactionCommandMap.t(), any()) :: map()
  def metadata(command_map, error) do
    Map.put(metadata(command_map), :error, inspect(error))
  end

  @spec changeset_metadata(TransactionCommandMap.t(), any()) :: map()
  def changeset_metadata(command_map, %Ecto.Changeset{} = changeset) do
    Map.put(
      metadata(command_map),
      :changeset_errors,
      all_errors_with_opts(changeset)
    )
  end
end

defimpl DoubleEntryLedger.Utils.Traceable, for: Map do
  import DoubleEntryLedger.Utils.Changeset

  @spec metadata(map()) :: map()
  def metadata(%{} = command_map) do
    %{
      is_map: true,
      instance_address:
        Map.get(command_map, :instance_address) || Map.get(command_map, "instance_address"),
      event_action: Map.get(command_map, :action) || Map.get(command_map, "action"),
      event_source: Map.get(command_map, :source) || Map.get(command_map, "source"),
      event_trace_id:
        [
          Map.get(command_map, :source) || Map.get(command_map, "source"),
          Map.get(command_map, :source_idempk) || Map.get(command_map, "source_idempk"),
          Map.get(command_map, :update_idempk) || Map.get(command_map, "update_idempk"),
          Map.get(command_map, :update_source) || Map.get(command_map, "update_idempk")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("-")
    }
  end

  @spec metadata(map(), any()) :: map()
  def metadata(command_map, error) do
    Map.put(metadata(command_map), :error, inspect(error))
  end

  @spec changeset_metadata(map(), any()) :: map()
  def changeset_metadata(command_map, %Ecto.Changeset{} = changeset) do
    Map.put(
      metadata(command_map),
      :changeset_errors,
      all_errors_with_opts(changeset)
    )
  end
end
