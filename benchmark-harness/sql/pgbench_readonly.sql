-- Read-only pgbench transaction script.
-- Select one random account row; keeps workload light and read-focused.
\set aid random(1, :scale * 100000)
SELECT abalance FROM pgbench_accounts WHERE aid = :aid;
