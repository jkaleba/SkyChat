import copy
import datetime as dt
import hashlib
import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'ci_signing.py'
spec = importlib.util.spec_from_file_location('ci_signing', SCRIPT)
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


def profile():
    return {
        'ExpirationDate': dt.datetime(2099, 1, 1),
        'TeamIdentifier': ['ABCDE12345'],
        'UUID': '12345678-1234-1234-1234-123456789abc',
        'DeveloperCertificates': [b'test-certificate'],
        'Entitlements': {
            'application-identifier': 'ABCDE12345.pl.example.skychat',
            'get-task-allow': False,
            'com.apple.developer.nfc.readersession.formats': ['TAG'],
            'com.apple.developer.networking.HotspotConfiguration': True,
        },
    }


IDENTITY = hashlib.sha1(b'test-certificate').hexdigest().upper()


class SigningTests(unittest.TestCase):
    def test_profile_binds_team_bundle_and_imported_private_key_identity(self):
        config = signing.read_profile(profile(), f'1) {IDENTITY} "Apple Distribution: Test"')
        self.assertEqual(config['bundle'], 'pl.example.skychat')
        self.assertEqual(config['team'], 'ABCDE12345')
        self.assertEqual(config['certificate'], IDENTITY)
        options = signing.export_options(config)
        self.assertEqual(options['method'], 'app-store-connect')
        self.assertEqual(options['provisioningProfiles'], {config['bundle']: config['uuid']})
        with self.assertRaises(signing.ConfigurationError):
            signing.read_profile(profile(), 'no matching private key')

    def test_missing_capabilities_are_rejected_before_building(self):
        for key in ('com.apple.developer.nfc.readersession.formats',
                    'com.apple.developer.networking.HotspotConfiguration'):
            value = profile()
            value['Entitlements'].pop(key)
            with self.subTest(key=key), self.assertRaises(signing.ConfigurationError):
                signing.read_profile(value, IDENTITY)

    def test_development_adhoc_enterprise_expired_and_wildcard_profiles_are_rejected(self):
        variants = []
        value = profile(); value['Entitlements']['get-task-allow'] = True; variants.append(value)
        value = profile(); value['ProvisionedDevices'] = ['device-udid']; variants.append(value)
        value = profile(); value['ProvisionsAllDevices'] = True; variants.append(value)
        value = profile(); value['ExpirationDate'] = dt.datetime(2000, 1, 1); variants.append(value)
        value = profile(); value['Entitlements']['application-identifier'] = 'ABCDE12345.*'; variants.append(value)
        for value in variants:
            with self.subTest(value=value), self.assertRaises(signing.ConfigurationError):
                signing.read_profile(value, IDENTITY)

    def test_only_runner_configs_change_and_reconfiguration_is_idempotent(self):
        project_path = Path(__file__).resolve().parents[3] / 'ios/Runner.xcodeproj/project.pbxproj'
        original = project_path.read_text()
        config = signing.read_profile(profile(), IDENTITY)
        changed = signing.configure_project(original, config)
        self.assertEqual(changed.count('PRODUCT_BUNDLE_IDENTIFIER = "pl.example.skychat";'), 3)
        self.assertEqual(changed.count('CODE_SIGN_STYLE = "Manual";'), 3)
        for line in original.splitlines():
            if 'RunnerTests' in line or 'IPHONEOS_DEPLOYMENT_TARGET' in line:
                self.assertIn(line, changed)
        second = copy.deepcopy(config); second['bundle'] = 'pl.example.skychat.next'
        repeated = signing.configure_project(changed, second)
        self.assertEqual(repeated.count('PRODUCT_BUNDLE_IDENTIFIER = "pl.example.skychat.next";'), 3)
        self.assertNotIn('PRODUCT_BUNDLE_IDENTIFIER = "pl.example.skychat";', repeated)
        self.assertEqual(repeated.count('PROVISIONING_PROFILE_SPECIFIER = '), 3)

    def test_unknown_project_layout_fails_instead_of_silently_missigning(self):
        with self.assertRaises(signing.ConfigurationError):
            signing.configure_project('buildSettings = { unrelated = YES;\n};',
                                      signing.read_profile(profile(), IDENTITY))


if __name__ == '__main__':
    unittest.main()
