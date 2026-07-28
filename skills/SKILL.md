---
name: setup-plaud-flutter
description: Set up the Plaud SDK Flutter plugin (BLE connect, on-device recording, file list, audio export) in an existing or new Flutter app. Use when a user wants to integrate Plaud's native iOS device SDK into a Flutter app, wire up scan → connect → list → export, or troubleshoot why the plugin isn't linking or is unavailable at runtime.
---

# Setting up the Plaud Flutter plugin

`plaud_sdk` is a local [Flutter plugin](https://docs.flutter.dev/packages-and-plugins/developing-packages)
that bridges Plaud's precompiled native iOS device SDK into Dart. It exposes BLE scan/connect,
on-device recording events, file listing, and audio export as a static `PlaudSdk` API with
typed [broadcast streams](https://api.dart.dev/stable/dart-async/Stream-class.html). The plugin
lives at `plugins/plaud_sdk/` in this repo; a full reference app is at `lib/` (`lib/src/home_page.dart`
is the canonical usage example).

Use this skill to add the plugin to an app and get it building on a device.

## ⚠️ Read these constraints before anything else

The Plaud frameworks are **arm64, iOS 15+, device-only**. There is **no simulator slice** and
**no Android support**. This dictates the entire workflow:

- You **must run on a physical iPhone** (`flutter run -d <device>`), never the simulator.
  Simulator builds **fail at link** — there is no arm64-simulator slice to link against.
- On any non-iOS platform (or the simulator, where the plugin isn't linked),
  `isPlaudSdkAvailable` is `false` and every `PlaudSdk` method throws a `MissingPluginException`.
  Guard every call site with `isPlaudSdkAvailable` so the app stays functional (just without
  the SDK) on those targets.

If the user is on the simulator or expects Android support, stop and set expectations first —
no amount of setup makes the SDK run there.

## Prerequisites

| Tool | Notes |
| --- | --- |
| Flutter | 3.22+ (Dart SDK 3.12+); this repo pins `sdk: ^3.12.2` |
| Xcode | 16.x+, with a physical iPhone + Apple ID for signing |
| CocoaPods | `brew install cocoapods` |

Flutter runs `pod install` automatically on the first iOS build — there is no manual native
linking step. The three Plaud `.xcframework`s are vendored by the plugin's podspec and CocoaPods
embeds/code-signs them.

## Setup workflow

Work through these steps in order. Do not skip the `isPlaudSdkAvailable` guard (Step 4) — it is
the difference between an app that degrades gracefully off-device and one that crashes.

### Step 1 — copy the plugin into the app

Drop the whole plugin folder into the app (a `plugins/` folder at the project root is the
convention this repo uses):

```bash
cp -R plugins/plaud_sdk /path/to/your-app/plugins/plaud_sdk
```

The `.xcframework`s under `plugins/plaud_sdk/ios/Frameworks/` are **large binaries** — make sure
they copied over (a shallow copy that drops them breaks the vendored-frameworks link).

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
`pluginClass: PlaudSdkPlugin` under `flutter.plugin.platforms.ios`) — **no manual Podfile edits,
no Xcode edits.**

### Step 3 — set the iOS deployment target and BLE permissions

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

### Step 4 — use it from Dart (guard, init, subscribe, drive, clean up)

The plugin is **event-driven**: Dart calls (`startScan`, `connectBleDevice`, `getFileList`) kick
off work, and results arrive on typed streams, not as return values. The five-part shape:

```dart
import 'package:plaud_sdk/plaud_sdk.dart';

// 1. GUARD — off-iOS the native plugin isn't linked. Degrade gracefully.
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
  PlaudSdk.onConnectState.listen((s) {
    if (s.connected) PlaudSdk.getFileList();   // ask for recordings once connected
  }),
  PlaudSdk.onFileList.listen((files) {/* show recordings */}),
  PlaudSdk.onExportProgress.listen((p) {/* progress UI: p.progress, p.message */}),
];

// 4. DRIVE it.
await PlaudSdk.startScan();
await PlaudSdk.connectBleDevice(uuid: device.uuid);        // from an onScanResult device
final export = await PlaudSdk.exportAudio(sessionId: file.sessionId, format: PlaudAudioFormat.mp3);

// 5. CLEAN UP subscriptions in dispose().
for (final s in subs) { s.cancel(); }
```

`lib/src/home_page.dart` is a complete, production-shaped version (a `StatefulWidget` with
`initState`/`dispose`, error banners, live-recording banner, unpair flow). **Read it before
building your own screen** — it shows the correct stream → `setState` wiring for every callback.

## References

Pull these in only when the task needs them:

- **`references/api-reference.md`** — every `PlaudSdk` method, every event stream and its payload,
  and all the Dart types. Consult when writing call sites or handling a specific event.
- **`references/transcription-and-tokens.md`** — where the per-user JWT comes from, and the
  optional export → upload → transcribe HTTP flow (which is **not** part of the native plugin
  and belongs behind a backend in production).
- **`references/troubleshooting.md`** — symptom → cause table for the common failures
  (`isPlaudSdkAvailable` false, scan returns nothing, connect fails, pod/build errors).

## Key facts to keep straight

- **`customDomain` is domain-only** — `platform-us.plaud.ai`, not `https://platform-us.plaud.ai`.
- **`initSDK` does not mint the token.** The per-user Bearer JWT is an app/backend
  responsibility. For local testing this repo reads it from a compile-time define
  (`--dart-define-from-file=.env` → `String.fromEnvironment('PLAUD_ACCESS_TOKEN')` in
  `lib/src/config.dart`), but dart-defines are baked into the app binary and extractable — never
  ship credentials in the client.
- **The token is a short-lived (~24 h) per-user JWT.** If init or upload fails with an auth error,
  mint a fresh one from https://platform.plaud.ai/developer/portal.
- **`exportAudio` returns a raw filesystem path** (`Documents/PlaudExports`). It may be missing
  the `file://` scheme — strip or add it as needed before handing to `dart:io File` / `http`.
- **Events are streams, not callbacks.** Subscribe with `PlaudSdk.on<Event>.listen(...)` and
  cancel every `StreamSubscription` in `dispose()`; a leaked subscription calls `setState` after
  the widget is gone.
