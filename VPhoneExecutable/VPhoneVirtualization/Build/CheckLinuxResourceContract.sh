#!/bin/zsh
# vphone-tier: build
set -euo pipefail

root="$(cd "${0:a:h}/../../.." && pwd)"
backend=${1:?usage: CheckLinuxResourceContract.sh backend-source resources.zip VPhone.bundle}
archive=${2:?usage: CheckLinuxResourceContract.sh backend-source resources.zip VPhone.bundle}
reference=${3:?usage: CheckLinuxResourceContract.sh backend-source resources.zip VPhone.bundle}
temporary=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-linux-contract.XXXXXX")
trap '/bin/rm -rf "$temporary"' EXIT
/bin/mkdir -p "$temporary/src" "$temporary/release"
/bin/cp "$archive" "$temporary/release/VPhone-resource-contract.zip"

# Run the real release phase against an isolated source/release directory.
# The preloaded archive prevents its network-download branch from running.
VSETUP_SRC="$temporary/src" VSETUP_RELEASE="$temporary/release" \
    VSETUP_DEVICES="$temporary/unused-devices" SWIFTLY_HOME_DIR="$temporary/unused-swiftly" \
    VPHONE_CLI_PUBLIC=resource-contract /bin/bash "$backend/setup/setup.sh" release

bundle="$temporary/release/app/VPhone.bundle"
resources="$bundle/Contents/Resources"
/usr/bin/diff -qr "$reference/Contents/Resources/guest-resources" "$resources/guest-resources"
[[ "$(/usr/bin/readlink "$temporary/src/guest-resources")" == "$resources/guest-resources" ]]
[[ ! -e "$bundle/Contents/MacOS" && ! -e "$bundle/Contents/Frameworks" ]]
for component in OpenAVB OpenSEP; do
    /usr/bin/cmp "$reference/Contents/Resources/$component/$component.bin" "$temporary/src/$component/$component.bin"
    /usr/bin/cmp "$reference/Contents/Resources/$component/LICENSE" "$resources/$component/LICENSE"
done
/usr/bin/cmp "$reference/Contents/Resources/OpenAVB/APSL-2.0.txt" "$resources/OpenAVB/APSL-2.0.txt"
for notice in vphone-cli.txt Swift-Apache-2.0-with-Runtime-Library-Exception.txt; do
    /usr/bin/cmp "$reference/Contents/Resources/Licenses/$notice" "$resources/Licenses/$notice"
done
"$root/scripts/stage-package-notices.zsh" --check "$resources/Licenses/packages"
(
    cd "$bundle"
    /usr/bin/shasum -a 256 -c SHA256SUMS
)
actual=$(/usr/bin/shasum -a 256 "$resources/guest-resources/vphoned" | /usr/bin/awk '{print $1}')
[[ $(jq -r .worker_sha256 "$bundle/manifest.json") == $actual ]]
jq -e '.toolchain.iphoneos_sdk | type == "string" and length > 0' "$bundle/manifest.json" > /dev/null
print 'Backend extraction contract, complete guest payload, ROMs, notices and manifest checks passed'
