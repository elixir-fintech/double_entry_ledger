defmodule DoubleEntryLedger.Types do
  @moduledoc """
  This module defines types used in the DoubleEntryLedger application.
  """
  @type c_or_d :: :credit | :debit

  @type trx_types :: :posted | :pending | :pending_to_posted | :pending_to_archived

end
