# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import check_licenses
from supply_chain_inventory import Component


class CheckLicensesTest(unittest.TestCase):
    def test_rejects_an_unapproved_license(self) -> None:
        inventory = [
            Component(
                name="fixture",
                version="1.0.0",
                ecosystem="Hex",
                purl="pkg:hex/fixture@1.0.0",
                sources=("manifest.toml",),
                licenses=("GPL-3.0-only",),
            )
        ]

        with self.assertRaisesRegex(check_licenses.PolicyError, "not allowed"):
            check_licenses.validate_license_set(inventory, {"Apache-2.0"})

    def test_requires_every_reviewed_notice_phrase(self) -> None:
        requirements = {
            "pkg:hex/fixture@1.0.0": ["Required upstream attribution"]
        }

        with self.assertRaisesRegex(check_licenses.PolicyError, "NOTICE is missing"):
            check_licenses.validate_notice(
                "Notify project notice\n", requirements, {"pkg:hex/fixture@1.0.0"}
            )


if __name__ == "__main__":
    unittest.main()
