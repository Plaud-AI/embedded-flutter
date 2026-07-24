# Work done — Flutter port of the Plaud React Native demo

_2026-07-24. Ported `../embedded-react-native/react-native-demo` (Expo SDK 57)
to this Flutter project, starting from a freshly generated Flutter 3.44.8
counter app._

## Goal

Recreate the RN demo app 1:1 in Flutter for iOS, implementing the Plaud SDK
(`../plaud-sdk-public/sdk/ios`): pair a Plaud recorder over BLE, observe
device-initiated recording live, list on-device recordings, export a
recording to MP3, and transcribe it via the Plaud cloud API.

## What was built

### 1. `plugins/plaud_sdk/` — local Flutter plugin (new)

- **`ios/Classes/PlaudSdkPlugin.swift`** — line-for-line port of the RN
  bridge (`modules/plaud-sdk/ios/PlaudSdkModule.swift`), swapping Expo's
  `Module`/`Promise` for `FlutterPlugin`/`FlutterResult` +
  `FlutterStreamHandler`. Same behavior preserved:
  - `PlaudSdkController: NSObject, PlaudDeviceAgentProtocol` owns all
    `PlaudDeviceAgent.shared` calls; delegate callbacks hop to the main queue
    before crossing into Dart.
  - Scan cache keyed by peripheral `uuid` (Dart only carries identifiers;
    `connectBleDevice` looks the real `BleDevice` back up).
  - Bluetooth power-on gating: polls `BleAgent.shared.isPoweredOn` ~18 s
    before scanning, else emits `scanTimeout {reason: bluetoothNotPoweredOn}`.
  - Connect passes a `deviceToken` (explicit or the `initSDK` userId) to bind
    device ↔ user.
  - `ExportCallbackBridge` adapts the SDK's `AudioExportCallback`: progress →
    `exportProgress` events, completion/error → resolves/rejects the call.
    Exports land in `Documents/PlaudExports/`.
- **`lib/plaud_sdk.dart` + `lib/src/types.dart`** — Dart API:
  `MethodChannel('plaud_sdk/methods')` + `EventChannel('plaud_sdk/events')`.
  9 methods (`initSDK`, `startScan`, `stopScan`, `connectBleDevice`,
  `disconnect`, `depair`, `isConnected`, `getFileList`, `exportAudio`) and
  typed streams for the 12 events (`scanResult`, `scanTimeout`,
  `connectState`, `penState`, `bind`, `fileList`, `exportProgress`,
  `recordStart/Stop/Pause/Resume`, `depair`). `isPlaudSdkAvailable` guards
  the iOS-only surface.
- **`ios/plaud_sdk.podspec`** — vendors the three Plaud `.xcframework`s
  (copied from the RN module; verified **byte-identical by md5** to the
  `.framework` binaries in `../plaud-sdk-public/sdk/ios`). iOS 15.1,
  `static_framework = true`, mirroring the RN podspec. One addition beyond
  the RN setup: `PlaudDeviceBasicSDK` is a static framework so it is never
  embedded — its localization bundle (`PlaudDeviceBasicSDK.bundle`, used by
  `PlaudLocalizationManager`) is copied explicitly via `s.resource`. (The RN
  app actually ships without this bundle.)

### 2. `lib/` — the app

- `src/home_page.dart` — port of `src/app/index.tsx`: same state machine
  (devices/files/connected/recording/isLive/error/scanning/tokenReady/
  results/openSessionId), same event wiring (connect → auto `getFileList`,
  `recordStop` → refresh list, `depair` → full reset), same
  export-then-transcribe flow per tapped recording.
- `src/transcription.dart` — port of `src/lib/plaud-transcription.ts`:
  generate-presigned-urls → PUT chunks to S3 (collect ETags) →
  complete-upload (with md5) → submit transcription
  (`plaud-fast-whisper`, language auto) → poll every 3 s, 3 min timeout,
  tolerant transcript extraction (`text` | `results[].text` |
  `segments[].text`).
- `src/theme.dart` / `src/widgets.dart` / `src/file_modal.dart` — Plaud
  "dev" design tokens (exact colors from `constants/theme.ts`) and component
  ports of `dev-ui.tsx` (DevButton variants, DevCard, DevRow, Mono, Overline,
  Pill, animated WaveBars) and `file-modal.tsx` (bottom-anchored 90%-height
  card: progress lines → error+Retry → scrollable transcript). SF Symbols
  mapped to Material icons. The modal renders inline in a `Stack` so it
  rebuilds as parent state changes.
- `src/config.dart` — domain `platform-us.plaud.ai`, user `jackmu`,
  credentials via `String.fromEnvironment`.
- `main.dart` — dark-only MaterialApp. Default counter test replaced with a
  home-screen smoke test.

### 3. iOS project config

- `Info.plist`: `NSBluetoothAlwaysUsageDescription` + `UIBackgroundModes:
  [bluetooth-central]` (same strings as the RN `app.json`).
- Deployment target 13.0 → **15.1** in `Runner.xcodeproj` (all 3 configs).
- `ios/Podfile` created (standard Flutter template, `platform :ios, '15.1'`,
  post_install re-raises pod targets to 15.1). The project was generated in
  Flutter's SPM era with no Podfile; the CocoaPods-only plugin needs one.
- `pubspec.yaml`: added `http`, `crypto`, and the path dependency on
  `plugins/plaud_sdk`.
- `.env.example` (committed) + `.env` (gitignored) with
  `PLAUD_ACCESS_TOKEN` / `PLAUD_CLIENT_ID` / `PLAUD_API_KEY`, consumed via
  `--dart-define-from-file=.env`. Values seeded from the RN repo's `.env`;
  note the access token is a ~24 h JWT and will need re-minting.

## Verification

- `flutter analyze` — no issues.
- `flutter test` — passes.
- `flutter build ios --no-codesign --dart-define-from-file=.env` — release
  device build succeeds; confirmed `PlaudBleSDK.framework` +
  `PlaudWiFiSDK.framework` embedded in `Runner.app/Frameworks/` and
  `PlaudDeviceBasicSDK.bundle` copied into the app root.
- Not yet exercised on hardware — needs a signing team
  (`ios/Runner.xcworkspace` → Signing & Capabilities), a physical iPhone,
  a Plaud recorder, and a fresh access token.

## Deliberate scope choices (parity with the RN demo)

- Only the RN demo's bridged surface was ported. Unbridged SDK capabilities
  (app-initiated `startRecord`/`stopRecord`, `downloadFile`/`deleteFile`,
  WiFi fast transfer, firmware OTA, playback via `JXOggPlayer`/
  `PlaudPCMPlayer`) were left out, as in the RN demo.
- Client-side transcription with baked-in partner credentials is demo-only,
  same caveat as the RN demo — production should proxy through a backend.
- The RN `explore.tsx` screen is Expo starter leftover with no navigation to
  it; intentionally not ported.
