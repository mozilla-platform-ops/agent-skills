-- ============================================================
-- Local cross-cloud join — DuckDB
-- ============================================================
-- TREE = 'autoland'   (change in the WHERE at the bottom for try, central, ...)
--
-- Inputs (CWD):
--   azure_vm_cost.csv        (from queries/02)
--   azure_task_runs_all.csv  (from queries/03; ALL trees, not just autoland)
-- Output:
--   azure_per_task.csv       (per-task Azure cost rows, autoland only)
--
-- Methodology (mirrors RELOPS-2330 with one improvement):
--   uptime_sec  ≈  EPOCH(MAX(resolved)) - EPOCH(MIN(started))   per (worker, date)
--   run_cost    =  LEAST(1.0, task_duration / uptime) * vm_cost_for_that_VM_day
--
-- The reference query in RELOPS-2330 uses `uptime_sec > task_duration_sec`,
-- which excludes single-task VMs entirely. We use `>=` and cap the ratio at
-- 1.0 — for a single-task VM this attributes 100% of vm_cost to that one
-- task, which is closer to truth (the VM existed only for that task).
-- Empirically this shrinks the unattributed gap from ~27% to ~12% on Azure.
-- See ../references/methodology.md for the full bucket decomposition.
-- ============================================================

CREATE OR REPLACE VIEW vm_cost AS
SELECT worker_id, usage_date::DATE AS usage_date, cost_usd
FROM read_csv_auto('azure_vm_cost.csv');

-- All vm-* task_runs in the window (any tree). Used for the uptime denominator.
CREATE OR REPLACE VIEW task_runs_all AS
SELECT * FROM read_csv_auto('azure_task_runs_all.csv', AUTO_DETECT=TRUE);

CREATE OR REPLACE VIEW vm_uptime AS
SELECT
  worker_id,
  usage_date,
  EPOCH(MAX(resolved)) - EPOCH(MIN(started)) AS uptime_sec
FROM task_runs_all
GROUP BY worker_id, usage_date;

CREATE OR REPLACE TABLE azure_per_task AS
SELECT
  tr.tree,
  tr.kind,
  tr.label,
  tr.task_id,
  tr.run_id,
  tr.task_group_id,
  tr.worker_pool_id,
  tr.os,
  tr.test_platform,
  tr.usage_date AS submission_date,
  tr.task_duration_sec,
  u.uptime_sec,
  c.cost_usd AS vm_cost_usd,
  LEAST(1.0, CAST(tr.task_duration_sec AS DOUBLE) / u.uptime_sec) * c.cost_usd AS run_cost_usd,
  'azure' AS cloud
FROM task_runs_all tr
JOIN vm_cost c USING (worker_id, usage_date)
JOIN vm_uptime u USING (worker_id, usage_date)
WHERE u.uptime_sec >= tr.task_duration_sec
  AND u.uptime_sec > 0
  AND tr.tree = 'autoland';

COPY azure_per_task TO 'azure_per_task.csv' (HEADER, DELIMITER ',');

-- Sanity check: how much Azure VM-day cost is attributed vs total in window?
-- A 25-30% gap is expected — see methodology.md.
SELECT 'attributed_per_task_total (this tree)' AS metric,
       printf('%.2f', SUM(run_cost_usd)) AS usd,
       COUNT(*) AS rows
FROM azure_per_task
UNION ALL
SELECT 'attributed_per_task_total (all trees, sanity)' AS metric,
       printf('%.2f', SUM(run_cost_usd)) AS usd,
       NULL
FROM (
  SELECT LEAST(1.0, CAST(tr.task_duration_sec AS DOUBLE) / u.uptime_sec) * c.cost_usd AS run_cost_usd
  FROM task_runs_all tr
  JOIN vm_cost c USING (worker_id, usage_date)
  JOIN vm_uptime u USING (worker_id, usage_date)
  WHERE u.uptime_sec >= tr.task_duration_sec
    AND u.uptime_sec > 0
)
UNION ALL
SELECT 'azure_total_vm_spend_in_window' AS metric,
       printf('%.2f', SUM(cost_usd)) AS usd,
       NULL
FROM vm_cost;
