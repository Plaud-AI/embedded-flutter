/// Demo configuration. Mirrors the RN demo's constants + `EXPO_PUBLIC_*` env.
///
/// Credentials come from compile-time defines — run with:
///   flutter run --dart-define-from-file=.env
/// (see .env.example). ⚠️ DEMO ONLY: baking partner credentials into a client
/// binary is fine for a demo build, never ship it — in production, mint the
/// user token and proxy upload/transcription through a backend.
abstract final class PlaudConfig {
  static const domain = 'platform-us.plaud.ai';
  static const userId = 'jackmu';

  /// Per-user JWT for `initSDK` and file upload (Bearer).
  static const accessToken = String.fromEnvironment('PLAUD_ACCESS_TOKEN');

  /// Partner credentials for the transcription API (X-Client-* headers).
  static const clientId = String.fromEnvironment('PLAUD_CLIENT_ID');
  static const apiKey = String.fromEnvironment('PLAUD_API_KEY');
}
