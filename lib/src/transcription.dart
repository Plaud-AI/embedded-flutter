import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show md5;
import 'package:http/http.dart' as http;

import 'config.dart';

/// Client-side Plaud transcription flow. ⚠️ DEMO ONLY.
///
/// In production this belongs behind a backend, because it needs the partner
/// API key — here the credentials are compile-time defines baked into the
/// binary. Port of the RN demo's `plaud-transcription.ts`.
///
/// Flow:
///   1. upload → generate-presigned-urls → PUT parts to S3 → complete-upload
///      → DownloadUrl                (Bearer USER token — same as initSDK)
///   2. submit → POST /open/partner/ai/transcriptions/ { file_url }  (X-Client-*)
///   3. poll   → GET  /open/partner/ai/transcriptions/{id}           (X-Client-*)
const _baseUrl = 'https://platform-us.plaud.ai/developer/api';

typedef StatusFn = void Function(String message);

/// Transcription API auth: partner client id + api key (X-Client-* headers).
Map<String, String> _transcriptionHeaders() {
  if (PlaudConfig.clientId.isEmpty || PlaudConfig.apiKey.isEmpty) {
    throw Exception(
      'Missing transcription credentials — set PLAUD_CLIENT_ID and '
      'PLAUD_API_KEY (flutter run --dart-define-from-file=.env).',
    );
  }
  return {
    'X-Client-Id': PlaudConfig.clientId,
    'X-Client-Api-Key': PlaudConfig.apiKey,
  };
}

dynamic _readJson(http.Response res) {
  final text = res.body;
  dynamic body;
  try {
    body = text.isEmpty ? null : jsonDecode(text);
  } catch (_) {
    body = text;
  }
  if (res.statusCode < 200 || res.statusCode >= 300) {
    final detail = body is String ? body : jsonEncode(body);
    final clipped = detail.length > 300 ? detail.substring(0, 300) : detail;
    throw Exception('HTTP ${res.statusCode}: $clipped');
  }
  return body;
}

// --- Step 1: S3 multipart upload (Bearer user token) → DownloadUrl ---

Future<String> _uploadFile(
  String filePath,
  String userAccessToken,
  StatusFn? onStatus,
) async {
  final file = File(filePath);
  if (!file.existsSync()) {
    throw Exception('Exported file not found at $filePath');
  }
  final bytes = await file.readAsBytes();
  final size = bytes.length;

  onStatus?.call('requesting upload URLs…');
  final presigned = _readJson(await http.post(
    Uri.parse('$_baseUrl/open/partner/files/upload/generate-presigned-urls'),
    headers: {
      'Authorization': 'Bearer $userAccessToken',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({'filesize': size, 'filetype': 'mp3'}),
  )) as Map;

  final chunkSize = (presigned['ChunkSize'] as num).toInt();
  final parts = (presigned['Parts'] as List? ?? const []);
  final uploadedParts = <Map<String, Object>>[];

  for (final part in parts) {
    final partNumber = ((part as Map)['PartNumber'] as num).toInt();
    final presignedUrl = part['PresignedUrl'] as String;
    final start = (partNumber - 1) * chunkSize;
    final end = (start + chunkSize) > size ? size : start + chunkSize;
    final chunk = bytes.sublist(start, end);

    onStatus?.call('uploading part $partNumber/${parts.length}…');
    final put = await http.put(Uri.parse(presignedUrl), body: chunk);
    if (put.statusCode < 200 || put.statusCode >= 300) {
      throw Exception('Part $partNumber upload failed (HTTP ${put.statusCode})');
    }
    final etag = (put.headers['etag'] ?? '').replaceAll('"', '');
    if (etag.isEmpty) {
      throw Exception('Part $partNumber upload returned no ETag');
    }
    uploadedParts.add({'PartNumber': partNumber, 'ETag': etag});
  }

  onStatus?.call('finalizing upload…');
  final complete = _readJson(await http.post(
    Uri.parse('$_baseUrl/open/partner/files/upload/complete-upload'),
    headers: {
      'Authorization': 'Bearer $userAccessToken',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({
      'file_id': presigned['FileId'],
      'upload_id': presigned['UploadId'],
      'part_list': uploadedParts,
      'filetype': 'mp3',
      'file_md5': md5.convert(bytes).toString(),
    }),
  )) as Map?;

  final downloadUrl = complete?['DownloadUrl'] as String?;
  if (downloadUrl == null || downloadUrl.isEmpty) {
    throw Exception('complete-upload returned no DownloadUrl');
  }
  return downloadUrl;
}

// --- Step 2 + 3: submit transcription and poll (X-Client-* headers) ---

Future<String> _submitTranscription(String fileUrl, StatusFn? onStatus) async {
  onStatus?.call('submitting transcription…');
  final res = _readJson(await http.post(
    Uri.parse('$_baseUrl/open/partner/ai/transcriptions/'),
    headers: {..._transcriptionHeaders(), 'Content-Type': 'application/json'},
    body: jsonEncode({
      'file_url': fileUrl,
      'params': {
        'transcribe': {'language': 'auto', 'model': 'plaud-fast-whisper'},
        'vad': {'decode_silence': false},
        'diarization': {'enabled': false, 'return_embedding': false},
      },
    }),
  ));
  final id = (res as Map?)?['transcription_id'] ?? res?['data']?['task_id'];
  if (id == null) {
    final raw = jsonEncode(res);
    throw Exception(
      'Submit returned no transcription id: '
      '${raw.length > 200 ? raw.substring(0, 200) : raw}',
    );
  }
  return '$id';
}

/// Pull the transcript text out of the poll response, whatever shape it
/// arrives in.
String _extractTranscript(dynamic data) {
  if (data is! Map) return '';
  final text = data['text'];
  if (text is String && text.trim().isNotEmpty) return text;
  final results = data['results'];
  if (results is List) {
    return results
        .map((r) => (r is Map ? r['text'] : null) ?? '')
        .where((t) => (t as String).isNotEmpty)
        .join('\n\n');
  }
  final segments = data['segments'];
  if (segments is List) {
    return segments
        .map((s) => (s is Map ? s['text'] : null) ?? '')
        .where((t) => (t as String).isNotEmpty)
        .join(' ');
  }
  return '';
}

Future<String> _pollTranscription(
  String transcriptionId,
  StatusFn? onStatus, {
  Duration interval = const Duration(seconds: 3),
  Duration timeout = const Duration(minutes: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final res = _readJson(await http.get(
      Uri.parse('$_baseUrl/open/partner/ai/transcriptions/$transcriptionId'),
      headers: _transcriptionHeaders(),
    ));
    final data = (res is Map ? res['data'] : null) ?? res;
    final transcript = _extractTranscript(data);
    if (transcript.isNotEmpty) return transcript;

    final status =
        '${(res is Map ? res['status'] : null) ?? (data is Map ? data['task_status'] : null) ?? ''}'
            .toUpperCase();
    if (status.contains('FAIL') || status.contains('ERROR')) {
      throw Exception(
          'Transcription failed: ${status.isEmpty ? 'unknown error' : status}');
    }
    onStatus?.call(
        'transcribing… (${status.isEmpty ? 'processing' : status.toLowerCase()})');
    await Future<void>.delayed(interval);
  }
  throw Exception('Transcription timed out');
}

/// Upload an exported audio file and return its transcript. [filePath] is the
/// output path from `PlaudSdk.exportAudio`; [userAccessToken] is the token
/// used for `initSDK`.
Future<String> transcribeExportedFile(
  String filePath,
  String userAccessToken, {
  StatusFn? onStatus,
}) async {
  final fileUrl = await _uploadFile(filePath, userAccessToken, onStatus);
  final transcriptionId = await _submitTranscription(fileUrl, onStatus);
  return _pollTranscription(transcriptionId, onStatus);
}
