-- ============================================================
-- ALL task_runs on Azure (vm-*) workers in window — any tree
-- ============================================================
-- WINDOW_START = '2026-04-28'
-- WINDOW_END   = '2026-05-02'
--
-- Account:  <user>@mozilla.com
-- Project:  mozdata
-- Reads:    moz-fx-data-shared-prod.fxci_derived.task_runs_v1
--           moz-fx-data-shared-prod.fxci_derived.tasks_v2
-- Output:   azure_task_runs_all.csv
--
-- DO NOT add `tags.project = 'autoland'` here. A VM can run tasks from
-- multiple branches in the same day. The tree filter is applied AFTER the
-- join in 05_local_join.sql.
--
-- See: ../references/methodology.md
-- ============================================================

SELECT
  tr.task_id,
  tr.run_id,
  tr.worker_id,
  tr.started,
  tr.resolved,
  TIMESTAMP_DIFF(tr.resolved, tr.started, SECOND) AS task_duration_sec,
  DATE(tr.started) AS usage_date,
  t.tags.project AS tree,
  t.tags.kind AS kind,
  t.tags.label AS label,
  t.task_group_id,
  t.task_queue_id AS worker_pool_id,
  t.tags.os AS os,
  t.tags.test_platform AS test_platform
FROM `moz-fx-data-shared-prod.fxci_derived.task_runs_v1` tr
JOIN `moz-fx-data-shared-prod.fxci_derived.tasks_v2` t USING (task_id)
WHERE tr.submission_date BETWEEN '2026-04-28' AND '2026-05-02'
  AND t.submission_date BETWEEN '2026-04-28' AND '2026-05-03'
  AND tr.worker_id LIKE 'vm-%'
  AND tr.started IS NOT NULL
  AND tr.resolved IS NOT NULL
  AND DATE(tr.started) BETWEEN '2026-04-28' AND '2026-05-02'
