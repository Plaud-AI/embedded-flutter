import 'package:flutter/material.dart';
import 'package:plaud_sdk/plaud_sdk.dart';

import 'file_result.dart';
import 'theme.dart';
import 'widgets.dart';

/// Bottom-anchored recording detail card — export/transcribe progress, error
/// + retry, and the transcript once ready. Port of the RN `file-modal.tsx`;
/// rendered inline in a Stack (like the RN Modal) so it rebuilds live as the
/// parent's result state changes.
class FileModal extends StatelessWidget {
  const FileModal({
    super.key,
    required this.file,
    required this.result,
    required this.onClose,
    required this.onRetry,
  });

  final PlaudFile file;
  final FileResult? result;
  final VoidCallback onClose;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final status = result?.status;
    final busy = status == FileResultStatus.exporting ||
        status == FileResultStatus.transcribing;

    return Positioned.fill(
      child: GestureDetector(
        onTap: onClose,
        child: Container(
          color: PlaudColors.backdrop,
          padding: const EdgeInsets.all(16),
          alignment: Alignment.bottomCenter,
          child: GestureDetector(
            // Stop taps inside the card from closing the modal.
            onTap: () {},
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 448),
              child: FractionallySizedBox(
                heightFactor: 0.9,
                child: DevCard(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(),
                      if (busy && result?.transcribeStatus != null)
                        _progressLine(result!.transcribeStatus!),
                      if (status == FileResultStatus.exporting)
                        _progressLine(result?.exportInfo ?? 'exporting…'),
                      if (status == FileResultStatus.error) _errorBlock(),
                      if (status == FileResultStatus.ready)
                        Expanded(child: _transcriptSection()),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Overline('Recording'),
            const SizedBox(height: 4),
            Mono('Session #${file.sessionId}', size: 18, color: PlaudColors.textWhite),
            const SizedBox(height: 4),
            Mono(
              '${file.duration}s · ${(file.size / 1024).toStringAsFixed(0)} KB',
              size: 12,
              color: PlaudColors.textFaint,
            ),
          ],
        ),
        IconButton(
          onPressed: onClose,
          tooltip: 'Close',
          icon: const Icon(PlaudIcons.close, size: 22, color: PlaudColors.textDim),
        ),
      ],
    );
  }

  Widget _progressLine(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Mono(text, size: 12, color: PlaudColors.accentBlue),
    );
  }

  Widget _errorBlock() {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            result?.error ?? 'Something went wrong.',
            style: const TextStyle(fontSize: 13, color: PlaudColors.statusError),
          ),
          const SizedBox(height: 12),
          DevButton(label: 'Retry', onPressed: onRetry),
        ],
      ),
    );
  }

  Widget _transcriptSection() {
    final transcript = result?.transcript;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            spacing: 6,
            children: [
              Icon(PlaudIcons.fileText, size: 14, color: PlaudColors.textFaint),
              Overline('Transcript'),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: PlaudColors.surfaceInput,
                border: Border.all(color: PlaudColors.borderSubtle),
                borderRadius: BorderRadius.circular(PlaudRadius.sm),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Text(
                  (transcript != null && transcript.isNotEmpty)
                      ? transcript
                      : 'No speech detected.',
                  style: TextStyle(
                    fontSize: 13,
                    height: 20 / 13,
                    color: (transcript != null && transcript.isNotEmpty)
                        ? PlaudColors.textLight
                        : PlaudColors.textDim,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
