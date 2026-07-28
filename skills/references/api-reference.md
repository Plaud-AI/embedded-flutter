# Plaud SDK — Dart API reference

The static `PlaudSdk` class (from `package:plaud_sdk/plaud_sdk.dart`). Source of truth:
`plugins/plaud_sdk/lib/plaud_sdk.dart`, `plugins/plaud_sdk/lib/src/types.dart`, and
`plugins/plaud_sdk/ios/Classes/PlaudSdkPlugin.swift`.

All methods are iOS-device-only and throw a `MissingPluginException` on other platforms / the
simulator. Guard call sites with `isPlaudSdkAvailable`. Methods that fetch data (`startScan`,
`getFileList`) return a `Future<void>` that completes immediately and deliver results later via
**event streams** — the future completing means "the request was sent," not "here's the data."

## Library exports

```dart
import 'package:plaud_sdk/plaud_sdk.dart';
```

- `isPlaudSdkAvailable: bool` — `true` only on a physical iOS device where the native plugin is
  linked (`!kIsWeb && Platform.isIOS`). `false` elsewhere, where every `PlaudSdk` method throws.
- `PlaudSdk` — the static API (private constructor; call methods on the class, no instance).
- All the payload types (`PlaudScanDevice`, `PlaudFile`, …) are re-exported from `src/types.dart`.

## Methods

| Method | Signature | Notes |
| --- | --- | --- |
| `initSDK` | `({required String userAccessToken, required String customDomain, String? userId}) → Future<void>` | Call once before anything else. `customDomain` is domain-only (no `https://`). `userId` is reused as the default connect `deviceToken`. Throws `ERR_PLAUD_ARGS` if token/domain missing. |
| `startScan` | `() → Future<void>` | Begins BLE scan. Internally waits for CoreBluetooth to reach `.poweredOn` (polls ~18 s); emits `onScanTimeout` with reason `bluetoothNotPoweredOn` if it never powers on. Devices arrive via `onScanResult`. |
| `stopScan` | `() → Future<void>` | Stops scanning. |
| `connectBleDevice` | `({String? uuid, String? serialNumber, String? deviceToken}) → Future<void>` | Connect to a device from a prior `onScanResult`. Prefer `uuid`. Must scan first (device objects are cached natively) or it throws `ERR_PLAUD_UNKNOWN_DEVICE`. `deviceToken` defaults to the `userId` from `initSDK`. Result arrives via `onConnectState`. |
| `disconnect` | `() → Future<void>` | Disconnect the current device. |
| `depair` | `({bool clear = true}) → Future<void>` | Unpair. `clear` (default `true`) also wipes local pairing state. Completion arrives via `onDepair`. |
| `isConnected` | `() → Future<bool>` | Direct status check (this one returns data directly, not via a stream). |
| `getFileList` | `({int startSessionId = 0}) → Future<void>` | Request the on-device recording list. Results arrive via `onFileList`. |
| `exportAudio` | `({required int sessionId, PlaudAudioFormat format = PlaudAudioFormat.mp3, int channels = 1}) → Future<PlaudExportResult>` | Decode a recording to a file in `Documents/PlaudExports`. Resolves with `{sessionId, outputPath}`; emits `onExportProgress` along the way. Throws `ERR_PLAUD_ARGS` (bad sessionId) or `ERR_PLAUD_EXPORT`. |

`enum PlaudAudioFormat { pcm, mp3, wav, opus }` — `format` defaults to `mp3`.

`PlaudExportResult.outputPath` is a raw path; it may lack the `file://` scheme — normalize it
(strip or add the prefix) before handing to `dart:io File` or an HTTP upload.

## Event streams

Each is a `static Stream<…> get on<Event>` off `PlaudSdk`, sourced from a single underlying
broadcast `EventChannel`. Subscribe with `.listen(cb)`, keep the returned `StreamSubscription`,
and `.cancel()` it in `dispose()`. There is also a raw `PlaudSdk.events` stream (each event is a
`Map` tagged with an `event` key) if you need an event the typed getters don't surface.

| Stream | Emits | When |
| --- | --- | --- |
| `onScanResult` | `List<PlaudScanDevice>` | Devices discovered during a scan (fires repeatedly with a cumulative, growing list). |
| `onScanTimeout` | `String?` (reason) | Scan window ended, or BLE never powered on (reason `bluetoothNotPoweredOn`). |
| `onConnectState` | `PlaudConnectState` | Connection state changed. `state`: `1`=connected, `0`=disconnected, `{2,-1,-2}`=failure (`failed == true`). |
| `onPenState` | `Map<String, Object?>` | Device status snapshot (raw map, informational). |
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
  final String uuid;         // CoreBluetooth peripheral id — use this to connect
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
