defmodule DoubleEntryLedger.MixProject do
  use Mix.Project

  def project do
    [
      app: :double_entry_ledger,
      version: "0.2.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      dialyzer: [
        plt_add_deps: [:ecto, :postgrex, :money],
        plt_add_apps: [:mix]
        # flags: [:overspecs]
      ],
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {DoubleEntryLedger.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto_sql, "~> 3.0"},
      {:postgrex, ">= 0.0.0"},
      {:money, "~> 1.12"},
      {:logger_json, "~> 7.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.1", only: [:dev], runtime: false},
      {:mox, "~> 1.0", only: [:test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:perf), do: ["lib", "test/performance"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      test: ["ecto.create --quiet", "ecto.migrate", "test"]
    ]
  end

  defp before_closing_head_tag(_) do
    """
    <style>
      .sidebar-header, .sidebar {
        width: 400px !important;
      }
    </style>
    """
  end

  defp docs() do
    [
      main: "readme",
      extras: [
        "README.md",
        "pages/DoubleEntryLedger.md",
        "pages/AsynchronousEventProcessing.md",
        "pages/HandlingPendingTransactions.md",
        "LICENSE"
        ],
      groups_for_modules: [
        Instance: [
          DoubleEntryLedger.InstanceStore,
          DoubleEntryLedger.Instance
        ],
        Account: [
          DoubleEntryLedger.AccountStore,
          DoubleEntryLedger.Account,
          DoubleEntryLedger.Balance,
          DoubleEntryLedger.BalanceHistoryEntry
        ],
        Transaction: [
          DoubleEntryLedger.TransactionStore,
          DoubleEntryLedger.Transaction,
          DoubleEntryLedger.Entry
        ],
        Event: [
          DoubleEntryLedger.EventStore,
          DoubleEntryLedger.EventStoreHelper,
          DoubleEntryLedger.Event,
          DoubleEntryLedger.Event.EventMap,
          DoubleEntryLedger.Event.EntryData,
          DoubleEntryLedger.Event.TransactionData,
          DoubleEntryLedger.Event.ErrorMap
        ],
        EventWorker: [
          DoubleEntryLedger.EventWorker,
          DoubleEntryLedger.EventWorker.ProcessEvent,
          DoubleEntryLedger.EventWorker.ProcessEventMap,
          DoubleEntryLedger.EventWorker.CreateEvent,
          DoubleEntryLedger.EventWorker.UpdateEvent,
          DoubleEntryLedger.EventWorker.EventTransformer,
          DoubleEntryLedger.EventWorker.AddUpdateEventError,
          DoubleEntryLedger.EventWorker.ErrorHandler
        ],
        "EventQueue": [
          DoubleEntryLedger.EventQueue.Supervisor,
          DoubleEntryLedger.EventQueue.Scheduling,
          DoubleEntryLedger.EventQueue.InstanceProcessor,
          DoubleEntryLedger.EventQueue.InstanceMonitor,
        ],
        "Protocols, Types, Constants and Currency": [
          DoubleEntryLedger.EntryHelper,
          DoubleEntryLedger.Types,
          DoubleEntryLedger.Currency
        ],
        "Optimistic Concurrency Control": [
          DoubleEntryLedger.Occ.Processor,
          DoubleEntryLedger.Occ.Helper,
          DoubleEntryLedger.Occ.Occable,
        ],
        Repo: [
          DoubleEntryLedger.Repo,
          DoubleEntryLedger.RepoBehaviour,
          DoubleEntryLedger.BaseSchema
        ]
      ],
      before_closing_head_tag: &before_closing_head_tag/1
    ]
  end
end
