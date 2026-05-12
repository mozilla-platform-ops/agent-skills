-- ============================================================
-- Azure worker uptime from Taskcluster worker metrics
-- ============================================================
-- WINDOW_START = '2026-04-28'
-- WINDOW_END   = '2026-05-02'
--
-- Account:  <user>@mozilla.com
-- Project:  mozdata
-- Reads:    moz-fx-data-shared-prod.taskclusteretl.worker_metrics
-- Output:   azure_worker_uptime.csv
--
-- This uses generic-worker WORKER_METRICS lifecycle events. It is a better
-- denominator than MAX(task resolved) - MIN(task started), because it includes
-- worker boot, ready, task, reboot, and shutdown intervals observed by the
-- worker.
-- ============================================================

WITH date_window AS (
  SELECT
    TIMESTAMP(DATE '2026-04-28') AS window_start,
    TIMESTAMP_ADD(TIMESTAMP(DATE '2026-05-02'), INTERVAL 1 DAY) AS window_end
),
date_spine AS (
  SELECT day
  FROM UNNEST(GENERATE_DATE_ARRAY(DATE '2026-04-28', DATE '2026-05-02')) AS day
),
worker_event AS (
  SELECT
    workerId AS worker_id,
    workerPoolId AS worker_pool_id,
    LOWER(region) AS region,
    eventType AS event_type,
    timestamp AS event_time,
    CASE eventType
      WHEN 'instanceBoot' THEN 1
      WHEN 'workerReady' THEN 2
      WHEN 'taskStart' THEN 3
      WHEN 'taskFinish' THEN 4
      WHEN 'instanceReboot' THEN 5
      WHEN 'instanceShutdown' THEN 6
    END AS event_order
  FROM `moz-fx-data-shared-prod.taskclusteretl.worker_metrics`, date_window
  WHERE timestamp >= TIMESTAMP_SUB(window_start, INTERVAL 1 DAY)
    AND timestamp < TIMESTAMP_ADD(window_end, INTERVAL 1 DAY)
    AND worker = 'generic-worker'
    AND workerId LIKE 'vm-%'
    AND region IS NOT NULL
    AND eventType IN (
      'instanceBoot',
      'workerReady',
      'taskStart',
      'taskFinish',
      'instanceReboot',
      'instanceShutdown'
    )
    AND REGEXP_CONTAINS(workerPoolId, r'^(gecko-t|enterprise-t|comm-t)/win')
),
worker_interval AS (
  SELECT
    *,
    LEAD(event_time) OVER (
      PARTITION BY worker_pool_id, worker_id
      ORDER BY event_time, event_order
    ) AS next_event_time
  FROM worker_event
),
daily_interval AS (
  SELECT
    worker_id,
    worker_pool_id,
    region,
    day AS usage_date,
    GREATEST(event_time, TIMESTAMP(day)) AS interval_start,
    LEAST(next_event_time, TIMESTAMP_ADD(TIMESTAMP(day), INTERVAL 1 DAY)) AS interval_end
  FROM worker_interval
  JOIN date_spine
    ON next_event_time > TIMESTAMP(day)
    AND event_time < TIMESTAMP_ADD(TIMESTAMP(day), INTERVAL 1 DAY)
  WHERE event_type != 'instanceShutdown'
    AND next_event_time IS NOT NULL
)
SELECT
  worker_id,
  ANY_VALUE(worker_pool_id) AS worker_pool_id,
  ANY_VALUE(region) AS region,
  usage_date,
  SUM(TIMESTAMP_DIFF(interval_end, interval_start, SECOND)) AS uptime_sec
FROM daily_interval
WHERE interval_end > interval_start
GROUP BY worker_id, usage_date
