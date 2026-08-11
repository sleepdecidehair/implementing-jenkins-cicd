#!/usr/bin/env python3
"""Render reusable Jenkins trigger and server-side Git deployment scripts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any, NoReturn
from urllib.parse import urlsplit
from xml.sax.saxutils import escape as xml_escape


SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent
TEMPLATE_DIR = SKILL_DIR / "assets" / "templates"
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
SAFE_BRANCH = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$")
SAFE_ARTIFACT = re.compile(r"^[A-Za-z0-9._/*?\[\]-]+$")
TOP_LEVEL_KEYS = {
    "schema_version",
    "project_name",
    "repository_url",
    "jenkins_url",
    "jenkins_job",
    "branches",
    "source_roots",
    "deploy_roots",
    "commands",
    "artifact_paths",
    "health_urls",
    "release_retention",
    "clean_excludes",
    "execution",
}
ENVIRONMENT_KEYS = {"test", "production"}
COMMAND_KEYS = {"install", "lint", "test", "build", "activate_test", "activate_production"}
EXECUTION_KEYS = {"node_label", "deploy_script_path", "lock_file"}
CONTROL_PLANE_SCRIPTS = (
    "apply-server-pull-job.sh",
    "install-server-pull-script.sh",
    "jenkins-cli-safe.sh",
    "verify-server-pull-delivery.sh",
)


def fail(message: str) -> NoReturn:
    print(f"ERROR: {message}", file=os.sys.stderr)
    raise SystemExit(2)


def require_exact_keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    actual = set(value)
    if actual != expected:
        missing = ", ".join(sorted(expected - actual)) or "none"
        extra = ", ".join(sorted(actual - expected)) or "none"
        fail(f"{label} has invalid keys (missing: {missing}; extra: {extra})")
    return value


def require_string(value: Any, label: str, *, allow_empty: bool = False) -> str:
    if not isinstance(value, str) or (not allow_empty and not value.strip()):
        fail(f"{label} must be a {'string' if allow_empty else 'non-empty string'}")
    if "\0" in value or "\r" in value:
        fail(f"{label} contains an unsupported control character")
    return value


def validate_http_url(value: Any, label: str, *, allow_query: bool = False) -> str:
    url = require_string(value, label).rstrip("/")
    parsed = urlsplit(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        fail(f"{label} must be an absolute HTTP or HTTPS URL")
    if parsed.username or parsed.password or parsed.fragment or (parsed.query and not allow_query):
        fail(f"{label} must not contain credentials, a fragment, or unsupported query parameters")
    return url


def validate_repository_url(value: Any) -> str:
    repository = require_string(value, "repository_url")
    parsed = urlsplit(repository)
    if parsed.scheme:
        if parsed.scheme not in {"https", "ssh", "git", "file"}:
            fail("repository_url must use HTTPS, SSH, Git, or file transport")
        if parsed.scheme != "file" and not parsed.netloc:
            fail("repository_url is missing its host")
        if parsed.username and parsed.password:
            fail("repository_url must not embed a password or token")
        if parsed.query or parsed.fragment:
            fail("repository_url must not contain a query or fragment")
    elif not re.fullmatch(r"[^\s@:]+@[^\s:]+:[^\s]+", repository):
        fail("repository_url must be an absolute Git URL or an SSH-style Git URL")
    return repository


def validate_branch(value: Any, label: str) -> str:
    branch = require_string(value, label)
    if (
        SAFE_BRANCH.fullmatch(branch) is None
        or ".." in branch
        or branch.startswith("/")
        or branch.endswith("/")
        or branch.endswith(".")
        or "//" in branch
        or "/." in branch
        or "@{" in branch
    ):
        fail(f"{label} is not a safe branch name")
    return branch


def validate_root(value: Any, label: str) -> str:
    raw = require_string(value, label)
    path = Path(raw).expanduser()
    if not path.is_absolute():
        fail(f"{label} must be an absolute path")
    resolved = path.resolve(strict=False)
    home = Path.home().resolve()
    if resolved in {Path("/"), home}:
        fail(f"{label} must not be the filesystem root or the Jenkins user's home")
    return str(resolved)


def validate_relative_pattern(value: Any, label: str, *, allow_glob: bool) -> str:
    item = require_string(value, label)
    if "\n" in item or (allow_glob and SAFE_ARTIFACT.fullmatch(item) is None):
        fail(f"{label} contains unsupported characters")
    pure = PurePosixPath(item)
    if pure.is_absolute() or item.startswith("-") or any(part in {"", ".", ".."} for part in pure.parts):
        fail(f"{label} must be a safe relative path")
    if not allow_glob and any(character in item for character in "*?[]"):
        fail(f"{label} must not contain glob characters")
    return item


def load_config(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"cannot read configuration: {error}")
    config = require_exact_keys(payload, TOP_LEVEL_KEYS, "configuration")
    if config["schema_version"] != 2:
        fail("schema_version must be 2")

    project_name = require_string(config["project_name"], "project_name")
    jenkins_job = require_string(config["jenkins_job"], "jenkins_job")
    if SAFE_NAME.fullmatch(project_name) is None or SAFE_NAME.fullmatch(jenkins_job) is None:
        fail("project_name and jenkins_job may contain only letters, digits, dot, underscore, and hyphen")
    config["repository_url"] = validate_repository_url(config["repository_url"])
    config["jenkins_url"] = validate_http_url(config["jenkins_url"], "jenkins_url")

    branches = require_exact_keys(config["branches"], ENVIRONMENT_KEYS, "branches")
    branches["test"] = validate_branch(branches["test"], "branches.test")
    branches["production"] = validate_branch(branches["production"], "branches.production")
    if branches["test"] == branches["production"]:
        fail("test and production branches must be different")

    all_roots: list[str] = []
    for group_name in ("source_roots", "deploy_roots"):
        roots = require_exact_keys(config[group_name], ENVIRONMENT_KEYS, group_name)
        for environment in sorted(ENVIRONMENT_KEYS):
            roots[environment] = validate_root(roots[environment], f"{group_name}.{environment}")
            all_roots.append(roots[environment])
    if len(set(all_roots)) != len(all_roots):
        fail("source and deployment roots must all be distinct")
    resolved_roots = [Path(item) for item in all_roots]
    for index, left in enumerate(resolved_roots):
        for right in resolved_roots[index + 1 :]:
            try:
                right.relative_to(left)
            except ValueError:
                pass
            else:
                fail(f"source and deployment roots must not be nested: {left} contains {right}")
            try:
                left.relative_to(right)
            except ValueError:
                pass
            else:
                fail(f"source and deployment roots must not be nested: {right} contains {left}")

    commands = require_exact_keys(config["commands"], COMMAND_KEYS, "commands")
    for name in COMMAND_KEYS:
        commands[name] = require_string(commands[name], f"commands.{name}", allow_empty=name in {"install", "lint", "test"})

    artifacts = config["artifact_paths"]
    if not isinstance(artifacts, list) or not artifacts:
        fail("artifact_paths must be a non-empty array")
    config["artifact_paths"] = [
        validate_relative_pattern(item, f"artifact_paths[{index}]", allow_glob=True)
        for index, item in enumerate(artifacts)
    ]

    excludes = config["clean_excludes"]
    if not isinstance(excludes, list):
        fail("clean_excludes must be an array")
    config["clean_excludes"] = [
        validate_relative_pattern(item, f"clean_excludes[{index}]", allow_glob=False)
        for index, item in enumerate(excludes)
    ]

    health_urls = require_exact_keys(config["health_urls"], ENVIRONMENT_KEYS, "health_urls")
    for environment in sorted(ENVIRONMENT_KEYS):
        health_urls[environment] = validate_http_url(
            health_urls[environment], f"health_urls.{environment}", allow_query=True
        )

    retention = config["release_retention"]
    if isinstance(retention, bool) or not isinstance(retention, int) or not 2 <= retention <= 50:
        fail("release_retention must be an integer between 2 and 50")

    execution = require_exact_keys(config["execution"], EXECUTION_KEYS, "execution")
    node_label = require_string(execution["node_label"], "execution.node_label")
    if SAFE_NAME.fullmatch(node_label) is None:
        fail("execution.node_label may contain only letters, digits, dot, underscore, and hyphen")
    execution["node_label"] = node_label
    execution["deploy_script_path"] = validate_root(
        execution["deploy_script_path"], "execution.deploy_script_path"
    )
    execution["lock_file"] = validate_root(execution["lock_file"], "execution.lock_file")
    if execution["deploy_script_path"] == execution["lock_file"]:
        fail("execution.deploy_script_path and execution.lock_file must be different")
    return config


def shell_single(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def shell_array(values: list[str]) -> str:
    if not values:
        return ""
    return "\n".join(f"  {shell_single(value)}" for value in values)


def render_template(name: str, replacements: dict[str, str]) -> str:
    path = TEMPLATE_DIR / name
    if not path.is_file():
        fail(f"required template is missing: {path}")
    rendered = path.read_text(encoding="utf-8")
    for key, value in replacements.items():
        rendered = rendered.replace(f"__{key}__", value)
    leftovers = sorted(set(re.findall(r"__[A-Z0-9_]+__", rendered)))
    if leftovers:
        fail(f"template {name} has unresolved fields: {', '.join(leftovers)}")
    if not rendered.endswith("\n"):
        rendered += "\n"
    return rendered


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def approval_metadata(config: dict[str, Any]) -> dict[str, Any]:
    tooling = {
        "renderer": file_sha256(Path(__file__).resolve()),
        "trigger_template": file_sha256(TEMPLATE_DIR / "trigger-deploy.sh.tmpl"),
        "deploy_template": file_sha256(TEMPLATE_DIR / "deploy-from-git.sh.tmpl"),
        "job_template": file_sha256(TEMPLATE_DIR / "server-pull-job.xml.tmpl"),
        "control_plane": {
            name: file_sha256(SCRIPT_DIR / name)
            for name in CONTROL_PLANE_SCRIPTS
        },
    }
    config_payload = json.dumps(config, sort_keys=True, separators=(",", ":")).encode()
    config_sha256 = hashlib.sha256(config_payload).hexdigest()
    approval_payload = json.dumps(
        {"schema_version": 2, "config_sha256": config_sha256, "tooling": tooling},
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return {
        "config_sha256": config_sha256,
        "tooling": tooling,
        "plan_id": hashlib.sha256(approval_payload).hexdigest(),
    }


def render(config: dict[str, Any], plan_id: str) -> dict[str, str]:
    branches = config["branches"]
    trigger = render_template(
        "trigger-deploy.sh.tmpl",
        {
            "PLANNED_JENKINS_URL": shell_single(config["jenkins_url"]),
            "JENKINS_JOB": shell_single(config["jenkins_job"]),
            "TEST_BRANCH": shell_single(branches["test"]),
            "PRODUCTION_BRANCH": shell_single(branches["production"]),
        },
    )
    deploy = render_template(
        "deploy-from-git.sh.tmpl",
        {
            "PROJECT_NAME": shell_single(config["project_name"]),
            "REPOSITORY_URL": shell_single(config["repository_url"]),
            "TEST_BRANCH": shell_single(branches["test"]),
            "PRODUCTION_BRANCH": shell_single(branches["production"]),
            "TEST_SOURCE_ROOT": shell_single(config["source_roots"]["test"]),
            "PRODUCTION_SOURCE_ROOT": shell_single(config["source_roots"]["production"]),
            "TEST_DEPLOY_ROOT": shell_single(config["deploy_roots"]["test"]),
            "PRODUCTION_DEPLOY_ROOT": shell_single(config["deploy_roots"]["production"]),
            "INSTALL_COMMAND": shell_single(config["commands"]["install"]),
            "LINT_COMMAND": shell_single(config["commands"]["lint"]),
            "TEST_COMMAND": shell_single(config["commands"]["test"]),
            "BUILD_COMMAND": shell_single(config["commands"]["build"]),
            "ACTIVATE_TEST_COMMAND": shell_single(config["commands"]["activate_test"]),
            "ACTIVATE_PRODUCTION_COMMAND": shell_single(config["commands"]["activate_production"]),
            "TEST_HEALTH_URL": shell_single(config["health_urls"]["test"]),
            "PRODUCTION_HEALTH_URL": shell_single(config["health_urls"]["production"]),
            "RELEASE_RETENTION": str(config["release_retention"]),
            "ARTIFACT_PATHS": shell_array(config["artifact_paths"]),
            "CLEAN_EXCLUDES": shell_array(config["clean_excludes"]),
            "LOCK_FILE": shell_single(config["execution"]["lock_file"]),
        },
    )
    job = render_template(
        "server-pull-job.xml.tmpl",
        {
            "PLAN_ID": xml_escape(plan_id),
            "NODE_LABEL": xml_escape(config["execution"]["node_label"]),
            "DEPLOY_SCRIPT_PATH": xml_escape(config["execution"]["deploy_script_path"]),
        },
    )
    return {"trigger-deploy.sh": trigger, "deploy-from-git.sh": deploy, "job.xml": job}


def expected_manifest(config: dict[str, Any], files: dict[str, str]) -> dict[str, Any]:
    metadata = approval_metadata(config)
    return {
        "schema_version": 2,
        **metadata,
        "files": {name: hashlib.sha256(content.encode()).hexdigest() for name, content in sorted(files.items())},
    }


def write_output(output: Path, files: dict[str, str], manifest: dict[str, Any]) -> None:
    if output.exists():
        fail(f"output path already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    old_umask = os.umask(0o077)
    staging: Path | None = None
    try:
        staging = Path(tempfile.mkdtemp(prefix=f".{output.name}.staging.", dir=output.parent))
        for name, content in files.items():
            target = staging / name
            target.write_text(content, encoding="utf-8")
            target.chmod(0o700 if name.endswith(".sh") else 0o600)
        manifest_path = staging / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        manifest_path.chmod(0o600)
        staging.replace(output)
        staging = None
    finally:
        os.umask(old_umask)
        if staging is not None and staging.exists():
            for child in staging.iterdir():
                child.unlink()
            staging.rmdir()


def verify_output(output: Path, files: dict[str, str], manifest: dict[str, Any]) -> None:
    if not output.is_dir() or output.is_symlink():
        fail(f"rendered output must be a regular directory: {output}")
    try:
        actual_manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"cannot read rendered manifest: {error}")
    if actual_manifest != manifest:
        fail("rendered manifest does not match the approved configuration and tooling")
    expected_names = set(files) | {"manifest.json"}
    actual_names = {path.name for path in output.iterdir() if path.is_file()}
    if actual_names != expected_names:
        fail("rendered output has missing or unexpected files")
    for name, content in files.items():
        try:
            actual = (output / name).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as error:
            fail(f"cannot read rendered file {name}: {error}")
        if actual != content:
            fail(f"rendered file differs from approved content: {name}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path, help="validated JSON configuration")
    output_group = parser.add_mutually_exclusive_group(required=True)
    output_group.add_argument("--output", type=Path, help="new directory for rendered scripts and job XML")
    output_group.add_argument("--verify-output", type=Path, help="verify an existing rendered directory")
    output_group.add_argument("--print-plan-id", action="store_true", help="print the approval identifier")
    args = parser.parse_args()
    config = load_config(args.config)
    metadata = approval_metadata(config)
    files = render(config, metadata["plan_id"])
    manifest = expected_manifest(config, files)
    if args.print_plan_id:
        print(metadata["plan_id"])
    elif args.verify_output:
        verify_output(args.verify_output.resolve(strict=False), files, manifest)
        print(metadata["plan_id"])
    else:
        assert args.output is not None
        write_output(args.output.resolve(strict=False), files, manifest)
        print(f"Rendered {len(files)} Jenkins Server Pull assets into {args.output}")


if __name__ == "__main__":
    main()
