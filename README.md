# Embedded Flutter Plugin

Flutter plugin for the Plaud Embedded SDK. If you have a Flutter app, try the plugin and Flutter demo to see how a Flutter app can connect to Plaud devices to record conversations and transcribe them.

## Flutter Demo App

### Setup

1. Copy `.env.example` to `.env` and fill in your credentials from the
   [Plaud developer portal](https://platform.plaud.ai/developer/portal):
   - `PLAUD_ACCESS_TOKEN` — per-user JWT, used for `initSDK` and file upload.
   - `PLAUD_CLIENT_ID` / `PLAUD_API_KEY` — partner credentials for the
     transcription API.
2. For iOS, open `ios/Runner.xcworkspace` once to set your signing team
   (Runner → Signing & Capabilities). Android needs no setup step.

### Run

```sh
flutter pub get
flutter run --dart-define-from-file=.env   # with an iPhone or Android phone plugged in
```

The credentials are compile-time defines — `--dart-define-from-file=.env` is
required on every `run`/`build`, otherwise the app starts with a "No Plaud
access token" error.

⚠️ **Demo only:** this bakes partner credentials into the client binary and
calls the platform API directly from the device. In production, mint the user
token and proxy upload/transcription through your backend.

## Using the `plaud_sdk` plugin in your own app

`plugins/plaud_sdk/` is a self-contained Flutter plugin — you can drop it into
any Flutter app to get BLE scan/connect, on-device recording events, file
listing, and audio export. It covers iOS and Android behind one Dart API — the
Swift and Kotlin bridges implement the same nine methods and twelve events, so
your code never branches on platform. Use a real phone (the iOS frameworks are
arm64 device-only, and an Android emulator has no BLE radio). Everything is
event-driven: method calls kick off work, results arrive on typed streams.

### Try the Embedded Flutter Skill

Give your coding agent context of how Plaud Embedded works with Flutter, along with references and examples.

```bash
npx skills add Plaud-AI/embedded_flutter
```

### 1. Copy the plugin in

```sh
cp -R plugins/plaud_sdk /path/to/your-app/plugins/plaud_sdk
```

The vendored SDK binaries are large — make sure they copy over (a shallow copy
that drops them breaks the build): the `.xcframework`s under
`plugins/plaud_sdk/ios/Frameworks/`, and the `.aar` under
`plugins/plaud_sdk/android/m2repo/`.

### 2. Depend on it via a path reference

```yaml
# your-app/pubspec.yaml
dependencies:
  plaud_sdk:
    path: plugins/plaud_sdk
```

```sh
flutter pub get
```

Flutter's plugin autolinking handles the rest — no manual Podfile, Xcode, or
Gradle edits.

### 3. Configure iOS

- Set the deployment target to **15.1** in `ios/Podfile`
  (`platform :ios, '15.1'`) and the Runner Xcode target. The Plaud frameworks
  require it; don't go lower.
- Add BLE permissions to `ios/Runner/Info.plist` (without the first key, the
  app hard-crashes the moment it touches Bluetooth):

  ```xml
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Plaud uses Bluetooth to connect to your recorder and sync recordings.</string>
  <key>UIBackgroundModes</key>
  <array>
    <string>bluetooth-central</string>
  </array>
  ```

### 3b. Configure Android

Nothing to do. `minSdk` must be **24 or higher** (Flutter's default already
is), and the BLE permissions merge into your manifest from the plugin — the
plugin requests the runtime ones itself when you call `startScan`, so there's
no permission library to add.

### 4. Use it from Dart

Guard every call with `isPlaudSdkAvailable`, init once, subscribe to the
streams, then drive it — and cancel your subscriptions in `dispose()`:

```dart
import 'package:plaud_sdk/plaud_sdk.dart';

if (!isPlaudSdkAvailable) { /* off-device: show a "device required" state */ }

await PlaudSdk.initSDK(
  userAccessToken: token,               // per-user Bearer JWT
  customDomain: 'platform-us.plaud.ai', // domain only, no https://
  userId: 'your-app-user-id',           // default connect deviceToken
);

final subs = <StreamSubscription>[
  PlaudSdk.onScanResult.listen((devices) {/* show devices */}),
  PlaudSdk.onConnectState.listen((s) {
    if (s.connected) PlaudSdk.getFileList();   // load recordings on connect
  }),
  PlaudSdk.onFileList.listen((files) {/* show recordings */}),
  PlaudSdk.onExportProgress.listen((p) {/* p.progress (0–100), p.message */}),
];

await PlaudSdk.startScan();
await PlaudSdk.connectBleDevice(uuid: device.uuid);  // from an onScanResult device
final export = await PlaudSdk.exportAudio(
  sessionId: file.sessionId,
  format: PlaudAudioFormat.mp3,
);
// export.outputPath → the decoded mp3 under the app's PlaudExports directory
//                     (iOS Documents/, Android the private files/ dir)
```

`lib/src/home_page.dart` is the complete, production-shaped reference
(`StatefulWidget` with full stream → `setState` wiring, error handling, and an
unpair flow) — read it before building your own screen.

> **Token & transcription:** `initSDK` needs a per-user Bearer JWT that your
> backend mints (it's short-lived, ~24 h). Transcription (export → upload →
> poll) is plain HTTP, **not** part of the plugin — see `lib/src/transcription.dart`.
> In production, keep partner credentials on a backend, never in the client.
