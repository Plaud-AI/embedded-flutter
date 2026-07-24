# embedded_flutter — Plaud SDK demo (iOS)

Flutter port of the React Native demo in `embedded-react-native/react-native-demo`:
pair a Plaud recorder over BLE, watch device-initiated recordings live, list
on-device recordings, then export one to MP3 and transcribe it via the Plaud
cloud API.

**iOS only, physical device required.** The vendored Plaud frameworks are
arm64 device builds (no simulator slice) — the app will not link for the
simulator, and Android is not supported by the SDK.

## Layout

- `lib/` — the app: single dark screen (`src/home_page.dart`), transcript
  modal (`src/file_modal.dart`), Plaud cloud transcription client
  (`src/transcription.dart`), design tokens (`src/theme.dart`).
- `plugins/plaud_sdk/` — local Flutter plugin wrapping the native Plaud iOS
  SDK (`PlaudDeviceAgent`) with a MethodChannel + EventChannel. The three
  Plaud `.xcframework`s are vendored under `plugins/plaud_sdk/ios/Frameworks/`
  (same binaries as `plaud-sdk-public/sdk/ios`). Swift bridge:
  `plugins/plaud_sdk/ios/Classes/PlaudSdkPlugin.swift`.

## Setup

1. Copy `.env.example` to `.env` and fill in your credentials from the
   [Plaud developer portal](https://platform.plaud.ai/developer/portal):
   - `PLAUD_ACCESS_TOKEN` — per-user JWT, used for `initSDK` and file upload.
   - `PLAUD_CLIENT_ID` / `PLAUD_API_KEY` — partner credentials for the
     transcription API.
2. Open `ios/Runner.xcworkspace` once to set your signing team (Runner →
   Signing & Capabilities).

## Run

```sh
flutter pub get
flutter run --dart-define-from-file=.env   # with an iPhone plugged in
```

The credentials are compile-time defines — `--dart-define-from-file=.env` is
required on every `run`/`build`, otherwise the app starts with a "No Plaud
access token" error.

⚠️ **Demo only:** this bakes partner credentials into the client binary and
calls the platform API directly from the device. In production, mint the user
token and proxy upload/transcription through your backend.

## Flow

1. **Init & scan** — `PlaudSdk.initSDK` (token + `platform-us.plaud.ai`), then
   BLE scan; discovered devices stream in via `scanResult` events.
2. **Connect** — tap a device; the bridge connects with a `deviceToken`
   (the demo user id) which binds device ↔ user during the handshake, then
   auto-loads the recording list.
3. **Record on the device** — button/VAD recording state streams in via
   `recordStart/Stop/Pause/Resume` events (live banner).
4. **Tap a recording** — native `exportAudio` decodes it to MP3 under
   `Documents/PlaudExports`, then the app uploads it (S3 multipart via
   presigned URLs) and polls `/open/partner/ai/transcriptions/{id}` until the
   transcript is ready.
