"""Contract: the version the app reports is the version that was released.

``source/Version.mc`` is the only place the app knows its own build. A Connect
IQ manifest has no version field and the store's number is not readable at
runtime, so if this constant is stale the About screen confidently reports the
wrong build -- which is worse than reporting nothing, because it is the line
someone checks to answer "did the fix reach the watch?".

Nothing keeps it in step with ``CHANGELOG.md`` except this test.

A failure here means "go edit the other side", not "fix this test".
"""

import os
import re
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
# contract -> tests -> mappack -> tools -> repo root
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
VERSION_MC = os.path.join(ROOT, "source", "Version.mc")
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")


def declared_version():
    with open(VERSION_MC, encoding="utf-8") as fh:
        match = re.search(r'const\s+APP\s*=\s*"([^"]+)"', fh.read())
    return match.group(1) if match else None


def newest_released_version():
    """The first `## [x.y.z] - date` heading, skipping `[Unreleased]`."""
    with open(CHANGELOG, encoding="utf-8") as fh:
        match = re.search(r"^## \[(\d+\.\d+\.\d+)\] - ", fh.read(), re.M)
    return match.group(1) if match else None


class TestVersionContract(unittest.TestCase):

    def test_version_mc_declares_a_version(self):
        self.assertIsNotNone(declared_version(),
                             "source/Version.mc has no `const APP = \"x.y.z\"`")

    def test_changelog_has_a_released_section(self):
        self.assertIsNotNone(newest_released_version(),
                             "CHANGELOG.md has no released `## [x.y.z] - date`")

    def test_the_app_reports_the_version_that_was_released(self):
        declared = declared_version()
        released = newest_released_version()
        self.assertEqual(
            declared, released,
            "source/Version.mc says %r but the newest CHANGELOG entry is %r. "
            "Bump Version.mc in the commit that cuts the release."
            % (declared, released))

    def test_version_is_three_numeric_parts(self):
        # The About screen prints this straight out, and the release tag is
        # built from it by hand. A stray suffix would show up on the watch.
        self.assertRegex(declared_version() or "", r"^\d+\.\d+\.\d+$")


if __name__ == "__main__":
    unittest.main()
