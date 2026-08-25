#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import sys
import tarfile
import tomllib
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlparse

import supply_chain_inventory


MAX_PACKAGE_BYTES = 64 * 1024 * 1024
MAX_METADATA_BYTES = 1024 * 1024
LICENSE_OVERRIDES = Path("supply-chain/license-overrides.json")
HEX_LICENSE_BLOCK = re.compile(
    rb'\{<<"licenses">>,\s*\[(?P<licenses>.*?)\]\}\.', re.DOTALL
)
HEX_LICENSE_VALUE = re.compile(rb'<<"([^"]+)"/utf8>>')
MIX_LICENSE_BLOCK = re.compile(rb"licenses:\s*\[(?P<licenses>[^\]]+)\]")
MIX_LICENSE_VALUE = re.compile(rb'"([^"]+)"')


def parse_hex_licenses(metadata: bytes) -> tuple[str, ...]:
    match = HEX_LICENSE_BLOCK.search(metadata)
    if match is None:
        raise ValueError("Hex package metadata does not declare licenses")
    licenses = tuple(
        sorted(
            {
                value.decode("utf-8")
                for value in HEX_LICENSE_VALUE.findall(match.group("licenses"))
            }
        )
    )
    if not licenses:
        raise ValueError("Hex package metadata does not declare licenses")
    return licenses


def parse_gleam_licenses(manifest: bytes) -> tuple[str, ...]:
    document = tomllib.loads(manifest.decode("utf-8"))
    declared = document.get("licenses", document.get("licences"))
    if not (
        isinstance(declared, list)
        and declared
        and all(isinstance(value, str) and value for value in declared)
    ):
        raise ValueError("Gleam package manifest does not declare licenses")
    return tuple(sorted(set(declared)))


def parse_mix_licenses(manifest: bytes) -> tuple[str, ...]:
    match = MIX_LICENSE_BLOCK.search(manifest)
    if match is None:
        raise ValueError("Mix package manifest does not declare licenses")
    licenses = tuple(
        sorted(
            {
                value.decode("utf-8")
                for value in MIX_LICENSE_VALUE.findall(match.group("licenses"))
            }
        )
    )
    if not licenses:
        raise ValueError("Mix package manifest does not declare licenses")
    return licenses


def validate_reviewed_override(
    purl: str, override: dict[str, Any], license_files: dict[str, bytes]
) -> tuple[str, ...]:
    licenses = override.get("licenses")
    expected_files = override.get("license_files")
    reason = override.get("reason")
    if not (
        isinstance(licenses, list)
        and licenses
        and all(isinstance(value, str) and value for value in licenses)
        and isinstance(expected_files, dict)
        and expected_files
        and isinstance(reason, str)
        and reason
    ):
        raise ValueError(f"invalid reviewed license override: {purl}")
    if set(expected_files) != set(license_files):
        raise ValueError(f"reviewed license files do not match package contents: {purl}")
    for path, expected_digest in expected_files.items():
        if not isinstance(expected_digest, str):
            raise ValueError(f"invalid reviewed license checksum: {purl}:{path}")
        actual_digest = hashlib.sha256(license_files[path]).hexdigest()
        if actual_digest != expected_digest:
            raise ValueError(f"license file checksum mismatch: {purl}:{path}")
    return tuple(sorted(set(licenses)))


def _download(url: str) -> bytes:
    request = urllib.request.Request(
        url, headers={"User-Agent": "notify-locked-license-refresh/1"}
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        contents = response.read(MAX_PACKAGE_BYTES + 1)
    if len(contents) > MAX_PACKAGE_BYTES:
        raise ValueError(f"package metadata response exceeds size limit: {url}")
    return contents


def _hex_policy(
    component: supply_chain_inventory.Component,
    override: dict[str, Any] | None,
) -> tuple[dict[str, Any], bool]:
    package_name = quote(component.name, safe="")
    package_version = quote(component.version, safe="")
    url = f"https://repo.hex.pm/tarballs/{package_name}-{package_version}.tar"
    archive = _download(url)
    digest = hashlib.sha256(archive).hexdigest()
    if digest != component.sha256:
        raise ValueError(
            f"Hex package checksum mismatch for {component.purl}: "
            f"expected {component.sha256}, got {digest}"
        )
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as package:
        try:
            member = package.getmember("metadata.config")
            contents_member = package.getmember("contents.tar.gz")
        except KeyError as error:
            raise ValueError(
                f"Hex package is missing a required member: {component.purl}"
            ) from error
        if member.size > MAX_METADATA_BYTES:
            raise ValueError(f"Hex metadata exceeds size limit: {component.purl}")
        metadata_file = package.extractfile(member)
        if metadata_file is None:
            raise ValueError(f"Hex metadata is unreadable: {component.purl}")
        metadata = metadata_file.read(MAX_METADATA_BYTES + 1)
        if contents_member.size > MAX_PACKAGE_BYTES:
            raise ValueError(f"Hex package contents exceed size limit: {component.purl}")
        contents_file = package.extractfile(contents_member)
        if contents_file is None:
            raise ValueError(f"Hex package contents are unreadable: {component.purl}")
        contents_archive = contents_file.read(MAX_PACKAGE_BYTES + 1)
    license_source = "metadata.config"
    override_used = False
    try:
        licenses = parse_hex_licenses(metadata)
    except ValueError as metadata_error:
        try:
            with tarfile.open(fileobj=io.BytesIO(contents_archive), mode="r:gz") as contents:
                members = {
                    member.name.removeprefix("./"): member
                    for member in contents.getmembers()
                }
                manifest_errors: list[str] = []
                licenses = ()
                for manifest_name, parser in (
                    ("gleam.toml", parse_gleam_licenses),
                    ("mix.exs", parse_mix_licenses),
                ):
                    manifest = members.get(manifest_name)
                    if manifest is None or manifest.size > MAX_METADATA_BYTES:
                        manifest_errors.append(f"no bounded root {manifest_name}")
                        continue
                    manifest_file = contents.extractfile(manifest)
                    if manifest_file is None:
                        manifest_errors.append(f"unreadable root {manifest_name}")
                        continue
                    try:
                        licenses = parser(manifest_file.read(MAX_METADATA_BYTES + 1))
                        license_source = f"contents.tar.gz/{manifest_name}"
                        break
                    except (UnicodeDecodeError, ValueError, tomllib.TOMLDecodeError) as error:
                        manifest_errors.append(str(error))
                if not licenses:
                    raise ValueError("; ".join(manifest_errors))
        except (ValueError, tarfile.TarError, tomllib.TOMLDecodeError) as error:
            if override is None:
                raise ValueError(
                    f"{component.purl}: {metadata_error}; fallback failed: {error}"
                ) from error
            expected_files = override.get("license_files")
            if not isinstance(expected_files, dict) or not expected_files:
                raise ValueError(f"invalid reviewed license override: {component.purl}")
            reviewed_files: dict[str, bytes] = {}
            with tarfile.open(fileobj=io.BytesIO(contents_archive), mode="r:gz") as contents:
                members = {
                    member.name.removeprefix("./"): member
                    for member in contents.getmembers()
                }
                for path in expected_files:
                    member = members.get(path)
                    if member is None or member.size > MAX_METADATA_BYTES:
                        raise ValueError(
                            f"reviewed license file is missing or oversized: "
                            f"{component.purl}:{path}"
                        )
                    license_file = contents.extractfile(member)
                    if license_file is None:
                        raise ValueError(
                            f"reviewed license file is unreadable: {component.purl}:{path}"
                        )
                    reviewed_files[path] = license_file.read(MAX_METADATA_BYTES + 1)
            licenses = validate_reviewed_override(
                component.purl, override, reviewed_files
            )
            license_source = "reviewed:" + ",".join(sorted(reviewed_files))
            override_used = True
    return (
        {
            "licenses": list(licenses),
            "license_source": license_source,
            "sha256": digest,
            "source": url,
        },
        override_used,
    )


def _git_policy(component: supply_chain_inventory.Component) -> dict[str, Any]:
    if component.repository is None or component.commit is None:
        raise ValueError(f"incomplete Git component: {component.purl}")
    parsed = urlparse(component.repository)
    path_parts = parsed.path.removesuffix(".git").strip("/").split("/")
    if parsed.hostname != "github.com" or len(path_parts) != 2:
        raise ValueError(f"unsupported Git component: {component.purl}")
    owner, repository = path_parts
    url = (
        f"https://raw.githubusercontent.com/{quote(owner, safe='')}/"
        f"{quote(repository, safe='')}/{quote(component.commit, safe='')}/gleam.toml"
    )
    document = tomllib.loads(_download(url).decode("utf-8"))
    declared = document.get("licenses", document.get("licences"))
    if not (
        isinstance(declared, list)
        and declared
        and all(isinstance(value, str) and value for value in declared)
    ):
        raise ValueError(f"Git component does not declare licenses: {component.purl}")
    return {
        "commit": component.commit,
        "licenses": sorted(set(declared)),
        "source": url,
    }


def _load_overrides(root: Path) -> dict[str, dict[str, Any]]:
    path = root / LICENSE_OVERRIDES
    if not path.is_file():
        raise ValueError(f"required license override policy is missing: {path}")
    document = json.loads(path.read_text(encoding="utf-8"))
    components = document.get("components")
    if document.get("schema_version") != 1 or not isinstance(components, dict):
        raise ValueError(f"unsupported license override format: {LICENSE_OVERRIDES}")
    if not all(isinstance(value, dict) for value in components.values()):
        raise ValueError(f"invalid license override entry: {LICENSE_OVERRIDES}")
    return components


def generate_policy(root: Path) -> dict[str, Any]:
    inventory = supply_chain_inventory.collect_inventory(
        root.resolve(), apply_license_policy=False
    )
    overrides = _load_overrides(root)
    unused_overrides = set(overrides)
    components: dict[str, dict[str, Any]] = {}
    for component in inventory:
        if component.ecosystem == "Hex":
            policy, override_used = _hex_policy(
                component, overrides.get(component.purl)
            )
            components[component.purl] = policy
            if override_used:
                unused_overrides.discard(component.purl)
        elif component.ecosystem == "Git":
            components[component.purl] = _git_policy(component)
    if unused_overrides:
        raise ValueError(
            "unused reviewed license overrides: " + ", ".join(sorted(unused_overrides))
        )
    return {
        "schema_version": 1,
        "components": {purl: components[purl] for purl in sorted(components)},
    }


def _serialise(document: dict[str, Any]) -> str:
    return json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Refresh license metadata bound to Notify's locked dependencies"
    )
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument(
        "--output", type=Path, default=Path("supply-chain/locked-licenses.json")
    )
    parser.add_argument(
        "--check", action="store_true", help="fail instead of rewriting stale policy"
    )
    arguments = parser.parse_args()
    output = arguments.output
    if not output.is_absolute():
        output = arguments.root / output

    try:
        rendered = _serialise(generate_policy(arguments.root))
        if arguments.check:
            if not output.is_file() or output.read_text(encoding="utf-8") != rendered:
                print(f"locked license policy is stale: {output}", file=sys.stderr)
                return 1
        else:
            output.parent.mkdir(parents=True, exist_ok=True)
            temporary_output = output.with_suffix(output.suffix + ".tmp")
            temporary_output.write_text(rendered, encoding="utf-8")
            temporary_output.replace(output)
    except (
        OSError,
        UnicodeDecodeError,
        ValueError,
        tarfile.TarError,
        tomllib.TOMLDecodeError,
        urllib.error.URLError,
        supply_chain_inventory.InventoryError,
    ) as error:
        print(f"license refresh error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
