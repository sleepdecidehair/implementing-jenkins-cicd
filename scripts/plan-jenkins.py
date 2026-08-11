#!/usr/bin/env python3
"""Create and verify deterministic, approval-bound Jenkins change plans."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Any, NoReturn
from urllib.parse import urlparse


PLAN_SCHEMA_VERSION = 1
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
SAFE_IMAGE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@-]{0,255}$")
SAFE_HOST = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.@:-]{0,254}$")
SAFE_PLUGIN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}:[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$")
SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent
PLAN_BOUND_SCRIPTS = (
    "apply-jenkins-job.sh",
    "bootstrap-jenkins-cli-profile.sh",
    "configure-jenkins-plugins.sh",
    "install-jenkins-docker.sh",
    "jenkins-cli-safe.sh",
    "orchestrate-jenkins-delivery.sh",
    "plan-jenkins.py",
    "render-jenkins-assets.py",
    "verify-jenkins-delivery.sh",
)


def fail(message: str) -> NoReturn:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(2)


def canonical(payload: dict[str, Any]) -> bytes:
    clean = dict(payload)
    clean.pop("plan_id", None)
    return json.dumps(clean, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def plan_identifier(payload: dict[str, Any]) -> str:
    return hashlib.sha256(canonical(payload)).hexdigest()


def renderer_fingerprint() -> dict[str, str]:
    renderer = SCRIPT_DIR / "render-jenkins-assets.py"
    assets = sorted(path for path in (SKILL_DIR / "assets").rglob("*") if path.is_file())
    digest = hashlib.sha256()
    for path in assets:
        digest.update(path.relative_to(SKILL_DIR).as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    script_digest = hashlib.sha256()
    for name in PLAN_BOUND_SCRIPTS:
        path = SCRIPT_DIR / name
        script_digest.update(name.encode("utf-8"))
        script_digest.update(b"\0")
        script_digest.update(path.read_bytes())
        script_digest.update(b"\0")
    return {
        "renderer_sha256": hashlib.sha256(renderer.read_bytes()).hexdigest(),
        "assets_sha256": digest.hexdigest(),
        "scripts_sha256": script_digest.hexdigest(),
    }


def verify_tooling(payload: dict[str, Any]) -> None:
    expected = payload.get("tooling")
    if not isinstance(expected, dict) or expected != renderer_fingerprint():
        fail("plan-bound tooling changed after plan creation; create and approve a new plan")


def read_json(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"cannot read JSON {path}: {error}")
    if not isinstance(payload, dict):
        fail(f"JSON root must be an object: {path}")
    return payload


def atomic_write(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, ensure_ascii=False, indent=2, sort_keys=True)
            stream.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def validate_url(value: str, name: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        fail(f"{name} must be an absolute HTTP or HTTPS URL")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        fail(f"{name} must not contain credentials, a query, or a fragment")
    return value.rstrip("/")


def validate_name(value: str, name: str) -> str:
    if not SAFE_NAME.fullmatch(value):
        fail(f"{name} contains unsupported characters: {value}")
    return value


def validate_pinned_image(value: str, name: str) -> str:
    if not SAFE_IMAGE.fullmatch(value):
        fail(f"{name} contains unsupported characters")
    if re.search(r"@sha256:[0-9a-fA-F]{64}$", value):
        return value
    final_component = value.rsplit("/", 1)[-1]
    if ":" not in final_component:
        fail(f"{name} must use a versioned tag or sha256 digest")
    tag = final_component.rsplit(":", 1)[1]
    if re.search(r"\d+\.\d+", tag) is None:
        fail(f"{name} must not use a mutable latest, lts, or runtime-only tag")
    return value


def locked_plugins() -> list[str]:
    path = SKILL_DIR / "assets" / "plugins.lock.txt"
    try:
        plugins = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip() and not line.startswith("#")]
    except (OSError, UnicodeDecodeError) as error:
        fail(f"cannot read plugin lock: {error}")
    if not plugins or any(SAFE_PLUGIN.fullmatch(plugin) is None for plugin in plugins):
        fail("plugin lock must contain artifactId:version entries only")
    names = [plugin.split(":", 1)[0] for plugin in plugins]
    if len(names) != len(set(names)):
        fail("plugin lock contains duplicate artifact IDs")
    return sorted(plugins)


def credential_source(value: str | None, name: str) -> dict[str, str]:
    if not value:
        return {"path": "", "sha256": ""}
    path = Path(value).expanduser().resolve()
    if not path.is_file() or path.is_symlink():
        fail(f"{name} must be a regular file")
    if path.stat().st_size > 1024 * 1024 or path.stat().st_size == 0:
        fail(f"{name} is empty or unexpectedly large")
    if path.stat().st_mode & 0o077:
        fail(f"{name} must not be accessible by group or other users")
    return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def create_plan(arguments: argparse.Namespace) -> dict[str, Any]:
    discovery_path = arguments.discovery.expanduser().resolve()
    discovery = read_json(discovery_path)
    if discovery.get("schema_version") != 1:
        fail("unsupported discovery schema")
    project = discovery.get("project")
    applications = discovery.get("applications")
    if not isinstance(project, dict) or not isinstance(applications, list):
        fail("discovery is missing project or applications")
    selected_applications = applications
    if arguments.app_root:
        requested_roots = set(arguments.app_root)
        known_roots = {str(item.get("root")) for item in applications if isinstance(item, dict)}
        missing_roots = sorted(requested_roots - known_roots)
        if missing_roots:
            fail(f"requested application roots were not discovered: {', '.join(missing_roots)}")
        selected_applications = [
            item for item in applications if isinstance(item, dict) and str(item.get("root")) in requested_roots
        ]
    umbrella_root = Path(str(project.get("root"))).expanduser().resolve()
    build_applications = [
        item
        for item in selected_applications
        if isinstance(item, dict) and item.get("type") != "docker" and item.get("commands")
    ]
    discovered_repository_roots = {
        str(item.get("git", {}).get("repository_root"))
        for item in build_applications
        if isinstance(item.get("git"), dict) and item.get("git", {}).get("repository_root")
    }
    if len(discovered_repository_roots) == 1:
        source_root = Path(next(iter(discovered_repository_roots))).expanduser().resolve()
    elif len(build_applications) == 1:
        selected_root = str(build_applications[0].get("root") or ".")
        source_root = umbrella_root if selected_root == "." else (umbrella_root / selected_root).resolve()
    else:
        source_root = umbrella_root
    plan_applications: list[dict[str, Any]] = []
    application_outside_source = False
    for item in selected_applications:
        if not isinstance(item, dict):
            continue
        copied = json.loads(json.dumps(item))
        item_root = str(item.get("root") or ".")
        absolute_root = umbrella_root if item_root == "." else (umbrella_root / item_root).resolve()
        try:
            normalized_root = absolute_root.relative_to(source_root).as_posix()
            copied["root"] = normalized_root or "."
        except ValueError:
            application_outside_source = True
        plan_applications.append(copied)
    job_name = validate_name(arguments.job or str(project.get("name") or "project"), "job name")
    credentials_id = "" if arguments.scm_public else arguments.credentials_id
    if credentials_id:
        validate_name(credentials_id, "SCM credentials ID")
    validate_name(arguments.deployment_credentials_id, "deployment credentials ID")
    validate_name(arguments.scm_ssh_user, "SCM SSH user")
    validate_name(arguments.deployment_ssh_user, "deployment SSH user")
    validate_name(arguments.agent_label, "agent label")
    arguments.image = validate_pinned_image(arguments.image, "controller image")
    arguments.agent_image = validate_pinned_image(arguments.agent_image, "agent image")
    port = arguments.port
    if port < 1 or port > 65535:
        fail("port must be between 1 and 65535")
    if arguments.retention < 2:
        fail("release retention may not be lower than two")
    if arguments.target == "ssh" and not arguments.ssh_target:
        fail("--ssh-target is required for an SSH controller target")
    if arguments.target == "local" and arguments.ssh_target:
        fail("--ssh-target is only valid with --target ssh")
    jenkins_url = validate_url(arguments.jenkins_url, "Jenkins URL")
    health_default = validate_url(arguments.health_url, "health URL") if arguments.health_url else ""
    test_health = validate_url(arguments.test_health_url, "test health URL") if arguments.test_health_url else health_default
    production_health = (
        validate_url(arguments.production_health_url, "production health URL")
        if arguments.production_health_url
        else health_default
    )
    git = project.get("git") if isinstance(project.get("git"), dict) else {}
    discovered_remotes = {
        str(item.get("git", {}).get("remote"))
        for item in build_applications
        if isinstance(item.get("git"), dict) and item.get("git", {}).get("remote")
    }
    repo_url = arguments.repo_url or (next(iter(discovered_remotes)) if len(discovered_remotes) == 1 else "") or git.get("remote") or ""
    scm_key_source = credential_source(arguments.scm_key_file, "SCM SSH private key")
    deployment_key_source = credential_source(arguments.deployment_key_file, "deployment SSH private key")
    deploy_base = Path(arguments.deploy_root)
    test_root = arguments.test_deploy_root or str(deploy_base / "test")
    production_root = arguments.production_deploy_root or str(deploy_base / "production")
    for root_name, root_value in (("test deploy root", test_root), ("production deploy root", production_root)):
        if not root_value.startswith("/") or not re.fullmatch(r"/[A-Za-z0-9_./-]+", root_value) or root_value in {"/", str(Path.home())}:
            fail(f"{root_name} must be a safe absolute path")
    if arguments.allow_agent_local_deploy:
        test_host = "local"
        production_host = "local"
    else:
        test_host = arguments.test_deploy_host or ""
        production_host = arguments.production_deploy_host or ""
    for host_name, host_value in (("test deploy host", test_host), ("production deploy host", production_host)):
        if host_value and host_value != "local" and not SAFE_HOST.fullmatch(host_value):
            fail(f"{host_name} contains unsupported characters")
    questions = list(discovery.get("questions") or [])
    if len(discovered_repository_roots) > 1 or len(discovered_remotes) > 1:
        questions.append("Selected applications span multiple Git repositories; create one Jenkins plan per repository.")
    if application_outside_source:
        questions.append("A selected application is outside the resolved source repository root.")
    parsed_jenkins_url = urlparse(jenkins_url)
    if parsed_jenkins_url.scheme == "http" and parsed_jenkins_url.hostname not in {"localhost", "127.0.0.1", "::1"}:
        questions.append("Credential-bearing Jenkins CLI access requires HTTPS or a loopback SSH tunnel; public HTTP is refused.")
    build_roots = sorted(
        {
            str(item.get("root"))
            for item in plan_applications
            if isinstance(item, dict) and item.get("type") != "docker" and item.get("commands")
        }
    )
    if not arguments.app_root and len(build_roots) > 1:
        questions.append(
            "Multiple deployable application roots were found; select --app-root for the intended Jenkins job: "
            + ", ".join(build_roots)
        )
    if not build_roots:
        questions.append("The selected application roots have no authoritative non-container build command.")
    artifact_outputs = sorted(
        {
            str(candidate)
            for item in plan_applications
            if isinstance(item, dict) and item.get("type") != "docker"
            for candidate in (item.get("artifact_candidates") or [])
            if isinstance(candidate, str) and candidate and not candidate.startswith("container-image:")
        }
    )
    if build_roots and not artifact_outputs:
        questions.append(
            "The selected application has no authoritative deployment artifact output; "
            "record a project-owned output path or choose Server Pull before apply."
        )
    if not repo_url:
        questions.append("Repository URL is unknown; provide the SCM URL before job creation.")
    if repo_url and not arguments.scm_public and not scm_key_source["path"] and not arguments.credentials_preconfigured:
        questions.append("Repository access requires --scm-key-file, --scm-public, or confirmation that its credential ID is preconfigured.")
    if not test_health:
        questions.append("Test health URL is unknown; provide it before the first test deployment.")
    if not production_health:
        questions.append("Production health URL is unknown; provide it before production deployment.")
    if not test_host:
        questions.append("Test deployment host is unknown; provide --test-deploy-host or explicitly allow agent-local deployment.")
    if not production_host:
        questions.append("Production deployment host is unknown; provide --production-deploy-host or explicitly allow agent-local deployment.")
    if not arguments.activation_confirmed:
        questions.append(
            "Confirm that the service or proxy consumes DEPLOY_ROOT/current, and provide activation commands when a restart or reload is required."
        )
    runtime_requirements = sorted(
        {
            f"{item.get('root')}:{name}={value}"
            for item in plan_applications
            if isinstance(item, dict)
            for name, value in (item.get("runtime_requirements") or {}).items()
        }
    )
    if runtime_requirements and not arguments.agent_toolchain_confirmed:
        questions.append(
            "The managed agent toolchain must be pinned to the discovered runtime requirements before apply: "
            + ", ".join(runtime_requirements)
        )
    known_hosts_text = ""
    known_hosts_sha256 = ""
    if arguments.deployment_known_hosts:
        known_hosts_path = Path(arguments.deployment_known_hosts).expanduser().resolve()
        if not known_hosts_path.is_file() or known_hosts_path.is_symlink():
            fail("deployment known_hosts must be a regular file")
        if known_hosts_path.stat().st_size > 1024 * 1024:
            fail("deployment known_hosts file is unexpectedly large")
        try:
            known_hosts_text = known_hosts_path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as error:
            fail(f"cannot read deployment known_hosts: {error}")
        if not known_hosts_text.strip():
            fail("deployment known_hosts file is empty")
        known_hosts_sha256 = hashlib.sha256(known_hosts_text.encode("utf-8")).hexdigest()
    elif any(host and host != "local" for host in (test_host, production_host)):
        questions.append("Verified SSH host keys are required for remote deployment; provide --deployment-known-hosts.")
    if any(host and host != "local" for host in (test_host, production_host)) and not deployment_key_source["path"] and not arguments.credentials_preconfigured:
        questions.append("Remote deployment requires --deployment-key-file or confirmation that its credential ID is preconfigured.")

    discovery_digest = hashlib.sha256(canonical(discovery)).hexdigest()
    project_root = source_root
    project_targets = [
        "Jenkinsfile",
        "ops/jenkins/deploy.sh",
        "ops/jenkins/activate.sh",
        "ops/jenkins/health-check.sh",
        "ops/jenkins/rollback.sh",
        "ops/jenkins/cleanup-releases.sh",
        "ops/jenkins/trigger-deploy.sh",
    ]
    target_hashes: dict[str, str | None] = {}
    for target_name in project_targets:
        target_path = project_root / target_name
        if target_path.is_file() and not target_path.is_symlink():
            target_hashes[target_name] = hashlib.sha256(target_path.read_bytes()).hexdigest()
        elif target_path.exists():
            fail(f"project target is not a regular file: {target_path}")
        else:
            target_hashes[target_name] = None
    plan: dict[str, Any] = {
        "schema_version": PLAN_SCHEMA_VERSION,
        "discovery": {
            "path": str(discovery_path),
            "sha256": discovery_digest,
            "project_root": str(source_root),
            "umbrella_root": str(umbrella_root),
            "project_name": project.get("name"),
            "applications": plan_applications,
        },
        "controller": {
            "target": arguments.target,
            "ssh_target": arguments.ssh_target,
            "url": jenkins_url,
            "http_port": port,
            "install_dir": str(Path(arguments.install_dir).expanduser().resolve()),
            "image": arguments.image,
            "agent_image": arguments.agent_image,
            "java_line": 21,
            "docker_socket_mount": False,
            "bootstrap_executors": 0,
            "managed_agent": True,
            "agent_name": "jenkins-agent",
            "agent_label": arguments.agent_label,
            "agent_toolchain": {"java": 21, "node": arguments.node_version, "maven": arguments.maven_version},
        },
        "job": {
            "name": job_name,
            "type": "managed-pipeline",
            "repository_url": repo_url,
            "credentials_id": credentials_id,
            "jenkinsfile": "Jenkinsfile",
            "trigger_mode": "project-script-only",
            "automatic_scm_trigger": False,
            "branch_environment_map": {
                arguments.test_branch: "test",
                arguments.production_branch: "production",
            },
        },
        "delivery": {
            "requested_environment": arguments.environment,
            "deploy_roots": {"test": test_root, "production": production_root},
            "deploy_hosts": {"test": test_host, "production": production_host},
            "deployment_credentials_id": arguments.deployment_credentials_id,
            "credential_sources": {
                "scm": {**scm_key_source, "username": arguments.scm_ssh_user},
                "deployment": {**deployment_key_source, "username": arguments.deployment_ssh_user},
                "preconfigured": arguments.credentials_preconfigured,
            },
            "known_hosts": {"sha256": known_hosts_sha256, "content": known_hosts_text},
            "activation_commands": {
                "test": arguments.test_activation_command or "",
                "production": arguments.production_activation_command or "",
            },
            "health_urls": {"test": test_health, "production": production_health},
            "release_retention": arguments.retention,
            "cleanup_gate": "after-active-health-success",
            "protect_current_and_previous": True,
        },
        "project_changes": {"before_sha256": target_hashes},
        "tooling": renderer_fingerprint(),
        "plugins": locked_plugins(),
        "operations": {
            "allowed_cli_writes": [
                "create-job",
                "install-plugin",
                "reload-jcasc-configuration",
                "safe-restart",
                "update-job",
            ],
            "requires_exact_plan_approval": True,
            "production_requires_separate_confirmation": True,
        },
        "questions": sorted(set(str(item) for item in questions)),
    }
    plan["plan_id"] = plan_identifier(plan)
    return plan


def verify_plan(path: Path, approval: str) -> None:
    payload = read_json(path.expanduser().resolve())
    if payload.get("schema_version") != PLAN_SCHEMA_VERSION:
        fail("unsupported plan schema")
    stored = payload.get("plan_id")
    calculated = plan_identifier(payload)
    if not isinstance(stored, str) or stored != calculated:
        fail("plan content does not match its stored identifier")
    if approval != stored:
        fail("approval does not match the exact plan identifier")
    verify_tooling(payload)
    print(stored)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    subparsers = root.add_subparsers(dest="command", required=True)
    create = subparsers.add_parser("create", help="create a deterministic change plan")
    create.add_argument("--discovery", required=True, type=Path)
    create.add_argument("--output", required=True, type=Path)
    create.add_argument("--target", choices=("local", "ssh", "existing"), default="local")
    create.add_argument("--ssh-target")
    create.add_argument("--jenkins-url", default="http://localhost:8080")
    create.add_argument("--port", type=int, default=8080)
    create.add_argument("--install-dir", default="./jenkins-controller")
    create.add_argument("--image", default="jenkins/jenkins:2.568.1-jdk21")
    create.add_argument("--agent-image", default="jenkins/ssh-agent:8.6.0-jdk21")
    create.add_argument("--node-version", default="22.18.0")
    create.add_argument("--maven-version", default="3.9.11")
    create.add_argument("--job")
    create.add_argument("--repo-url")
    create.add_argument("--credentials-id", default="scm-credentials")
    create.add_argument("--scm-public", action="store_true")
    create.add_argument("--scm-key-file")
    create.add_argument("--scm-ssh-user", default="git")
    create.add_argument("--app-root", action="append", help="select one discovered application root; repeat when intentional")
    create.add_argument("--test-branch", default="dev")
    create.add_argument("--production-branch", default="main")
    create.add_argument("--branch", help="deprecated input retained for simple callers")
    create.add_argument("--environment", choices=("test", "production"), default="test")
    create.add_argument("--deploy-root", default="/opt/jenkins-deployments")
    create.add_argument("--test-deploy-root")
    create.add_argument("--production-deploy-root")
    create.add_argument("--test-deploy-host")
    create.add_argument("--production-deploy-host")
    create.add_argument("--deployment-credentials-id", default="deployment-ssh")
    create.add_argument("--deployment-key-file")
    create.add_argument("--deployment-ssh-user", default="jenkins")
    create.add_argument("--credentials-preconfigured", action="store_true")
    create.add_argument("--deployment-known-hosts")
    create.add_argument("--agent-label", default="jenkins-agent")
    create.add_argument("--agent-toolchain-confirmed", action="store_true")
    create.add_argument("--allow-agent-local-deploy", action="store_true")
    create.add_argument("--activation-confirmed", action="store_true")
    create.add_argument("--test-activation-command")
    create.add_argument("--production-activation-command")
    create.add_argument("--health-url")
    create.add_argument("--test-health-url")
    create.add_argument("--production-health-url")
    create.add_argument("--retention", type=int, default=5)
    verify = subparsers.add_parser("verify", help="verify plan integrity and exact approval")
    verify.add_argument("--plan", required=True, type=Path)
    verify.add_argument("--approve", required=True)
    verify.add_argument("--require-ready", action="store_true")
    return root


def main() -> None:
    arguments = parser().parse_args()
    if arguments.command == "create":
        payload = create_plan(arguments)
        atomic_write(arguments.output.expanduser().resolve(), payload)
        print(payload["plan_id"])
    else:
        verify_plan(arguments.plan, arguments.approve)
        if arguments.require_ready:
            payload = read_json(arguments.plan.expanduser().resolve())
            if payload.get("questions"):
                fail("plan still has blocking questions: " + " | ".join(payload["questions"]))


if __name__ == "__main__":
    main()
