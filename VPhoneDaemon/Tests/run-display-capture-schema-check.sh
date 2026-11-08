#!/bin/zsh
set -euo pipefail

daemon="${0:a:h:h}"
extractor=${1:?usage: run-display-capture-schema-check.sh extractor-source revision}
revision=${2:?usage: run-display-capture-schema-check.sh extractor-source revision}
[[ $(/usr/bin/git -C "$extractor" rev-parse HEAD) == "$revision" ]] || { print -u2 'Schema extractor revision mismatch'; exit 1; }
package="$extractor/VPhoneDaemon/Tests/ResultSchema"
catalog="$extractor/VPhoneDaemon/Tests/methods-catalog.tsv"
/usr/bin/git -C "$extractor" diff --exit-code HEAD -- \
    VPhoneDaemon/Tests/ResultSchema/Package.swift \
    VPhoneDaemon/Tests/ResultSchema/Sources/ResultSchemaKit VPhoneDaemon/Tests/methods-catalog.tsv

# This series has no all-RPC catalogue. Reuse the pinned production extractor
# with a capture-only entry point in the disposable CI checkout.
/bin/cp "$daemon/Tests/DisplayCaptureSchemaCheck.swift" "$package/Sources/ResultSchemaCheck/main.swift"
/usr/bin/xcrun swift build --package-path "$package" -c release --product ResultSchemaCheck -j 4
binary=$(/usr/bin/xcrun swift build --package-path "$package" -c release --show-bin-path)
"$binary/ResultSchemaCheck" "$daemon/Native/vphoned_display_capture.m" "$catalog"
/usr/bin/git -C "$extractor" diff --exit-code HEAD -- \
    VPhoneDaemon/Tests/ResultSchema/Package.swift \
    VPhoneDaemon/Tests/ResultSchema/Sources/ResultSchemaKit VPhoneDaemon/Tests/methods-catalog.tsv
