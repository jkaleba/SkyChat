"""Install explicit Apple signing material on an ephemeral macOS runner.

Only the Runner target is reconfigured. The profile supplies the registered
Bundle ID and team; Android, Pods and RunnerTests settings are left alone.
"""
import base64
import datetime as dt
import hashlib
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import subprocess
import sys


class ConfigurationError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ConfigurationError(message)


def command(args, label):
    result = subprocess.run(args, capture_output=True)
    # Never include argv: security import carries a secret password.
    require(result.returncode == 0, f'{label} failed. Check the certificate, password and Apple profile.')
    return result.stdout


def decode_secret(name):
    value = os.environ.get(name, '').strip()
    require(bool(value), f'Missing GitHub environment secret: {name}')
    try:
        return base64.b64decode(value, validate=True)
    except ValueError:
        raise ConfigurationError(f'{name} must contain Base64 file contents.') from None


def read_profile(profile, identities, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    expires = profile.get('ExpirationDate')
    require(isinstance(expires, dt.datetime), 'Profile has no expiration date.')
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=dt.timezone.utc)
    require(expires > now, 'Apple provisioning profile has expired. Generate a new one.')
    require(not profile.get('ProvisionedDevices') and not profile.get('ProvisionsAllDevices'),
            'Use an App Store Connect distribution profile, not Development, Ad Hoc or Enterprise.')
    entitlements = profile.get('Entitlements', {})
    require(entitlements.get('get-task-allow') is False, 'Use an App Store Connect distribution profile.')
    teams = profile.get('TeamIdentifier', [])
    require(len(teams) == 1 and re.fullmatch(r'[A-Z0-9]{10}', teams[0]), 'Invalid profile Team ID.')
    app_id = entitlements.get('application-identifier', '')
    require('.' in app_id, 'Profile has no explicit App ID.')
    bundle = app_id.split('.', 1)[1]
    require(re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle), 'Use an explicit Bundle ID, not a wildcard profile.')
    require('TAG' in entitlements.get('com.apple.developer.nfc.readersession.formats', []),
            'Enable NFC Tag Reading on the App ID and regenerate the provisioning profile.')
    require(entitlements.get('com.apple.developer.networking.HotspotConfiguration') is True,
            'Enable Hotspot Configuration on the App ID and regenerate the provisioning profile.')
    uuid = profile.get('UUID', '')
    require(re.fullmatch(r'[A-Fa-f0-9-]{36}', uuid), 'Invalid provisioning profile UUID.')
    certificates = {hashlib.sha1(data).hexdigest().upper() for data in profile.get('DeveloperCertificates', [])}
    available = set(re.findall(r'\b[A-Fa-f0-9]{40}\b', identities.upper()))
    matches = certificates & available
    require(len(matches) == 1, 'The P12 private key/certificate does not match this provisioning profile, or is not trusted.')
    return {'team': teams[0], 'bundle': bundle, 'uuid': uuid, 'certificate': matches.pop()}


def configure_project(text, config):
    count = 0

    def rewrite(match):
        nonlocal count
        body = match.group(2)
        if not re.search(r'INFOPLIST_FILE\s*=\s*Runner/Info\.plist;', body):
            return match.group(0)
        count += 1
        settings = {
            'PRODUCT_BUNDLE_IDENTIFIER': config['bundle'],
            'DEVELOPMENT_TEAM': config['team'],
            'CODE_SIGN_STYLE': 'Manual',
            'CODE_SIGN_IDENTITY': config['certificate'],
            '"CODE_SIGN_IDENTITY[sdk=iphoneos*]"': config['certificate'],
            'PROVISIONING_PROFILE_SPECIFIER': config['uuid'],
        }
        for key, value in settings.items():
            pattern = rf'(?m)^\s*{re.escape(key)}\s*=\s*[^;]+;'
            body = re.sub(pattern, '', body)
            body += f'\n\t\t\t\t{key} = "{value}";\n'
        return match.group(1) + body + match.group(3)

    result = re.sub(r'(?ms)(\bbuildSettings\s*=\s*\{)(.*?)(^\s*\};)', rewrite, text)
    require(count == 3, 'Expected exactly three Runner configurations. Update the signing script for this Xcode project.')
    return result


def export_options(config):
    return {
        'method': 'app-store-connect', 'signingStyle': 'manual', 'teamID': config['team'],
        'signingCertificate': config['certificate'],
        'provisioningProfiles': {config['bundle']: config['uuid']},
        'manageAppVersionAndBuildNumber': False, 'uploadSymbols': True,
    }


def work_directory():
    temporary = os.environ.get('RUNNER_TEMP')
    require(bool(temporary), 'This command runs on a GitHub-hosted macOS runner.')
    path = Path(temporary) / 'skychat-ios-signing'
    path.mkdir(parents=True, exist_ok=True)
    return path


def profile_paths():
    run_id = os.environ.get('GITHUB_RUN_ID', '')
    require(run_id.isdigit(), 'Missing GitHub run ID.')
    return [Path.home() / root / f'skychat-ci-{run_id}.mobileprovision' for root in (
        'Library/MobileDevice/Provisioning Profiles',
        'Library/Developer/Xcode/UserData/Provisioning Profiles',
    )]


def install():
    require(sys.platform == 'darwin', 'Signing installation requires the macOS GitHub runner.')
    work = work_directory()
    password = os.environ.get('P12_PASSWORD', '')
    require(bool(password), 'Missing GitHub environment secret: P12_PASSWORD')
    p12 = work / 'distribution.p12'
    p12.write_bytes(decode_secret('BUILD_CERTIFICATE_BASE64')); p12.chmod(0o600)
    profile = work / 'distribution.mobileprovision'
    profile.write_bytes(decode_secret('BUILD_PROVISION_PROFILE_BASE64')); profile.chmod(0o600)
    decoded = command(['security', 'cms', '-D', '-i', str(profile)], 'Read provisioning profile')
    keychain = work / 'signing.keychain-db'
    keychain_password = secrets.token_urlsafe(32)
    previous = shlex.split(command(['security', 'list-keychains', '-d', 'user'], 'Read keychain search list').decode())
    command(['security', 'create-keychain', '-p', keychain_password, str(keychain)], 'Create temporary keychain')
    command(['security', 'set-keychain-settings', '-lut', '21600', str(keychain)], 'Configure temporary keychain')
    command(['security', 'unlock-keychain', '-p', keychain_password, str(keychain)], 'Unlock temporary keychain')
    command(['security', 'import', str(p12), '-P', password, '-A', '-t', 'cert', '-f', 'pkcs12', '-k', str(keychain)], 'Import P12')
    command(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-k', keychain_password, str(keychain)], 'Allow Apple signing tools')
    command(['security', 'list-keychains', '-d', 'user', '-s', str(keychain), *previous], 'Set keychain search list')
    identities = command(['security', 'find-identity', '-v', '-p', 'codesigning', str(keychain)], 'Read signing identity').decode()
    config = read_profile(plistlib.loads(decoded), identities)
    for destination in profile_paths():
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(profile.read_bytes()); destination.chmod(0o600)
    project = Path('ios/Runner.xcodeproj/project.pbxproj')
    project.write_text(configure_project(project.read_text(), config))
    (work / 'ExportOptions.plist').write_bytes(plistlib.dumps(export_options(config)))
    print(f'Signing configured for {config["bundle"]}.')


def upload():
    require(sys.platform == 'darwin', 'Upload requires the macOS GitHub runner.')
    key = os.environ.get('APP_STORE_CONNECT_API_KEY', '').strip()
    key_id = os.environ.get('APP_STORE_CONNECT_KEY_ID', '').strip()
    issuer = os.environ.get('APP_STORE_CONNECT_ISSUER_ID', '').strip()
    require(key.startswith('-----BEGIN PRIVATE KEY-----') and '-----END PRIVATE KEY-----' in key,
            'APP_STORE_CONNECT_API_KEY must contain the full .p8 text, not Base64.')
    require(re.fullmatch(r'[A-Z0-9]{10}', key_id), 'Set APP_STORE_CONNECT_KEY_ID to the Apple team key ID.')
    require(re.fullmatch(r'[A-Fa-f0-9-]{36}', issuer), 'Set APP_STORE_CONNECT_ISSUER_ID to the team issuer UUID.')
    ipas = list(Path('build/ios/ipa').glob('*.ipa'))
    require(len(ipas) == 1, 'Expected one signed IPA.')
    work = work_directory()
    key_path = Path.home() / '.appstoreconnect/private_keys' / f'AuthKey_{key_id}.p8'
    key_path.parent.mkdir(parents=True, exist_ok=True)
    (work / 'upload-key-path.txt').write_text(str(key_path))
    key_path.write_text(key + '\n'); key_path.chmod(0o600)
    try:
        # Keep Apple's diagnostic output: it explains duplicate build numbers,
        # pending agreements, app-record mismatches and validation errors.
        result = subprocess.run(['xcrun', 'altool', '--upload-app', '--type', 'ios', '-f', str(ipas[0]),
                                 '--apiKey', key_id, '--apiIssuer', issuer])
        require(result.returncode == 0, 'Apple rejected the upload. See the altool diagnostic above.')
    finally:
        key_path.unlink(missing_ok=True)
    print('Upload accepted. Wait for Apple processing, then select the build in TestFlight Internal Testing.')


def cleanup():
    if sys.platform != 'darwin' or not os.environ.get('RUNNER_TEMP'):
        return
    work = work_directory()
    keychain = work / 'signing.keychain-db'
    if keychain.exists():
        subprocess.run(['security', 'delete-keychain', str(keychain)], capture_output=True)
    for path in profile_paths():
        path.unlink(missing_ok=True)
    key_manifest = work / 'upload-key-path.txt'
    if key_manifest.exists():
        key_path = Path(key_manifest.read_text())
        expected = Path.home() / '.appstoreconnect/private_keys'
        if key_path.parent == expected and re.fullmatch(r'AuthKey_[A-Z0-9]{10}\.p8', key_path.name):
            key_path.unlink(missing_ok=True)
    for name in ('distribution.p12', 'distribution.mobileprovision', 'ExportOptions.plist', 'upload-key-path.txt'):
        (work / name).unlink(missing_ok=True)


if __name__ == '__main__':
    try:
        require(len(sys.argv) == 2 and sys.argv[1] in ('install', 'upload', 'cleanup'),
                'Usage: ci_signing.py install|upload|cleanup')
        {'install': install, 'upload': upload, 'cleanup': cleanup}[sys.argv[1]]()
    except ConfigurationError as error:
        print(f'::error::{error}', file=sys.stderr)
        sys.exit(1)
