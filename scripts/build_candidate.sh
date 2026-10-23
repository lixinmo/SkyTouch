#!/bin/bash
set -euo pipefail
export LC_ALL=C LANG=C
task_dir=$(cd "$(dirname "$0")/.." && pwd)
/usr/bin/python3 "$task_dir/scripts/prepare_original.py"
task_stage=$(mktemp -d "$task_dir/build/.candidate-build.XXXXXX")
trap 'rm -rf "$task_stage"' EXIT
task_app="$task_stage/SkyTouch.app"
task_destination="$task_dir/build/Candidate/SkyTouch.app"
task_sdk=$(xcrun --sdk iphoneos --show-sdk-path)
# RootHide's published deployment range starts at iOS 15. Compile every own
# binary to that ABI baseline; package metadata does not impose a firmware
# version. Private services are checked for their actual ABI at runtime.
task_target=arm64-apple-ios15.0
mkdir -p "$task_app/Original" "$task_app/Licenses"
cp -R "$task_dir/build/OriginalRuntime/FZKeymappingHelper.bundle" "$task_app/"
cp "$task_dir/build/OriginalRuntime/flydigi.dylib" "$task_app/Original/"
cp "$task_dir/app/Info.plist" "$task_app/Info.plist"
cp "$task_dir/app/Icons/"AppIcon*.png "$task_app/"
cp "$task_dir/licenses/"*.txt "$task_app/Licenses/"
xcrun --sdk iphoneos clang -target "$task_target" -isysroot "$task_sdk" -std=c11 -Os \
    -Wall -Wextra -Werror -c "$task_dir/vendor/fishhook/fishhook.c" -o "$task_stage/fishhook.o"
task_mapping_sources=(
    "$task_dir/src/OPConfigurationUI.mm"
    "$task_dir/src/OPLocalSwitcherUI.mm" "$task_dir/src/OPLocalConfiguration.mm"
    "$task_dir/src/OPLocalSwitcherFilter.mm"
    "$task_dir/src/OPRuntimeControl.mm"
    "$task_dir/src/OPBluetoothLifetime.mm"
    "$task_dir/src/OPControllerIdentity.mm" "$task_dir/src/OPOriginalOfflineEditor.mm"
    "$task_dir/src/OPHUDHost.mm" "$task_dir/src/OPForegroundContext.mm" "$task_dir/src/OPSessionSupervisor.mm"
    "$task_dir/src/OPOriginalBridge.mm" "$task_dir/src/OPOriginalMotionFix.mm" "$task_dir/src/OPOriginalMotionPersistence.mm"
    "$task_dir/src/OPOriginalMOBAEditor.mm" "$task_dir/src/OPPhysicalTouchMirror.mm"
    "$task_dir/src/OPPanelCalibration.mm" "$task_dir/src/OPOriginalCloudTransport.mm"
    "$task_dir/src/OPGlobalProfile.mm"
    "$task_dir/src/OPBluetoothBroker.mm" "$task_dir/src/OPOriginalBluetoothClient.mm"
    "$task_dir/shared/src/SMBluetooth.mm" "$task_dir/shared/src/SMBluetoothDevice.mm" "$task_dir/shared/core/FlydigiProtocol.cpp"
    "$task_dir/src/OPOriginalContext.mm" "$task_dir/src/OPSystemTouch.mm" "$task_dir/src/OPVirtualTouchService.mm"
)
xcrun --sdk iphoneos clang++ -target "$task_target" -std=c++17 -fobjc-arc \
    -isysroot "$task_sdk" -Wall -Wextra -Werror -Wno-deprecated-declarations -Os \
    -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics -framework CoreBluetooth -framework PhotosUI -framework Security \
    "$task_dir/app/main.mm" "$task_dir/src/OPFloatingControl.mm" \
    "$task_dir/src/OPConfigurationManager.mm" "$task_dir/src/OPConfigurationManagerUI.mm" \
    "${task_mapping_sources[@]}" "$task_stage/fishhook.o" -o "$task_app/SkyTouch"
mkdir -p "$task_app/SystemMapping.bundle"
cp "$task_dir/packaging/MappingService-Info.plist" "$task_app/SystemMapping.bundle/Info.plist"
# Vendor resource lookup uses its real main bundle. Preserve the original
# bytes at that location too, without impersonating the configuration app.
cp -R "$task_dir/build/OriginalRuntime/FZKeymappingHelper.bundle" "$task_app/SystemMapping.bundle/"
xcrun --sdk iphoneos clang++ -target "$task_target" -std=c++17 -fobjc-arc \
    -isysroot "$task_sdk" -Wall -Wextra -Werror -Wno-deprecated-declarations -Os \
    -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics -framework CoreBluetooth -framework PhotosUI -framework Security \
    "$task_dir/app/MappingService.mm" "${task_mapping_sources[@]}" "$task_stage/fishhook.o" -o "$task_app/SystemMapping.bundle/SkyTouchMapping"
codesign --force --sign - --timestamp=none --entitlements "$task_dir/packaging/host-entitlements.plist" "$task_app/SystemMapping.bundle"
xcrun --sdk iphoneos clang -target "$task_target" -isysroot "$task_sdk" -std=c11 -Os \
    -Wall -Wextra -Werror "$task_dir/app/ServiceControl.c" -o "$task_app/SkyTouchControl"
codesign --force --sign - --timestamp=none "$task_app/SkyTouchControl"
xcrun --sdk iphoneos clang++ -target "$task_target" -std=c++17 -fobjc-arc -isysroot "$task_sdk" \
    -Wall -Wextra -Werror -Wno-deprecated-declarations -Os -framework Foundation \
    "$task_dir/app/StorageMaintenance.mm" "$task_dir/src/OPConfigurationArchive.mm" -o "$task_app/SkyTouchStorage"
codesign --force --sign - --timestamp=none --identifier com.lixinmo.skytouch.storage \
    --entitlements "$task_dir/packaging/storage-entitlements.plist" "$task_app/SkyTouchStorage"
mkdir -p "$task_app/SystemBluetooth.bundle"
cp "$task_dir/packaging/BluetoothService-Info.plist" "$task_app/SystemBluetooth.bundle/Info.plist"
xcrun --sdk iphoneos clang++ -target "$task_target" -std=c++17 -fobjc-arc -isysroot "$task_sdk" \
    -Wall -Wextra -Werror -Wno-deprecated-declarations -Os -framework Foundation -framework CoreBluetooth \
    "$task_dir/app/BluetoothService.mm" "$task_dir/src/OPBluetoothBroker.mm" "$task_dir/src/OPControllerIdentity.mm" \
    "$task_dir/src/OPBluetoothLifetime.mm" "$task_dir/src/OPRuntimeControl.mm" \
    "$task_dir/shared/src/SMBluetooth.mm" "$task_dir/shared/src/SMBluetoothDevice.mm" "$task_dir/shared/core/FlydigiProtocol.cpp" \
    -o "$task_app/SystemBluetooth.bundle/SkyTouchBLE"
codesign --force --sign - --timestamp=none --entitlements "$task_dir/packaging/bluetooth-entitlements.plist" "$task_app/SystemBluetooth.bundle"
# No algorithm, symbol or resource patching of the vendor image.
codesign --force --sign - --timestamp=none "$task_app/Original/flydigi.dylib"
/usr/bin/python3 "$task_dir/scripts/verify_original.py" --runtime-dylib "$task_app/Original/flydigi.dylib"
codesign --force --sign - --timestamp=none --entitlements "$task_dir/packaging/host-entitlements.plist" "$task_app"
codesign --verify --strict "$task_app"
# Replace only this local generated candidate after all build checks passed.
# A fresh staging tree prevents stale resources/diagnostics entering the deb.
mkdir -p "$task_dir/build/Candidate"
if [ -L "$task_destination" ]; then echo 'Candidate destination must not be a symlink' >&2; exit 1; fi
rm -rf "$task_destination"
mv "$task_app" "$task_destination"
printf 'Signed build ready for packaging: %s\n' "$task_destination"
