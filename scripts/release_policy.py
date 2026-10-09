"""Pure release checks shared by the packager and its synthetic policy fixtures."""
import datetime
import hashlib
import re

TEAM_ID = "KBLA5ALX62"
BUNDLE_ID = "com.leakret.app"
ACCESS_GROUP = TEAM_ID + "." + BUNDLE_ID
GRDB_LICENSE_SHA256 = "9853f9dce81365fcc1d9b46004633354450164b8d17904e92e80c444545f7e87"
BETTERLEAKS_BINARY_SHA256 = "70d2103c2915aababa0e1eea121bd3db0ff0da86bee40ddc6f5982181acaf6d0"
BETTERLEAKS_RULES_SHA256 = "a8f553eb634ac3c5c1ca3f0dc95e2b8abdea7d14b622604c5af07f30ce7926ef"
BETTERLEAKS_LICENSE_SHA256 = "caea114592a8f8e5e05a116d63a99e0ccd79a3ff74f4ddf270bcf4c929eb021e"
RUNTIME_EXCEPTIONS = {
    "com.apple.security.get-task-allow", "get-task-allow", "com.apple.security.cs.debugger",
    "com.apple.security.cs.allow-jit", "com.apple.security.cs.allow-unsigned-executable-memory",
    "com.apple.security.cs.disable-executable-page-protection",
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.cs.allow-dyld-environment-variables",
}


class ReleaseError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def validate_team(team):
    require(team == TEAM_ID, "Release team must preserve the existing personal vault identity " + TEAM_ID + ".")


def validate_identity_request(identity, team):
    validate_team(team)
    require(bool(identity), "Supply one exact Developer ID Application name or SHA-1 fingerprint.")
    require(bool(re.fullmatch(r"[0-9a-fA-F]{40}", identity)) or
            (identity.startswith("Developer ID Application: ") and identity.endswith("(" + team + ")")),
            "Use an exact Developer ID Application identity for the personal team; generic identity names are refused.")


def select_explicit_identity(identity, team, installed_output):
    validate_identity_request(identity, team)
    identities = re.findall(r'^\s*\d+\)\s+([0-9a-fA-F]{40})\s+"([^"\n]+)"', installed_output, flags=re.MULTILINE)
    matches = [(sha.upper(), name) for sha, name in identities
               if sha.upper() == identity.upper() or name == identity]
    require(len(matches) == 1, "Supplied identity is missing or ambiguous; provide its exact installed fingerprint.")
    sha, name = matches[0]
    require(name.startswith("Developer ID Application: ") and name.endswith("(" + team + ")"),
            "Supplied certificate belongs to a different team or is not Developer ID Application.")
    return sha


def validate_build(manifest):
    build = manifest.get("applicationBuild", {})
    require(build.get("configuration") == "Release", "Build a Release bundle before packaging.")
    conditions = build.get("swiftCompilationConditions")
    require(isinstance(conditions, list) and all(isinstance(value, str) for value in conditions)
            and "DEBUG" not in conditions, "Release build metadata must exclude the DEBUG compilation condition.")
    flags = build.get("otherSwiftFlags")
    require(isinstance(flags, list) and all(isinstance(value, str) for value in flags) and
            "-DDEBUG" not in flags and not any(flags[index:index + 2] == ["-D", "DEBUG"]
                                               for index in range(len(flags))),
            "Release compiler flags must exclude DEBUG definitions.")
    require(build.get("architectures") == ["arm64"], "Only the declared Apple Silicon build is validated.")
    require(build.get("minimumSystemVersion") == "14.0", "Release metadata must retain the macOS 14 baseline.")


def validate_entitlements(entitlements, *, app):
    require(isinstance(entitlements, dict), "Code entitlements could not be decoded.")
    for key in RUNTIME_EXCEPTIONS:
        require(key not in entitlements or entitlements[key] is False or
                type(entitlements[key]) is int and entitlements[key] == 0,
                "Release code has a debug or unvalidated runtime-exception entitlement: " + key)
    if app:
        require(entitlements.get("com.apple.application-identifier") == ACCESS_GROUP,
                "Application identifier does not preserve the existing vault identity.")
        require(entitlements.get("keychain-access-groups") == [ACCESS_GROUP],
                "Application Keychain access groups must contain only the stable Spillcheck group.")
        require(entitlements.get("com.apple.developer.team-identifier", TEAM_ID) == TEAM_ID,
                "Application team entitlement is mismatched.")
        allowed = {"com.apple.application-identifier", "com.apple.developer.team-identifier", "keychain-access-groups"}
        require(set(entitlements).issubset(allowed | RUNTIME_EXCEPTIONS), "Application has an unreviewed release entitlement.")
    else:
        require(not entitlements, "Bundled helper/scanner must have no entitlements.")


def validate_signature(description, team):
    validate_team(team)
    require(re.search(r'^TeamIdentifier=' + re.escape(team) + r'$', description, flags=re.MULTILINE) is not None,
            "Code signature has a mismatched team.")
    authorities = re.findall(r'^Authority=(.+)$', description, flags=re.MULTILINE)
    require(authorities and authorities[0].startswith("Developer ID Application: ") and
            authorities[0].endswith("(" + team + ")"), "Code must use a personal-team Developer ID Application signature.")
    timestamp = re.search(r'^Timestamp=(.+)$', description, flags=re.MULTILINE)
    require(timestamp is not None and timestamp[1].lower() not in {"none", "n/a", ""},
            "Code signature is missing a secure timestamp.")
    require(re.search(r'flags=0x[0-9a-fA-F]+\([^\n)]*\bruntime\b[^\n)]*\)', description) is not None,
            "Code signature must enable hardened runtime.")


def permitted_profile_value(claim, values):
    return isinstance(values, list) and any(isinstance(value, str) and
        (value == claim or value.startswith(TEAM_ID + ".") and value.endswith("*") and
         value.count("*") == 1 and claim.startswith(value[:-1])) for value in values)


def validate_profile(profile, team, certificate_fingerprint, now=None):
    validate_team(team)
    require(isinstance(profile, dict), "Embedded provisioning profile could not be decoded.")
    require(profile.get("TeamIdentifier") == [team], "Distribution provisioning profile has a mismatched team.")
    require("ProvisionedDevices" not in profile, "A development/ad-hoc provisioning profile cannot be distributed.")
    certificates = profile.get("DeveloperCertificates")
    require(isinstance(certificates, list) and any(isinstance(certificate, bytes) and
            hashlib.sha1(certificate).hexdigest().upper() == certificate_fingerprint.upper()
            for certificate in certificates), "Distribution profile does not authorize the signing certificate.")
    entitlements = profile.get("Entitlements", {})
    require(isinstance(entitlements, dict), "Provisioning-profile entitlements are malformed.")
    require(not entitlements.get("get-task-allow") and not entitlements.get("com.apple.security.get-task-allow"),
            "Development provisioning profile is not permitted.")
    app_id = entitlements.get("com.apple.application-identifier", entitlements.get("application-identifier"))
    require(isinstance(app_id, str) and permitted_profile_value(ACCESS_GROUP, [app_id]),
            "Distribution profile does not authorize Spillcheck's application identifier.")
    require(permitted_profile_value(ACCESS_GROUP, entitlements.get("keychain-access-groups")),
            "Distribution profile does not authorize Spillcheck's stable Keychain access group.")
    expiry = profile.get("ExpirationDate")
    require(isinstance(expiry, datetime.datetime), "Distribution provisioning profile has no expiration date.")
    expiry = expiry.replace(tzinfo=datetime.timezone.utc) if expiry.tzinfo is None else expiry
    now = now or datetime.datetime.now(datetime.timezone.utc)
    require(expiry > now, "Distribution provisioning profile has expired.")
    require(profile.get("Platform") == ["OSX"], "Use a macOS Developer ID distribution provisioning profile.")


def validate_minimum_os(description):
    require(re.search(r'^\s*platform\s+MACOS\s*$', description, flags=re.MULTILINE) is not None or
            "LC_VERSION_MIN_MACOSX" in description, "Bundled code is not a macOS executable.")
    versions = re.findall(r'^\s*(?:minos|version)\s+(\d+)\.(\d+)(?:\.(\d+))?\s*$', description, flags=re.MULTILINE)
    require(len(versions) == 1 and tuple(int(value or 0) for value in versions[0]) <= (14, 0, 0),
            "Bundled code requires a newer OS than the macOS 14 baseline.")
