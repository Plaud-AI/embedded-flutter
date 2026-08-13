# CLAUDE.md

Flutter port of the React Native Plaud demo at
`../embedded-react-native/react-native-demo`, running on iOS and Android.
Single dark screen: BLE-pair a Plaud recorder → list on-device recordings →
export to MP3 → upload + transcribe via the Plaud cloud API. See
`work-done.md` for how the port was built and verified.

## Commands

```sh
flutter pub get
flutter analyze
flutter test
flutter run --dart-define-from-file=.env      # physical iPhone / Android phone
flutter build ios --no-codesign --dart-define-from-file=.env   # link check without a device
flutter build apk --debug --dart-define-from-file=.env         # Android compile check
```

## Hard constraints

- **Physical devices only.** The vendored iOS frameworks are arm64
  device-only (no simulator slice); simulator builds fail at link. Android
  builds fine on an emulator but has no BLE there, so scanning finds nothing.
- **`--dart-define-from-file=.env` is required** on every run/build.
  Credentials (`PLAUD_ACCESS_TOKEN`, `PLAUD_CLIENT_ID`, `PLAUD_API_KEY`) are
  compile-time defines read in `lib/src/config.dart`; without them the app
  starts with a "No Plaud access token" error. `.env` is gitignored — copy
  `.env.example` and fill from https://platform.plaud.ai/developer/portal.
  The access token is a short-lived (~24 h) per-user JWT; if init or upload
  fails with auth errors, mint a fresh one.
- iOS deployment target is 15.1 everywhere (Runner pbxproj, Podfile, plugin
  podspec) — the Plaud frameworks require it. Don't lower it.
- The two native bridges implement one contract (9 methods, 12 events, same
  channel names and payload keys). Change one, change the other — Dart must
  never branch on platform.

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
  - `android/src/main/kotlin/ai/plaud/plaud_sdk/PlaudSdkPlugin.kt` — the same
    bridge over the Android facade `sdk.PlaudDeviceAgent` +
    `PlaudDeviceAgentListener`. The reference integration for that facade is
    `../plaud-sdk-public/android/app/src/main/java/com/plaud/template/managers/`
    (`DeviceManager.kt`, `SyncManager.kt`).
  - `ios/Frameworks/*.xcframework` — vendored Plaud SDK binaries, byte-identical
    to `../plaud-sdk-public/sdk/ios`.
  - `android/m2repo/ai/plaud/sdk/plaud-sdk/1.0.0/` — vendored Plaud Android SDK,
    byte-identical to `../plaud-sdk-public/sdk/android/plaud-sdk.aar`.

## Gotchas

- `PlaudDeviceBasicSDK` is a **static** framework: it links into the app
  binary and is NOT embedded, so its localization bundle must be copied via
  `s.resource` in `plugins/plaud_sdk/ios/plaud_sdk.podspec` (already done —
  don't remove it). `PlaudBleSDK`/`PlaudWiFiSDK` are dynamic and embed
  normally.
- Scanning only works after CoreBluetooth reaches `.poweredOn`; the Swift
  bridge polls ~18 s and emits `scanTimeout {reason: bluetoothNotPoweredOn}`
  — don't "simplify" that away. The Kotlin bridge polls the Bluetooth adapter
  the same way, and additionally requests the runtime BLE permissions itself
  (emitting `scanTimeout {reason: permissionDenied}` on refusal) so Dart can
  call `startScan` unconditionally on both platforms.
- Connect always passes a `deviceToken` (defaults to the `userId` from
  `initSDK`) — it binds device ↔ user during the handshake.
- Android needs two handshake prerequisites that iOS does internally, both in
  `connectBleDevice`: wait for `NiceBuildSdk.isPartnerDataReady()` (initSDK
  fetches the partner RSA keys over HTTP, asynchronously), then
  `signAndStoreDeviceSn`. And `initSDK` must call
  `NiceBuildSdk.getPartnerApiManager().updateBaseUrl(...)` first — the Partner
  API defaults to platform-jp and does *not* follow `customDomain`, so a US
  token would 401 and every handshake after it would fail.
- The Android SDK ships as a bare `.aar`, which can't be an
  `implementation(files(...))` dependency: the Flutter Gradle plugin builds
  each plugin project's AAR and AGP refuses to bundle one that has direct local
  `.aar` file deps. Hence the checked-in one-artifact Maven repo under
  `android/m2repo`, registered on `rootProject.allprojects` so the host app can
  resolve it too. The AAR also carries no POM, so its transitive deps are
  re-declared by hand in `android/build.gradle.kts`.
- Android's `BleFile` exposes only `sessionId`/`fileSize`/`attribute`/`scene`,
  so `fileList` fills `sn`, `channels` and `isOgg` from the connected
  `BleDevice` and derives `duration` from the SDK's own Opus formula. `uuid` is
  the MAC address there, standing in for the CoreBluetooth peripheral id.
- The SDK surface used here is a small slice of `PlaudDeviceAgent` (scan,
  connect, file list, export). The SDK also supports app-initiated recording,
  file download/delete, WiFi transfer, and firmware OTA — unbridged, like in
  the RN demo.
- The modal is rendered inline in a `Stack` (not `showModalBottomSheet`) so
  it rebuilds live as export/transcription state changes in the parent.
