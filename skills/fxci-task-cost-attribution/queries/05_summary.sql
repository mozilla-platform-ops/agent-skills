-- ============================================================
-- Combine GCP + Azure per-task costs and summarize — DuckDB
-- ============================================================
-- Inputs (CWD):
--   gcp_per_task.csv     (from queries/01)
--   azure_per_task.csv   (from queries/04)
-- Output:
--   autoland_per_task.csv  (combined; column-compatible across clouds)
--   plus inline tables (totals, top kinds, top labels, top pushes)
-- ============================================================

CREATE OR REPLACE VIEW gcp AS
SELECT tree, kind, label, task_id, run_id, task_group_id, worker_pool_id,
       os, test_platform, submission_date, run_cost_usd, cloud
FROM read_csv_auto('gcp_per_task.csv');

CREATE OR REPLACE VIEW azure AS
SELECT tree, kind, label, task_id, run_id, task_group_id, worker_pool_id,
       os, test_platform, submission_date, run_cost_usd, cloud
FROM read_csv_auto('azure_per_task.csv');

CREATE OR REPLACE TABLE all_runs AS
SELECT * FROM gcp UNION ALL SELECT * FROM azure;

COPY all_runs TO 'autoland_per_task.csv' (HEADER, DELIMITER ',');

.print
.print === Total cost in window ===
SELECT cloud,
       COUNT(*) AS task_runs,
       COUNT(DISTINCT task_id) AS distinct_tasks,
       COUNT(DISTINCT task_group_id) AS distinct_pushes,
       printf('%.2f', SUM(run_cost_usd)) AS total_usd
FROM all_runs
GROUP BY cloud
UNION ALL
SELECT 'TOTAL', COUNT(*), COUNT(DISTINCT task_id), COUNT(DISTINCT task_group_id),
       printf('%.2f', SUM(run_cost_usd))
FROM all_runs
ORDER BY cloud;

.print
.print === Top 15 kinds by cost ===
SELECT kind, cloud,
       COUNT(*) AS runs,
       printf('%.2f', SUM(run_cost_usd)) AS cost_usd,
       printf('%.4f', AVG(run_cost_usd)) AS avg_run_usd
FROM all_runs
GROUP BY kind, cloud
ORDER BY SUM(run_cost_usd) DESC
LIMIT 15;

.print
.print === Top 15 labels by cost ===
SELECT label, cloud,
       COUNT(*) AS runs,
       printf('%.2f', SUM(run_cost_usd)) AS cost_usd
FROM all_runs
WHERE label IS NOT NULL AND label != ''
GROUP BY label, cloud
ORDER BY SUM(run_cost_usd) DESC
LIMIT 15;

.print
.print === Top 10 pushes by cost ===
SELECT task_group_id,
       COUNT(*) AS runs,
       SUM(IF(cloud='gcp',1,0)) AS gcp_runs,
       SUM(IF(cloud='azure',1,0)) AS azure_runs,
       printf('%.2f', SUM(run_cost_usd)) AS push_cost_usd
FROM all_runs
GROUP BY task_group_id
ORDER BY SUM(run_cost_usd) DESC
LIMIT 10;
