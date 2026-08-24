# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import supply_chain_inventory


class SupplyChainInventoryTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        (self.root / "packages/notify_core").mkdir(parents=True)
        (self.root / "web").mkdir()
        (self.root / "test/e2e").mkdir(parents=True)
        (self.root / "supply-chain").mkdir()

        (self.root / "manifest.toml").write_text(
            """\
packages = [
  { name = "gleam_stdlib", version = "1.0.5", source = "hex", outer_checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
  { name = "notify_core", version = "0.1.0", source = "local", path = "packages/notify_core" },
]
""",
            encoding="utf-8",
        )
        (self.root / "packages/notify_core/manifest.toml").write_text(
            """\
packages = [
  { name = "gleam_stdlib", version = "1.0.5", source = "hex", outer_checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
  { name = "gleam_mutants", version = "0.1.0", source = "git", repo = "https://github.com/P4suta/gleam-mutants.git", commit = "21f2798f5b7eaebe6cdbb2067f38e35dac2b6b1d" },
]
""",
            encoding="utf-8",
        )
        (self.root / "web/manifest.toml").write_text(
            "packages = []\n", encoding="utf-8"
        )
        (self.root / "gleam.toml").write_text(
            'name = "notify"\nversion = "0.1.0"\n', encoding="utf-8"
        )
        (self.root / "mix.lock").write_text(
            '%{\n  "burrito": {:hex, :burrito, "1.6.0", "checksum", [:mix], [], "hexpm", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},\n}\n',
            encoding="utf-8",
        )
        (self.root / "mix.exs").write_text(
            'def project, do: [archives: [mix_gleam: "== 0.6.2"]]\n',
            encoding="utf-8",
        )
        (self.root / "supply-chain/build-tools.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "components": {
                        "mix_gleam": {
                            "version": "0.6.2",
                            "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        (self.root / "test/e2e/package-lock.json").write_text(
            json.dumps(
                {
                    "lockfileVersion": 3,
                    "packages": {
                        "": {"name": "fixture"},
                        "node_modules/@axe-core/playwright": {
                            "version": "4.13.0",
                            "dev": True,
                            "license": "MPL-2.0",
                        },
                    },
                }
            ),
            encoding="utf-8",
        )
        self.license_policy = {
            "schema_version": 1,
            "components": {
                "pkg:github/P4suta/gleam-mutants@21f2798f5b7eaebe6cdbb2067f38e35dac2b6b1d": {
                    "commit": "21f2798f5b7eaebe6cdbb2067f38e35dac2b6b1d",
                    "licenses": ["Apache-2.0", "MIT"],
                },
                "pkg:hex/burrito@1.6.0": {
                    "licenses": ["Apache-2.0"],
                    "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                },
                "pkg:hex/gleam_stdlib@1.0.5": {
                    "licenses": ["Apache-2.0"],
                    "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                },
                "pkg:hex/mix_gleam@0.6.2": {
                    "licenses": ["Apache-2.0"],
                    "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
                },
            },
        }
        self._write_license_policy()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_collects_every_locked_ecosystem_deterministically(self) -> None:
        inventory = supply_chain_inventory.collect_inventory(self.root)

        self.assertEqual(
            [component.purl for component in inventory],
            [
                "pkg:github/P4suta/gleam-mutants@21f2798f5b7eaebe6cdbb2067f38e35dac2b6b1d",
                "pkg:hex/burrito@1.6.0",
                "pkg:hex/gleam_stdlib@1.0.5",
                "pkg:hex/mix_gleam@0.6.2",
                "pkg:npm/%40axe-core/playwright@4.13.0",
            ],
        )
        stdlib = inventory[2]
        self.assertEqual(stdlib.licenses, ("Apache-2.0",))
        self.assertEqual(
            stdlib.sources,
            ("manifest.toml", "packages/notify_core/manifest.toml"),
        )

    def test_rejects_build_tool_version_drift(self) -> None:
        (self.root / "mix.exs").write_text(
            'def project, do: [archives: [mix_gleam: "== 0.6.1"]]\n',
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            supply_chain_inventory.InventoryError, "build-tool version mismatch"
        ):
            supply_chain_inventory.collect_inventory(self.root)

    def test_emits_osv_and_cyclonedx_contracts(self) -> None:
        inventory = supply_chain_inventory.collect_inventory(self.root)

        osv = supply_chain_inventory.osv_document(inventory)
        packages = [entry["package"] for entry in osv["results"][0]["packages"]]
        self.assertIn(
            {"ecosystem": "Hex", "name": "burrito", "version": "1.6.0"},
            packages,
        )
        self.assertIn(
            {
                "commit": "21f2798f5b7eaebe6cdbb2067f38e35dac2b6b1d",
                "name": "https://github.com/P4suta/gleam-mutants.git",
            },
            packages,
        )

        bom = supply_chain_inventory.cyclonedx_document(self.root, inventory)
        self.assertEqual(bom["bomFormat"], "CycloneDX")
        self.assertEqual(bom["specVersion"], "1.6")
        self.assertEqual(bom["metadata"]["component"]["name"], "notify")
        npm = next(
            component
            for component in bom["components"]
            if component["purl"].startswith("pkg:npm/")
        )
        self.assertEqual(npm["licenses"], [{"license": {"id": "MPL-2.0"}}])
        self.assertEqual(npm["scope"], "optional")

    def test_rejects_a_missing_mix_lock(self) -> None:
        (self.root / "mix.lock").unlink()

        with self.assertRaisesRegex(
            supply_chain_inventory.InventoryError, "required lock file is missing"
        ):
            supply_chain_inventory.collect_inventory(self.root)

    def test_rejects_license_policy_drift(self) -> None:
        del self.license_policy["components"]["pkg:hex/burrito@1.6.0"]
        self._write_license_policy()

        with self.assertRaisesRegex(
            supply_chain_inventory.InventoryError,
            "license policy does not match locked components",
        ):
            supply_chain_inventory.collect_inventory(self.root)

    def _write_license_policy(self) -> None:
        (self.root / "supply-chain/locked-licenses.json").write_text(
            json.dumps(self.license_policy), encoding="utf-8"
        )


if __name__ == "__main__":
    unittest.main()
