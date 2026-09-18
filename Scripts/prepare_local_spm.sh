#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SDK_ROOT="${1:-${NAVIGATION_IOS_ROOT:-}}"
ARTIFACTS_DIR="${DEMO_ROOT}/LocalPackages/NextBillionNavigationLocal/Artifacts"

if [[ -z "${SDK_ROOT}" ]]; then
    echo "Usage: $0 /absolute/path/to/navigation-ios"
    echo "Alternatively, set NAVIGATION_IOS_ROOT before running this script."
    exit 1
fi

mkdir -p "${ARTIFACTS_DIR}"

for FRAMEWORK in Nbmap NbmapCoreNavigation NbmapNavigation Turf; do
    SOURCE="${SDK_ROOT}/Carthage/Build/${FRAMEWORK}.xcframework"
    TARGET="${ARTIFACTS_DIR}/${FRAMEWORK}.xcframework"
    if [[ ! -d "${SOURCE}" ]]; then
        echo "Missing ${SOURCE}"
        echo "Build the current navigation-ios XCFrameworks first, or pass the correct navigation-ios path."
        exit 1
    fi
    ln -sfn "${SOURCE}" "${TARGET}"
done

echo "Local SPM artifacts now point to: ${SDK_ROOT}/Carthage/Build"
echo "Open OfflineNavigationDemo_iOS.xcodeproj and build OfflineNavigationDemo."
