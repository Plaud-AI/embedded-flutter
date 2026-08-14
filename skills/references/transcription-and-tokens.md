# Tokens and transcription

Two things the native plugin does **not** do — both are your app/backend's responsibility.

## The per-user access token

`initSDK` requires a **per-user access token** (a Bearer JWT). The SDK does *not* mint it.

- **Production:** mint it via Plaud's partner OAuth flow on your backend and hand it to the
  client. The same token is used both for `initSDK` and for authenticating file uploads.
- **Local testing:** this repo reads it from a compile-time define. `.env` (gitignored; copy
  `.env.example`) holds the value, and every run/build must pass it:

  ```sh
  flutter run --dart-define-from-file=.env                       # iPhone or Android phone
  flutter build ios --no-codesign --dart-define-from-file=.env   # iOS link check
  flutter build apk --debug --dart-define-from-file=.env         # Android compile check
  ```

  `lib/src/config.dart` reads the defines with `String.fromEnvironment`:

  ```dart
  abstract final class PlaudConfig {
    static const domain = 'platform-us.plaud.ai';
    static const accessToken = String.fromEnvironment('PLAUD_ACCESS_TOKEN');
    static const clientId    = String.fromEnvironment('PLAUD_CLIENT_ID');
    static const apiKey      = String.fromEnvironment('PLAUD_API_KEY');
  }
  ```

> ⚠️ `--dart-define` values are compiled into the app binary and are **extractable** from the
> app. Fine for a demo build; never ship credentials in the client.

The token is a short-lived (~24 h) per-user JWT. If `initSDK` or an upload fails with an auth
error, mint a fresh one from https://platform.plaud.ai/developer/portal.

## Transcription is plain HTTP, not the native plugin

Once a recording is exported to a local file (via `PlaudSdk.exportAudio`), uploading and
transcribing it is ordinary HTTP against the Plaud platform API — nothing to do with the native
bridge. In production this belongs **behind a backend** (it needs the partner API key). The demo
does it client-side for convenience only.

The full working implementation is `lib/src/transcription.dart` (`transcribeExportedFile`),
built on `package:http` and `package:crypto`. The flow:

1. **Upload** (Bearer *user* token — the same one passed to `initSDK`):
   `POST .../files/upload/generate-presigned-urls` → PUT each part to S3 →
   `POST .../files/upload/complete-upload` → returns a `DownloadUrl`. The MD5 of the file bytes
   is sent as `file_md5` on complete.
2. **Submit** (`X-Client-Id` / `X-Client-Api-Key` partner headers):
   `POST /open/partner/ai/transcriptions/` with `{ file_url, params }`.
3. **Poll** (partner headers): `GET /open/partner/ai/transcriptions/{id}` until a terminal
   `SUCCESS`-family status, then extract the transcript text from the response.

Base URL in the demo: `https://platform-us.plaud.ai/developer/api`.

### Two different credentials — don't mix them up

| Call | Auth |
| --- | --- |
| `initSDK` + file upload (presigned URLs, complete-upload) | `Authorization: Bearer <per-user token>` |
| Submit + poll transcription | `X-Client-Id` + `X-Client-Api-Key` (partner credentials) |

Partner credentials come from the Plaud Developer Portal:
https://platform.plaud.ai/developer/portal.

### Dart-specific upload notes

- Chunk from an in-memory `Uint8List` (`await file.readAsBytes()` then `bytes.sublist(start, end)`).
  Use the `ChunkSize`/`Parts` array the presign response returns — don't invent your own chunking.
- Grab the `etag` response header from each S3 PUT and strip the surrounding quotes; the
  `complete-upload` call needs `{ PartNumber, ETag }` for every part.
- Poll termination is gated on **status**, not on whether text was extracted: a completed
  `SUCCESS` with no speech returns an empty transcript instead of hanging the loop. Copy
  `transcription.dart` rather than re-deriving this — the terminal-status handling is the subtle part.

### Env vars (demo)

```
PLAUD_ACCESS_TOKEN=   # per-user Bearer JWT for initSDK + upload
PLAUD_CLIENT_ID=      # partner X-Client-Id (transcription)
PLAUD_API_KEY=        # partner X-Client-Api-Key (transcription)
```
