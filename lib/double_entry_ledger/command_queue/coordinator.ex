defmodule DoubleEntryLedger.CommandQueue.Coordinator do
  @moduledoc """
  Decides which ledgers this node should *attempt* to own, and holds a
  reservation for each attempt from before its acquisition task starts until
  its processor exits.

  A coordinator never grants ownership and never fences a write; that is
  `CommandQueue.Lease`. A reservation only permits a call to
  `Lease.acquire/4`, and losing one never revokes a grant. `reserve/2` is the
  single operation a distributed implementation makes atomic, so two nodes
  cannot both start acquiring the same ledger. This release ships
  `Coordinator.DatabasePolling`; `:erlang_cluster` is a future strategy.

  ## What a reservation has to carry

  A reservation's identity is the whole of its production contract: `reserve/2`
  either grants one for a ledger or refuses, and `release/2` gives it back.
  `acquisition_started/3` and `processor_started/3` exist so an implementation
  *may* record which task and which processor an outstanding reservation
  belongs to, but nothing in `InstanceMonitor` reads that back — it keeps its
  own `refs` map for the work it has to do, and a coordinator is never asked
  who holds what. In `Coordinator.DatabasePolling` the two recorded fields are
  therefore advisory: `task_ref` is written and never read, and `processor_pid`
  is read only by a test. An implementation is free to ignore both arguments;
  the callbacks are in the behaviour because a clustered strategy will need
  them to publish ownership, and because a reservation's lifetime is easier to
  reason about when both ends of it are announced.
  """

  @type state :: term()
  @type reservation :: term()

  # Two guarantees (design §9): an attempt reservation, which stops a second
  # local attempt for the same ledger within one monitor incarnation and may
  # be lost on restart (a duplicate attempt gets :held or :busy from the
  # lease); and processor exclusion, which stops new attempts for a ledger
  # whose processor runs on this node for its whole lifetime. DatabasePolling
  # holds the latter in its map and, across a monitor restart, in the Registry.
  #
  # Two known gaps, recorded for the :erlang_cluster spec (design §9): init/1
  # cannot hand the monitor reservation-to-process associations to rebuild
  # `refs` (R24.2), and every callback is monitor-initiated, so a coordinator
  # cannot report asynchronously that a reservation was lost (R25.2).
  @callback init(keyword()) :: state()
  @callback candidates(state()) :: {[Ecto.UUID.t()], state()}
  @callback reserve(Ecto.UUID.t(), state()) :: {:ok, reservation(), state()} | {:skip, state()}
  @callback acquisition_started(reservation(), reference(), state()) :: state()
  @callback processor_started(reservation(), pid(), state()) :: state()
  @callback release(reservation(), state()) :: state()
end
