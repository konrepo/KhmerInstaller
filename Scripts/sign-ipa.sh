#!/bin/bash
set -euo pipefail
umask 077

# Identifiers are derived from the provisioning profiles.
APP_ID=""
TUNNEL_ID=""
APP_GROUP=""

WORK=""
TEMP_KEYCHAIN=""
OUTPUT=""

cleanup() {
    if [[ -n "$TEMP_KEYCHAIN" ]]; then
        security delete-keychain "$TEMP_KEYCHAIN" \
            >/dev/null 2>&1 || true
    fi
    if [[ -n "$WORK" ]]; then
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

read_path() {
    local prompt="$1"
    local result
    read -r -p "$prompt" result
    result="${result/#\~/$HOME}"
    [[ -f "$result" ]] || fail "File not found: $result"
    printf '%s' "$result"
}

echo "========================================"
echo " KhmerInstaller IPA Signing Tool"
echo "========================================"
echo
echo "1) Import .p12 certificate"
echo "2) Use existing Keychain certificate"
echo "3) Exit"
echo

read -r -p "Choice: " METHOD

case "$METHOD" in
    1|2) ;;
    3) exit 0 ;;
    *) fail "Invalid selection." ;;
esac

echo
IPA=$(read_path "Unsigned IPA path: ")
echo
MAIN_PROFILE=$(read_path "Main app provisioning profile: ")
TUNNEL_PROFILE=$(read_path "Packet Tunnel provisioning profile: ")

WORK=$(mktemp -d "${TMPDIR:-/tmp/}khmer-sign.XXXXXXXX")
mkdir -p "$WORK/Payload"

echo
echo "=== EXTRACT IPA ==="

# Validate archive structure before extraction.
python3 - "$IPA" <<'PYTHON'
import sys
import zipfile
import stat

seen = set()

with zipfile.ZipFile(sys.argv[1]) as archive:
    for info in archive.infolist():
        name = info.filename
        parts = name.rstrip("/").split("/")

        if (
            not name.startswith("Payload/")
            or name.startswith("/")
            or "\\" in name
            or any(part in ("", ".", "..") for part in parts)
        ):
            raise SystemExit("Unsafe IPA archive path.")

        normalized = name.rstrip("/")

        if normalized in seen:
            raise SystemExit("Duplicate IPA archive entry.")

        seen.add(normalized)

        mode = (info.external_attr >> 16) & 0o170000

        if mode not in (
            0,
            stat.S_IFREG,
            stat.S_IFDIR,
        ):
            raise SystemExit("Unsupported IPA file type.")

        if info.is_dir() and mode == stat.S_IFREG:
            raise SystemExit("Invalid directory entry.")

        if not info.is_dir() and mode == stat.S_IFDIR:
            raise SystemExit("Invalid file entry.")

print("PASS: IPA archive structure validated.")
PYTHON

ditto -x -k "$IPA" "$WORK"

APP="$WORK/Payload/KunInstaller.app"
TUNNEL="$APP/PlugIns/KunInstallerTunnel.appex"
FRAMEWORK="$APP/Frameworks/OpenSSL.framework"

[[ -d "$APP" ]] || fail "Main app missing."
[[ -d "$TUNNEL" ]] || fail "Packet Tunnel missing."
[[ -d "$FRAMEWORK" ]] || fail "OpenSSL framework missing."

echo "=== DECODE PROVISIONING PROFILES ==="

security cms -D -i "$MAIN_PROFILE" \
    -o "$WORK/main-profile.plist" \
    || fail "Invalid main provisioning profile."

security cms -D -i "$TUNNEL_PROFILE" \
    -o "$WORK/tunnel-profile.plist" \
    || fail "Invalid Packet Tunnel provisioning profile."

echo "=== VALIDATE PROFILES ==="

python3 - \
    "$WORK/main-profile.plist" \
    "$WORK/tunnel-profile.plist" \
    "$APP/Info.plist" \
    "$TUNNEL/Info.plist" \
    "$WORK" <<'PYTHON'
import sys
import plistlib
from pathlib import Path
from datetime import datetime, timezone

main_path, tunnel_path, app_info_path, tunnel_info_path, work_path = sys.argv[1:]

def load(path):
    with open(path, "rb") as f:
        return plistlib.load(f)

main = load(main_path)
tunnel = load(tunnel_path)
app_info = load(app_info_path)
tunnel_info = load(tunnel_info_path)

# Derive identifiers from the provisioning profiles.
main_team = main["TeamIdentifier"][0]
tunnel_team = tunnel["TeamIdentifier"][0]

assert main_team == tunnel_team, "Profiles use different teams"

main_ent = main["Entitlements"]
tunnel_ent = tunnel["Entitlements"]

main_application = main_ent["application-identifier"]
tunnel_application = tunnel_ent["application-identifier"]

prefix = main_team + "."

assert main_application.startswith(prefix), "Invalid main App ID"
assert tunnel_application.startswith(prefix), "Invalid tunnel App ID"

app_id = main_application[len(prefix):]
tunnel_id = tunnel_application[len(prefix):]

assert "*" not in app_id, "Wildcard main App ID unsupported"
assert "*" not in tunnel_id, "Wildcard tunnel App ID unsupported"

assert tunnel_id == app_id + ".KunInstallerTunnel", (
    "Packet Tunnel Bundle ID does not match main app"
)

main_groups = set(
    main_ent.get("com.apple.security.application-groups", [])
)
tunnel_groups = set(
    tunnel_ent.get("com.apple.security.application-groups", [])
)

shared_groups = sorted(main_groups & tunnel_groups)

assert len(shared_groups) == 1, (
    "Expected exactly one shared App Group"
)

group = shared_groups[0]

assert group.startswith("group."), "Invalid App Group"

# Update only the extracted IPA metadata.
app_info["CFBundleIdentifier"] = app_id
tunnel_info["CFBundleIdentifier"] = tunnel_id

app_info["KhmerInstallerAppGroup"] = group
tunnel_info["KhmerInstallerAppGroup"] = group

with open(app_info_path, "wb") as f:
    plistlib.dump(app_info, f)

with open(tunnel_info_path, "wb") as f:
    plistlib.dump(tunnel_info, f)

print("Main Bundle ID:", app_id)
print("Tunnel Bundle ID:", tunnel_id)
print("Shared App Group:", group)

teams = []
now = datetime.now(timezone.utc)

for label, profile, bundle_id in [
    ("Main", main, app_id),
    ("Tunnel", tunnel, tunnel_id),
]:
    team_ids = profile.get("TeamIdentifier", [])
    assert len(team_ids) == 1, f"{label}: Invalid TeamIdentifier"
    team = team_ids[0]
    teams.append(team)

    expiry = profile.get("ExpirationDate")
    assert expiry is not None, f"{label}: Missing expiration"
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=timezone.utc)
    assert expiry > now, f"{label}: Profile expired"

    ent = profile.get("Entitlements", {})
    expected = team + "." + bundle_id

    assert ent.get("application-identifier") == expected, (
        f"{label}: Bundle ID not authorized"
    )
    assert ent.get("com.apple.developer.team-identifier") == team, (
        f"{label}: Team entitlement mismatch"
    )

    groups = ent.get("com.apple.security.application-groups", [])
    assert group in groups, f"{label}: App Group not authorized"

    network = ent.get("com.apple.developer.networking.networkextension", [])
    assert "packet-tunnel-provider" in network, (
        f"{label}: Packet Tunnel entitlement missing"
    )

    assert profile.get("DeveloperCertificates"), (
        f"{label}: No developer certificates"
    )

    # Generate signing entitlements from the authorized profile.
    # Do not copy unrelated provisioning-profile metadata.
    required_keys = (
        "application-identifier",
        "com.apple.developer.team-identifier",
        "com.apple.security.application-groups",
        "com.apple.developer.networking.networkextension",
    )

    optional_keys = (
        "keychain-access-groups",
        "get-task-allow",
        "aps-environment",
        "com.apple.developer.associated-domains",
    )

    signing_entitlements = {
        key: ent[key]
        for key in required_keys
    }

    # Request only the Network Extension capability
    # actually used by KhmerInstaller.
    signing_entitlements[
        "com.apple.developer.networking.networkextension"
    ] = ["packet-tunnel-provider"]

    # Use only the App Group selected for this IPA.
    signing_entitlements[
        "com.apple.security.application-groups"
    ] = [group]

    for key in optional_keys:
        if key in ent:
            signing_entitlements[key] = ent[key]

    output = (
        Path(work_path)
        / f"{label.lower()}-entitlements.plist"
    )

    with open(output, "wb") as f:
        plistlib.dump(signing_entitlements, f)

assert teams[0] == teams[1], "Provisioning profiles belong to different teams"

print("PASS: Bundle IDs")
print("PASS: App Group")
print("PASS: Network Extension")
print("PASS: Team IDs")
print("PASS: Profile expiration")
PYTHON

echo
echo "=== SELECT SIGNING CERTIFICATE ==="

if [[ "$METHOD" == "1" ]]; then
    P12=$(read_path ".p12 certificate path: ")

    echo "macOS will request the .p12 password securely."

    TEMP_KEYCHAIN="$WORK/signing.keychain-db"

    KEYCHAIN_PASSWORD=$(openssl rand -hex 24)

    security create-keychain \
        -p "$KEYCHAIN_PASSWORD" "$TEMP_KEYCHAIN"

    security unlock-keychain \
        -p "$KEYCHAIN_PASSWORD" "$TEMP_KEYCHAIN"

    security set-keychain-settings -lut 21600 "$TEMP_KEYCHAIN"

    # Omit -P so macOS requests the password securely.
    security import "$P12" \
        -k "$TEMP_KEYCHAIN" \
        -f pkcs12 \
        -T /usr/bin/codesign \
        || fail "Certificate import failed."

    security set-key-partition-list \
        -S apple-tool:,apple: \
        -s \
        -k "$KEYCHAIN_PASSWORD" \
        "$TEMP_KEYCHAIN" >/dev/null

    security find-identity -v -p codesigning "$TEMP_KEYCHAIN"

    read -r -p "Enter signing identity SHA-1: " IDENTITY

    SIGNING_KEYCHAIN="$TEMP_KEYCHAIN"
else
    security find-identity -v -p codesigning

    read -r -p "Enter signing identity SHA-1: " IDENTITY

    SIGNING_KEYCHAIN=""
fi

[[ "$IDENTITY" =~ ^[A-Fa-f0-9]{40}$ ]] \
    || fail "Invalid signing identity SHA-1."

IDENTITY=$(printf '%s' "$IDENTITY" | tr '[:lower:]' '[:upper:]')

echo
echo "=== VERIFY SIGNING IDENTITY ==="

if [[ "$METHOD" == "1" ]]; then
    IDENTITY_LIST=$(
        security find-identity -v -p codesigning "$TEMP_KEYCHAIN"
    )
else
    IDENTITY_LIST=$(
        security find-identity -v -p codesigning
    )
fi

if ! printf '%s\n' "$IDENTITY_LIST" |
    grep -Eq "^[[:space:]]*[0-9]+\) ${IDENTITY}[[:space:]]"
then
    fail "Selected signing identity is not available or valid in the selected Keychain."
fi

echo "PASS: Signing identity available."

echo
echo "=== VALIDATE CERTIFICATE AGAINST PROFILES ==="

python3 - \
    "$WORK/main-profile.plist" \
    "$WORK/tunnel-profile.plist" \
    "$IDENTITY" <<'PYTHON'
import sys
import hashlib
import plistlib

identity = sys.argv[3].lower()

for path in sys.argv[1:3]:
    with open(path, "rb") as f:
        profile = plistlib.load(f)

    certificates = profile["DeveloperCertificates"]

    fingerprints = [
        hashlib.sha1(cert).hexdigest().lower()
        for cert in certificates
    ]

    assert identity in fingerprints, (
        "Selected certificate is not authorized by a provisioning profile"
    )

print("PASS: Certificate authorized by both profiles")
PYTHON

echo
echo "=== INSTALL PROVISIONING PROFILES ==="

ditto "$MAIN_PROFILE" "$APP/embedded.mobileprovision"
ditto "$TUNNEL_PROFILE" "$TUNNEL/embedded.mobileprovision"

echo
echo "=== SIGN OPENSSL FRAMEWORK ==="

sign_component() {
    if [[ -n "$SIGNING_KEYCHAIN" ]]; then
        codesign --force --sign "$IDENTITY" \
            --keychain "$SIGNING_KEYCHAIN" "$@"
    else
        codesign --force --sign "$IDENTITY" "$@"
    fi
}

sign_component \
    "$FRAMEWORK"

echo
echo "=== SIGN PACKET TUNNEL ==="

sign_component \
    --entitlements "$WORK/tunnel-entitlements.plist" \
    "$TUNNEL"

echo
echo "=== SIGN MAIN APP ==="

sign_component \
    --entitlements "$WORK/main-entitlements.plist" \
    "$APP"

echo
echo "=== VERIFY SIGNATURES ==="

codesign --verify --strict --verbose=2 "$FRAMEWORK"
codesign --verify --strict --verbose=2 "$TUNNEL"
codesign --verify --strict --verbose=2 "$APP"

echo
echo "=== VERIFY SIGNED ENTITLEMENTS ==="

codesign -d --entitlements :- "$APP" \
    > "$WORK/main-signed-entitlements.plist" 2>/dev/null

codesign -d --entitlements :- "$TUNNEL" \
    > "$WORK/tunnel-signed-entitlements.plist" 2>/dev/null

python3 - "$WORK" <<'PYTHON'
import plistlib
import sys
from pathlib import Path

work = Path(sys.argv[1])

for component in ("main", "tunnel"):
    expected_path = work / f"{component}-entitlements.plist"
    actual_path = work / f"{component}-signed-entitlements.plist"

    with expected_path.open("rb") as f:
        expected = plistlib.load(f)

    with actual_path.open("rb") as f:
        actual = plistlib.load(f)

    if actual != expected:
        raise SystemExit(
            f"STOP: {component} signed entitlements do not match."
        )

    print(f"PASS: {component} signed entitlements verified.")
PYTHON

echo
echo "=== EXPORT SIGNED IPA ==="

if [[ "$METHOD" == "1" ]]; then
    OUTPUT="$(dirname "$IPA")/KhmerInstaller-Signed-P12.ipa"
else
    OUTPUT="$(dirname "$IPA")/KhmerInstaller-Signed-Keychain.ipa"
fi

[[ ! -e "$OUTPUT" ]] || fail "Output already exists: $OUTPUT"

echo "=== PACKAGE AND VERIFY ==="

TEMP_OUTPUT="$WORK/KhmerInstaller-Signed.ipa"

(
    cd "$WORK"
    zip -q -r -y "$TEMP_OUTPUT" Payload
)

unzip -t "$TEMP_OUTPUT" > "$WORK/zip-verification.log"

echo "PASS: Signed IPA archive verified."

# Copy only after packaging and verification succeed.
# Refuse to overwrite an existing destination.
python3 - "$TEMP_OUTPUT" "$OUTPUT" <<'PYTHON'
import os
import shutil
import sys

source, destination = sys.argv[1:]

destination_dir = os.path.dirname(os.path.abspath(destination))

import tempfile

fd, temporary = tempfile.mkstemp(
    prefix=".khmerinstaller-",
    suffix=".ipa.tmp",
    dir=destination_dir
)

try:
    with open(source, "rb") as src:
        with os.fdopen(fd, "wb") as dst:
            shutil.copyfileobj(src, dst)
            dst.flush()
            os.fsync(dst.fileno())

    # Atomic publication without overwriting an existing IPA.
    os.link(temporary, destination)
finally:
    os.unlink(temporary)
PYTHON

echo
echo "SUCCESS: Signed IPA created."
echo "Output: $OUTPUT"
