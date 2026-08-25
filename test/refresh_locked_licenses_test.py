# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import sys
import hashlib
import io
import tarfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import refresh_locked_licenses


class RefreshLockedLicensesTest(unittest.TestCase):
    def test_parses_release_specific_hex_licenses(self) -> None:
        metadata = b"""\
{<<"name">>, <<"fixture"/utf8>>}.
{<<"licenses">>, [<<"Apache-2.0"/utf8>>, <<"MIT"/utf8>>]}.
{<<"build_tools">>, [<<"gleam"/utf8>>]}.
"""

        self.assertEqual(
            refresh_locked_licenses.parse_hex_licenses(metadata),
            ("Apache-2.0", "MIT"),
        )

    def test_rejects_missing_hex_licenses(self) -> None:
        with self.assertRaisesRegex(ValueError, "does not declare licenses"):
            refresh_locked_licenses.parse_hex_licenses(
                b'{<<"name">>, <<"fixture"/utf8>>}.\n'
            )

    def test_parses_gleam_manifest_license_fallback(self) -> None:
        self.assertEqual(
            refresh_locked_licenses.parse_gleam_licenses(
                b'name = "fixture"\nlicences = ["MIT", "Apache-2.0"]\n'
            ),
            ("Apache-2.0", "MIT"),
        )

    def test_parses_mix_package_license_fallback(self) -> None:
        self.assertEqual(
            refresh_locked_licenses.parse_mix_licenses(
                b'defp package, do: [licenses: ["MIT", "Apache-2.0"], links: %{}]\n'
            ),
            ("Apache-2.0", "MIT"),
        )

    def test_validates_reviewed_license_file_hashes(self) -> None:
        contents = b"reviewed compound license\n"
        override = {
            "licenses": ["BSD-3-Clause", "BSD-4-Clause", "ISC"],
            "license_files": {"LICENSE": hashlib.sha256(contents).hexdigest()},
            "reason": "Upstream metadata omits its compound license declaration.",
        }

        self.assertEqual(
            refresh_locked_licenses.validate_reviewed_override(
                "pkg:hex/fixture@1.0.0", override, {"LICENSE": contents}
            ),
            ("BSD-3-Clause", "BSD-4-Clause", "ISC"),
        )
        with self.assertRaisesRegex(ValueError, "license file checksum mismatch"):
            refresh_locked_licenses.validate_reviewed_override(
                "pkg:hex/fixture@1.0.0", override, {"LICENSE": b"changed\n"}
            )

    def test_rejects_hex_archives_missing_required_members(self) -> None:
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w") as package:
            metadata = b'{<<"licenses">>,[<<"Apache-2.0">>]}.'
            member = tarfile.TarInfo("metadata.config")
            member.size = len(metadata)
            package.addfile(member, io.BytesIO(metadata))
        component = refresh_locked_licenses.supply_chain_inventory.Component(
            name="fixture",
            version="1.0.0",
            ecosystem="Hex",
            purl="pkg:hex/fixture@1.0.0",
            sources=("fixture.lock",),
            sha256=hashlib.sha256(archive.getvalue()).hexdigest(),
        )
        original_download = refresh_locked_licenses._download
        self.addCleanup(setattr, refresh_locked_licenses, "_download", original_download)
        refresh_locked_licenses._download = lambda _url: archive.getvalue()

        with self.assertRaisesRegex(ValueError, "missing a required member"):
            refresh_locked_licenses._hex_policy(component, None)


if __name__ == "__main__":
    unittest.main()
