/// Per-recording export/transcription progress, keyed by sessionId in the
/// home screen state. Mirrors `FileResult` in the RN demo.
enum FileResultStatus { exporting, transcribing, ready, error }

class FileResult {
  const FileResult({
    this.status,
    this.src,
    this.exportInfo,
    this.transcribeStatus,
    this.transcript,
    this.error,
  });

  final FileResultStatus? status;

  /// Local path of the exported audio file.
  final String? src;
  final String? exportInfo;
  final String? transcribeStatus;
  final String? transcript;
  final String? error;

  FileResult copyWith({
    FileResultStatus? status,
    String? src,
    String? exportInfo,
    String? transcribeStatus,
    String? transcript,
    String? error,
    bool clearTranscript = false,
    bool clearError = false,
  }) {
    return FileResult(
      status: status ?? this.status,
      src: src ?? this.src,
      exportInfo: exportInfo ?? this.exportInfo,
      transcribeStatus: transcribeStatus ?? this.transcribeStatus,
      transcript: clearTranscript ? null : (transcript ?? this.transcript),
      error: clearError ? null : (error ?? this.error),
    );
  }
}
