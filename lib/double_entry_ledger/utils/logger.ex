defmodule DoubleEntryLedger.Logger do
  @moduledoc """
  Bespoke logger
  """
  defmacro __using__(_opts) do
    quote do
      alias DoubleEntryLedger.Event
      require Logger

      @module_name __MODULE__ |> Module.split() |> List.last()

      @spec info(String.t(), Event.t(), any()) :: {:ok, String.t()}
      def info(message, event, schema) do
        message = "#{@module_name}: #{message}"
        {Logger.info(message, Event.log_trace(event, schema)), message}
      end

      @spec warn(String.t(), Event.t()) :: {:ok, String.t()}
      def warn(message, event) do
        message = "#{@module_name}: #{message}"
        {Logger.warning(message, Event.log_trace(event)), message}
      end

      @spec warn(String.t(), Event.t(), any()) :: {:ok, String.t()}
      def warn(message, event, %Ecto.Changeset{} = changeset) do
        message = "#{@module_name}: #{message} #{changeset_errors(changeset)}"
        {Logger.warning(message, Event.log_trace(event, changeset.errors)), message}
      end

      def warn(message, event, schema) do
        message = "#{@module_name}: #{message}"
        {Logger.warning(message, Event.log_trace(event, schema)), message}
      end

      @spec error(String.t(), Event.t(), any()) :: {:ok, String.t()}
      def error(message, event, %Ecto.Changeset{} = changeset) do
        message = "#{@module_name}: #{message} #{changeset_errors(changeset)}"
        {Logger.error(message, Event.log_trace(event, changeset.errors)), message}
      end

      def error(message, event, schema) do
        message = "#{@module_name}: #{message}"
        {Logger.error(message, Event.log_trace(event, schema)), message}
      end

      @spec changeset_errors(Ecto.Changeset.t()) :: String.t()
      defp changeset_errors(changeset) do
        Ecto.Changeset.traverse_errors(changeset, fn {msg, _}  ->
          "#{msg}"
        end)
        |> inspect()
      end
    end
  end

end
