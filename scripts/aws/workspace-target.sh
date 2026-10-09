#!/usr/bin/env bash
# AWS-owned metadata/credential boundary; Python stays embedded to respect the
# foundation's existing repository layout checks. No third-party dependency.
set -euo pipefail
exec python3 - "$@" 3<&0 <<'PY'
import configparser
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

# Commands deliberately run from the repository root (also checked below).
REPO = Path.cwd().resolve()
BASE = REPO / "evidence" / "aws"


class Failure(Exception):
    pass


def require(condition, reason):
    if not condition:
        raise Failure(reason)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def digest(value):
    return hashlib.sha256(value).hexdigest()


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def inside(path):
    require(path.resolve().is_relative_to((REPO / "evidence").resolve()), "evidence path escapes repository evidence/")
    require((REPO / "evidence").resolve() == REPO / "evidence", "evidence root must not be a symlink")
    require(not any(p.is_symlink() for p in [path, *path.parents] if p.is_relative_to(REPO / "evidence")), "evidence symlink would reuse another scope")
    return path


def write(path, value):
    inside(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.open("x", encoding="utf-8") as f:
        json.dump(value, f, indent=2, sort_keys=True)
        f.write("\n")


def targets():
    config_path = os.environ.get("WORKSPACE_CONFIG")
    path = inside(Path(config_path).absolute()) if config_path else inside(BASE / "targets.json")
    require(path.is_file(), "missing evidence/aws/targets.json; copy and review infra/aws/targets.example.json")
    data = json.loads(path.read_text())
    if config_path:
        data = {"version": 1, "targets": {data["target_name"]: data["target"]}}
    require(set(data) == {"version", "targets"} and data["version"] == 1, "invalid target config version/fields")
    require(isinstance(data["targets"], dict) and data["targets"], "targets must be a nonempty object")
    for name, t in data["targets"].items():
        require(re.fullmatch(r"aws-[a-z0-9-]{1,40}", name), "invalid target alias")
        require(set(t) == {"profile", "account_id", "region", "operator_arn", "deployment_role_arn", "backend", "inventory"}, "missing or unknown target fields")
        require(all(isinstance(t[k], str) for k in ("profile", "account_id", "region", "operator_arn", "deployment_role_arn")), "target fields must be strings")
        require(re.fullmatch(r"[A-Za-z0-9_+=,.@-]+", t["profile"]) and t["profile"] != "default", "explicit non-default native profile required")
        require(re.fullmatch(r"[0-9]{12}", t["account_id"]), "account_id must have 12 digits")
        require(re.fullmatch(r"[a-z]{2}(-gov)?-[a-z]+-[0-9]+", t["region"]), "invalid region")
        arn = r"arn:(aws|aws-us-gov|aws-cn):iam::" + t["account_id"] + r":"
        require(re.fullmatch(arn + r"(user|role)/[A-Za-z0-9_+=,.@/-]+", t["operator_arn"]), "operator must be an exact account-native user or role ARN")
        require(re.fullmatch(arn + r"role/[A-Za-z0-9_+=,.@/-]+", t["deployment_role_arn"]), "deployment role must belong to expected account")
        b, inv = t["backend"], t["inventory"]
        require(set(b) == {"bucket", "region", "platform_key", "runner_prefix"}, "explicit backend scope required")
        require(all(isinstance(v, str) and v for v in b.values()), "backend fields must be nonempty strings")
        require(b["region"] == t["region"], "backend region must equal selected region")
        prefix = "aws/" + t["account_id"] + "/" + t["region"] + "/"
        require(b["platform_key"] == prefix + "platform/platform.tfstate" and b["runner_prefix"] == prefix + "runner/", "backend keys must match existing account/region root layout")
        require(re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", b["bucket"]), "invalid state bucket")
        require(set(inv) == {"resource_prefix", "buckets", "repositories", "roles", "policies", "schedule_groups"}, "explicit inventory fields required")
        require(isinstance(inv["resource_prefix"], str) and re.fullmatch(r"[a-z0-9-]{1,40}", inv["resource_prefix"]), "invalid inventory prefix")
        for k in ("buckets", "repositories", "roles", "policies", "schedule_groups"):
            require(isinstance(inv[k], list) and len(inv[k]) <= 20 and all(isinstance(v, str) and re.fullmatch(r"[A-Za-z0-9_+=,.@/-]+", v) for v in inv[k]), "invalid/broad inventory list")
        require(b["bucket"] not in inv["buckets"], "state and workload bucket lists must be separate")
    return data["targets"]


def check_environment():
    # Detect rather than silently discard credentials, alternate endpoints or
    # OpenTofu arguments that could invalidate the reviewed target.
    allowed = {"AWS_CONFIG_FILE", "AWS_SHARED_CREDENTIALS_FILE", "AWS_LOGIN_CACHE_DIRECTORY", "AWS_CA_BUNDLE"}
    conflicts = [k for k in os.environ if (k.startswith("AWS_") and k not in allowed)
                 or k.startswith("TF_VAR_") or k.startswith("TF_CLI_ARGS")
                 or k in {"TF_DATA_DIR", "TF_WORKSPACE", "TF_CLI_CONFIG_FILE", "BOTO_CONFIG"}]
    require(not conflicts, "conflicting environment sources: " + ", ".join(sorted(conflicts)))


def profile_documents():
    config = configparser.RawConfigParser()
    config.read(os.environ.get("AWS_CONFIG_FILE", str(Path.home() / ".aws/config")))
    credentials = configparser.RawConfigParser()
    credentials.read(os.environ.get("AWS_SHARED_CREDENTIALS_FILE", str(Path.home() / ".aws/credentials")))
    require(not config.defaults() and not credentials.defaults(), "implicit INI defaults rejected")
    return config, credentials


def profile_environment(profile_name, region):
    check_environment()
    config, credentials = profile_documents()
    seen = set()

    def profile(name):
        require(name != "default" and name not in seen, "implicit default or cyclic source profile")
        seen.add(name)
        section = "profile " + name
        cfg = dict(config.items(section)) if config.has_section(section) else {}
        cred = dict(credentials.items(name)) if credentials.has_section(name) else {}
        require(cfg or cred, "native profile is missing")
        require(not (cfg.keys() & cred.keys()), "conflicting config/credentials profile fields")
        p = {**cfg, **cred}
        require(not any(k in p for k in ("credential_source", "web_identity_token_file", "endpoint_url", "services", "aws_security_token")), "unsupported fallback or alternate endpoint in native profile")
        methods = sum(bool(p.get(k)) for k in ("source_profile", "credential_process", "login_session", "sso_session", "aws_access_key_id"))
        if p.get("sso_start_url") and not p.get("sso_session"):
            methods += 1
        require(methods == 1, "missing or conflicting native credential sources")
        if p.get("aws_access_key_id"):
            require(p.get("aws_session_token") and p.get("aws_secret_access_key"), "long-lived or incomplete credential profile rejected")
        else:
            require(not any(k in p for k in ("aws_secret_access_key", "aws_session_token")), "conflicting credential material")
        if p.get("source_profile"):
            require(p.get("role_arn"), "source_profile requires role_arn")
            profile(p["source_profile"])
        else:
            require(not p.get("role_arn"), "role profile requires explicit source_profile")
    profile(profile_name)
    e = os.environ.copy()
    e.update(AWS_PROFILE=profile_name, AWS_DEFAULT_PROFILE=profile_name,
             AWS_REGION=region, AWS_DEFAULT_REGION=region, AWS_SDK_LOAD_CONFIG="1",
             AWS_EC2_METADATA_DISABLED="true", AWS_PAGER="", AWS_MAX_ATTEMPTS="1")
    return e


def environment(t):
    e = profile_environment(t["profile"], t["region"])
    e.update(TF_VAR_aws_account_id=t["account_id"], TF_VAR_aws_region=t["region"],
             TF_VAR_deployer_role_arn=t["deployment_role_arn"], TF_WORKSPACE="default")
    return e


def error_category(stderr):
    low = stderr.lower()
    if any(v in low for v in ("expired", "login again", "refresh failed", "invalidgrant")):
        return "expired_login"
    if any(v in low for v in ("nosuchentity", "nosuchbucket", "nosuchkey", "repositorynotfoundexception", "(404)")):
        return "resource_lookup_unknown"
    if any(v in low for v in ("unable to locate credentials", "token does not exist", "error loading sso token", "credentialretrievalerror")):
        return "missing_login"
    if any(v in low for v in ("accessdenied", "unauthorized", "forbidden")):
        return "permission_unknown"
    return "request_failed_unknown"


def request(cmd, e, seconds):
    # Also bound native credential_process descendants, which can retain pipe
    # descriptors after their AWS CLI parent is killed.
    p = subprocess.Popen(cmd, env=e, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, start_new_session=True)
    try:
        out, err = p.communicate(timeout=seconds)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        p.communicate(timeout=2)
        raise
    return subprocess.CompletedProcess(cmd, p.returncode, out, err)


def aws(t, e, args, query=None, seconds=20):
    cmd = ["aws", "--profile", t["profile"], "--region", t["region"], "--no-cli-pager",
           "--cli-connect-timeout", "5", "--cli-read-timeout", "10", "--no-paginate", *args, "--output", "json"]
    if query:
        cmd += ["--query", query]
    try:
        p = request(cmd, e, seconds)
        if p.returncode:
            return {"status": "unknown", "error": error_category(p.stderr)}
        return {"status": "observed", "data": json.loads(p.stdout)}
    except subprocess.TimeoutExpired:
        return {"status": "unknown", "error": "timeout"}


def identity(t, e):
    result = aws(t, e, ["sts", "get-caller-identity"], "{account:Account,arn:Arn}")
    require(result["status"] == "observed", "authentication failed: " + result.get("error", "unknown"))
    observed = result["data"]
    require(observed["account"] == t["account_id"], "account mismatch; no inventory/context/command allowed")
    expected, actual = t["operator_arn"], observed["arn"]
    matches = actual == expected
    if ":role/" in expected:
        role = expected.rsplit("/", 1)[1]
        sts_prefix = expected.split(":iam:")[0] + ":sts::" + t["account_id"] + ":assumed-role/" + role + "/"
        matches = actual.startswith(sts_prefix) and bool(actual[len(sts_prefix):])
    require(matches, "operator identity mismatch; no inventory/context/command allowed")
    return observed


def source():
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    changes = subprocess.check_output(["git", "diff", "HEAD", "--", "."])
    for name in subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard"], text=True).splitlines():
        p = REPO / name
        require(p.is_file() and not p.is_symlink(), "source contains unsupported untracked entry")
        changes += name.encode() + b"\0" + p.read_bytes()
    return {"revision": revision, "working_tree_sha256": digest(changes)}


def context(name, t, root):
    require(root in {"platform", "runner"}, "bootstrap retains its existing local state; no migration supported")
    src = source()
    binding = {"target": name, "configuration": t, "source": src, "root": root}
    path = inside(BASE / name / digest(canonical(t)) / "contexts" / digest(canonical(binding)))
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Context preparation never initializes OpenTofu or reads/writes its state.
    key = t["backend"]["platform_key"] if root == "platform" else t["backend"]["runner_prefix"]
    info = {**binding, "binding_sha256": digest(canonical(binding)), "data_dir": str(path / "tofu-data"),
            "provider_environment": {"AWS_PROFILE": t["profile"], "AWS_REGION": t["region"],
                                     "TF_VAR_aws_account_id": t["account_id"], "TF_VAR_aws_region": t["region"],
                                     "TF_VAR_deployer_role_arn": t["deployment_role_arn"], "TF_DATA_DIR": str(path / "tofu-data"),
                                     "TF_WORKSPACE": "default"},
            "backend": {"bucket": t["backend"]["bucket"], "key_or_prefix": key,
                        "region": t["region"], "profile": t["profile"], "allowed_account_ids": [t["account_id"]],
                        "encrypt": True, "use_lockfile": True},
            "planning": "closed until workspace roots and exact runner key/role checks are reviewed"}
    if not (path / "binding.json").exists():
        write(path / "binding.json", info)
    else:
        require(json.loads((path / "binding.json").read_text()) == info, "existing context binding changed")
    if root == "platform":
        backend_path = path / "backend.hcl"
        backend_text = "\n".join(k + " = " + json.dumps(v) for k, v in {
            "bucket": t["backend"]["bucket"], "key": key, "region": t["region"],
            "profile": t["profile"], "allowed_account_ids": [t["account_id"]],
            "encrypt": True, "use_lockfile": True}.items()) + "\n"
        if not backend_path.exists():
            inside(backend_path)
            with backend_path.open("x") as f:
                f.write(backend_text)
        else:
            require(backend_path.read_text() == backend_text, "existing backend selection changed")
    return info


def preflight(name, t, e, path, ident):
    started = time.monotonic()
    results = []
    inv, backend = t["inventory"], t["backend"]

    def read(label, args, query):
        if time.monotonic() - started >= 160:
            r = {"status": "unknown", "error": "collection_time_bound"}
        else:
            r = aws(t, e, args, query, seconds=min(20, max(1, 180 - (time.monotonic() - started))))
        r.update(check=label, observed_at=now(), argv=args, query=query)
        write(path / (label + ".json"), r)
        results.append({k: v for k, v in r.items() if k != "data"})
        return r

    read("regions", ["ec2", "describe-regions", "--all-regions", "--region-names", t["region"]], "Regions[].{name:RegionName,opt_in:OptInStatus}")
    read("zones", ["ec2", "describe-availability-zones"], "AvailabilityZones[].{zone:ZoneName,state:State,opt_in:OptInStatus}")
    read("quota-cpu", ["service-quotas", "get-service-quota", "--service-code", "ec2", "--quota-code", "L-1216C47A"], "Quota.{name:QuotaName,value:Value,adjustable:Adjustable}")
    read("instances", ["ec2", "describe-instances", "--max-results", "100"], "{items:Reservations[].Instances[].{id:InstanceId,state:State.Name,type:InstanceType,launch:LaunchTime,profile:IamInstanceProfile.Arn,volumes:BlockDeviceMappings[].Ebs.VolumeId,ownership:Tags[?Key=='Project'||Key=='Root'||Key=='Deployment'||Key=='ManagedBy']},next:NextToken}")
    read("volumes", ["ec2", "describe-volumes", "--max-results", "100"], "{items:Volumes[].{id:VolumeId,state:State,size:Size,attachments:Attachments[].{instance:InstanceId,state:State},ownership:Tags[?Key=='Project'||Key=='Root'||Key=='Deployment'||Key=='ManagedBy']},next:NextToken}")
    read("addresses", ["ec2", "describe-addresses"], "Addresses[].{allocation:AllocationId,association:AssociationId,instance:InstanceId,interface:NetworkInterfaceId}")
    read("vpcs", ["ec2", "describe-vpcs", "--max-results", "100"], "{items:Vpcs[].{id:VpcId,default:IsDefault,ownership:Tags[?Key=='Project'||Key=='Root'||Key=='ManagedBy']},next:NextToken}")
    read("subnets", ["ec2", "describe-subnets", "--max-results", "100"], "{items:Subnets[].{id:SubnetId,vpc:VpcId,zone:AvailabilityZone,ownership:Tags[?Key=='Project'||Key=='Root'||Key=='ManagedBy']},next:NextToken}")
    read("security-groups", ["ec2", "describe-security-groups", "--max-results", "100"], "{items:SecurityGroups[].{id:GroupId,vpc:VpcId,name:GroupName},next:NextToken}")
    read("gateways", ["ec2", "describe-internet-gateways", "--max-results", "100"], "{items:InternetGateways[].{id:InternetGatewayId,attachments:Attachments},next:NextToken}")
    read("routes", ["ec2", "describe-route-tables", "--max-results", "100"], "{items:RouteTables[].{id:RouteTableId,vpc:VpcId,associations:Associations[].{id:RouteTableAssociationId,subnet:SubnetId,main:Main}},next:NextToken}")
    for i, group in enumerate(inv["schedule_groups"]):
        schedules = read(f"schedules-{i}", ["scheduler", "list-schedules", "--group-name", group, "--max-results", "100"], "{items:Schedules[].{name:Name,arn:Arn,state:State,target:Target.Arn},next:NextToken}")
        for j, schedule in enumerate((schedules.get("data") or {}).get("items", [])[:10]):
            read(f"schedule-detail-{i}-{j}", ["scheduler", "get-schedule", "--group-name", group, "--name", schedule["name"]], "{arn:Arn,state:State,expression:ScheduleExpression,timezone:ScheduleExpressionTimezone,window:FlexibleTimeWindow,role:Target.RoleArn,target:Target.Arn,retry:Target.RetryPolicy}")
    for i, role in enumerate(inv["roles"]):
        read(f"role-{i}", ["iam", "get-role", "--role-name", role], "Role.{name:RoleName,arn:Arn,boundary:PermissionsBoundary.PermissionsBoundaryArn,created:CreateDate}")
        read(f"role-attached-{i}", ["iam", "list-attached-role-policies", "--role-name", role, "--max-items", "100"], "{items:AttachedPolicies,more:IsTruncated,marker:Marker}")
        read(f"role-inline-{i}", ["iam", "list-role-policies", "--role-name", role, "--max-items", "100"], "{items:PolicyNames,more:IsTruncated,marker:Marker}")
    read("roles", ["iam", "list-roles", "--max-items", "100"], "{items:Roles[].{name:RoleName,arn:Arn,boundary:PermissionsBoundary.PermissionsBoundaryArn},more:IsTruncated,marker:Marker}")
    for i, policy in enumerate(inv["policies"]):
        partition = t["operator_arn"].split(":")[1]
        read(f"policy-{i}", ["iam", "get-policy", "--policy-arn", f"arn:{partition}:iam::{t['account_id']}:policy/{policy}"], "Policy.{arn:Arn,version:DefaultVersionId,attachments:AttachmentCount,boundaries:PermissionsBoundaryUsageCount}")
    for i, bucket in enumerate([backend["bucket"], *inv["buckets"]]):
        owner = ["--bucket", bucket, "--expected-bucket-owner", t["account_id"]]
        read(f"bucket-location-{i}", ["s3api", "get-bucket-location", *owner], "{location:LocationConstraint}")
        read(f"bucket-versioning-{i}", ["s3api", "get-bucket-versioning", *owner], "{status:Status}")
        read(f"bucket-protection-{i}", ["s3api", "get-public-access-block", *owner], "PublicAccessBlockConfiguration")
        if i > 0:
            read(f"bucket-content-metadata-{i}", ["s3api", "list-object-versions", *owner, "--max-keys", "100"], "{versions:Versions[].{key:Key,version:VersionId,latest:IsLatest,size:Size},delete_markers:length(DeleteMarkers || `[]`),more:IsTruncated}")
    read("regional-buckets", ["s3api", "list-buckets", "--bucket-region", t["region"], "--max-buckets", "100"], "{items:Buckets[].{name:Name,created:CreationDate},next:ContinuationToken}")
    read("platform-state-versions", ["s3api", "list-object-versions", "--bucket", backend["bucket"], "--prefix", backend["platform_key"], "--max-keys", "100", "--expected-bucket-owner", t["account_id"]], "{versions:Versions[].{key:Key,version:VersionId,latest:IsLatest,size:Size},deleted:DeleteMarkers[].{key:Key,version:VersionId,latest:IsLatest},more:IsTruncated}")

    def state_summary(label, key):
        head = read(label + "-head", ["s3api", "head-object", "--bucket", backend["bucket"], "--key", key, "--expected-bucket-owner", t["account_id"]], "{version:VersionId,size:ContentLength,modified:LastModified,etag:ETag}")
        metadata = head.get("data") or {}
        summary = {"status": "unknown", "error": "state_metadata_unavailable"}
        if metadata.get("version") and 0 < metadata.get("size", 0) <= 2097152 and time.monotonic() - started < 160:
            # The exact version is read into memory only. Never persist complete
            # state, outputs, attributes or credential-process stderr in logs.
            cmd = ["aws", "--profile", t["profile"], "--region", t["region"], "--no-cli-pager",
                   "--cli-connect-timeout", "5", "--cli-read-timeout", "10", "s3api", "get-object",
                   "--bucket", backend["bucket"], "--key", key, "--version-id", metadata["version"],
                   "--expected-bucket-owner", t["account_id"], "--range", "bytes=0-2097151", "/dev/stdout", "--query", "null", "--output", "json"]
            try:
                p = request(cmd, e, 20)
                if p.returncode:
                    summary = {"status": "unknown", "error": error_category(p.stderr)}
                else:
                    state, _ = json.JSONDecoder().raw_decode(p.stdout.lstrip())
                    safe_types = {"aws_s3_bucket", "aws_iam_role", "aws_iam_role_policy", "aws_iam_policy", "aws_iam_instance_profile", "aws_ecr_repository", "aws_instance", "aws_scheduler_schedule", "aws_vpc", "aws_subnet", "aws_security_group", "aws_internet_gateway", "aws_route_table", "aws_route_table_association", "aws_ebs_volume", "aws_eip"}
                    resources = []
                    for resource in state.get("resources", []):
                        if resource.get("mode") != "managed":
                            continue
                        for instance in resource.get("instances", []):
                            item = {"type": resource["type"], "name": resource["name"], "index": instance.get("index_key"), "module": resource.get("module")}
                            if resource["type"] in safe_types:
                                item["id"] = instance.get("attributes", {}).get("id")
                            resources.append(item)
                    summary = {"status": "observed", "lineage": state.get("lineage"), "serial": state.get("serial"), "resources": resources}
            except (subprocess.TimeoutExpired, ValueError, KeyError, TypeError):
                summary = {"status": "unknown", "error": "state_read_failed_or_timed_out"}
        summary.update(check=label + "-summary", bucket=backend["bucket"], key=key, version=metadata.get("version"), observed_at=now())
        write(path / (label + "-summary.json"), summary)
        results.append({k: v for k, v in summary.items() if k != "resources"})

    state_summary("platform-state", backend["platform_key"])
    versions = read("runner-state-versions", ["s3api", "list-object-versions", "--bucket", backend["bucket"], "--prefix", backend["runner_prefix"], "--max-keys", "100", "--expected-bucket-owner", t["account_id"]], "{versions:Versions[].{key:Key,version:VersionId,latest:IsLatest,size:Size,modified:LastModified},deleted:DeleteMarkers[].{key:Key,version:VersionId,latest:IsLatest},more:IsTruncated}")
    keys = sorted({v["key"] for v in (versions.get("data") or {}).get("versions", []) if v.get("latest") and v["key"].startswith(backend["runner_prefix"]) and v["key"].endswith(".tfstate")})
    for i, key in enumerate(keys[:10]):
        state_summary(f"runner-state-{i}", key)
    read("regional-registries", ["ecr", "describe-repositories", "--registry-id", t["account_id"], "--max-results", "100"], "{items:repositories[].{arn:repositoryArn,name:repositoryName},next:nextToken}")
    for i, repo in enumerate(inv["repositories"]):
        read(f"registry-{i}", ["ecr", "describe-repositories", "--registry-id", t["account_id"], "--repository-names", repo], "repositories[].{arn:repositoryArn,name:repositoryName,mutability:imageTagMutability,created:createdAt}")
        read(f"registry-images-{i}", ["ecr", "list-images", "--registry-id", t["account_id"], "--repository-name", repo, "--max-results", "100"], "{items:imageIds[].imageDigest,next:nextToken}")
    return {"status": "read_only_collection_complete", "identity": ident, "checks": results,
            "coverage": "one bounded page per listing; at most ten runner state/schedule details; 2 MiB per state; continuation or limits mean incomplete; errors are unknown, never absence",
            "deployment_rights": "unverified", "native_workspace_acceptance": "unverified"}


def main():
    os.umask(0o077)
    require((REPO / "infra/aws/platform/provider.tf").is_file(), "run from repository root")
    args = sys.argv[1:]
    require(args, "usage: bash scripts/aws/workspace-target.sh list | identity TARGET | preflight TARGET | context TARGET platform|runner | exec TARGET -- COMMAND...")
    ts = targets()
    if args == ["list"]:
        print(json.dumps([{ "target": n, "profile": t["profile"], "account_id": t["account_id"], "region": t["region"]} for n, t in sorted(ts.items())], indent=2))
        return
    action = args[0]
    require(action in {"identity", "preflight", "context", "exec"} and len(args) >= 2, "unknown action or missing explicit target")
    name = args[1]
    require(name in ts, "unknown target; no default fallback")
    require((action in {"identity", "preflight"} and len(args) == 2)
            or (action == "context" and len(args) == 3)
            or (action == "exec" and len(args) >= 4 and args[2] == "--"), "invalid action arguments")
    t = ts[name]
    run = inside(BASE / name / digest(canonical(t)) / "checks" / (dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ") + f"-{os.getpid()}"))
    binding = {"target": name, "configuration": t, "source": source(), "started_at": now()}
    write(run / "scope.json", binding)
    try:
        e = environment(t)
        ident = identity(t, e)
        write(run / "identity.json", ident)
        if action == "identity":
            result = {"status": "authenticated", "identity": ident, "deployment_rights": "unverified"}
        elif action == "preflight":
            result = preflight(name, t, e, run, ident)
        elif action == "context":
            result = context(name, t, args[2])
        else:
            cmd = args[3:]
            # OpenTofu roots are still historical. Do not provide an alternate
            # entry point for init/plan/apply/state commands before their review.
            require(Path(cmd[0]).name not in {"tofu", "terraform"}, "OpenTofu execution closed at milestone A; use context for reviewed metadata")
            if Path(cmd[0]).name == "aws":
                forbidden = ("--profile", "--region", "--endpoint-url", "--no-sign-request", "--cli-input-json", "--cli-input-yaml")
                # AWS CLI accepts long-option prefixes, with separate or = values.
                options = (a.split("=", 1)[0] for a in cmd[1:] if a.startswith("--"))
                require(not any(flag.startswith(option) for option in options for flag in forbidden), "command overrides selected AWS target")
            result = {"status": "authenticated_command_context", "identity": ident, "deployment_rights": "unverified"}
            write(run / "result.json", result)
            os.dup2(3, 0)
            os.close(3)
            os.execvpe(cmd[0], cmd, e)
        result["evidence"] = str(run.relative_to(REPO))
        write(run / "result.json", result)
        print(json.dumps(result, indent=2))
    except Failure as exc:
        write(run / "result.json", {"status": "blocked", "reason": str(exc), "observed_at": now(), "deployment_rights": "unverified"})
        raise


try:
    main()
except (Failure, ValueError, KeyError, TypeError, OSError, configparser.Error) as exc:
    # Raw AWS/credential-process stderr is intentionally never logged.
    print("aws-workspace-target: FAIL: " + (str(exc) if isinstance(exc, Failure) else type(exc).__name__), file=sys.stderr)
    sys.exit(2)
PY
