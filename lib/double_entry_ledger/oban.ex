defmodule DoubleEntryLedger.Oban do
  @moduledoc """
  Marker module for DoubleEntryLedger's dedicated Oban instance.

  The library runs a **named** Oban supervisor registered under the atom
  `DoubleEntryLedger.Oban`, separate from any Oban the consumer app runs
  for its own background jobs. This avoids colliding with the default
  unnamed `Oban` instance and makes the library drop-in: consumers don't
  need to know DEL's queue names.

  As of v0.5, the library no longer enqueues any synchronous Oban jobs
  on the create/update path — the previous `JournalEventLinks` worker
  was removed when the link tables were collapsed into direct FKs on
  `journal_events` (migration v5). Consumers can still attach their own
  workers under this name.
  """
end
