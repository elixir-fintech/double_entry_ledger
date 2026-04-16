defmodule DoubleEntryLedger.Telemetry do
  @moduledoc """
  Telemetry events emitted by DoubleEntryLedger.

  All events use the `[:double_entry_ledger, ...]` prefix. The library emits
  events but does not attach handlers — consumers attach their own handlers
  at application boot.

  ## Event Catalog

  ### Span Events (automatic start/stop/exception with duration)

  | Event prefix | Description |
  |---|---|
  | `[:double_entry_ledger, :command, :process]` | Command processing lifecycle |

  ### Point Events

  | Event | Description |
  |---|---|
  | `[:double_entry_ledger, :command, :enqueue]` | Command persisted to queue |
  | `[:double_entry_ledger, :command, :claim]` | Command claimed by processor |
  | `[:double_entry_ledger, :command, :retry]` | Command scheduled for retry |
  | `[:double_entry_ledger, :command, :dead_letter]` | Command permanently failed |
  | `[:double_entry_ledger, :command, :idempotency_hit]` | Duplicate command detected |
  | `[:double_entry_ledger, :occ, :retry]` | OCC retry attempt |
  | `[:double_entry_ledger, :transaction, :created]` | Transaction created |
  | `[:double_entry_ledger, :transaction, :posted]` | Transaction posted |
  | `[:double_entry_ledger, :transaction, :archived]` | Transaction archived |
  | `[:double_entry_ledger, :account, :created]` | Account created |
  | `[:double_entry_ledger, :account, :updated]` | Account updated |
  | `[:double_entry_ledger, :instance, :created]` | Instance created |
  | `[:double_entry_ledger, :instance_processor, :start]` | Instance processor started |
  | `[:double_entry_ledger, :instance_processor, :stop]` | Instance processor stopped |

  ## Phoenix LiveDashboard Integration

  If `telemetry_metrics` is available, call `dashboard_metrics/0` to get a list
  of recommended `Telemetry.Metrics` definitions:

      def metrics do
        MyApp.my_metrics() ++ DoubleEntryLedger.Telemetry.dashboard_metrics()
      end
  """

  @doc """
  Wraps command processing in a telemetry span.

  Emits `[:double_entry_ledger, :command, :process, :start]`,
  `[:double_entry_ledger, :command, :process, :stop]`, and
  `[:double_entry_ledger, :command, :process, :exception]` events.

  ## Parameters

    - `metadata` - Map with `:action`, `:instance_id`, `:source`, `:trace_context`
    - `fun` - Zero-arity function to execute within the span

  ## Returns

    The return value of `fun`.
  """
  @spec command_process_span(map(), (-> result)) :: result when result: any()
  def command_process_span(metadata, fun) do
    :telemetry.span(
      [:double_entry_ledger, :command, :process],
      metadata,
      fn ->
        result = fun.()
        {result, metadata}
      end
    )
  end

  @doc """
  Emits a command enqueue event.

  ## Metadata

    - `:action` - Command action atom
    - `:instance_id` - Ledger instance UUID
    - `:source` - Source system identifier
    - `:trace_context` - Consumer-supplied tracing context (map or nil)
  """
  @spec command_enqueue(map()) :: :ok
  def command_enqueue(metadata) do
    execute([:double_entry_ledger, :command, :enqueue], metadata)
  end

  @doc """
  Emits a command claim event.

  ## Metadata

    - `:command_id` - Command UUID
    - `:instance_id` - Ledger instance UUID
    - `:processor_id` - Processor identifier string
    - `:trace_context` - Consumer-supplied tracing context (map or nil)
  """
  @spec command_claim(map()) :: :ok
  def command_claim(metadata) do
    execute([:double_entry_ledger, :command, :claim], metadata)
  end

  @doc """
  Emits a command retry event.

  ## Metadata

    - `:command_id` - Command UUID
    - `:instance_id` - Ledger instance UUID
    - `:status` - Status being set (`:failed`, `:occ_timeout`)
    - `:retry_count` - Current retry count
    - `:trace_context` - Consumer-supplied tracing context (map or nil)
  """
  @spec command_retry(map()) :: :ok
  def command_retry(metadata) do
    execute([:double_entry_ledger, :command, :retry], metadata)
  end

  @doc """
  Emits a command dead letter event.

  ## Metadata

    - `:command_id` - Command UUID
    - `:instance_id` - Ledger instance UUID
    - `:error` - Reason for dead-lettering
    - `:trace_context` - Consumer-supplied tracing context (map or nil)
  """
  @spec command_dead_letter(map()) :: :ok
  def command_dead_letter(metadata) do
    execute([:double_entry_ledger, :command, :dead_letter], metadata)
  end

  @doc """
  Emits a command idempotency hit event.

  ## Metadata

    - `:action` - Command action atom
    - `:instance_id` - Ledger instance UUID
    - `:source` - Source system identifier
    - `:source_idempk` - Idempotency key that was duplicated
    - `:trace_context` - Consumer-supplied tracing context (map or nil)
  """
  @spec command_idempotency_hit(map()) :: :ok
  def command_idempotency_hit(metadata) do
    execute([:double_entry_ledger, :command, :idempotency_hit], metadata)
  end

  @doc """
  Emits an OCC retry event.

  ## Metadata

    - `:module` - Processor module handling the command
    - `:attempts_remaining` - Retry attempts left
    - `:command_id` - Command UUID (nil on synchronous path)
    - `:instance_id` - Ledger instance UUID
    - `:action` - Command action atom
    - `:source` - Source system identifier
    - `:source_idempk` - Source idempotency key
    - `:trace_context` - Consumer-supplied tracing context (map or nil)
  """
  @spec occ_retry(map()) :: :ok
  def occ_retry(metadata) do
    execute([:double_entry_ledger, :occ, :retry], metadata)
  end

  @doc """
  Emits a transaction created event.

  ## Metadata

    - `:transaction_id` - Transaction UUID
    - `:instance_id` - Ledger instance UUID
    - `:status` - Initial status (`:pending` or `:posted`)
    - `:trace_context` - Consumer-supplied tracing context (map or nil)
  """
  @spec transaction_created(map()) :: :ok
  def transaction_created(metadata) do
    execute([:double_entry_ledger, :transaction, :created], metadata)
  end

  @doc """
  Emits a transaction posted event.

  ## Metadata

    - `:transaction_id` - Transaction UUID
    - `:instance_id` - Ledger instance UUID
    - `:trace_context` - Consumer-supplied tracing context (map or nil)
  """
  @spec transaction_posted(map()) :: :ok
  def transaction_posted(metadata) do
    execute([:double_entry_ledger, :transaction, :posted], metadata)
  end

  @doc """
  Emits a transaction archived event.

  ## Metadata

    - `:transaction_id` - Transaction UUID
    - `:instance_id` - Ledger instance UUID
    - `:trace_context` - Consumer-supplied tracing context (map or nil)
  """
  @spec transaction_archived(map()) :: :ok
  def transaction_archived(metadata) do
    execute([:double_entry_ledger, :transaction, :archived], metadata)
  end

  @doc """
  Emits an account created event.

  ## Metadata

    - `:account_address` - Account address
    - `:instance_id` - Ledger instance UUID
    - `:type` - Account type (`:asset`, `:liability`, etc.)
    - `:currency` - Account currency atom
    - `:trace_context` - Consumer-supplied tracing context (map or nil)
  """
  @spec account_created(map()) :: :ok
  def account_created(metadata) do
    execute([:double_entry_ledger, :account, :created], metadata)
  end

  @doc """
  Emits an account updated event.

  ## Metadata

    - `:account_address` - Account address
    - `:instance_id` - Ledger instance UUID
    - `:trace_context` - Consumer-supplied tracing context (map or nil)
  """
  @spec account_updated(map()) :: :ok
  def account_updated(metadata) do
    execute([:double_entry_ledger, :account, :updated], metadata)
  end

  @doc """
  Emits an instance created event.

  ## Metadata

    - `:instance_id` - Instance UUID
  """
  @spec instance_created(map()) :: :ok
  def instance_created(metadata) do
    execute([:double_entry_ledger, :instance, :created], metadata)
  end

  @doc """
  Emits an instance processor start event.

  ## Metadata

    - `:instance_id` - Instance UUID being processed
  """
  @spec instance_processor_start(map()) :: :ok
  def instance_processor_start(metadata) do
    execute([:double_entry_ledger, :instance_processor, :start], metadata)
  end

  @doc """
  Emits an instance processor stop event.

  ## Metadata

    - `:instance_id` - Instance UUID that was being processed
  """
  @spec instance_processor_stop(map()) :: :ok
  def instance_processor_stop(metadata) do
    execute([:double_entry_ledger, :instance_processor, :stop], metadata)
  end

  @doc """
  Emits the appropriate transaction lifecycle event based on the transaction's state.

  Dispatches to `transaction_created/1`, `transaction_posted/1`, or
  `transaction_archived/1` based on the transaction's status and whether it
  has been modified since creation (via `inserted_at == updated_at`).

  ## Parameters

    - `transaction` - The `Transaction` struct
    - `trace_context` - Consumer-supplied tracing context (map or nil)
  """
  @spec emit_transaction(Ecto.Schema.t(), map() | nil) :: :ok
  def emit_transaction(transaction, trace_context) do
    meta = %{
      transaction_id: transaction.id,
      instance_id: transaction.instance_id,
      trace_context: trace_context
    }

    case transaction.status do
      :pending ->
        transaction_created(Map.put(meta, :status, :pending))

      :posted ->
        if transaction.inserted_at == transaction.updated_at do
          transaction_created(Map.put(meta, :status, :posted))
        else
          transaction_posted(meta)
        end

      :archived ->
        transaction_archived(meta)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  @doc """
  Emits the appropriate account lifecycle event based on whether the account
  was just created or updated.

  Dispatches to `account_created/1` or `account_updated/1` based on whether
  the account has been modified since creation (via `inserted_at == updated_at`).

  ## Parameters

    - `account` - The `Account` struct
    - `trace_context` - Consumer-supplied tracing context (map or nil)
  """
  @spec emit_account(Ecto.Schema.t(), map() | nil) :: :ok
  def emit_account(account, trace_context) do
    meta = %{
      account_address: account.address,
      instance_id: account.instance_id,
      trace_context: trace_context
    }

    if account.inserted_at == account.updated_at do
      account_created(Map.merge(meta, %{type: account.type, currency: account.currency}))
    else
      account_updated(meta)
    end
  rescue
    _ -> :ok
  end

  defp execute(event, metadata) do
    :telemetry.execute(event, %{system_time: System.system_time()}, metadata)
  rescue
    _ -> :ok
  end

  # Phoenix LiveDashboard integration — only defined when telemetry_metrics is available
  if Code.ensure_loaded?(Telemetry.Metrics) do
    @doc """
    Returns a list of recommended `Telemetry.Metrics` definitions for Phoenix LiveDashboard.

    Add these to your application's telemetry module:

        def metrics do
          MyApp.my_metrics() ++ DoubleEntryLedger.Telemetry.dashboard_metrics()
        end

    Then reference it in your LiveDashboard route:

        live_dashboard "/dashboard", metrics: MyAppWeb.Telemetry

    Requires the optional `telemetry_metrics` dependency.
    """
    @spec dashboard_metrics() :: [Telemetry.Metrics.t()]
    def dashboard_metrics do
      import Telemetry.Metrics

      [
        summary("double_entry_ledger.command.process.stop.duration",
          unit: {:native, :millisecond},
          tags: [:action, :source]
        ),
        counter("double_entry_ledger.command.enqueue.system_time",
          tags: [:action, :source]
        ),
        counter("double_entry_ledger.command.claim.system_time"),
        counter("double_entry_ledger.command.retry.system_time",
          tags: [:status]
        ),
        counter("double_entry_ledger.command.dead_letter.system_time"),
        counter("double_entry_ledger.command.idempotency_hit.system_time",
          tags: [:action, :source]
        ),
        counter("double_entry_ledger.occ.retry.system_time",
          tags: [:module]
        ),
        counter("double_entry_ledger.transaction.created.system_time",
          tags: [:status]
        ),
        counter("double_entry_ledger.transaction.posted.system_time"),
        counter("double_entry_ledger.transaction.archived.system_time"),
        counter("double_entry_ledger.account.created.system_time",
          tags: [:type, :currency]
        ),
        counter("double_entry_ledger.account.updated.system_time"),
        counter("double_entry_ledger.instance.created.system_time")
      ]
    end
  end
end
