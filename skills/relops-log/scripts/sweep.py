# /// script
# requires-python = ">=3.11"
# ///
"""RelOps log sweep: tc-logview, paperctl, and ronin_puppet Kitchen Windows CI.

Writes one JSON report with errors grouped by normalized signature.
Works on Windows, Linux, and macOS.

    uv run sweep.py
    uv run sweep.py --hours 6 --skip papertrail --out sweep.json
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta

RONIN = "mozilla-platform-ops/ronin_puppet"
TC_FILTER = 'resource.labels.namespace_name="taskcluster-prod" AND jsonPayload.Severity<=3'
PT_QUERY = "severity:ERROR OR severity:CRITICAL OR severity:ALERT"
# Some programs log most lines as EMERGENCY. Keep only lines that read like a failure.
PT_EMERG_QUERY = (
    "severity:EMERGENCY AND (error OR fail OR failed OR failure OR fatal OR panic"
    ' OR exception OR denied OR timeout OR "exit status")'
)
MOZLOG = {0: "EMERGENCY", 1: "ALERT", 2: "CRITICAL", 3: "ERROR"}

NORMALIZE = [
    (r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", "<uuid>"),
    (r"\bvm-[a-z0-9]{10,}\b", "vm-<id>"),
    (r"(?<![\w-])(?=[\w-]*\d)(?=[\w-]*[A-Z])[\w-]{22}(?![\w-])", "<slugid>"),
    (r"with id \S+ in \d+ms", "with id <reqid>"),
    (r"\b\d{4}[-/]\d\d[-/]\d\d[T ][\d:.]+Z?", "<ts>"),
    (r"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b", "<ip>"),
    (r"\b0x[0-9a-f]+\b|\b[0-9a-f]{12,}\b", "<hex>"),
    (r"\d+", "N"),
]
NORMALIZE = [(re.compile(p, re.IGNORECASE if "0-9a-f" in p else 0), r) for p, r in NORMALIZE]


def norm(msg):
    msg = " ".join(str(msg).split())
    for rx, rep in NORMALIZE:
        msg = rx.sub(rep, msg)
    return msg[:160]


def host_class(host):
    if host.endswith(".reddog.microsoft.com") or re.fullmatch(r"[a-z0-9]{14,15}", host):
        return "azure-windows-vm"
    return re.sub(r"\d+", "N", re.sub(r"-+[a-z0-9]{10,}$", "", host))


def run(*args):
    """Run a CLI by name. shutil.which finds .exe/.cmd shims on Windows."""
    exe = shutil.which(args[0])
    if not exe:
        return 127, "", f"{args[0]} not found on PATH"
    p = subprocess.run([exe, *args[1:]], check=False, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=600)
    return p.returncode, p.stdout, p.stderr.strip()[-300:]


def windows(hours):
    end = datetime.now(UTC).replace(microsecond=0)
    fmt = "%Y-%m-%dT%H:%M:%SZ"
    return [((end - timedelta(hours=i + 1)).strftime(fmt), (end - timedelta(hours=i)).strftime(fmt))
            for i in range(hours)]


def group(rows, limit):
    """rows: (key tuple, ts, sample, host or None, top label or None)."""
    out = {}
    for key, ts, sample, host, top in rows:
        g = out.setdefault(key, {"count": 0, "first_seen": ts, "last_seen": ts,
                                 "sample": str(sample)[:400], "hosts": set(), "top": {}})
        g["count"] += 1
        g["first_seen"], g["last_seen"] = min(g["first_seen"], ts), max(g["last_seen"], ts)
        if host:
            g["hosts"].add(host)
        if top:
            g["top"][top] = g["top"].get(top, 0) + 1
    result = []
    for key, g in sorted(out.items(), key=lambda kv: -kv[1]["count"])[:limit]:
        hosts = g.pop("hosts")
        if hosts:
            g["host_count"], g["example_hosts"] = len(hosts), sorted(hosts)[:5]
        g["top"] = dict(sorted(g["top"].items(), key=lambda kv: -kv[1])[:8])
        result.append({"key": list(key), **g})
    return result


def parallel(fn, items, workers):
    with ThreadPoolExecutor(workers) as ex:
        return list(ex.map(fn, items))


# Taskcluster ----------------------------------------------------------------

def tc_window(w):
    for attempt in range(3):
        rc, out, err = run("tc-logview", "query", "-e", "fx-ci", "--from", w[0], "--to", w[1],
                           "--no-cache", "--limit", "5000", "--filter", TC_FILTER, "--raw")
        if rc == 0 or "RESOURCE_EXHAUSTED" not in err:
            break
        time.sleep(20 * (attempt + 1))  # shared Cloud Logging read quota
    return w[0], out if rc == 0 else "", None if rc == 0 else err


def taskcluster(hours):
    rows, errors = [], []
    for start, out, err in parallel(tc_window, windows(hours), 3):
        if err:
            errors.append({"window": start, "error": err})
        for line in out.splitlines():
            if not line.startswith("{"):
                continue
            e = json.loads(line)
            jp = e.get("jsonPayload") or {}
            f = jp.get("Fields") or {}
            msg = f.get("message") or f.get("msg") or f.get("error") or ""
            svc = e.get("resource", {}).get("labels", {}).get("container_name", "?")
            key = (MOZLOG.get(jp.get("Severity"), "?"), svc, jp.get("Type", "-"), norm(msg))
            rows.append((key, e.get("timestamp", ""), msg, None, f.get("workerPoolId")))
    return {"key": ["severity", "service", "type", "signature"], "entries": len(rows),
            "window_errors": errors, "signatures": group(rows, 60)}


def worker_errors(hours):
    rc, out, err = run("tc-logview", "query", "-e", "fx-ci", "--since", f"{hours}h",
                       "--type", "worker-error", "--limit", "20000", "--json")
    if rc:
        return {"error": err}
    rows = []
    for line in out.splitlines():
        if line.startswith("{"):
            e = json.loads(line)
            desc = e.get("description", "")
            rows.append(((e.get("workerPoolId"), e.get("kind"), norm(desc)), e.get("ts", ""), desc, None, None))
    return {"key": ["workerPoolId", "kind", "signature"], "entries": len(rows), "signatures": group(rows, 60)}


# Papertrail -----------------------------------------------------------------

def pt_window(args):
    query, limit, (start, end) = args
    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)  # Windows cannot reopen a file that is still open
    try:
        rc, _, err = run("paperctl", "search", query, "--since", start, "--until", end,
                         "--limit", str(limit), "--output", "json", "-F", path)
        with open(path, encoding="utf-8") as fh:
            data = fh.read().strip()
        return start, json.loads(data) if rc == 0 and data else [], None if rc == 0 else err
    finally:
        os.remove(path)


def papertrail(query, hours, limit):
    rows, errors = [], []
    for start, events, err in parallel(pt_window, [(query, limit, w) for w in windows(hours)], 4):
        if err:
            errors.append({"window": start, "error": err})
        for e in events:
            host, msg = e.get("hostname", "?"), e.get("message", "")
            key = (e.get("severity", "?"), e.get("program", "?"), norm(msg))
            rows.append((key, e.get("time", ""), msg, host, host_class(host)))
    return {"key": ["severity", "program", "signature"], "query": query, "sampled_events": len(rows),
            "per_hour_limit": limit, "window_errors": errors, "signatures": group(rows, 80)}


# Kitchen Windows ------------------------------------------------------------

ERR_LINE = re.compile(r">>>>>>|##\[error\]|Error:|FAILED|Failed to complete|Exception")


def job_errors(job_id):
    rc, out, err = run("gh", "run", "view", "-R", RONIN, "--job", str(job_id), "--log-failed")
    if rc:
        return [f"<log unavailable: {err}>"]
    lines = []
    for raw in out.splitlines():
        line = re.sub(r"^\S+Z |\x1b\[[0-9;]*m", "", raw.split("\t")[-1]).strip()
        if ERR_LINE.search(line) and "/gems/" not in line and not line.startswith(("D ", "echo")) \
                and line not in lines:
            lines.append(line[:300])
    return lines[-15:]


def kitchen(hours):
    since = (datetime.now(UTC) - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
    fields = "databaseId,conclusion,headBranch,event,createdAt,url,displayTitle"
    rc, out, err = run("gh", "run", "list", "-R", RONIN, "--workflow", "Kitchen Windows",
                       "--created", f">={since}", "-L", "200", "--json", fields)
    if rc:
        return {"error": err}
    runs, failed = json.loads(out), []
    for r in runs:
        if r["conclusion"] not in ("failure", "timed_out", "startup_failure"):
            continue
        _, jout, _ = run("gh", "run", "view", str(r["databaseId"]), "-R", RONIN, "--json", "jobs")
        jobs = [j for j in json.loads(jout or "{}").get("jobs", []) if j["conclusion"] in ("failure", "timed_out")]
        failed.append({"run": r["url"], "title": r["displayTitle"], "branch": r["headBranch"],
                       "event": r["event"], "created": r["createdAt"],
                       "jobs": [{"name": j["name"], "url": j["url"], "errors": job_errors(j["databaseId"])}
                                for j in jobs]})
    _, mout, _ = run("gh", "run", "list", "-R", RONIN, "--workflow", "Kitchen Windows",
                     "--branch", "master", "-L", "1", "--json", "conclusion,url,createdAt")
    return {"runs": len(runs), "failed": len(failed), "latest_master": (json.loads(mout or "[]") or [None])[0],
            "failed_runs": failed}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hours", type=int, default=24)
    ap.add_argument("--pt-limit", type=int, default=2000, help="paperctl events per 1h window")
    ap.add_argument("--skip", action="append", default=[], choices=["taskcluster", "papertrail", "kitchen"])
    ap.add_argument("--out", default=os.path.join(tempfile.gettempdir(), "relops-log.json"))
    a = ap.parse_args()

    tasks = {
        "taskcluster": ("taskcluster", lambda: taskcluster(a.hours)),
        "worker_errors": ("taskcluster", lambda: worker_errors(a.hours)),
        "papertrail": ("papertrail", lambda: papertrail(PT_QUERY, a.hours, a.pt_limit)),
        "papertrail_emergency": ("papertrail", lambda: papertrail(PT_EMERG_QUERY, a.hours, a.pt_limit // 2)),
        "kitchen_windows": ("kitchen", lambda: kitchen(a.hours)),
    }
    tasks = {k: fn for k, (src, fn) in tasks.items() if src not in a.skip}
    report = {"generated": datetime.now(UTC).isoformat(), "hours": a.hours}
    with ThreadPoolExecutor(len(tasks) or 1) as ex:
        futures = {k: ex.submit(fn) for k, fn in tasks.items()}
        for k, fut in futures.items():
            try:
                report[k] = fut.result()
            except Exception as exc:  # noqa: BLE001 - keep other sections if one source fails
                report[k] = {"error": repr(exc)}

    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)
    print(f"wrote {a.out}")
    for k in tasks:
        sec = report[k]
        status = f"ERROR {sec['error'][:150]}" if "error" in sec else \
            f"{sec.get('entries', sec.get('sampled_events', sec.get('runs')))} entries"
        print(f"  {k}: {status}", file=sys.stderr if "error" in sec else sys.stdout)


if __name__ == "__main__":
    main()
