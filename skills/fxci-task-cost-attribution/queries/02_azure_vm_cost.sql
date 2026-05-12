-- ============================================================
-- Azure per-VM-day cost
-- ============================================================
-- WINDOW_START = '2026-04-28'
-- WINDOW_END   = '2026-05-02'
--
-- Account:  <user>@firefox.gcp.mozilla.com
-- Project:  moz-fx-data-billing-prod-9147
-- Reads:    moz-fx-data-billing-prod-9147.azure_billing_raw.fxci_daily_actual_load
-- Output:   azure_vm_cost.csv
--
-- Why a separate account: human IAM is split. moz-fx-data-billing-prod-9147 is
-- only readable by `<user>@firefox.gcp.mozilla.com` (via finops/viewers). The
-- mozilla.com SSO account that reads moz-fx-data-shared-prod has no access
-- here. See ../references/auth-split.md.
--
-- VM-name regex matches the FXCI `vm-<id>` naming convention.
--
-- See: ../references/methodology.md
-- ============================================================

SELECT
  REGEXP_EXTRACT(ResourceId, r'virtualMachines/([^/]+)$') AS worker_id,
  DATE(`date`) AS usage_date,
  SUM(costInBillingCurrency) AS cost_usd
FROM `moz-fx-data-billing-prod-9147.azure_billing_raw.fxci_daily_actual_load`
WHERE DATE(`date`) BETWEEN '2026-04-28' AND '2026-05-02'
  AND ResourceId LIKE '%/virtualMachines/vm-%'
GROUP BY worker_id, usage_date
