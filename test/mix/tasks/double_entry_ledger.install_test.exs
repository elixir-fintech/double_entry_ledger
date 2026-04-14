defmodule Mix.Tasks.DoubleEntryLedger.InstallTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  @tmp_dir Path.join(System.tmp_dir!(), "del_install_test")

  setup do
    migrations_path = Path.join(@tmp_dir, "priv/repo/migrations")
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(migrations_path)

    on_exit(fn -> File.rm_rf!(@tmp_dir) end)

    {:ok, migrations_path: migrations_path}
  end

  describe "run/1" do
    test "generates core migration file", %{migrations_path: migrations_path} do
      run_in_tmp(fn ->
        capture_io(fn -> Mix.Tasks.DoubleEntryLedger.Install.run([]) end)

        files = File.ls!(migrations_path)
        assert length(files) == 1

        [core_file] = files
        assert core_file =~ "setup_double_entry_ledger.exs"

        core_content = File.read!(Path.join(migrations_path, core_file))
        assert core_content =~ "DoubleEntryLedger.Migration.up()"
        assert core_content =~ "DoubleEntryLedger.Migration.down()"
      end)
    end

    test "generates upgrade migration with --from", %{migrations_path: migrations_path} do
      run_in_tmp(fn ->
        capture_io(fn -> Mix.Tasks.DoubleEntryLedger.Install.run(["--from", "1"]) end)

        files = File.ls!(migrations_path)
        assert length(files) == 1

        [upgrade_file] = files
        assert upgrade_file =~ "upgrade_double_entry_ledger.exs"

        content = File.read!(Path.join(migrations_path, upgrade_file))
        assert content =~ "DoubleEntryLedger.Migration.up(from: 1)"
        assert content =~ "DoubleEntryLedger.Migration.down(version: 1)"
      end)
    end
  end

  defp run_in_tmp(fun) do
    original_dir = File.cwd!()
    File.cd!(@tmp_dir)

    try do
      fun.()
    after
      File.cd!(original_dir)
    end
  end
end
