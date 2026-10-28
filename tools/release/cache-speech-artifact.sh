#!/bin/bash
set -euo pipefail

# Fetch the pinned FluidAudio binary target before SwiftPM starts: URLSession
# downloads have stalled on hosted macOS runners. Derive its URL and checksum
# from the dependency pin so an upgrade cannot leave this cache on an old asset.
root="$(cd "$(dirname "$0")/../.." && pwd)"
revision="$(python3 - "$root/apps/mac/Package.resolved" <<'PY'
import json, re, sys
with open(sys.argv[1]) as stream:
    pins = json.load(stream)["pins"]
matches = [pin for pin in pins if pin["identity"] == "fluidaudio"]
assert len(matches) == 1, "Expected one pinned FluidAudio dependency"
pin = matches[0]
assert pin["location"] == "https://github.com/FluidInference/FluidAudio.git", "Unexpected FluidAudio source"
revision = pin["state"]["revision"]
assert re.fullmatch(r"[0-9a-f]{40}", revision), "Invalid FluidAudio revision"
print(revision)
PY
)"
cache_dir="${HOME}/Library/Caches/org.swift.swiftpm/artifacts"
mkdir -p "$cache_dir"
work_dir="$(mktemp -d "$cache_dir/.nemo-download.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
manifest="$work_dir/Package.swift"
curl_args=(--fail --location --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 120)

# Release CI uses Swift 6.2. Prefer its manifest, falling back only when that
# versioned manifest is absent; network and server failures must remain errors.
manifest_base="https://raw.githubusercontent.com/FluidInference/FluidAudio/$revision"
if ! status="$(curl "${curl_args[@]}" --write-out '%{http_code}' \
    "$manifest_base/Package@swift-6.2.swift" --output "$manifest")"; then
    if [[ "$status" != "404" ]]; then
        echo "Could not fetch pinned FluidAudio manifest (HTTP $status)." >&2
        exit 1
    fi
    curl "${curl_args[@]}" "$manifest_base/Package.swift" --output "$manifest"
fi

artifact="$(python3 - "$manifest" <<'PY'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
matches = re.findall(
    r'\.binaryTarget\s*\(\s*name:\s*"NemoTextProcessing"\s*,\s*'
    r'url:\s*"([^"]+)"\s*,\s*checksum:\s*"([0-9a-f]{64})"\s*\)',
    source,
)
assert len(matches) == 1, "Expected one NemoTextProcessing binary target with a SHA-256 checksum"
url, checksum = matches[0]
assert re.fullmatch(
    r"https://github\.com/FluidInference/text-processing-rs/releases/download/[^/]+/NemoTextProcessing\.xcframework\.zip",
    url,
), "Unexpected NemoTextProcessing artifact URL"
print(url + "\t" + checksum)
PY
)"
IFS=$'\t' read -r url checksum <<< "$artifact"
echo "FluidAudio $revision requires $url"
cache_name="$(printf '%s' "$url" | LC_ALL=C tr -c '[:alnum:]' '_')"
cache_file="$cache_dir/$cache_name"

valid() {
    [[ -f "$1" ]] && [[ "$(shasum -a 256 "$1" | cut -d ' ' -f 1)" == "$checksum" ]]
}

if valid "$cache_file"; then
    echo "Verified cached NemoTextProcessing artifact."
    exit 0
fi

download="$work_dir/artifact.zip"
curl "${curl_args[@]}" "$url" --output "$download"
if ! valid "$download"; then
    echo "NemoTextProcessing artifact checksum mismatch." >&2
    exit 1
fi
mv "$download" "$cache_file"
echo "Cached verified NemoTextProcessing artifact for SwiftPM."
