#!/bin/bash
# Installs the published v1.0.0 Mac app without sudo or security-policy changes.
set -euo pipefail
version=1.0.0
base="https://github.com/agraja38/Caliper3D/releases/download/v$version"
image="Caliper3D-$version.dmg"
if [[ $(uname -s) != Darwin ]]; then
  echo 'Caliper3D requires macOS 14 or later.' >&2; exit 1
fi
major=$(/usr/bin/sw_vers -productVersion | cut -d. -f1)
if (( major < 14 )); then
  echo 'Caliper3D requires macOS 14 or later.' >&2; exit 1
fi
destination="$HOME/Applications/Caliper3D.app"
if [[ -e "$destination" || -L "$destination" ]]; then
  echo "An app already exists at $destination. Move it aside before installing." >&2; exit 1
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/caliper3d-install.XXXXXX")
mounted=false
staged=''
cleanup() {
  if [[ "$mounted" == true ]]; then /usr/bin/hdiutil detach "$work/mount" -quiet || true; fi
  if [[ -n "$staged" ]]; then rm -rf "$staged"; fi
  rm -rf "$work"
}
trap cleanup EXIT
/usr/bin/curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$base/$image" -o "$work/$image"
/usr/bin/curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$base/$image.sha256" -o "$work/checksum"
# Compare a strictly parsed digest, never execute or use paths from checksum content.
expected=$(awk 'NR == 1 {print $1}' "$work/checksum")
if [[ ! "$expected" =~ ^[a-fA-F0-9]{64}$ ]]; then echo 'Invalid release checksum.' >&2; exit 1; fi
actual=$(/usr/bin/shasum -a 256 "$work/$image" | awk '{print $1}')
if [[ "$actual" != "$expected" ]]; then echo 'Release checksum mismatch.' >&2; exit 1; fi
mkdir "$work/mount"
/usr/bin/hdiutil attach "$work/$image" -mountpoint "$work/mount" -readonly -nobrowse -quiet
mounted=true
app="$work/mount/Caliper3D.app"
/usr/bin/codesign --verify --deep --strict "$app"
installedVersion=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
if [[ "$installedVersion" != "$version" ]]; then echo 'Unexpected app version.' >&2; exit 1; fi
mkdir -p "$HOME/Applications"
staged=$(mktemp -d "$HOME/Applications/.caliper3d-install.XXXXXX")
/usr/bin/ditto "$app" "$staged/Caliper3D.app"
# Refuse replacement, including if another install appeared while downloading.
if [[ -e "$destination" || -L "$destination" ]]; then echo 'Destination now exists; installation cancelled.' >&2; exit 1; fi
/bin/mv -n "$staged/Caliper3D.app" "$destination"
if [[ -d "$staged/Caliper3D.app" ]]; then echo 'Installation was not completed.' >&2; exit 1; fi
printf 'Installed Caliper3D %s to %s\n' "$version" "$destination"
printf '%s\n' 'This foundation/demo release is ad-hoc signed and not notarized.' \
  'Open it from Finder. If macOS blocks it, review Privacy & Security in System Settings.' \
  'Live object scanning is not implemented in this release.'
