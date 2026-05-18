#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# ///
"""File and manage Azure support tickets via `az support in-subscription tickets`.

Subcommands:
    quota   File a quota-increase ticket
    bump    Update an existing ticket's severity
    list    List recent tickets in the subscription
    show    Show one ticket's details

Why this exists: the `az support` CLI surface accepts the right inputs
but the per-quota-type payload format, the ASCII-only description
rule, and the service/problem-classification GUIDs are easy to get
wrong. The script encodes the working recipe so quota requests file
cleanly on the first try.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import shutil
import subprocess
import sys
import unicodedata
from typing import Any

QUOTA_SERVICE_ID = "06bfd9d3-516b-d5c6-5802-169c800dec89"
COMPUTE_VM_PC = "e12e3d1d-7fa0-af33-c6d0-3c50df9658a3"
QUOTA_PROBLEM_CLASSIFICATION = (
    f"/providers/Microsoft.Support/services/{QUOTA_SERVICE_ID}"
    f"/problemClassifications/{COMPUTE_VM_PC}"
)

# Map --quota-type to the per-payload Type and the VMFamily literal.
# `lowPriority` and `cores` are the API's magic strings for the regional
# total Spot and dedicated pools respectively — they aren't real family
# names. For per-family changes, --vm-family overrides this.
QUOTA_TYPES = {
    "LowPriorityCores": {
        "type": "LowPriority",
        "vm_family": "lowPriority",
        "subtype": "Service",
    },
    "RegularCores": {
        "type": "Dedicated",
        "vm_family": "cores",
        "subtype": "Service",
    },
    "VMFamilyCores": {
        "type": "Dedicated",
        "vm_family": None,
        "subtype": "Service",
    },
    "VMFamilyLowPriority": {
        "type": "LowPriority",
        "vm_family": None,
        "subtype": "Service",
    },
}

DEFAULT_SUBSCRIPTION = "a30e97ab-734a-4f3b-a0e4-c51c0bff0701"

DEFAULT_CONTACT = {
    "country": "USA",
    "language": "en-us",
    "method": "email",
    "timezone": "Pacific Standard Time",
}

# Codepoints that the support API rejects. The error from the service
# is a generic JsonDeserializationError with no offset, so the cheapest
# defense is to normalize before sending.
_NON_ASCII_REPLACEMENTS = {
    "—": "-",   # em-dash
    "–": "-",   # en-dash
    "‘": "'",   # left single quote
    "’": "'",   # right single quote / apostrophe
    "“": '"',   # left double quote
    "”": '"',   # right double quote
    "…": "...", # ellipsis
    " ": " ",   # non-breaking space
}


def sanitize_ascii(text: str) -> tuple[str, list[str]]:
    """Strip the description down to ASCII. Returns (clean, notices)."""
    notices: list[str] = []
    out_chars = []
    for ch in text:
        if ch in _NON_ASCII_REPLACEMENTS:
            out_chars.append(_NON_ASCII_REPLACEMENTS[ch])
            continue
        if ord(ch) < 128:
            out_chars.append(ch)
            continue
        # Try NFKD decomposition (catches accented Latin)
        decomposed = unicodedata.normalize("NFKD", ch)
        ascii_part = decomposed.encode("ascii", "ignore").decode("ascii")
        if ascii_part:
            out_chars.append(ascii_part)
            notices.append(
                f"normalized '{ch}' (U+{ord(ch):04X}) to '{ascii_part}'"
            )
        else:
            notices.append(
                f"dropped '{ch}' (U+{ord(ch):04X}) - no ASCII equivalent"
            )
    return "".join(out_chars), notices


def az(*args: str, capture: bool = True) -> dict[str, Any]:
    """Run an `az` command and return parsed JSON.

    Tolerates non-JSON success output by returning {"raw": stdout}.
    """
    cmd = ["az", *args]
    proc = subprocess.run(cmd, capture_output=capture, text=True)
    if proc.returncode != 0:
        raise SystemExit(
            f"az failed: {' '.join(cmd)}\n  stderr: {proc.stderr.strip()}"
        )
    out = proc.stdout.strip()
    if not out:
        return {}
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return {"raw": out}


def ensure_support_extension() -> None:
    """`az support` lives in an opt-in extension that may not be installed."""
    try:
        subprocess.run(
            ["az", "extension", "show", "--name", "support"],
            check=True, capture_output=True,
        )
    except subprocess.CalledProcessError:
        print("Installing 'support' extension...", file=sys.stderr)
        subprocess.run(
            ["az", "extension", "add", "--name", "support"],
            check=True,
        )


def get_signed_in_user() -> dict[str, str]:
    """Default the contact info from the signed-in Azure identity."""
    try:
        u = az(
            "ad", "signed-in-user", "show",
            "--query", "{mail:mail,upn:userPrincipalName,"
            "given:givenName,surname:surname}",
        )
    except SystemExit:
        return {}
    return {
        "email": u.get("mail") or u.get("upn") or "",
        "first_name": u.get("given") or "",
        "last_name": u.get("surname") or "",
    }


def make_ticket_name(region: str, quota_type: str, new_limit: int) -> str:
    ts = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    qslug = quota_type.lower().replace(" ", "-")
    return f"quota-{region}-{qslug}-{new_limit}-{ts}"


def build_quota_payload(
    quota_type: str, vm_family: str | None, new_limit: int,
) -> tuple[str, str]:
    """Returns (subtype, json-array-string) for --quota-change-requests."""
    meta = QUOTA_TYPES.get(quota_type)
    if not meta:
        raise SystemExit(
            f"Unknown --quota-type {quota_type}. "
            f"Choose: {', '.join(QUOTA_TYPES)}"
        )
    family = vm_family or meta["vm_family"]
    if not family:
        raise SystemExit(
            f"--vm-family is required when --quota-type={quota_type}"
        )
    payload = (
        f"{{VMFamily:{family},NewLimit:{new_limit},Type:{meta['type']}}}"
    )
    return meta["subtype"], payload


def cmd_quota(args: argparse.Namespace) -> None:
    ensure_support_extension()

    if not shutil.which("az"):
        raise SystemExit("az CLI not on PATH")

    contact = get_signed_in_user()
    email = args.contact_email or contact.get("email")
    first_name = args.contact_first_name or contact.get("first_name")
    last_name = args.contact_last_name or contact.get("last_name")
    if not (email and first_name and last_name):
        raise SystemExit(
            "Could not determine contact info; pass --contact-email, "
            "--contact-first-name, --contact-last-name explicitly."
        )

    reason = args.reason or ""
    if args.reason_file:
        with open(args.reason_file) as f:
            reason = f.read()
    if not reason.strip():
        raise SystemExit("--reason or --reason-file is required")

    clean, notices = sanitize_ascii(reason)
    for n in notices:
        print(f"[sanitize] {n}", file=sys.stderr)

    subtype, payload = build_quota_payload(
        args.quota_type, args.vm_family, args.new_limit,
    )
    quota_change_requests = (
        f"[{{region:'{args.region}',payload:'{payload}'}}]"
    )

    ticket_name = args.ticket_name or make_ticket_name(
        args.region, args.quota_type, args.new_limit,
    )
    title = args.title or (
        f"Increase {args.quota_type} quota in {args.region} "
        f"to {args.new_limit}"
    )

    cmd = [
        "az", "support", "in-subscription", "tickets", "create",
        "--subscription", args.subscription,
        "--ticket-name", ticket_name,
        "--title", title,
        "--description", clean,
        "--severity", args.severity,
        "--advanced-diagnostic-consent", "Yes",
        "--contact-first-name", first_name,
        "--contact-last-name", last_name,
        "--contact-method", args.contact_method,
        "--contact-email", email,
        "--contact-language", args.contact_language,
        "--contact-timezone", args.contact_timezone,
        "--contact-country", args.contact_country,
        "--problem-classification", QUOTA_PROBLEM_CLASSIFICATION,
        "--quota-change-version", "1.0",
        "--quota-change-subtype", subtype,
        "--quota-change-requests", quota_change_requests,
    ]

    if args.dry_run:
        print("[dry-run] would invoke:", file=sys.stderr)
        printable = " \\\n  ".join(_quote(c) for c in cmd)
        print(printable)
        return

    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit(f"az failed: {proc.stderr.strip()}")
    resp = json.loads(proc.stdout)
    summary = {
        "resource_name": resp.get("name"),
        "ticket_id": resp.get("supportTicketId"),
        "severity": resp.get("severity"),
        "status": resp.get("status"),
        "support_plan": resp.get("supportPlanDisplayName"),
        "sla_minutes": (resp.get("serviceLevelAgreement") or {}).get(
            "slaMinutes",
        ),
        "title": resp.get("title"),
    }
    print(json.dumps(summary, indent=2))


def cmd_bump(args: argparse.Namespace) -> None:
    ensure_support_extension()
    # Resolve ticket-name from either resource name or display ticket id
    name = args.ticket_name
    if name and name.isdigit():
        # Caller passed the display id; look up the resource name
        rows = az(
            "support", "in-subscription", "tickets", "list",
            "--subscription", args.subscription,
            "--query", f"[?supportTicketId=='{name}']."
            "{name:name,id:supportTicketId,severity:severity,status:status}",
        )
        if not rows:
            raise SystemExit(
                f"No ticket with supportTicketId {name} in {args.subscription}"
            )
        name = rows[0]["name"]
        print(f"Resolved ticket-name: {name}", file=sys.stderr)

    cmd = [
        "az", "support", "in-subscription", "tickets", "update",
        "--subscription", args.subscription,
        "--ticket-name", name,
        "--severity", args.severity,
    ]
    if args.dry_run:
        printable = " \\\n  ".join(_quote(c) for c in cmd)
        print(printable)
        return
    resp = az(*cmd[1:])
    print(json.dumps({
        "resource_name": resp.get("name"),
        "ticket_id": resp.get("supportTicketId"),
        "severity": resp.get("severity"),
        "status": resp.get("status"),
    }, indent=2))


def cmd_list(args: argparse.Namespace) -> None:
    ensure_support_extension()
    rows = az(
        "support", "in-subscription", "tickets", "list",
        "--subscription", args.subscription,
        "--query", "[].{name:name,id:supportTicketId,severity:severity,"
        "status:status,title:title,created:createdDate}",
    )
    print(json.dumps(rows, indent=2))


def cmd_show(args: argparse.Namespace) -> None:
    ensure_support_extension()
    resp = az(
        "support", "in-subscription", "tickets", "show",
        "--subscription", args.subscription,
        "--ticket-name", args.ticket_name,
    )
    print(json.dumps(resp, indent=2))


def _quote(s: str) -> str:
    if not s or any(c in s for c in " \"'\\$`"):
        return "'" + s.replace("'", "'\"'\"'") + "'"
    return s


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Wrap `az support in-subscription tickets` for quota work."
        ),
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    def common(p: argparse.ArgumentParser) -> None:
        p.add_argument(
            "--subscription", default=DEFAULT_SUBSCRIPTION,
            help=f"Azure subscription ID. Default: {DEFAULT_SUBSCRIPTION}",
        )

    pq = sub.add_parser("quota", help="File a quota-increase ticket")
    common(pq)
    pq.add_argument("--region", required=True, help="Azure region (e.g. southcentralus)")
    pq.add_argument(
        "--quota-type", required=True, choices=list(QUOTA_TYPES),
        help="LowPriorityCores | RegularCores | VMFamilyCores | VMFamilyLowPriority",
    )
    pq.add_argument("--new-limit", type=int, required=True, help="New core limit")
    pq.add_argument(
        "--vm-family", default=None,
        help="Required for VMFamily* quota types, e.g. standardDADSv5Family",
    )
    pq.add_argument(
        "--severity", default="moderate",
        choices=["minimal", "moderate", "critical", "highestcriticalimpact"],
        help="Sev C / Sev B / Sev A / Sev 0. Default: moderate (Sev B)",
    )
    pq.add_argument("--reason", help="Plain-text justification")
    pq.add_argument("--reason-file", help="Read reason body from a file")
    pq.add_argument("--title", help="Override the auto-generated title")
    pq.add_argument(
        "--ticket-name",
        help=(
            "Resource name (must be unique). Defaults to "
            "quota-{region}-{quota-type}-{new-limit}-{timestamp}"
        ),
    )
    pq.add_argument("--contact-email", help="Override signed-in user email")
    pq.add_argument("--contact-first-name", help="Override given name")
    pq.add_argument("--contact-last-name", help="Override surname")
    pq.add_argument(
        "--contact-method", default=DEFAULT_CONTACT["method"],
        choices=["email", "phone"],
    )
    pq.add_argument("--contact-language", default=DEFAULT_CONTACT["language"])
    pq.add_argument("--contact-timezone", default=DEFAULT_CONTACT["timezone"])
    pq.add_argument("--contact-country", default=DEFAULT_CONTACT["country"])
    pq.add_argument(
        "--dry-run", action="store_true",
        help="Print the az command without filing.",
    )
    pq.set_defaults(func=cmd_quota)

    pb = sub.add_parser("bump", help="Update an existing ticket's severity")
    common(pb)
    pb.add_argument(
        "--ticket-name", required=True,
        help=(
            "Ticket resource name OR display supportTicketId; the script "
            "resolves the latter via list."
        ),
    )
    pb.add_argument(
        "--severity", required=True,
        choices=["minimal", "moderate", "critical", "highestcriticalimpact"],
    )
    pb.add_argument("--dry-run", action="store_true")
    pb.set_defaults(func=cmd_bump)

    pl = sub.add_parser("list", help="List recent tickets")
    common(pl)
    pl.set_defaults(func=cmd_list)

    ps = sub.add_parser("show", help="Show one ticket")
    common(ps)
    ps.add_argument("--ticket-name", required=True)
    ps.set_defaults(func=cmd_show)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
