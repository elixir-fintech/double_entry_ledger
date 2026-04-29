#!/usr/bin/env bash
  SQL="SELECT coalesce(wait_event_type, 'CPU') AS type, coalesce(wait_event, '(running)') AS event, count(*) FROM pg_stat_activity WHERE datname = current_database() AND state != 'idle' AND pid != pg_backend_pid() GROUP BY 1, 2 ORDER BY 3
  DESC;"

  for i in 1 2 3 4 5; do
    echo "--- sample $i ---"
    PGPASSWORD=postgres psql -h localhost -U postgres \
      -d double_entry_ledger_repo_performance -c "$SQL"
    sleep 5
  done

  Then: terminal A runs MIX_ENV=perf mix load_test 50 60, terminal B runs bash sample_waits.sh once the load test starts.

  If you'd rather not deal with bash quoting at all, just run this single one-liner repeatedly (5×, ~5 seconds apart) by hand while the load test is running:

  PGPASSWORD=postgres psql -h localhost -U postgres -d double_entry_ledger_repo_performance -c "SELECT coalesce(wait_event_type,'CPU') AS type, coalesce(wait_event,'(running)') AS event, count(*) FROM pg_stat_activity WHERE
  datname=current_database() AND state!='idle' AND pid!=pg_backend_pid() GROUP BY 1,2 ORDER BY 3 DESC;"
