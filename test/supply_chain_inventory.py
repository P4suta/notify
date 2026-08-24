#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlparse


class InventoryError(ValueError):
    """Raised when a lock file cannot be represented without guessing."""


@dataclass(frozen=True)
class Component:
    name: str
    version: str
    ecosystem: str
    purl: str
    sources: tuple[str, ...]
    licenses: tuple[str, ...] = ()
    optional: bool = False
    repository: str | None = None
    commit: str | None = None
    sha256: str | None = None


GLEAM_MANIFESTS = (
    Path("manifest.toml"),
    Path("packages/notify_core/manifest.toml"),
    Path("web/manifest.toml"),
)
NPM_LOCK = Path("test/e2e/package-lock.json")
MIX_LOCK = Path("mix.lock")
MIX_PROJECT = Path("mix.exs")
BUILD_TOOL_LOCK = Path("supply-chain/build-tools.json")
LICENSE_POLICY = Path("supply-chain/locked-licenses.json")
MIX_HEX_PACKAGE = re.compile(
    r'^\s*"(?P<key>[^"]+)":\s*\{:hex,\s*:(?P<name>[a-zA-Z0-9_]+),\s*"(?P<version>[^"]+)".*?,\s*"hexpm",\s*"(?P<checksum>[0-9a-fA-F]{64})"\},?\s*$',
    re.MULTILINE,
)
SPDX_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.+-]*$")
MIX_ARCHIVES = re.compile(r"archives:\s*\[(?P<archives>[^\]]*)\]")
MIX_ARCHIVE_ENTRY = re.compile(
    r'\s*(?P<name>[a-zA-Z0-9_]+):\s*"==\s*(?P<version>[0-9A-Za-z.+-]+)"\s*(?:,|$)'
)


def _read_toml(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise InventoryError(f"required lock file is missing: {path}")
    try:
        with path.open("rb") as source:
            return tomllib.load(source)
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise InventoryError(f"cannot parse {path}: {error}") from error


def _add_component(
    components: dict[str, Component], component: Component
) -> None:
    existing = components.get(component.purl)
    if existing is None:
        components[component.purl] = component
        return

    identity = (
        "name",
        "version",
        "ecosystem",
        "repository",
        "commit",
        "sha256",
    )
    if any(getattr(existing, field) != getattr(component, field) for field in identity):
        raise InventoryError(f"conflicting component identity: {component.purl}")

    components[component.purl] = replace(
        existing,
        sources=tuple(sorted(set(existing.sources + component.sources))),
        licenses=tuple(sorted(set(existing.licenses + component.licenses))),
        optional=existing.optional and component.optional,
    )


def _hex_component(
    name: str, version: str, source: str, optional: bool, sha256: str
) -> Component:
    if not re.fullmatch(r"[0-9a-fA-F]{64}", sha256):
        raise InventoryError(f"invalid Hex checksum for {name}@{version}: {sha256!r}")
    return Component(
        name=name,
        version=version,
        ecosystem="Hex",
        purl=f"pkg:hex/{quote(name, safe='')}@{quote(version, safe='')}",
        sources=(source,),
        optional=optional,
        sha256=sha256.lower(),
    )


def _github_component(package: dict[str, Any], source: str) -> Component:
    repository = package.get("repo")
    commit = package.get("commit")
    name = package.get("name")
    if not all(isinstance(value, str) and value for value in (repository, commit, name)):
        raise InventoryError(f"incomplete git dependency in {source}: {package!r}")

    parsed = urlparse(repository)
    path_parts = parsed.path.removesuffix(".git").strip("/").split("/")
    if parsed.hostname != "github.com" or len(path_parts) != 2:
        raise InventoryError(f"unsupported git dependency URL in {source}: {repository}")
    owner, repository_name = path_parts
    canonical_repository = f"https://github.com/{owner}/{repository_name}.git"
    purl = (
        f"pkg:github/{quote(owner, safe='')}/{quote(repository_name, safe='')}"
        f"@{quote(commit, safe='')}"
    )
    return Component(
        name=name,
        version=commit,
        ecosystem="Git",
        purl=purl,
        sources=(source,),
        repository=canonical_repository,
        commit=commit,
    )


def _collect_gleam(root: Path, components: dict[str, Component]) -> None:
    for relative_path in GLEAM_MANIFESTS:
        document = _read_toml(root / relative_path)
        packages = document.get("packages")
        if not isinstance(packages, list):
            raise InventoryError(f"packages must be an array: {relative_path}")
        for package in packages:
            if not isinstance(package, dict):
                raise InventoryError(f"invalid package in {relative_path}: {package!r}")
            source = package.get("source")
            if source == "local":
                continue
            name = package.get("name")
            version = package.get("version")
            checksum = package.get("outer_checksum")
            if source == "hex":
                if not all(
                    isinstance(value, str) and value
                    for value in (name, version, checksum)
                ):
                    raise InventoryError(
                        f"incomplete Hex dependency in {relative_path}: {package!r}"
                    )
                component = _hex_component(
                    name,
                    version,
                    relative_path.as_posix(),
                    optional=False,
                    sha256=checksum,
                )
            elif source == "git":
                component = _github_component(package, relative_path.as_posix())
            else:
                raise InventoryError(
                    f"unsupported dependency source in {relative_path}: {source!r}"
                )
            _add_component(components, component)


def _normalise_licenses(value: Any) -> tuple[str, ...]:
    if isinstance(value, str) and value:
        return (value,)
    if isinstance(value, list):
        licenses = tuple(sorted(item for item in value if isinstance(item, str) and item))
        if licenses:
            return licenses
    return ()


def _collect_npm(root: Path, components: dict[str, Component]) -> None:
    path = root / NPM_LOCK
    if not path.is_file():
        raise InventoryError(f"required lock file is missing: {path}")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise InventoryError(f"cannot parse {path}: {error}") from error
    packages = document.get("packages")
    if document.get("lockfileVersion") != 3 or not isinstance(packages, dict):
        raise InventoryError(f"unsupported npm lock format: {NPM_LOCK}")

    for package_path, package in packages.items():
        if not package_path or not isinstance(package, dict):
            continue
        version = package.get("version")
        if not isinstance(version, str) or not version:
            raise InventoryError(f"npm package has no version: {package_path}")
        marker = "node_modules/"
        if marker not in package_path:
            raise InventoryError(f"unsupported npm package path: {package_path}")
        name = package_path.rsplit(marker, 1)[1]
        purl_name = quote(name, safe="/")
        _add_component(
            components,
            Component(
                name=name,
                version=version,
                ecosystem="npm",
                purl=f"pkg:npm/{purl_name}@{quote(version, safe='')}",
                sources=(NPM_LOCK.as_posix(),),
                licenses=_normalise_licenses(package.get("license")),
                optional=bool(package.get("dev") or package.get("optional")),
            ),
        )


def _collect_mix(root: Path, components: dict[str, Component]) -> None:
    path = root / MIX_LOCK
    if not path.is_file():
        raise InventoryError(f"required lock file is missing: {path}")
    try:
        contents = path.read_text(encoding="utf-8")
    except OSError as error:
        raise InventoryError(f"cannot read {path}: {error}") from error
    matches = list(MIX_HEX_PACKAGE.finditer(contents))
    if not matches:
        raise InventoryError(f"no Hex packages found in {MIX_LOCK}")
    for match in matches:
        _add_component(
            components,
            _hex_component(
                match.group("name"),
                match.group("version"),
                MIX_LOCK.as_posix(),
                optional=True,
                sha256=match.group("checksum"),
            ),
        )


def _collect_mix_archives(root: Path, components: dict[str, Component]) -> None:
    project_path = root / MIX_PROJECT
    lock_path = root / BUILD_TOOL_LOCK
    try:
        project = project_path.read_text(encoding="utf-8")
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise InventoryError(f"cannot read build-tool lock: {error}") from error

    archive_block = MIX_ARCHIVES.search(project)
    if archive_block is None:
        raise InventoryError(f"{MIX_PROJECT} must declare exact Mix archives")
    archive_text = archive_block.group("archives")
    archives: dict[str, str] = {}
    position = 0
    while position < len(archive_text):
        match = MIX_ARCHIVE_ENTRY.match(archive_text, position)
        if match is None:
            raise InventoryError(f"Mix archives must use exact == versions: {MIX_PROJECT}")
        name = match.group("name")
        if name in archives:
            raise InventoryError(f"duplicate Mix archive: {name}")
        archives[name] = match.group("version")
        position = match.end()
    if not archives:
        raise InventoryError(f"{MIX_PROJECT} must declare at least one Mix archive")

    locked = lock.get("components")
    if lock.get("schema_version") != 1 or not isinstance(locked, dict):
        raise InventoryError(f"unsupported build-tool lock format: {BUILD_TOOL_LOCK}")
    if set(archives) != set(locked):
        raise InventoryError("build-tool lock does not match Mix archives")
    for name, version in sorted(archives.items()):
        entry = locked[name]
        if not isinstance(entry, dict) or set(entry) != {"sha256", "version"}:
            raise InventoryError(f"invalid build-tool lock entry: {name}")
        if entry.get("version") != version:
            raise InventoryError(f"build-tool version mismatch: {name}")
        checksum = entry.get("sha256")
        if not isinstance(checksum, str):
            raise InventoryError(f"build-tool checksum is missing: {name}")
        component = _hex_component(
            name,
            version,
            MIX_PROJECT.as_posix(),
            optional=True,
            sha256=checksum,
        )
        _add_component(
            components,
            replace(
                component,
                sources=(MIX_PROJECT.as_posix(), BUILD_TOOL_LOCK.as_posix()),
            ),
        )


def _apply_license_policy(root: Path, components: dict[str, Component]) -> None:
    path = root / LICENSE_POLICY
    if not path.is_file():
        raise InventoryError(f"required license policy is missing: {path}")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise InventoryError(f"cannot parse {path}: {error}") from error
    policy = document.get("components")
    if document.get("schema_version") != 1 or not isinstance(policy, dict):
        raise InventoryError(f"unsupported license policy format: {LICENSE_POLICY}")

    expected = {
        purl
        for purl, component in components.items()
        if component.ecosystem in {"Git", "Hex"}
    }
    actual = set(policy)
    if expected != actual:
        missing = ", ".join(sorted(expected - actual)) or "none"
        extra = ", ".join(sorted(actual - expected)) or "none"
        raise InventoryError(
            "license policy does not match locked components "
            f"(missing: {missing}; extra: {extra})"
        )

    for purl in sorted(expected):
        entry = policy[purl]
        if not isinstance(entry, dict):
            raise InventoryError(f"invalid license policy entry: {purl}")
        licenses = entry.get("licenses")
        if not (
            isinstance(licenses, list)
            and licenses
            and all(isinstance(license_name, str) and license_name for license_name in licenses)
        ):
            raise InventoryError(f"component has no declared licenses: {purl}")
        component = components[purl]
        if component.ecosystem == "Hex" and entry.get("sha256") != component.sha256:
            raise InventoryError(f"license policy checksum mismatch: {purl}")
        if component.ecosystem == "Git" and entry.get("commit") != component.commit:
            raise InventoryError(f"license policy commit mismatch: {purl}")
        components[purl] = replace(
            component,
            licenses=tuple(sorted(set(component.licenses + tuple(licenses)))),
        )


def collect_inventory(
    root: Path, *, apply_license_policy: bool = True
) -> list[Component]:
    components: dict[str, Component] = {}
    _collect_gleam(root, components)
    _collect_npm(root, components)
    _collect_mix(root, components)
    _collect_mix_archives(root, components)
    if apply_license_policy:
        _apply_license_policy(root, components)
    return [components[purl] for purl in sorted(components)]


def osv_document(inventory: list[Component]) -> dict[str, Any]:
    packages: list[dict[str, Any]] = []
    for component in inventory:
        if component.ecosystem == "Git":
            package = {
                "name": component.repository,
                "commit": component.commit,
            }
        else:
            package = {
                "name": component.name,
                "version": component.version,
                "ecosystem": component.ecosystem,
            }
        packages.append({"package": package})
    return {"results": [{"packages": packages}]}


def _cyclonedx_license(value: str) -> dict[str, Any]:
    if SPDX_IDENTIFIER.fullmatch(value):
        return {"license": {"id": value}}
    return {"expression": value}


def cyclonedx_document(root: Path, inventory: list[Component]) -> dict[str, Any]:
    project = _read_toml(root / "gleam.toml")
    name = project.get("name")
    version = project.get("version")
    if not all(isinstance(value, str) and value for value in (name, version)):
        raise InventoryError("gleam.toml must contain a project name and version")
    root_reference = f"pkg:github/P4suta/notify@{quote(version, safe='')}"

    components: list[dict[str, Any]] = []
    for component in inventory:
        entry: dict[str, Any] = {
            "bom-ref": component.purl,
            "type": "library",
            "name": component.name,
            "version": component.version,
            "purl": component.purl,
            "scope": "optional" if component.optional else "required",
            "properties": [
                {
                    "name": "notify:inventory:sources",
                    "value": ",".join(component.sources),
                }
            ],
        }
        if component.licenses:
            entry["licenses"] = [
                _cyclonedx_license(value) for value in component.licenses
            ]
        if component.sha256 is not None:
            entry["hashes"] = [{"alg": "SHA-256", "content": component.sha256}]
        components.append(entry)

    return {
        "$schema": "https://cyclonedx.org/schema/bom-1.6.schema.json",
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "version": 1,
        "metadata": {
            "component": {
                "bom-ref": root_reference,
                "type": "application",
                "name": name,
                "version": version,
                "purl": root_reference,
            },
            "properties": [
                {
                    "name": "notify:inventory:lock-files",
                    "value": ",".join(
                        [path.as_posix() for path in GLEAM_MANIFESTS]
                        + [
                            NPM_LOCK.as_posix(),
                            MIX_LOCK.as_posix(),
                            MIX_PROJECT.as_posix(),
                            BUILD_TOOL_LOCK.as_posix(),
                        ]
                    ),
                }
            ],
        },
        "components": components,
        "dependencies": [
            {
                "ref": root_reference,
                "dependsOn": [component.purl for component in inventory],
            }
        ],
    }


def _write_json(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate deterministic Notify dependency inventories"
    )
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--osv-output", type=Path)
    parser.add_argument("--cyclonedx-output", type=Path)
    arguments = parser.parse_args()
    if arguments.osv_output is None and arguments.cyclonedx_output is None:
        parser.error("at least one output path is required")

    try:
        inventory = collect_inventory(arguments.root.resolve())
        if arguments.osv_output is not None:
            _write_json(arguments.osv_output, osv_document(inventory))
        if arguments.cyclonedx_output is not None:
            _write_json(
                arguments.cyclonedx_output,
                cyclonedx_document(arguments.root.resolve(), inventory),
            )
    except InventoryError as error:
        print(f"inventory error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
