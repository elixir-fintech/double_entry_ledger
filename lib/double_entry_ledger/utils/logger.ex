defmodule DoubleEntryLedger.Logger do
  @moduledoc """
  Bespoke logger
  """
  defmacro __using__(_opts) do
    quote do
      alias DoubleEntryLedger.Command
      alias DoubleEntryLedger.Command.{AccountCommandMap, TransactionEventMap}
      require Logger

      import DoubleEntryLedger.Utils.Traceable
      import DoubleEntryLedger.Utils.Changeset

      @type logable() :: Command.t() | AccountCommandMap.t() | TransactionEventMap.t() | map()

      @module_name __MODULE__ |> Module.split() |> List.last()

      @spec info(String.t(), logable(), any()) :: {:ok, String.t()}
      def info(message, logable, schema) do
        message = "#{@module_name}: #{message}"
        {Logger.info(message, metadata(logable, schema)), message}
      end

      @spec warn(String.t(), logable()) :: {:ok, String.t()}
      def warn(message, logable) do
        message = "#{@module_name}: #{message}"
        {Logger.warning(message, metadata(logable)), message}
      end

      @spec warn(String.t(), logable(), any()) :: {:ok, String.t()}
      def warn(message, logable, %Ecto.Changeset{} = changeset) do
        message = "#{@module_name}: #{message} #{all_errors(changeset)}"
        {Logger.warning(message, changeset_metadata(logable, changeset)), message}
      end

      def warn(message, logable, schema) do
        message = "#{@module_name}: #{message}"
        {Logger.warning(message, metadata(logable, schema)), message}
      end

      @spec error(String.t(), logable(), any()) :: {:ok, String.t()}
      def error(message, logable, %Ecto.Changeset{} = changeset) do
        message = "#{@module_name}: #{message} #{all_errors(changeset)}"
        {Logger.error(message, changeset_metadata(logable, changeset)), message}
      end

      def error(message, logable, schema) do
        message = "#{@module_name}: #{message}"
        {Logger.error(message, metadata(logable, schema)), message}
      end
    end
  end
end
