#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

import supply_chain_inventory


class PolicyError(ValueError):
    """Raised when locked dependencies violate the reviewed license policy."""


def validate_license_set(
    inventory: list[supply_chain_inventory.Component], allowed: set[str]
) -> None:
    if not allowed:
        raise PolicyError("license allowlist is empty")
    for component in inventory:
        if not component.licenses:
            raise PolicyError(f"component has no license: {component.purl}")
        rejected = sorted(set(component.licenses) - allowed)
        if rejected:
            raise PolicyError(
                f"component license is not allowed: {component.purl}: "
                + ", ".join(rejected)
            )


def validate_notice(
    notice: str,
    requirements: dict[str, list[str]],
    locked_purls: set[str],
) -> None:
    unknown = set(requirements) - locked_purls
    if unknown:
        raise PolicyError(
            "NOTICE policy references unlocked components: " + ", ".join(sorted(unknown))
        )
    for purl, phrases in requirements.items():
        if not isinstance(phrases, list) or not phrases:
            raise PolicyError(f"NOTICE requirement is empty: {purl}")
        for phrase in phrases:
            if not isinstance(phrase, str) or not phrase or phrase not in notice:
                raise PolicyError(f"NOTICE is missing required phrase for {purl}: {phrase}")


def _read_json(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise PolicyError(f"required license policy is missing: {path}")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PolicyError(f"cannot parse {path}: {error}") from error
    if not isinstance(document, dict):
        raise PolicyError(f"license policy must be an object: {path}")
    return document


def _validate_reviewed_overrides(root: Path) -> None:
    locked = _read_json(root / supply_chain_inventory.LICENSE_POLICY)
    overrides = _read_json(root / "supply-chain/license-overrides.json")
    locked_components = locked.get("components")
    override_components = overrides.get("components")
    if not isinstance(locked_components, dict) or not isinstance(
        override_components, dict
    ):
        raise PolicyError("locked license and override policies require components")
    reviewed = {
        purl
        for purl, entry in locked_components.items()
        if isinstance(entry, dict)
        and isinstance(entry.get("license_source"), str)
        and entry["license_source"].startswith("reviewed:")
    }
    if reviewed != set(override_components):
        raise PolicyError("reviewed license overrides do not match locked policy")
    for purl in sorted(reviewed):
        locked_licenses = locked_components[purl].get("licenses")
        override_licenses = override_components[purl].get("licenses")
        if sorted(locked_licenses or []) != sorted(override_licenses or []):
            raise PolicyError(f"reviewed license override drift: {purl}")


def check(root: Path) -> int:
    policy = _read_json(root / "supply-chain/license-policy.json")
    if policy.get("schema_version") != 1:
        raise PolicyError("unsupported license policy schema")
    allowed_values = policy.get("allowed_licenses")
    notice_requirements = policy.get("notice_requirements")
    project_phrases = policy.get("project_notice_phrases")
    if not (
        isinstance(allowed_values, list)
        and all(isinstance(value, str) and value for value in allowed_values)
        and isinstance(notice_requirements, dict)
        and isinstance(project_phrases, list)
        and all(isinstance(value, str) and value for value in project_phrases)
    ):
        raise PolicyError("invalid license policy fields")

    inventory = supply_chain_inventory.collect_inventory(root)
    validate_license_set(inventory, set(allowed_values))
    notice = (root / "NOTICE").read_text(encoding="utf-8")
    validate_notice(notice, notice_requirements, {item.purl for item in inventory})
    for phrase in project_phrases:
        if phrase not in notice:
            raise PolicyError(f"NOTICE is missing project compatibility phrase: {phrase}")
    project_license = (root / "LICENSE").read_text(encoding="utf-8")
    if "Apache License" not in project_license or "Version 2.0" not in project_license:
        raise PolicyError("project LICENSE is not Apache-2.0")
    _validate_reviewed_overrides(root)
    print(
        f"License policy passed for {len(inventory)} locked components "
        f"across {len(set(allowed_values))} allowed SPDX licenses."
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Notify license and NOTICE policy")
    parser.add_argument("--root", type=Path, default=Path.cwd())
    arguments = parser.parse_args()
    try:
        return check(arguments.root.resolve())
    except (OSError, PolicyError, supply_chain_inventory.InventoryError) as error:
        print(f"license policy error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
