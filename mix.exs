defmodule DoubleEntryLedger.MixProject do
  use Mix.Project

  def project do
    [
      app: :double_entry_ledger,
      version: "0.1.0",
      description: """
        DoubleEntryLedger is an event sourced, multi-tenant double entry accounting engine for Elixir and PostgreSQL.
      """,
      elixir: "~> 1.15",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/elixir-fintech/double_entry_ledger"}
      ],
      source_url: "https://github.com/elixir-fintech/double_entry_ledger",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      dialyzer: [
        plt_add_deps: [:ecto, :postgrex, :money],
        plt_add_apps: [:mix]
        # flags: [:overspecs]
      ],
      docs: docs(),
      consolidate_protocols: if(Mix.env() == :test, do: false, else: true)
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      # use below for profiling
      # extra_applications: [:logger, :tools, :runtime_tools],
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
      {:jason, "~> 1.4"},
      {:oban, "~> 2.19"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.1", only: [:dev], runtime: false},
      {:mox, "~> 1.0", only: [:test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:tidewave, "~> 0.4", only: :dev},
      {:bandit, "~> 1.0", only: :dev}
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
      test: ["ecto.create --quiet", "ecto.migrate", "test"],
      tidewave:
        "run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4000) end)'"
    ]
  end

  defp before_closing_head_tag(_) do
    """
    <style>
      .sidebar-header, .sidebar {
        width: 400px !important;
      }
      .sidebar {
        --sidebarFontSize: 14px;
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
        "pages/EventSourcing.md",
        "LICENSE"
      ],
      groups_for_modules: [
        Instance: [
          DoubleEntryLedger.Instance,
          DoubleEntryLedger.Stores.InstanceStore,
          DoubleEntryLedger.Stores.InstanceStoreHelper
        ],
        Account: [
          DoubleEntryLedger.Account,
          DoubleEntryLedger.Balance,
          DoubleEntryLedger.BalanceHistoryEntry,
          DoubleEntryLedger.Stores.AccountStore,
          DoubleEntryLedger.Stores.AccountStoreHelper
        ],
        Transaction: [
          DoubleEntryLedger.Entry,
          DoubleEntryLedger.Entryable,
          DoubleEntryLedger.Transaction,
          DoubleEntryLedger.PendingTransactionLookup,
          DoubleEntryLedger.Stores.TransactionStore,
          DoubleEntryLedger.Stores.TransactionStoreHelper,
        ],
        JournalEvent: [
          DoubleEntryLedger.JournalEvent,
          DoubleEntryLedger.JournalEventAccountLink,
          DoubleEntryLedger.JournalEventCommandLink,
          DoubleEntryLedger.JournalEventTransactionLink,
          DoubleEntryLedger.Stores.JournalEventStore,
          DoubleEntryLedger.Stores.JournalEventStoreHelper
        ],
        Command: [
          DoubleEntryLedger.Command,
          DoubleEntryLedger.Command.CommandMap,
          DoubleEntryLedger.Command.EntryData,
          DoubleEntryLedger.Command.TransactionData,
          DoubleEntryLedger.Command.TransactionCommandMap,
          DoubleEntryLedger.Command.AccountData,
          DoubleEntryLedger.Command.AccountCommandMap,
          DoubleEntryLedger.Command.ErrorMap,
          DoubleEntryLedger.Command.Helper,
          DoubleEntryLedger.Command.IdempotencyKey,
          DoubleEntryLedger.Command.TransferErrors,
          DoubleEntryLedger.Stores.CommandStore,
          DoubleEntryLedger.Stores.CommandStoreHelper,
        ],
        CommandApi: [
          DoubleEntryLedger.Apis.CommandApi
        ],
        CommandWorker: [
          DoubleEntryLedger.Workers.CommandWorker,
          DoubleEntryLedger.Workers.CommandWorker.ProcessCommand,
          DoubleEntryLedger.Workers.CommandWorker.CreateTransactionCommand,
          DoubleEntryLedger.Workers.CommandWorker.CreateTransactionCommandMap,
          DoubleEntryLedger.Workers.CommandWorker.CreateTransactionCommandMapNoSaveOnError,
          DoubleEntryLedger.Workers.CommandWorker.UpdateTransactionCommand,
          DoubleEntryLedger.Workers.CommandWorker.UpdateTransactionCommandMap,
          DoubleEntryLedger.Workers.CommandWorker.UpdateTransactionCommandMapNoSaveOnError,
          DoubleEntryLedger.Workers.CommandWorker.TransactionCommandTransformer,
          DoubleEntryLedger.Workers.CommandWorker.TransactionCommandResponseHandler,
          DoubleEntryLedger.Workers.CommandWorker.TransactionCommandMapResponseHandler,
          DoubleEntryLedger.Workers.CommandWorker.CreateAccountCommand,
          DoubleEntryLedger.Workers.CommandWorker.CreateAccountCommandMapNoSaveOnError,
          DoubleEntryLedger.Workers.CommandWorker.UpdateAccountCommand,
          DoubleEntryLedger.Workers.CommandWorker.UpdateAccountCommandMapNoSaveOnError,
          DoubleEntryLedger.Workers.CommandWorker.AccountCommandMapResponseHandler,
          DoubleEntryLedger.Workers.CommandWorker.AccountCommandResponseHandler,
          DoubleEntryLedger.Workers.CommandWorker.UpdateCommandError
        ],
        CommandQueue: [
          DoubleEntryLedger.CommandQueueItem,
          DoubleEntryLedger.CommandQueue.Supervisor,
          DoubleEntryLedger.CommandQueue.Scheduling,
          DoubleEntryLedger.CommandQueue.InstanceProcessor,
          DoubleEntryLedger.CommandQueue.InstanceMonitor
        ],
        Oban: [
          DoubleEntryLedger.Workers.Oban.JournalEventLinks
        ],
        "Types, Utils and Logger": [
          DoubleEntryLedger.EntryHelper,
          DoubleEntryLedger.Types,
          DoubleEntryLedger.Utils.Changeset,
          DoubleEntryLedger.Utils.Currency,
          DoubleEntryLedger.Utils.Map,
          DoubleEntryLedger.Utils.Pagination,
          DoubleEntryLedger.Utils.Traceable,
          DoubleEntryLedger.Logger
        ],
        "Optimistic Concurrency Control": [
          DoubleEntryLedger.Occ.Processor,
          DoubleEntryLedger.Occ.Helper,
          DoubleEntryLedger.Occ.Occable
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
