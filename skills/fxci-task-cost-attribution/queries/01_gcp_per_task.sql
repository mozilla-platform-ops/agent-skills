-- ============================================================
-- GCP-side per-task cost
-- ============================================================
-- WINDOW_START = '2026-04-28'
-- WINDOW_END   = '2026-05-02'
-- TREE         = 'autoland'   (change for try, mozilla-central, ...)
--
-- Account:  <user>@mozilla.com
-- Project:  mozdata
-- Reads:    moz-fx-data-shared-prod.fxci_derived.task_run_costs_v1
--           moz-fx-data-shared-prod.fxci_derived.tasks_v2
-- Output:   gcp_per_task.csv
--
-- task_run_costs_v1 is the production GCP attribution table — already
-- joined to GCP billing. Schema is (task_id, run_id, submission_date,
-- run_cost). We add tree/kind/label by joining tasks_v2.
--
-- Coverage: GCP-hosted Linux/build/decision/scriptworker tasks. Azure
-- (Windows) tasks are NOT in this table — see 02 + 03 + 04.
--
-- See: ../references/methodology.md
-- ============================================================

SELECT
  t.tags.project AS tree,
  t.tags.kind AS kind,
  t.tags.label AS label,
  c.task_id,
  c.run_id,
  t.task_group_id,
  t.task_queue_id AS worker_pool_id,
  t.tags.os AS os,
  t.tags.test_platform AS test_platform,
  c.submission_date,
  c.run_cost AS run_cost_usd,
  'gcp' AS cloud
FROM `moz-fx-data-shared-prod.fxci_derived.task_run_costs_v1` c
JOIN `moz-fx-data-shared-prod.fxci_derived.tasks_v2` t USING (task_id)
WHERE c.submission_date BETWEEN '2026-04-28' AND '2026-05-02'
  -- tasks_v2 partitioned by submission_date; allow +1 day so a task that
  -- started near midnight UTC and resolved on the next partition still joins.
  AND t.submission_date BETWEEN '2026-04-28' AND '2026-05-03'
  AND t.tags.project = 'autoland'
