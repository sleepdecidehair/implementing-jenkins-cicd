#!/usr/bin/env python3
"""Inspect a repository for evidence needed to build a Jenkins delivery plan."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import re
from pathlib import Path
from typing import Any


EXCLUDED_DIRECTORIES = {
    ".git",
    ".gradle",
    ".idea",
    ".next",
    ".venv",
    "build",
    "coverage",
    "dist",
    "node_modules",
    "out",
    "target",
    "vendor",
}
MAX_DEPTH = 5
MAX_MANIFEST_BYTES = 2 * 1024 * 1024
MAX_EVIDENCE_BYTES = 1024 * 1024
BRANCH_REFERENCE = re.compile(r"(?:origin/|refs/heads/)?(dev|main|master)\b")


def fail(message: str) -> "NoReturn":
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(2)


def relative(root: Path, path: Path) -> str:
    value = path.relative_to(root).as_posix()
    return "." if value == "." else value


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_text(path: Path) -> str:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_EVIDENCE_BYTES:
        return ""
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return ""


def summarized_file_evidence(root: Path, path: Path) -> dict[str, Any]:
    text = safe_text(path)
    lowered = text.lower()
    return {
        "path": relative(root, path) if path == root or root in path.parents else str(path),
        "sha256": file_sha256(path),
        "findings": {
            "branch_references": sorted(set(BRANCH_REFERENCE.findall(lowered))),
            "uses_git_sync": any(token in lowered for token in ("git pull", "git fetch", "git reset")),
            "uses_artifact_transfer": any(token in lowered for token in ("scp ", "rsync ", "docker push", "docker pull")),
            "uses_container_runtime": any(token in lowered for token in ("docker ", "docker-compose", "docker compose")),
            "uses_health_check": any(token in lowered for token in ("health", "curl ", "wget ")),
        },
        "confidence": "observed",
    }


def iter_files(root: Path) -> list[Path]:
    found: list[Path] = []
    for current, directories, files in os.walk(root):
        current_path = Path(current)
        depth = len(current_path.relative_to(root).parts)
        directories[:] = sorted(
            name
            for name in directories
            if name not in EXCLUDED_DIRECTORIES and not name.startswith(".")
        )
        if depth >= MAX_DEPTH:
            directories[:] = []
        for name in sorted(files):
            found.append(current_path / name)
    return found


def run_git(root: Path, *arguments: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), *arguments],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        )
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    value = result.stdout.strip()
    return value or None


def git_evidence(root: Path) -> dict[str, str | None]:
    return {
        "repository_root": run_git(root, "rev-parse", "--show-toplevel"),
        "revision": run_git(root, "rev-parse", "HEAD"),
        "branch": run_git(root, "branch", "--show-current"),
        "remote": run_git(root, "remote", "get-url", "origin"),
    }


def parse_package_json(root: Path, path: Path, questions: list[str]) -> dict[str, Any] | None:
    if path.stat().st_size > MAX_MANIFEST_BYTES:
        questions.append(f"Package manifest is unexpectedly large: {relative(root, path)}")
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        questions.append(f"Package manifest could not be parsed: {relative(root, path)}")
        return None
    if not isinstance(payload, dict):
        questions.append(f"Package manifest is not a JSON object: {relative(root, path)}")
        return None
    return payload


def node_application(root: Path, manifest: Path, questions: list[str]) -> dict[str, Any] | None:
    payload = parse_package_json(root, manifest, questions)
    if payload is None:
        return None
    app_root = manifest.parent
    scripts = payload.get("scripts") if isinstance(payload.get("scripts"), dict) else {}
    if (app_root / "pnpm-lock.yaml").is_file():
        manager = "pnpm"
        install = "pnpm install --frozen-lockfile"
        run_prefix = "pnpm"
    elif (app_root / "yarn.lock").is_file():
        manager = "yarn"
        install = "yarn install --frozen-lockfile"
        run_prefix = "yarn"
    else:
        manager = "npm"
        install = "npm ci" if (app_root / "package-lock.json").is_file() else "npm install"
        run_prefix = "npm run"
    commands: dict[str, str] = {"install": install}
    for command_name in ("lint", "test", "build"):
        command_value = scripts.get(command_name)
        if not isinstance(command_value, str) or not command_value.strip():
            continue
        if command_name == "test" and manager == "npm":
            commands[command_name] = "npm test"
        elif manager == "yarn":
            commands[command_name] = f"yarn {command_name}"
        else:
            commands[command_name] = f"{run_prefix} {command_name}"
    artifacts = [
        name
        for name in ("dist", "build", ".next", "out")
        if (app_root / name).exists()
    ]
    if not artifacts and "build" in commands:
        artifacts = ["dist", "build"]
    engines = payload.get("engines") if isinstance(payload.get("engines"), dict) else {}
    runtime_requirements = {
        str(key): str(value)
        for key, value in engines.items()
        if key in {"node", "npm", "pnpm", "yarn"} and isinstance(value, (str, int, float))
    }
    return {
        "root": relative(root, app_root),
        "type": "node",
        "name": payload.get("name") if isinstance(payload.get("name"), str) else app_root.name,
        "manifest": relative(root, manifest),
        "manifest_sha256": file_sha256(manifest),
        "package_manager": manager,
        "commands": commands,
        "artifact_candidates": artifacts,
        "runtime_requirements": runtime_requirements,
        "git": git_evidence(app_root),
        "confidence": "observed",
    }


def maven_application(root: Path, manifest: Path) -> dict[str, Any]:
    app_root = manifest.parent
    executable = "./mvnw" if (app_root / "mvnw").is_file() else "mvn"
    return {
        "root": relative(root, app_root),
        "type": "maven",
        "name": app_root.name if app_root != root else root.name,
        "manifest": relative(root, manifest),
        "manifest_sha256": file_sha256(manifest),
        "commands": {"build": f"{executable} -B -ntp clean verify"},
        "artifact_candidates": ["target/*.jar", "target/*.war"],
        "git": git_evidence(app_root),
        "confidence": "observed",
    }


def gradle_application(root: Path, manifest: Path) -> dict[str, Any]:
    app_root = manifest.parent
    executable = "./gradlew" if (app_root / "gradlew").is_file() else "gradle"
    return {
        "root": relative(root, app_root),
        "type": "gradle",
        "name": app_root.name if app_root != root else root.name,
        "manifest": relative(root, manifest),
        "manifest_sha256": file_sha256(manifest),
        "commands": {"build": f"{executable} clean test build --no-daemon"},
        "artifact_candidates": ["build/libs/*.jar", "build/libs/*.war"],
        "git": git_evidence(app_root),
        "confidence": "observed",
    }


def docker_application(root: Path, dockerfile: Path) -> dict[str, Any]:
    app_root = dockerfile.parent
    return {
        "root": relative(root, app_root),
        "type": "docker",
        "name": app_root.name if app_root != root else root.name,
        "manifest": relative(root, dockerfile),
        "manifest_sha256": file_sha256(dockerfile),
        "commands": {},
        "artifact_candidates": ["container-image:${IMAGE_TAG}"],
        "git": git_evidence(app_root),
        "confidence": "observed",
    }


def python_application(root: Path, manifest: Path) -> dict[str, Any]:
    app_root = manifest.parent
    pyproject = app_root / "pyproject.toml"
    requirements = app_root / "requirements.txt"
    pyproject_text = safe_text(pyproject) if pyproject.is_file() else ""
    commands: dict[str, str] = {}
    if (app_root / "uv.lock").is_file():
        commands["install"] = "uv sync --frozen"
    elif (app_root / "poetry.lock").is_file():
        commands["install"] = "poetry install --no-interaction --no-root"
    elif requirements.is_file():
        commands["install"] = "python -m pip install -r requirements.txt"
    elif pyproject.is_file():
        commands["install"] = "python -m pip install ."
    pytest_evidence = (
        (app_root / "pytest.ini").is_file()
        or (app_root / "conftest.py").is_file()
        or "[tool.pytest" in pyproject_text
        or "pytest" in safe_text(requirements).lower()
    )
    if pytest_evidence:
        commands["test"] = "python -m pytest"
    if "[build-system]" in pyproject_text:
        commands["build"] = "python -m build"
    runtime_requirements: dict[str, str] = {}
    python_version = safe_text(app_root / ".python-version").strip()
    if python_version:
        runtime_requirements["python"] = python_version.splitlines()[0].strip()
    return {
        "root": relative(root, app_root),
        "type": "python",
        "name": app_root.name if app_root != root else root.name,
        "manifest": relative(root, manifest),
        "manifest_sha256": file_sha256(manifest),
        "commands": commands,
        "artifact_candidates": ["dist/*.whl", "dist/*.tar.gz"] if "build" in commands else [],
        "runtime_requirements": runtime_requirements,
        "git": git_evidence(app_root),
        "confidence": "observed",
    }


def go_application(root: Path, manifest: Path) -> dict[str, Any]:
    app_root = manifest.parent
    module_text = safe_text(manifest)
    go_version = next(
        (line.split(maxsplit=1)[1] for line in module_text.splitlines() if line.startswith("go ") and len(line.split()) == 2),
        None,
    )
    module_name = next(
        (line.split(maxsplit=1)[1] for line in module_text.splitlines() if line.startswith("module ") and len(line.split()) == 2),
        None,
    )
    runtime_requirements = {"go": go_version} if go_version else {}
    return {
        "root": relative(root, app_root),
        "type": "go",
        "name": module_name or (app_root.name if app_root != root else root.name),
        "manifest": relative(root, manifest),
        "manifest_sha256": file_sha256(manifest),
        "commands": {"test": "go test ./...", "build": "go build ./..."},
        "artifact_candidates": [],
        "runtime_requirements": runtime_requirements,
        "git": git_evidence(app_root),
        "confidence": "observed",
    }


def rust_application(root: Path, manifest: Path) -> dict[str, Any]:
    app_root = manifest.parent
    locked = (app_root / "Cargo.lock").is_file()
    suffix = " --locked" if locked else ""
    name_match = re.search(r'^name\s*=\s*["\']([^"\']+)["\']', safe_text(manifest), re.MULTILINE)
    return {
        "root": relative(root, app_root),
        "type": "rust",
        "name": name_match.group(1) if name_match else (app_root.name if app_root != root else root.name),
        "manifest": relative(root, manifest),
        "manifest_sha256": file_sha256(manifest),
        "commands": {
            "test": f"cargo test{suffix}",
            "build": f"cargo build --release{suffix}",
        },
        "artifact_candidates": ["target/release/*"],
        "runtime_requirements": {},
        "git": git_evidence(app_root),
        "confidence": "observed",
    }


def dotnet_application(root: Path, manifest: Path) -> dict[str, Any]:
    app_root = manifest.parent
    manifest_text = safe_text(manifest)
    target_match = re.search(r"<TargetFramework>([^<]+)</TargetFramework>", manifest_text)
    locked = (app_root / "packages.lock.json").is_file()
    restore = "dotnet restore --locked-mode" if locked else "dotnet restore"
    runtime_requirements = {"dotnet": target_match.group(1).strip()} if target_match else {}
    return {
        "root": relative(root, app_root),
        "type": "dotnet",
        "name": manifest.stem,
        "manifest": relative(root, manifest),
        "manifest_sha256": file_sha256(manifest),
        "commands": {
            "install": restore,
            "test": "dotnet test --no-restore",
            "build": "dotnet publish --configuration Release --no-restore --output publish",
        },
        "artifact_candidates": ["publish"],
        "runtime_requirements": runtime_requirements,
        "git": git_evidence(app_root),
        "confidence": "observed",
    }


def discover(project: Path) -> dict[str, Any]:
    files = iter_files(project)
    questions: list[str] = []
    applications: list[dict[str, Any]] = []
    package_files = [path for path in files if path.name == "package.json"]
    all_pom_files = [path for path in files if path.name == "pom.xml"]
    pom_set = set(all_pom_files)
    pom_files = [
        path
        for path in all_pom_files
        if not any(
            (ancestor / "pom.xml") in pom_set
            for ancestor in path.parent.parents
            if ancestor == project or project in ancestor.parents
        )
    ]
    all_gradle_files = [path for path in files if path.name in {"build.gradle", "build.gradle.kts"}]
    gradle_roots = {path.parent for path in all_gradle_files}
    gradle_files = [
        path
        for path in all_gradle_files
        if not any(ancestor in gradle_roots for ancestor in path.parent.parents if ancestor == project or project in ancestor.parents)
    ]
    docker_files = [path for path in files if path.name == "Dockerfile" or path.name.startswith("Dockerfile.")]
    pyproject_files = [path for path in files if path.name == "pyproject.toml"]
    pyproject_roots = {path.parent for path in pyproject_files}
    python_files = pyproject_files + [
        path for path in files if path.name == "requirements.txt" and path.parent not in pyproject_roots
    ]
    go_files = [path for path in files if path.name == "go.mod"]
    rust_files = [path for path in files if path.name == "Cargo.toml"]
    solution_roots = {path.parent for path in files if path.suffix.lower() == ".sln"}
    dotnet_files = [path for path in files if path.suffix.lower() == ".sln"] + [
        path
        for path in files
        if path.suffix.lower() in {".csproj", ".fsproj", ".vbproj"}
        and not any(ancestor in solution_roots for ancestor in (path.parent, *path.parent.parents))
    ]

    for manifest in package_files:
        application = node_application(project, manifest, questions)
        if application:
            applications.append(application)
    applications.extend(maven_application(project, path) for path in pom_files)
    applications.extend(gradle_application(project, path) for path in gradle_files)
    applications.extend(docker_application(project, path) for path in docker_files)
    applications.extend(python_application(project, path) for path in python_files)
    applications.extend(go_application(project, path) for path in go_files)
    applications.extend(rust_application(project, path) for path in rust_files)
    applications.extend(dotnet_application(project, path) for path in dotnet_files)
    applications.sort(key=lambda item: (item["root"], item["type"], item["manifest"]))

    root_node = next(
        (item for item in applications if item["root"] == "." and item["type"] == "node"),
        None,
    )
    project_name = root_node["name"] if root_node else project.name
    deploy_scripts = sorted(
        relative(project, path)
        for path in files
        if path.suffix in {".sh", ".bash"}
        and any(word in path.name.lower() for word in ("deploy", "release", "build", "rollback"))
    )
    compose_files = sorted(
        relative(project, path)
        for path in files
        if path.name in {"compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"}
        or path.name.startswith("docker-compose.")
    )
    jenkinsfiles = sorted(relative(project, path) for path in files if path.name.startswith("Jenkinsfile"))
    deployment_evidence_paths = sorted(
        {
            path
            for path in files
            if path.name.startswith("Jenkinsfile")
            or (
                path.suffix.lower() in {".sh", ".bash", ".yml", ".yaml"}
                and any(word in path.name.lower() for word in ("deploy", "release", "rollback", "backup", "compose"))
            )
        }
    )
    policy_paths = {path for path in files if path.name == "AGENTS.md"}
    for ancestor in (project, *project.parents):
        if ancestor == Path(ancestor.anchor):
            break
        candidate = ancestor / "AGENTS.md"
        if candidate.is_file() and not candidate.is_symlink():
            policy_paths.add(candidate)
    service_files = sorted(
        relative(project, path)
        for path in files
        if path.suffix == ".service"
        or "nginx" in path.name.lower()
        or path.name in {"Caddyfile", "Procfile"}
    )
    migration_files = sorted(
        relative(project, path)
        for path in files
        if any(part.lower() in {"migration", "migrations", "flyway", "liquibase"} for part in path.parts)
    )
    backup_files = sorted(
        relative(project, path)
        for path in files
        if "backup" in path.name.lower() or "restore" in path.name.lower()
    )
    if not applications:
        questions.append("No supported build manifest was found; provide the authoritative build command.")
    elif not any(item.get("commands") for item in applications if item.get("type") != "docker"):
        questions.append(
            "Only container definitions were found; provide the authoritative image tag, registry, and build command."
        )

    project_git = git_evidence(project)
    return {
        "schema_version": 1,
        "project": {
            "root": str(project),
            "name": project_name,
            "git": project_git,
        },
        "applications": applications,
        "deployment": {
            "existing_scripts": deploy_scripts,
            "compose_files": compose_files,
            "jenkinsfiles": jenkinsfiles,
            "evidence": [summarized_file_evidence(project, path) for path in deployment_evidence_paths],
            "service_and_proxy_files": service_files,
            "migration_file_count": len(migration_files),
            "backup_and_restore_files": backup_files,
        },
        "policies": [summarized_file_evidence(project, path) for path in sorted(policy_paths)],
        "questions": sorted(set(questions)),
    }


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
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


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    project = arguments.project.expanduser().resolve()
    if not project.is_dir():
        fail(f"project directory does not exist: {project}")
    output = arguments.output.expanduser().resolve()
    if output == project or project in output.parents and output.name in {".env", "package.json"}:
        fail("refusing unsafe discovery output path")
    atomic_write_json(output, discover(project))
    print(f"Project discovery written: {output}")


if __name__ == "__main__":
    main()
