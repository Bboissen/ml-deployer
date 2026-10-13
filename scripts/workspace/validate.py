#!/usr/bin/env python3
"""Offline workspace 2.0.0 validation; never executes terminal argv or cloud APIs."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit

from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = json.loads((ROOT / "shared/workspace/schema.json").read_text())
VALIDATOR = Draft202012Validator(SCHEMA, format_checker=FormatChecker())
TOOLS = json.loads((ROOT / "shared/workspace/toolbox.json").read_text())
BINDINGS = ("provider", "account_scope", "region", "workspace_id")


class ContractError(ValueError):
    """A validation message containing only trusted descriptions."""


def require(condition, message):
    if not condition:
        raise ContractError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON field")
        result[key] = value
    return result


def reject_constant(_):
    raise ContractError("nonfinite JSON")


def load(path, kind):
    with Path(path).open() as stream:
        value = json.load(stream, object_pairs_hook=unique_object, parse_constant=reject_constant)
    # Errors omit values: untrusted input must not echo possible credentials.
    require(not list(VALIDATOR.iter_errors(value)), "closed schema/type/version validation failed")
    require(value["kind"] == kind, "wrong record kind")
    return value


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"),
                       ensure_ascii=False, allow_nan=False) + "\n").encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def instant(value):
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")


def location(uri, provider, prefix=False):
    require(not re.search(r"[\s%\\]", uri), "URI contains whitespace, escaping or encoded path")
    parsed = urlsplit(uri)
    require(not parsed.query and not parsed.fragment and not parsed.username
            and not parsed.password and parsed.port is None, "URI contains auth/query/port")
    require(provider == "aws" and parsed.scheme == "s3", "native URI/provider mismatch")
    require("//" not in parsed.path, "empty object path segment")
    require(re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", parsed.netloc), "invalid native bucket")
    parts = parsed.path.lstrip("/").rstrip("/").split("/")
    require(all(part and part not in (".", "..") for part in parts), "unsafe/empty object path")
    require(not prefix or uri.endswith("/"), "storage prefixes must end with slash")
    return parsed.netloc


def request_semantics(request):
    provider = request["provider"]
    scope = request["account_scope"]
    require(provider == "aws" and re.fullmatch(r"[0-9]{12}", scope), "invalid provider account scope")
    storage = request["storage"]
    data = location(storage["data_uri"], provider, prefix=True)
    output = location(storage["output_uri"], provider, prefix=True)
    state = location(storage["state_uri"], provider)
    require(state not in (data, output), "state and workload storage must be separate resources")
    require(not storage["data_uri"].startswith(storage["output_uri"])
            and not storage["output_uri"].startswith(storage["data_uri"]), "read/write prefixes overlap")


def handoff_semantics(request, handoff):
    require(all(request[k] == handoff[k] for k in BINDINGS), "handoff scope binding mismatch")
    require(handoff["request_sha256"] == digest(request), "handoff request hash mismatch")
    require(handoff["storage"] == request["storage"], "storage handoff changed reviewed scope")
    require(handoff["toolbox_profile"] == request["toolbox_profile"], "toolbox profile mismatch")
    require(handoff["user"] != "root", "project user must be non-root")
    require(all(part not in (".", "..", "") for part in handoff["project_directory"].split("/")[1:]),
            "unsafe project directory")
    identity = handoff["identity"]
    require(identity["mode"] == "instance_role", "native identity/provider mismatch")
    require(re.fullmatch(r"arn:aws:iam::" + request["account_scope"] + r":role/[A-Za-z0-9+=,.@_/-]+", identity["selector"]),
            "instance role/account mismatch")
    argv = handoff["terminal"]["argv"]
    require(handoff["terminal"]["method"] == "ssm" and argv[:3] == ["aws", "ssm", "start-session"],
            "terminal argv must describe an interactive native route")
    actions = ("terminate",)
    lifetime = handoff["lifetime"]
    started, expires, active = (instant(lifetime[k]) for k in ("started_at", "expires_at", "guard_active_at"))
    require(active <= started < expires, "guard must be active before compute starts")
    require((expires - started).total_seconds() <= request["maximum_runtime_minutes"] * 60,
            "absolute expiry exceeds reviewed maximum lifetime")
    require(lifetime["expiry_action"] in actions, "provider expiry action mismatch")


def readiness_semantics(request, handoff, readiness, require_ready):
    require(all(request[k] == readiness[k] for k in BINDINGS), "readiness scope binding mismatch")
    require(readiness["request_sha256"] == digest(request)
            and readiness["handoff_sha256"] == digest(handoff), "readiness artifact hash mismatch")
    observed = instant(readiness["observed_at"])
    require(instant(handoff["lifetime"]["started_at"]) <= observed
            < instant(handoff["lifetime"]["expires_at"]), "readiness outside workspace lifetime")
    for check in readiness["checks"].values():
        evidence = check["evidence"]
        expected = f'evidence/{request["provider"]}/{request["workspace_id"]}/'
        require(evidence.startswith(expected)
                and all(p and p not in (".", "..") for p in evidence.split("/")), "evidence scope/path mismatch")
    if readiness["checks"]["profile"]["status"] == "pass":
        require(all(readiness["resources"][k] >= v for k, v in request["resources"].items()),
                "observed profile below reviewed minimum")
    if readiness["checks"]["toolbox"]["status"] == "pass":
        require(re.fullmatch(re.escape(TOOLS["python_minor"]) + r"\.[0-9]+", readiness["versions"]["python"]),
                "unsupported Python runtime")
    if require_ready:
        require(all(c["status"] == "pass" for c in readiness["checks"].values()),
                "workspace readiness has failed or unverified checks")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("request", type=Path)
    parser.add_argument("--handoff", type=Path)
    parser.add_argument("--readiness", type=Path)
    parser.add_argument("--require-ready", action="store_true")
    args = parser.parse_args()
    require(not args.readiness or args.handoff, "readiness requires handoff")
    require(not args.require_ready or args.readiness, "require-ready needs readiness")
    request = load(args.request, "request")
    request_semantics(request)
    result = request
    if args.handoff:
        result = load(args.handoff, "handoff")
        handoff_semantics(request, result)
    if args.readiness:
        handoff = result
        result = load(args.readiness, "readiness")
        readiness_semantics(request, handoff, result, args.require_ready)
    sys.stdout.buffer.write(canonical(result))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        message = str(error) if isinstance(error, ContractError) else "unreadable or invalid input"
        print(f"workspace validation failed: {message}", file=sys.stderr)
        sys.exit(2)
