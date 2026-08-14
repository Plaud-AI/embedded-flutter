---
name: setup-plaud-flutter
description: Set up the Plaud SDK Flutter plugin (BLE connect, on-device recording, file list, audio export) on iOS and Android in an existing or new Flutter app. Use when a user wants to integrate Plaud's native device SDK into a Flutter app, wire up scan → connect → list → export, or troubleshoot why the plugin isn't linking or is unavailable at runtime.
---

# Setting up the Plaud Flutter plugin

`plaud_sdk` is a local [Flutter plugin](https://docs.flutter.dev/packages-and-plugins/developing-packages)
that bridges Plaud's precompiled native device SDKs into Dart. It exposes BLE scan/connect,
on-device recording events, file listing, and audio export as a static `PlaudSdk` API with
typed [broadcast streams](https://api.dart.dev/stable/dart-async/Stream-class.html).

**iOS and Android are both supported behind one Dart API.** A Swift bridge
(`ios/Classes/PlaudSdkPlugin.swift`) and a Kotlin bridge
(`android/src/main/kotlin/ai/plaud/plaud_sdk/PlaudSdkPlugin.kt`) implement the same contract —
9 methods, 12 events, identical channel names and payload keys — so **Dart never branches on
platform.** If you change one bridge, change the other.

The plugin lives at `plugins/plaud_sdk/` in this repo; a full reference app is at `lib/`
(`lib/src/home_page.dart` is the canonical usage example).

Use this skill to add the plugin to an app and get it building on a device.

## ⚠️ Read these constraints before anything else

**Physical devices only, on both platforms** — for different reasons:

- **iOS:** the vendored frameworks are **arm64, iOS 15.1+, device-only**. There is no simulator
  slice, so simulator builds **fail at link**. Run on a physical iPhone (`flutter run -d <device>`).
- **Android:** builds and installs fine on an emulator, but an emulator has **no BLE radio** —
  scanning finds nothing, forever. Use a real phone.
- On any **other** platform (web, macOS, Windows, Linux), `isPlaudSdkAvailable` is `false` and
  every `PlaudSdk` method throws a `MissingPluginException`. Guard every call site with
  `isPlaudSdkAvailable` so the app stays functional (just without the SDK) there.

If the user is on the iOS simulator or an Android emulator, stop and set expectations first — no
amount of setup makes device pairing work there.

## Prerequisites

| Tool | Notes |
| --- | --- |
| Flutter | 3.22+ (Dart SDK 3.12+); this repo pins `sdk: ^3.12.2` |
| Xcode (iOS) | 16.x+, with a physical iPhone + Apple ID for signing |
| CocoaPods (iOS) | `brew install cocoapods` |
| JDK 17 (Android) | the plugin compiles at Java/JVM target 17 |
| Android SDK | `compileSdk 36`; host app `minSdk` must be **≥ 24** (Flutter's default already is) |

There is no manual native linking step on either platform. Flutter runs `pod install` on the
first iOS build (the three Plaud `.xcframework`s are vendored by the plugin's podspec, and
CocoaPods embeds/code-signs them). On Android the plugin's own `build.gradle.kts` registers its
checked-in Maven repo (`android/m2repo/`) on `rootProject.allprojects`, so the host app resolves
the vendored `.aar` without touching its Gradle files.

## Setup workflow

Work through these steps in order. Do not skip the `isPlaudSdkAvailable` guard (Step 4) — it is
the difference between an app that degrades gracefully off-device and one that crashes.

### Step 1 — copy the plugin into the app

Drop the whole plugin folder into the app (a `plugins/` folder at the project root is the
convention this repo uses):

```bash
cp -R plugins/plaud_sdk /path/to/your-app/plugins/plaud_sdk
```

Both platforms' SDKs are **large vendored binaries** — make sure they copied over (a shallow copy
that drops them breaks the build):

- iOS: the `.xcframework`s under `plugins/plaud_sdk/ios/Frameworks/`
- Android: the `.aar` under `plugins/plaud_sdk/android/m2repo/ai/plaud/sdk/plaud-sdk/1.0.0/`

### Step 2 — depend on it via a path reference

Add it to the app's `pubspec.yaml` as a path dependency, then fetch:

```yaml
# your-app/pubspec.yaml
dependencies:
  plaud_sdk:
    path: plugins/plaud_sdk
```

```bash
flutter pub get
```

Flutter's plugin autolinking reads the plugin's own `pubspec.yaml` (which declares
`pluginClass: PlaudSdkPlugin` for both `ios` and `android` under `flutter.plugin.platforms`) —
**no manual Podfile, Xcode, or Gradle edits.**

### Step 3a — iOS: deployment target and BLE permissions

Two native-side edits, both required:

**a. iOS deployment target → 15.1** (the frameworks require it). In `ios/Podfile`:

```ruby
platform :ios, '15.1'
```

Also raise `IPHONEOS_DEPLOYMENT_TARGET` to `15.1` in `ios/Runner.xcodeproj` (or the Xcode target's
Build Settings). Don't lower it anywhere — a mismatch fails the build.

**b. BLE permissions** in `ios/Runner/Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Plaud uses Bluetooth to connect to your recorder and sync recordings.</string>
<key>UIBackgroundModes</key>
<array>
  <string>bluetooth-central</string>
</array>
```

Without `NSBluetoothAlwaysUsageDescription` the app hard-crashes the moment it touches Bluetooth.
`UIBackgroundModes: [bluetooth-central]` keeps BLE alive when backgrounded.

### Step 3b — Android: nothing to configure

The BLE permissions (`BLUETOOTH_SCAN` / `BLUETOOTH_CONNECT` on Android 12+, the legacy
`BLUETOOTH` / `BLUETOOTH_ADMIN` / `ACCESS_FINE_LOCATION` trio below that, plus `INTERNET`) are
declared in the plugin's own `AndroidManifest.xml` and **merge into the host app's manifest**.
The plugin also **requests the runtime permissions itself** inside `startScan` — there is no
permission library to add and no `requestPermissions` call for you to write. Just confirm the
app's `minSdk` is ≥ 24.

If the user refuses the prompt, the plugin emits `onScanTimeout` with reason `permissionDenied`
(see Step 4) rather than silently scanning nothing.

### Step 4 — use it from Dart (guard, init, subscribe, drive, clean up)

Identical on both platforms. The plugin is **event-driven**: Dart calls (`startScan`,
`connectBleDevice`, `getFileList`) kick off work, and results arrive on typed streams, not as
return values. The five-part shape:

```dart
import 'package:plaud_sdk/plaud_sdk.dart';

// 1. GUARD — off iOS/Android the native plugin isn't linked. Degrade gracefully.
if (!isPlaudSdkAvailable) { /* show a "device required" state; skip SDK calls */ }

// 2. INIT — once, with a per-user JWT (see references/transcription-and-tokens.md).
await PlaudSdk.initSDK(
  userAccessToken: token,              // per-user Bearer JWT (your backend mints this)
  customDomain: 'platform-us.plaud.ai', // domain only, no https://
  userId: 'your-app-user-id',          // reused as the default connect deviceToken
);

// 3. SUBSCRIBE — this is where results land. Keep the subscriptions to cancel later.
final subs = <StreamSubscription>[
  PlaudSdk.onScanResult.listen((devices) {/* show devices */}),
  PlaudSdk.onScanTimeout.listen((reason) {
    // 'bluetoothNotPoweredOn' (both) | 'permissionDenied' (Android) | null (scan window ended)
  }),
  PlaudSdk.onConnectState.listen((s) {
    if (s.connected) PlaudSdk.getFileList();   // ask for recordings once connected
  }),
  PlaudSdk.onFileList.listen((files) {/* show recordings */}),
  PlaudSdk.onExportProgress.listen((p) {/* progress UI: p.progress, p.message */}),
];

// 4. DRIVE it. Call startScan unconditionally — the native side handles Bluetooth
//    readiness and (on Android) the runtime permission prompt.
await PlaudSdk.startScan();
await PlaudSdk.connectBleDevice(uuid: device.uuid);        // from an onScanResult device
final export = await PlaudSdk.exportAudio(sessionId: file.sessionId, format: PlaudAudioFormat.mp3);

// 5. CLEAN UP subscriptions in dispose().
for (final s in subs) { s.cancel(); }
```

`lib/src/home_page.dart` is a complete, production-shaped version (a `StatefulWidget` with
`initState`/`dispose`, error banners, live-recording banner, unpair flow). **Read it before
building your own screen** — it shows the correct stream → `setState` wiring for every callback.

### Step 5 — verify the build on both platforms

```sh
flutter analyze
flutter test
flutter build ios --no-codesign --dart-define-from-file=.env   # link check, no device needed
flutter build apk --debug --dart-define-from-file=.env         # Android compile check
flutter run --dart-define-from-file=.env                       # physical iPhone / Android phone
```

## References

Pull these in only when the task needs them:

- **`references/api-reference.md`** — every `PlaudSdk` method, every event stream and its payload,
  all the Dart types, and the handful of **iOS/Android behavioural differences** that leak
  through the shared API. Consult when writing call sites or handling a specific event.
- **`references/transcription-and-tokens.md`** — where the per-user JWT comes from, and the
  optional export → upload → transcribe HTTP flow (which is **not** part of the native plugin
  and belongs behind a backend in production).

## Key facts to keep straight

- **One contract, two bridges.** Swift and Kotlin implement the same 9 methods / 12 events with
  the same payload keys. Never write `if (Platform.isAndroid)` around a `PlaudSdk` call — if the
  behaviour differs, fix the bridge.
- **`customDomain` is domain-only** — `platform-us.plaud.ai`, not `https://platform-us.plaud.ai`.
  On Android it also retargets the SDK's Partner API, which otherwise defaults to platform-jp and
  would 401 a US token, failing every handshake after it.
- **`initSDK` does not mint the token.** The per-user Bearer JWT is an app/backend
  responsibility. For local testing this repo reads it from a compile-time define
  (`--dart-define-from-file=.env` → `String.fromEnvironment('PLAUD_ACCESS_TOKEN')` in
  `lib/src/config.dart`), but dart-defines are baked into the app binary and extractable — never
  ship credentials in the client.
- **The token is a short-lived (~24 h) per-user JWT.** If init or upload fails with an auth error,
  mint a fresh one from https://platform.plaud.ai/developer/portal.
- **Scan before you connect.** Both bridges cache the scanned device objects natively and look
  them up by the `uuid` from an `onScanResult`; a hardcoded id throws `ERR_PLAUD_UNKNOWN_DEVICE`.
  (That `uuid` is a CoreBluetooth peripheral id on iOS and the MAC address on Android — opaque
  either way, so just pass it back.)
- **`exportAudio` returns a raw filesystem path** — `Documents/PlaudExports` on iOS, the app's
  private `files/PlaudExports` on Android. It may be missing the `file://` scheme — strip or add
  it as needed before handing to `dart:io File` / `http`.
- **Events are streams, not callbacks.** Subscribe with `PlaudSdk.on<Event>.listen(...)` and
  cancel every `StreamSubscription` in `dispose()`; a leaked subscription calls `setState` after
  the widget is gone.
