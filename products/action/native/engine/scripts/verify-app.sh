#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/../../.." && pwd)
APP_DIR="${ACTION_DIST_DIR:-$ROOT_DIR/native/dist}/Action.app"
APP_PLIST_PATH="$APP_DIR/Contents/Info.plist"
AGENT_APP_DIR="$APP_DIR/Contents/Helpers/ActionAgent.app"
AGENT_PLIST_PATH="$AGENT_APP_DIR/Contents/Info.plist"

EXPECTED_APP_BUNDLE_ID="dev.lattices.Action"
EXPECTED_AGENT_BUNDLE_ID="dev.lattices.ActionAgent"
EXPECTED_URL_TYPE_NAME="dev.lattices.Action.links"
EXPECTED_URL_SCHEME="action"

if [[ ! -d "$APP_DIR" ]]; then
  echo "Action.app has not been built yet: $APP_DIR" >&2
  exit 1
fi

if [[ ! -d "$AGENT_APP_DIR" ]]; then
  echo "ActionAgent.app is missing from the built app: $AGENT_APP_DIR" >&2
  exit 1
fi

/usr/bin/plutil -lint "$APP_PLIST_PATH" "$AGENT_PLIST_PATH"

app_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PLIST_PATH")
agent_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$AGENT_PLIST_PATH")
url_type_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLName' "$APP_PLIST_PATH")
url_scheme=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$APP_PLIST_PATH")

if [[ "$app_bundle_id" != "$EXPECTED_APP_BUNDLE_ID" ]]; then
  echo "Unexpected Action.app bundle id: $app_bundle_id" >&2
  exit 1
fi

if [[ "$agent_bundle_id" != "$EXPECTED_AGENT_BUNDLE_ID" ]]; then
  echo "Unexpected ActionAgent.app bundle id: $agent_bundle_id" >&2
  exit 1
fi

if [[ "$url_type_name" != "$EXPECTED_URL_TYPE_NAME" ]]; then
  echo "Unexpected Action URL type name: $url_type_name" >&2
  exit 1
fi

if [[ "$url_scheme" != "$EXPECTED_URL_SCHEME" ]]; then
  echo "Unexpected Action URL scheme: $url_scheme" >&2
  exit 1
fi

if ! app_verification=$(codesign --verify --deep --strict --verbose=2 "$APP_DIR" 2>&1); then
  echo "Action.app failed strict signature verification." >&2
  echo "$app_verification" >&2
  exit 1
fi

if ! agent_verification=$(codesign --verify --strict --verbose=2 "$AGENT_APP_DIR" 2>&1); then
  echo "ActionAgent.app failed strict signature verification." >&2
  echo "$agent_verification" >&2
  exit 1
fi

app_signature=$(codesign -dv --verbose=4 "$APP_DIR" 2>&1)
agent_signature=$(codesign -dv --verbose=4 "$AGENT_APP_DIR" 2>&1)

verify_developer_signature() {
  local label="$1"
  local expected_identifier="$2"
  local signature="$3"
  local signed_identifier

  signed_identifier=$(awk -F= '/^Identifier=/{print $2; exit}' <<<"$signature")
  if [[ "$signed_identifier" != "$expected_identifier" ]]; then
    echo "$label signature identifier is $signed_identifier; expected $expected_identifier." >&2
    echo "$signature" >&2
    exit 1
  fi

  if ! grep -q 'Authority=Apple Development:' <<<"$signature" && ! grep -q 'Authority=Developer ID Application:' <<<"$signature"; then
    echo "$label is not signed with a developer identity." >&2
    echo "$signature" >&2
    exit 1
  fi

  if grep -q 'Signature=adhoc' <<<"$signature"; then
    echo "$label is ad-hoc signed, which is not acceptable for stable TCC checks." >&2
    echo "$signature" >&2
    exit 1
  fi

  if grep -q 'Info.plist=not bound' <<<"$signature"; then
    echo "$label signature does not bind Info.plist." >&2
    echo "$signature" >&2
    exit 1
  fi
}

verify_developer_signature "Action.app" "$EXPECTED_APP_BUNDLE_ID" "$app_signature"
verify_developer_signature "ActionAgent.app" "$EXPECTED_AGENT_BUNDLE_ID" "$agent_signature"

app_team_identifier=$(awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$app_signature")
agent_team_identifier=$(awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$agent_signature")

if [[ -z "$app_team_identifier" || "$app_team_identifier" == "not set" ]]; then
  echo "Action.app signature has no TeamIdentifier." >&2
  echo "$app_signature" >&2
  exit 1
fi

if [[ "$agent_team_identifier" != "$app_team_identifier" ]]; then
  echo "Action.app and ActionAgent.app are signed by different teams: $app_team_identifier vs $agent_team_identifier" >&2
  exit 1
fi

echo "bundleId=$app_bundle_id"
echo "agentBundleId=$agent_bundle_id"
echo "urlTypeName=$url_type_name"
echo "urlScheme=$url_scheme"
echo "teamIdentifier=$app_team_identifier"
echo "$app_signature" | awk '/^Identifier=|^Authority=|^TeamIdentifier=|^Signed Time=/{print "Action.app " $0}'
echo "$agent_signature" | awk '/^Identifier=|^Authority=|^TeamIdentifier=|^Signed Time=/{print "ActionAgent.app " $0}'
