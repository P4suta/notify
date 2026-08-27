#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import json
import re
import tomllib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HTTP3_REPOSITORY = "https://github.com/P4suta/http3.git"
EXPECTED_HTTP3_COMMIT = "48a8b3b0a609b7c33ff54c571c9c5935ad41336f"


class NativeHttp3DependencyContractTest(unittest.TestCase):
    def test_every_dependency_surface_uses_the_merged_commit(self) -> None:
        gleam_project = (ROOT / "gleam.toml").read_text(encoding="utf-8")
        manifest = tomllib.loads(
            (ROOT / "manifest.toml").read_text(encoding="utf-8")
        )
        mix_project = (ROOT / "mix.exs").read_text(encoding="utf-8")
        mix_lock = (ROOT / "mix.lock").read_text(encoding="utf-8")
        license_policy = json.loads(
            (ROOT / "supply-chain/locked-licenses.json").read_text(
                encoding="utf-8"
            )
        )

        self.assertRegex(
            gleam_project,
            re.escape(
                f'http3 = {{ git = "{HTTP3_REPOSITORY}", '
                f'ref = "{EXPECTED_HTTP3_COMMIT}" }}'
            ),
        )

        git_packages = {
            package["name"]: package
            for package in manifest["packages"]
            if package.get("repo") == HTTP3_REPOSITORY
        }
        self.assertEqual(set(git_packages), {"gleam_quic", "http3"})
        self.assertEqual(
            git_packages["gleam_quic"].get("path"), "packages/gleam_quic"
        )
        self.assertNotIn("path", git_packages["http3"])
        self.assertEqual(
            {package["commit"] for package in git_packages.values()},
            {EXPECTED_HTTP3_COMMIT},
        )
        self.assertEqual(
            manifest["requirements"]["http3"],
            {
                "git": HTTP3_REPOSITORY,
                "ref": EXPECTED_HTTP3_COMMIT,
            },
        )

        mix_dependency = re.compile(
            r'\{:http3,\s*git:\s*"' + re.escape(HTTP3_REPOSITORY)
            + r'",\s*ref:\s*"([0-9a-f]{40})"\}'
        )
        mix_match = mix_dependency.search(mix_project)
        self.assertIsNotNone(mix_match)
        self.assertEqual(
            mix_match.group(1),  # type: ignore[union-attr]
            EXPECTED_HTTP3_COMMIT,
        )
        mix_git_lock = re.compile(
            r'"http3":\s*\{:git,\s*"' + re.escape(HTTP3_REPOSITORY)
            + r'",\s*"([0-9a-f]{40})",\s*\[ref:\s*"([0-9a-f]{40})"\]\}'
        )
        lock_match = mix_git_lock.search(mix_lock)
        self.assertIsNotNone(lock_match)
        self.assertEqual(
            set(lock_match.groups()),  # type: ignore[union-attr]
            {EXPECTED_HTTP3_COMMIT},
        )

        expected_policy_keys = {
            f"pkg:github/P4suta/http3@{EXPECTED_HTTP3_COMMIT}",
            (
                f"pkg:github/P4suta/http3@{EXPECTED_HTTP3_COMMIT}"
                "#packages/gleam_quic"
            ),
        }
        policy_components = license_policy["components"]
        self.assertTrue(expected_policy_keys <= set(policy_components))
        for key in expected_policy_keys:
            self.assertEqual(
                policy_components[key]["commit"], EXPECTED_HTTP3_COMMIT
            )
            self.assertIn(
                f"/{EXPECTED_HTTP3_COMMIT}/", policy_components[key]["source"]
            )
        stale_http3 = {
            key
            for key in policy_components
            if key.startswith("pkg:github/P4suta/http3@")
            and key not in expected_policy_keys
        }
        self.assertEqual(stale_http3, set())

    def test_native_build_prunes_only_dependency_tests_before_compile(self) -> None:
        build = (ROOT / "packaging/native/build.sh").read_text(encoding="utf-8")
        dependency_fetch = "mix deps.get --only prod --check-locked"
        runtime_prune = (
            '"$root/packaging/native/stage_runtime_gleam_dependencies.sh" '
            '"$stage"'
        )
        dependency_compile = "mix deps.compile"
        self.assertLess(build.index(dependency_fetch), build.index(runtime_prune))
        self.assertLess(build.index(runtime_prune), build.index(dependency_compile))

    def test_release_and_workflow_keep_http3_native_contract(self) -> None:
        mix_project = (ROOT / "mix.exs").read_text(encoding="utf-8")
        native_workflow = (ROOT / ".github/workflows/native.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("gleam_quic: :permanent", mix_project)
        self.assertIn("http3: :permanent", mix_project)
        self.assertRegex(native_workflow, r"(?m)^  pull_request:\s*$")


if __name__ == "__main__":
    unittest.main()
