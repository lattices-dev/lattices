#!/usr/bin/env bash
# A separate, user-owned wf-recorder with cursor exclusion for remote control.
# Does not replace the system recorder or change compositor configuration.
set -euo pipefail

if [[ "$(uname -s)" != Linux ]]; then
  echo "Build this helper on the Linux host that streams the desktop." >&2
  exit 1
fi

for tool in curl tar sha256sum patch meson ninja pkg-config c++ install; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing build dependency: $tool (see packages/host-linux/README.md)." >&2
    exit 1
  fi
done

readonly revision=ca103be2473db0983baf74e17b291385c3c79d79
readonly archive_sha256=85905fdb7872c38de5ad9c4fff59cd14eac5007d79ee55cee4311a076169887b
readonly source_url="https://codeload.github.com/ammen99/wf-recorder/tar.gz/$revision"
readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly patch_file="$script_dir/../patches/wf-recorder-no-cursor.patch"
readonly ffmpeg9_patch="$script_dir/../patches/wf-recorder-ffmpeg9.patch"
readonly build_dir="$(mktemp -d "${TMPDIR:-/tmp}/lattices-recorder.XXXXXXXX")"
readonly destination="$HOME/.lattices/bin/lattices-wf-recorder"
trap 'rm -rf -- "$build_dir"' EXIT

curl --fail --location --proto '=https' --tlsv1.2 "$source_url" -o "$build_dir/source.tar.gz"
printf '%s  %s\n' "$archive_sha256" "$build_dir/source.tar.gz" | sha256sum --check --status
tar -xzf "$build_dir/source.tar.gz" -C "$build_dir"
readonly source_dir="$build_dir/wf-recorder-$revision"
patch --batch --fuzz=0 -d "$source_dir" -p1 < "$patch_file"
# Match Arch's compatibility fix when FFmpeg 9 has removed AVCodec fields.
if pkg-config --atleast-version=63 libavcodec; then
  patch --batch --fuzz=0 -d "$source_dir" -p1 < "$ffmpeg9_patch"
fi
meson setup "$build_dir/build" "$source_dir" --buildtype=release -Dpipewire=disabled -Dpulse=disabled
meson compile -C "$build_dir/build"

# --help exits before connecting to Wayland; check the installed capability.
"$build_dir/build/wf-recorder" --help > "$build_dir/help.txt"
if ! grep -q -- '--no-cursor' "$build_dir/help.txt"; then
  echo "Built recorder is missing --no-cursor; nothing installed." >&2
  exit 1
fi
install -d "$HOME/.lattices/bin" "$HOME/.lattices/share/lattices-wf-recorder"
# Rename atomically so a viewer opening during installation never sees a partial binary.
install -m 0755 "$build_dir/build/wf-recorder" "$destination.new"
mv -f -- "$destination.new" "$destination"
install -m 0644 "$source_dir/LICENSE" "$HOME/.lattices/share/lattices-wf-recorder/LICENSE"
printf 'upstream_revision=%s\nsource_sha256=%s\n' "$revision" "$archive_sha256" > "$HOME/.lattices/share/lattices-wf-recorder/source.txt"
sha256sum "$patch_file" >> "$HOME/.lattices/share/lattices-wf-recorder/source.txt"
if pkg-config --atleast-version=63 libavcodec; then
  sha256sum "$ffmpeg9_patch" >> "$HOME/.lattices/share/lattices-wf-recorder/source.txt"
fi
printf 'Installed %s\nReconnect the viewer after updating the Linux host source.\n' "$destination"
