# DuckDB local join — install and run

The cross-cloud join lives outside BigQuery (because no single account can read
both billing datasets). Stages 4 and 5 of the query pipeline run in DuckDB
against the CSVs that stages 1–3 produced.

DuckDB is a single static binary. Both stages run as
`duckdb < queries/04_local_join.sql` — no server, no setup beyond installing
the binary.

## Install

### macOS

```bash
brew install duckdb
duckdb --version
```

### Windows (elevated PowerShell)

Install [Chocolatey](https://chocolatey.org/install) first if you don't
already have it. Then:

```powershell
choco install -y duckdb
duckdb --version
```

If Chocolatey is unavailable, download the Windows binary from
<https://duckdb.org/docs/installation/> and add the directory to `PATH`.

### Linux

```bash
# Debian/Ubuntu
sudo apt install duckdb     # may not be in older repos

# Fallback: official binary release
curl -L https://github.com/duckdb/duckdb/releases/latest/download/duckdb_cli-linux-amd64.zip -o duckdb.zip
unzip duckdb.zip && sudo mv duckdb /usr/local/bin/
```

## Run

DuckDB reads relative paths from the **current working directory**, so run
everything from the same folder where the CSVs live.

### macOS / Linux / Git Bash

```bash
cd /path/to/your/working/dir   # contains the four CSVs
duckdb < queries/04_local_join.sql
duckdb < queries/05_summary.sql
```

### Windows (PowerShell)

```powershell
Set-Location C:\path\to\your\working\dir
Get-Content queries\04_local_join.sql | duckdb
Get-Content queries\05_summary.sql | duckdb
```

PowerShell cannot use `<` for input redirection; pipe via `Get-Content` instead.

## Inputs that must be in the working directory

| File | Produced by |
|---|---|
| `gcp_per_task.csv` | `bq query < queries/01_gcp_per_task.sql` |
| `azure_vm_cost.csv` | `bq query < queries/02_azure_vm_cost.sql` |
| `azure_task_runs_all.csv` | `bq query < queries/03_azure_task_runs_all.sql` |

If any of these is missing or empty, stage 4 / 5 will report
`Could not read file` or produce zero rows.

## Outputs

| File | Produced by | Use |
|---|---|---|
| `azure_per_task.csv` | stage 4 | Azure-side per-task rows after the cross-cloud join |
| `autoland_per_task.csv` | stage 5 | Combined GCP + Azure per-task rows; load this into pandas / Excel / a pivot tool |

## Interactive exploration

After stage 5, the combined CSV is the easiest place to keep poking:

```bash
duckdb -c "SELECT cloud, kind, SUM(run_cost_usd) usd
           FROM read_csv_auto('autoland_per_task.csv')
           GROUP BY cloud, kind ORDER BY usd DESC LIMIT 30"
```

Or open it from a Python notebook:

```python
import duckdb
df = duckdb.sql("SELECT * FROM 'autoland_per_task.csv' WHERE kind='mochitest'").df()
```

## Troubleshooting

**"`Could not read file 'azure_vm_cost.csv'`"** — wrong working directory. CD
to the folder holding the CSVs before invoking `duckdb`.

**"`Conversion Error: Could not convert string ... to TIMESTAMP`"** in stage 4 —
re-pull `azure_task_runs_all.csv`; you likely truncated the run mid-export and
got a partial last line.

**Stage 4 reports `attributed_per_task_total = 0`** — check the date window in
all five SQL files. Stage 3 must include at least the same date range as
stage 2; the join key is `(worker_id, usage_date)` and a window mismatch zeros
out every row.

**Mixed CRLF/LF line endings on Windows** — DuckDB handles both, but if
`Out-File` produced a UTF-16-encoded CSV, force UTF-8:
`-Encoding utf8` (PowerShell 5.x writes UTF-16 by default for some cmdlets).
