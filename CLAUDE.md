# CLAUDE.md

Flutter port (iOS-only) of the React Native Plaud demo at
`../embedded-react-native/react-native-demo`. Single dark screen: BLE-pair a
Plaud recorder → list on-device recordings → export to MP3 → upload +
transcribe via the Plaud cloud API. See `work-done.md` for how the port was
built and verified.

## Commands

```sh
flutter pub get
flutter analyze
flutter test
flutter run --dart-define-from-file=.env      # physical iPhone only
flutter build ios --no-codesign --dart-define-from-file=.env   # link check without a device
```

## Hard constraints

- **Physical iPhone only.** The vendored Plaud frameworks are arm64
  device-only (no simulator slice); simulator builds fail at link. Android is
  not supported by the SDK.
- **`--dart-define-from-file=.env` is required** on every run/build.
  Credentials (`PLAUD_ACCESS_TOKEN`, `PLAUD_CLIENT_ID`, `PLAUD_API_KEY`) are
  compile-time defines read in `lib/src/config.dart`; without them the app
  starts with a "No Plaud access token" error. `.env` is gitignored — copy
  `.env.example` and fill from https://platform.plaud.ai/developer/portal.
  The access token is a short-lived (~24 h) per-user JWT; if init or upload
  fails with auth errors, mint a fresh one.
- iOS deployment target is 15.1 everywhere (Runner pbxproj, Podfile, plugin
  podspec) — the Plaud frameworks require it. Don't lower it.

## Architecture

- `lib/src/home_page.dart` — all screen state + SDK event subscriptions;
  1:1 port of the RN demo's `src/app/index.tsx`.
- `lib/src/transcription.dart` — cloud flow: presigned S3 multipart upload
  (Bearer user token) → `POST /open/partner/ai/transcriptions/` → poll
  (X-Client-Id / X-Client-Api-Key headers). ⚠️ Demo-only: production must
  proxy this through a backend.
- `lib/src/theme.dart`, `widgets.dart`, `file_modal.dart` — Plaud "dev"
  design tokens and components mirroring the RN `dev-ui.tsx` / `file-modal.tsx`.
- `plugins/plaud_sdk/` — local Flutter plugin wrapping the native SDK:
  - `lib/plaud_sdk.dart` — static `PlaudSdk` API: 9 methods, typed event
    streams over `MethodChannel('plaud_sdk/methods')` +
    `EventChannel('plaud_sdk/events')` (events are maps tagged with an
    `event` key).
  - `ios/Classes/PlaudSdkPlugin.swift` — the bridge to
    `PlaudDeviceAgent.shared`. **Keep in sync** with the RN counterpart
    `../embedded-react-native/react-native-demo/modules/plaud-sdk/ios/PlaudSdkModule.swift`
    — both implement the same contract (9 methods, 12 events).
  - `ios/Frameworks/*.xcframework` — vendored Plaud SDK binaries, byte-identical
    to `../plaud-sdk-public/sdk/ios`.

## Gotchas

- `PlaudDeviceBasicSDK` is a **static** framework: it links into the app
  binary and is NOT embedded, so its localization bundle must be copied via
  `s.resource` in `plugins/plaud_sdk/ios/plaud_sdk.podspec` (already done —
  don't remove it). `PlaudBleSDK`/`PlaudWiFiSDK` are dynamic and embed
  normally.
- Scanning only works after CoreBluetooth reaches `.poweredOn`; the Swift
  bridge polls ~18 s and emits `scanTimeout {reason: bluetoothNotPoweredOn}`
  — don't "simplify" that away.
- Connect always passes a `deviceToken` (defaults to the `userId` from
  `initSDK`) — it binds device ↔ user during the handshake.
- The SDK surface used here is a small slice of `PlaudDeviceAgent` (scan,
  connect, file list, export). The SDK also supports app-initiated recording,
  file download/delete, WiFi transfer, and firmware OTA — unbridged, like in
  the RN demo.
- The modal is rendered inline in a `Stack` (not `showModalBottomSheet`) so
  it rebuilds live as export/transcription state changes in the parent.
