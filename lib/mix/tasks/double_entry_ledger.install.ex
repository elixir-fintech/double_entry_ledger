defmodule Mix.Tasks.DoubleEntryLedger.Install do
  @shortdoc "Generates DoubleEntryLedger migration file"

  @moduledoc """
  Generates a migration file for the DoubleEntryLedger package.

      mix double_entry_ledger.install

  ## Options

    * `--from N` - Generate an upgrade migration from version N instead of
      a fresh install. Use this if you already have DoubleEntryLedger tables
      from copied migration files (e.g., v0.1.0 = version 1).

  ## Examples

      # Fresh install (all versions)
      mix double_entry_ledger.install

      # Upgrade from v0.1.0 (apply only version 2 changes)
      mix double_entry_ledger.install --from 1

  ## Oban

  This task does not generate an Oban migration. The package uses your
  application's existing Oban setup. Ensure Oban is installed and configured
  in your application, and add the `double_entry_ledger` queue to your Oban
  config. See the README for details.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [from: :integer])
    from_version = Keyword.get(opts, :from)

    migrations_path = migrations_path()
    File.mkdir_p!(migrations_path)

    timestamp = timestamp()

    if from_version do
      create_migration(
        migrations_path,
        "#{timestamp}_upgrade_double_entry_ledger.exs",
        upgrade_template(from_version)
      )
    else
      create_migration(
        migrations_path,
        "#{timestamp}_setup_double_entry_ledger.exs",
        core_template()
      )
    end

    Mix.shell().info("""

    DoubleEntryLedger migration generated. Next steps:

      1. Configure :double_entry_ledger in your config/config.exs
      2. Ensure Oban is set up and add the :double_entry_ledger queue
      3. Run: mix ecto.migrate
    """)
  end

  defp create_migration(migrations_path, filename, template) do
    path = Path.join(migrations_path, filename)

    if File.exists?(path) do
      Mix.shell().info("* already exists #{path}")
    else
      File.write!(path, template)
      Mix.shell().info("* creating #{path}")
    end
  end

  defp core_template do
    """
    defmodule Repo.Migrations.SetupDoubleEntryLedger do
      use Ecto.Migration

      def up, do: DoubleEntryLedger.Migration.up()
      def down, do: DoubleEntryLedger.Migration.down()
    end
    """
  end

  defp upgrade_template(from_version) do
    """
    defmodule Repo.Migrations.UpgradeDoubleEntryLedger do
      use Ecto.Migration

      def up, do: DoubleEntryLedger.Migration.up(from: #{from_version})
      def down, do: DoubleEntryLedger.Migration.down(version: #{from_version})
    end
    """
  end

  defp migrations_path do
    app = Mix.Project.config()[:app]

    case Application.get_env(app, :ecto_repos, []) do
      [repo | _] ->
        repo_underscore =
          repo
          |> Module.split()
          |> List.last()
          |> Macro.underscore()

        Path.join(["priv", repo_underscore, "migrations"])

      [] ->
        Path.join(["priv", "repo", "migrations"])
    end
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(i) when i < 10, do: "0#{i}"
  defp pad(i), do: "#{i}"
end
