#!/bin/bash
set -euo pipefail

# FluidAudio 0.15.6 declares this binary target. Fetch it with bounded retries
# before SwiftPM starts: URLSession downloads have stalled on hosted macOS runners.
# Checksum source: FluidAudio/Package.swift at 4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b.
url="https://github.com/FluidInference/text-processing-rs/releases/download/v0.3.0/NemoTextProcessing.xcframework.zip"
checksum="76d0ee9a32b1ee2193231299180ca9bc4fc7e98794e771b3d55d66498352d85f"
cache_dir="${HOME}/Library/Caches/org.swift.swiftpm/artifacts"
cache_name="$(printf '%s' "$url" | LC_ALL=C tr -c '[:alnum:]' '_')"
cache_file="$cache_dir/$cache_name"
mkdir -p "$cache_dir"

valid() {
    [[ -f "$1" ]] && [[ "$(shasum -a 256 "$1" | cut -d ' ' -f 1)" == "$checksum" ]]
}

if valid "$cache_file"; then
    echo "Verified cached NemoTextProcessing artifact."
    exit 0
fi

download="$(mktemp "$cache_dir/.nemo-download.XXXXXX")"
trap 'rm -f "$download"' EXIT
curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 120 "$url" --output "$download"
if ! valid "$download"; then
    echo "NemoTextProcessing artifact checksum mismatch." >&2
    exit 1
fi
mv "$download" "$cache_file"
echo "Cached verified NemoTextProcessing artifact for SwiftPM."
