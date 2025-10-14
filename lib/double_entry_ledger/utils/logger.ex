defmodule DoubleEntryLedger.Logger do
  @moduledoc """
  Bespoke logger
  """
  defmacro __using__(_opts) do
    quote do
      alias DoubleEntryLedger.Event
      alias DoubleEntryLedger.Event.{AccountEventMap, TransactionEventMap}
      require Logger

      import DoubleEntryLedger.Utils.Traceable
      import DoubleEntryLedger.Utils.Changeset

      @type logable() :: Event.t() | AccountEventMap.t() | TransactionEventMap.t()

      @module_name __MODULE__ |> Module.split() |> List.last()

      @spec info(String.t(), logable(), any()) :: {:ok, String.t()}
      def info(message, event, schema) do
        message = "#{@module_name}: #{message}"
        {Logger.info(message, metadata(event, schema)), message}
      end

      @spec warn(String.t(), logable()) :: {:ok, String.t()}
      def warn(message, event) do
        message = "#{@module_name}: #{message}"
        {Logger.warning(message, metadata(event)), message}
      end

      @spec warn(String.t(), logable(), any()) :: {:ok, String.t()}
      def warn(message, event, %Ecto.Changeset{} = changeset) do
        message = "#{@module_name}: #{message} #{all_errors(changeset)}"
        {Logger.warning(message, changeset_metadata(event, changeset)), message}
      end

      def warn(message, event, schema) do
        message = "#{@module_name}: #{message}"
        {Logger.warning(message, metadata(event, schema)), message}
      end

      @spec error(String.t(), logable(), any()) :: {:ok, String.t()}
      def error(message, event, %Ecto.Changeset{} = changeset) do
        message = "#{@module_name}: #{message} #{all_errors(changeset)}"
        {Logger.error(message, changeset_metadata(event, changeset)), message}
      end

      def error(message, event, schema) do
        message = "#{@module_name}: #{message}"
        {Logger.error(message, metadata(event, schema)), message}
      end
    end
  end
end
