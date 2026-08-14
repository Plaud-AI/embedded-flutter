# Plaud SDK — Dart API reference

The static `PlaudSdk` class (from `package:plaud_sdk/plaud_sdk.dart`). Source of truth:
`plugins/plaud_sdk/lib/plaud_sdk.dart`, `plugins/plaud_sdk/lib/src/types.dart`, and the two
native bridges — `plugins/plaud_sdk/ios/Classes/PlaudSdkPlugin.swift` and
`plugins/plaud_sdk/android/src/main/kotlin/ai/plaud/plaud_sdk/PlaudSdkPlugin.kt`.

The API is **identical on iOS and Android** — the two bridges implement the same 9 methods and
12 events against the same channel names and payload keys, so no call site should branch on
platform. Everything below applies to both unless a row says otherwise; see
[iOS/Android differences](#iosandroid-differences) for the handful that leak through.

Methods throw a `MissingPluginException` on any other platform (web/desktop) and on the iOS
simulator, where the plugin isn't linked. Guard call sites with `isPlaudSdkAvailable`. Methods
that fetch data (`startScan`, `getFileList`) return a `Future<void>` that completes immediately
and deliver results later via **event streams** — the future completing means "the request was
sent," not "here's the data."

## Library exports

```dart
import 'package:plaud_sdk/plaud_sdk.dart';
```

- `isPlaudSdkAvailable: bool` — `true` on iOS and Android, where the native plugin is linked
  (`!kIsWeb && (Platform.isIOS || Platform.isAndroid)`). `false` elsewhere, where every
  `PlaudSdk` method throws. Note it is a *platform* check, not a *hardware* check: it's `true` on
  an Android emulator, which has no BLE radio and will never find a device.
- `PlaudSdk` — the static API (private constructor; call methods on the class, no instance).
- All the payload types (`PlaudScanDevice`, `PlaudFile`, …) are re-exported from `src/types.dart`.

## Methods

| Method | Signature | Notes |
| --- | --- | --- |
| `initSDK` | `({required String userAccessToken, required String customDomain, String? userId}) → Future<void>` | Call once before anything else. `customDomain` is domain-only (no `https://`). `userId` is reused as the default connect `deviceToken`. Throws `ERR_PLAUD_ARGS` if token/domain missing. |
| `startScan` | `() → Future<void>` | Begins BLE scan. Waits (polls ~18 s) for the Bluetooth radio to be on — CoreBluetooth `.poweredOn` on iOS, the `BluetoothAdapter` on Android — and emits `onScanTimeout` with reason `bluetoothNotPoweredOn` if it never comes up. On Android it *first* requests the runtime BLE permissions, emitting reason `permissionDenied` if refused. Call it unconditionally on both platforms. Devices arrive via `onScanResult`. |
| `stopScan` | `() → Future<void>` | Stops scanning. |
| `connectBleDevice` | `({String? uuid, String? serialNumber, String? deviceToken}) → Future<void>` | Connect to a device from a prior `onScanResult`. Prefer `uuid`. Must scan first (device objects are cached natively) or it throws `ERR_PLAUD_UNKNOWN_DEVICE`. `deviceToken` defaults to the `userId` from `initSDK`. Result arrives via `onConnectState`. Android additionally runs two handshake prerequisites here (partner-key wait + SN signing) and can throw `ERR_PLAUD_CONNECT`. |
| `disconnect` | `() → Future<void>` | Disconnect the current device. |
| `depair` | `({bool clear = true}) → Future<void>` | Unpair. `clear` (default `true`) also wipes local pairing state. Completion arrives via `onDepair`. |
| `isConnected` | `() → Future<bool>` | Direct status check (this one returns data directly, not via a stream). |
| `getFileList` | `({int startSessionId = 0}) → Future<void>` | Request the on-device recording list. Results arrive via `onFileList`. |
| `exportAudio` | `({required int sessionId, PlaudAudioFormat format = PlaudAudioFormat.mp3, int channels = 1}) → Future<PlaudExportResult>` | Decode a recording to a file in a `PlaudExports` directory (iOS `Documents/`, Android the app's private `files/`). Resolves with `{sessionId, outputPath}`; emits `onExportProgress` along the way. Throws `ERR_PLAUD_ARGS` (bad sessionId) or `ERR_PLAUD_EXPORT`. |

`enum PlaudAudioFormat { pcm, mp3, wav, opus }` — `format` defaults to `mp3`.

`PlaudExportResult.outputPath` is a raw path; it may lack the `file://` scheme — normalize it
(strip or add the prefix) before handing to `dart:io File` or an HTTP upload.

### Error codes

| Code | Thrown by | Meaning |
| --- | --- | --- |
| `ERR_PLAUD_ARGS` | `initSDK`, `exportAudio` | Missing/empty `userAccessToken` or `customDomain`; missing or negative `sessionId`. |
| `ERR_PLAUD_UNKNOWN_DEVICE` | `connectBleDevice` | No cached device matches the `uuid`/`serialNumber` — you didn't scan first, or you passed a stale id. |
| `ERR_PLAUD_CONNECT` | `connectBleDevice` (Android only) | The native connect call threw. iOS reports the equivalent failure asynchronously via `onConnectState.failed`. |
| `ERR_PLAUD_EXPORT` | `exportAudio` | Decode failed or the device dropped mid-export. |

## Event streams

Each is a `static Stream<…> get on<Event>` off `PlaudSdk`, sourced from a single underlying
broadcast `EventChannel`. Subscribe with `.listen(cb)`, keep the returned `StreamSubscription`,
and `.cancel()` it in `dispose()`. There is also a raw `PlaudSdk.events` stream (each event is a
`Map` tagged with an `event` key) if you need an event the typed getters don't surface.

| Stream | Emits | When |
| --- | --- | --- |
| `onScanResult` | `List<PlaudScanDevice>` | Devices discovered during a scan (fires repeatedly with a cumulative, growing list). |
| `onScanTimeout` | `String?` (reason) | `null` — the SDK's scan window ended; `bluetoothNotPoweredOn` — the radio never came up; `permissionDenied` — the user refused the runtime BLE permissions (**Android only**). |
| `onConnectState` | `PlaudConnectState` | Connection state changed. `state`: `1`=connected, `0`=disconnected, `{2,-1,-2}`=failure (`failed == true`). |
| `onPenState` | `Map<String, Object?>` | Device status snapshot (raw map, informational). Key set differs per platform — see below. |
| `onBind` | `Map<String, Object?>` | Device ↔ user bind/pairing handshake result (raw map, informational). |
| `onFileList` | `List<PlaudFile>` | Response to `getFileList`. |
| `onExportProgress` | `PlaudExportProgress` | Progress during `exportAudio`. |
| `onRecordStart` | `PlaudRecordStart` | Device-initiated recording started (physical button / VAD). |
| `onRecordResume` | `PlaudRecordStart` | Recording resumed. |
| `onRecordStop` | `PlaudRecordStop` | Recording stopped; includes resulting file info. |
| `onRecordPause` | `PlaudRecordStop` | Recording paused. |
| `onDepair` | `int` (status) | Unpair completed — reset all local device state here. |

`onRecordStart`/`onRecordStop`/etc. are **device-initiated** (the user pressed the button on the
recorder). Refresh the file list on `onRecordStop` to pick up the new recording.

## Types

```dart
class PlaudScanDevice {
  final String name;
  final String uuid;         // opaque handle — use this to connect
                             // (iOS: CoreBluetooth peripheral id; Android: MAC address)
  final String serialNumber;
  final double rssi;
  final bool supportWiFi;
}

class PlaudConnectState {
  final bool connected;
  final bool failed;         // true for handshake failure (state 2/-1/-2), not a normal disconnect
  final int state;
}

class PlaudFile {
  final String sn;
  final int sessionId;       // identifies the recording for exportAudio
  final int size;            // bytes
  final int scenes;
  final int channels;
  final bool isOgg;
  final bool isMusic;
  final int duration;        // seconds
}

class PlaudExportProgress {
  final int sessionId;
  final int progress;        // 0–100
  final String message;
}

class PlaudExportResult {
  final int sessionId;
  final String outputPath;   // file on local disk (Documents/PlaudExports)
}

class PlaudRecordStart {     // recordStart / recordResume
  final int sessionId, start, status, scene, startTime;
  final int? reason;
}

class PlaudRecordStop {      // recordStop / recordPause
  final int sessionId, reason, fileSize;
  final bool fileExist;
}
```

## Canonical scan → connect → list → export flow

```dart
final subs = <StreamSubscription>[
  PlaudSdk.onScanResult.listen((devices) => setState(() => _devices = devices)),
  PlaudSdk.onConnectState.listen((s) {
    if (s.connected) PlaudSdk.getFileList();          // load recordings on connect
    else if (s.failed) showError('Connection failed — move closer and retry');
  }),
  PlaudSdk.onFileList.listen((files) => setState(() => _files = files)),
];

await PlaudSdk.startScan();
// user picks a device:
await PlaudSdk.connectBleDevice(uuid: device.uuid);
// user picks a file:
final export = await PlaudSdk.exportAudio(sessionId: file.sessionId, format: PlaudAudioFormat.mp3);
// export.outputPath → the decoded mp3 on disk
```

See `lib/src/home_page.dart` for the full stateful version.

## iOS/Android differences

The Dart API is the same on both platforms — **do not branch on `Platform`**. These are the only
places the underlying native SDKs differ, and each is either already normalised by the bridges or
purely informational.

| Area | iOS | Android |
| --- | --- | --- |
| `PlaudScanDevice.uuid` | CoreBluetooth peripheral id | MAC address (`BleDevice.macAddress`, falling back to the SN) |
| `PlaudScanDevice.supportWiFi` | Reported by the SDK | Derived — `projectCode == 881` (NotePro is the model with WiFi fast transfer) |
| BLE permissions | Declared in `Info.plist`; iOS prompts on first use | Merged from the plugin's manifest; the bridge requests the runtime ones inside `startScan` and reports refusal as `onScanTimeout('permissionDenied')` |
| Connect handshake | Handled inside the SDK | The bridge first waits for `NiceBuildSdk.isPartnerDataReady()` (up to 10 s) then calls `signAndStoreDeviceSn`; skipping either leaves the handshake without an `snSignature` |
| Partner API host | Follows `customDomain` | Does **not** — the bridge calls `updateBaseUrl("https://$customDomain")` in `initSDK`, otherwise it defaults to platform-jp and 401s a US token |
| Connect errors | Surface asynchronously as `onConnectState.failed` | Same, plus a synchronous `ERR_PLAUD_CONNECT` if the native call throws |
| `onPenState` payload | 7 keys (adds `findMyToken`, `hasSndpKey`, `deviceAccessToken`) | 4 keys (`state`, `privacy`, `keyState`, `uDisk`) — read it defensively, it's a raw map |
| `PlaudFile` fields | All from the SDK's `BleFile` | `sn`, `channels`, `isOgg` come from the connected `BleDevice`; `duration` is derived with the SDK's Opus formula (Ogg-container recordings read slightly long, since page headers count toward size) |
| Export destination | `Documents/PlaudExports` | The app's private `files/PlaudExports` |
| Hardware | arm64 device only; no simulator slice (link failure) | Emulator builds and runs, but has no BLE radio (scans find nothing) |
