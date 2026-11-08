#!/bin/zsh
# vphone-tier: build
set -euo pipefail

root="$(cd "${0:a:h}/../../.." && pwd)"
bundle=${1:?usage: PackageLinuxResources.sh VPhone.bundle output.zip}
output=${2:?usage: PackageLinuxResources.sh VPhone.bundle output.zip}
"${0:a:h}/ValidateBundle.sh" "$bundle"
resources="$bundle/Contents/Resources"
temporary=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-linux-resources.XXXXXX")
trap '/bin/rm -rf "$temporary"' EXIT
stage="$temporary/VPhone.bundle"
linux_resources="$stage/Contents/Resources"
/bin/mkdir -p "$linux_resources/Licenses"
for component in guest-resources OpenAVB OpenSEP; do
    /usr/bin/ditto "$resources/$component" "$linux_resources/$component"
    /usr/bin/diff -qr "$resources/$component" "$linux_resources/$component"
done
for component in OpenAVB OpenSEP; do
    /bin/cp "$root/VPhoneExecutable/VPhoneVirtualization/Resources/$component/README.md" "$linux_resources/$component/"
done
/bin/cp "$root/LICENSE" "$linux_resources/Licenses/vphone-cli.txt"
/bin/cp "$resources/Licenses/Swift-Apache-2.0-with-Runtime-Library-Exception.txt" "$linux_resources/Licenses/"
/bin/cp "$root/VPhoneGuestComponents/GraphicLoader/README.md" "$linux_resources/Licenses/GraphicLoader-attribution.md"
"$root/scripts/stage-package-notices.zsh" "$linux_resources/Licenses/packages" \
    "$root/VPhoneDaemon/VPhoneDaemon.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
    "$root/.build/XcodeDaemon/SourcePackages"

# This is the same selected-toolchain runtime origin used by StageBundle.
runtime=$(/usr/bin/xcrun swift-stdlib-tool --print \
    --scan-executable "$resources/guest-resources/vphoned" --platform iphoneos | \
    /usr/bin/grep '/libswiftCompatibilitySpan.dylib$')
source_revision=$(/usr/bin/git -C "$root" rev-parse HEAD)
[[ ${GITHUB_SHA:-$source_revision} == $source_revision ]] || { print -u2 'Resource source revision differs from the workflow revision'; exit 1; }
(
    cd "$stage"
    export LC_ALL=C
    for file in Contents/**/*(.DN); do /usr/bin/shasum -a 256 "$file"; done
) > "$stage/SHA256SUMS"
jq -n --arg source "$source_revision" --arg run "${GITHUB_RUN_ID:-local}" \
    --arg xcode "$(/usr/bin/xcodebuild -version)" --arg swift "$(/usr/bin/xcrun swiftc --version)" \
    --arg sdk "$(/usr/bin/xcrun --sdk iphoneos --show-sdk-version)" \
    --arg runtime "${runtime#${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}/}" \
    --arg source_runtime_sha256 "$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')" \
    --arg bundled_runtime_sha256 "$(/usr/bin/shasum -a 256 "$resources/guest-resources/libswiftCompatibilitySpan.dylib" | /usr/bin/awk '{print $1}')" \
    --arg worker_sha256 "$(/usr/bin/shasum -a 256 "$resources/guest-resources/vphoned" | /usr/bin/awk '{print $1}')" \
    --slurpfile daemon "$root/VPhoneDaemon/VPhoneDaemon.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
    '{layout_version:1,source_revision:$source,run_id:$run,scope:"complete guest resources and OpenAVB/OpenSEP ROMs for Linux; CLI built separately from pinned source",resource_root:"Contents/Resources",distribution_status:"validation artifact pending root review",worker_sha256:$worker_sha256,guest_package_pins:$daemon[0].pins,toolchain:{xcode:$xcode,swift:$swift,iphoneos_sdk:$sdk,span_source_path:$runtime,span_source_sha256:$source_runtime_sha256,span_bundled_sha256:$bundled_runtime_sha256,swift_license_source:"https://www.swift.org/LICENSE.txt"},host_binaries_included:false}' \
    > "$stage/manifest.json"
/bin/cp "$stage/manifest.json" "${output%.zip}.json"
/usr/bin/ditto -c -k --keepParent "$stage" "$output"
