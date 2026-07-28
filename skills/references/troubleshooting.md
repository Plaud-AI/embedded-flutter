# Plaud Flutter plugin — troubleshooting

Symptom → cause → fix. Most problems trace back to the device-only constraint or to skipping a
setup step.

## `isPlaudSdkAvailable` is `false` / every method throws `MissingPluginException`

The native plugin isn't linked and callable in this context. Causes, most common first:

- **Running on the simulator, macOS, web, or Android.** The frameworks are arm64 iOS-device-only —
  there is no simulator slice and no Android build. Run on a physical iPhone: `flutter run -d
  <device-id>` (list devices with `flutter devices`). This is expected behavior off-device, not a
  bug — the app should degrade gracefully.
- **Plugin not resolved.** Confirm `plugins/plaud_sdk/` exists at the app root, `pubspec.yaml` has
  the `plaud_sdk: { path: plugins/plaud_sdk }` dependency, and you ran `flutter pub get`. The
  plugin's `pubspec.yaml` must declare `pluginClass: PlaudSdkPlugin` under
  `flutter.plugin.platforms.ios` (that's what autolinking keys on).

## App crashes on launch or when scanning

Missing `NSBluetoothAlwaysUsageDescription`. iOS hard-crashes any Bluetooth access without a
usage-description string. Add it (and `UIBackgroundModes: [bluetooth-central]`) to
`ios/Runner/Info.plist`, then rebuild.

## `startScan` completes but `onScanResult` never fires

- **Bluetooth off or permission denied.** The plugin waits ~18 s for CoreBluetooth to power on,
  then emits `onScanTimeout` with reason `bluetoothNotPoweredOn`. Handle that event — prompt the
  user to enable Bluetooth and grant permission. (Don't "simplify away" the poll — scanning only
  works after CoreBluetooth reaches `.poweredOn`.)
- **No device advertising.** The Plaud recorder must be on and in range. `onScanResult` fires
  repeatedly with a growing device list; give it a few seconds.

## `connectBleDevice` throws `ERR_PLAUD_UNKNOWN_DEVICE`

You must **scan before you connect** — the native side caches the device objects from
`onScanResult` and looks them up by `uuid`/`serialNumber`. Connect using a `uuid` from a device
that appeared in an `onScanResult`, in the same session (don't connect to a hardcoded id).

## `onConnectState` reports `failed: true`

Handshake failure (`state` ∈ {2, -1, -2}), distinct from a normal disconnect (`state` 0). Usually
signal/range or a token mismatch. Move the device closer and retry. Confirm `initSDK` ran with a
valid `userAccessToken`, and that the `userId` (which becomes the default connect `deviceToken`
that binds device ↔ user) is set.

## `initSDK` throws `ERR_PLAUD_ARGS`

`userAccessToken` or `customDomain` is empty. `customDomain` must be **domain-only** —
`platform-us.plaud.ai`, not `https://platform-us.plaud.ai`. If the token is empty, you likely
forgot `--dart-define-from-file=.env` on the run/build command (see
`references/transcription-and-tokens.md`).

## `exportAudio` never completes / throws `ERR_PLAUD_EXPORT`

- Watch `onExportProgress` events (`progress` 0–100, plus a `message`) to see how far it got.
- The output lands in `Documents/PlaudExports`. `PlaudExportResult.outputPath` may or may not
  carry the `file://` scheme — normalize it before passing to `dart:io File` / `http`.
- Ensure the device stayed connected throughout; a disconnect mid-export aborts it.

## Build fails at link (`Undefined symbols` / "no such module") for the simulator

You're building for the simulator. The vendored `.xcframework`s have no arm64-simulator slice, so
the linker has nothing to resolve against. Build for a physical device only:
`flutter build ios --no-codesign --dart-define-from-file=.env` (link check) or `flutter run -d
<device>`.

## Pod install / build failures after adding the plugin

- Run `flutter pub get`, then `flutter run -d <device>` (Flutter runs `pod install` on the first
  iOS build). If Pods look stale, `cd ios && pod install --repo-update`.
- Confirm CocoaPods is installed (`brew install cocoapods`) and the iOS deployment target is
  **15.1** in *all* of `ios/Podfile`, the Runner Xcode target, and the plugin podspec. The Plaud
  frameworks require 15.1 — a lower target fails the build.
- The three `.xcframework`s must have copied over with the plugin (large binaries under
  `plugins/plaud_sdk/ios/Frameworks/`). A shallow copy that dropped them breaks the vendored link.
- `PlaudDeviceBasicSDK` is a **static** framework, so it isn't embedded; its localization bundle
  is copied via `s.resource` in the plugin podspec. Don't remove that line — the SDK's
  `PlaudLocalizationManager` needs the bundle at runtime.

## Verify the toolchain

```sh
flutter pub get
flutter analyze
flutter test
```
