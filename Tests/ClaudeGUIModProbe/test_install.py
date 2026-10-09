"""Owned-entry comparisons, without provider/global configuration mutation."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("mod_install_test", Path(__file__).with_name("install.py"))
install = importlib.util.module_from_spec(spec)
spec.loader.exec_module(install)
MARKETPLACE = "spillcheck-side-probe-00000000"
PLUGIN = "spillcheck-side-probe@" + MARKETPLACE

class OwnedInstallComparisons(unittest.TestCase):
    def test_only_owned_entries_and_empty_owned_containers_are_removed(self):
        original = {"permissions": {"allow": ["private-unowned-permission"]}, "enabledPlugins": {"private-unowned-plugin": True}}
        installed = {**original, "enabledPlugins": {"private-unowned-plugin": True, PLUGIN: True},
            "extraKnownMarketplaces": {MARKETPLACE: {"private-path": True}}}
        self.assertEqual(install.without_owned(installed, MARKETPLACE, PLUGIN), original)
        self.assertEqual(install.without_owned(None, MARKETPLACE, PLUGIN), {})
        installed["enabledPlugins"].pop("private-unowned-plugin")
        self.assertNotEqual(install.without_owned(installed, MARKETPLACE, PLUGIN), original)

    def test_current_unowned_edits_survive_removal_without_restoring_old_settings(self):
        initial = {"settings": {"permissions": {"allow": ["private-old"]}}}
        before = {"settings": {"permissions": {"allow": ["private-old", "private-concurrent"]},
            "enabledPlugins": {PLUGIN: True}}}
        after = {"settings": {"permissions": {"allow": ["private-old", "private-concurrent"]}}}
        self.assertTrue(install.comparison(before, after, MARKETPLACE, PLUGIN)["settings"])
        self.assertFalse(install.comparison(initial, after, MARKETPLACE, PLUGIN)["settings"])

if __name__ == "__main__":
    unittest.main()
