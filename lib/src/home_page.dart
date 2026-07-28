import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoAlertDialog, CupertinoDialogAction, showCupertinoDialog;
import 'package:flutter/material.dart';
import 'package:plaud_sdk/plaud_sdk.dart';

import 'config.dart';
import 'file_modal.dart';
import 'file_result.dart';
import 'theme.dart';
import 'transcription.dart';
import 'widgets.dart';

/// The Plaud "Connect. Record. Transcribe." screen — a 1:1 port of the RN
/// demo's `src/app/index.tsx`.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<PlaudScanDevice> _devices = [];
  List<PlaudFile> _files = [];
  bool _connected = false;
  String? _recording;
  bool _isLive = false;
  String? _error;
  bool _scanning = false;
  bool _tokenReady = false;

  final Map<int, FileResult> _results = {};
  int? _openSessionId;

  final List<StreamSubscription<Object?>> _subs = [];

  @override
  void initState() {
    super.initState();
    _subscribeToEvents();
    _initSdk();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  /// Scan results arrive in discovery order (effectively random). Sort by name
  /// (case-insensitive), falling back to uuid so the ordering is stable across
  /// rescans when two devices share a name or have none.
  List<PlaudScanDevice> _sortDevices(List<PlaudScanDevice> found) {
    final sorted = [...found];
    sorted.sort((a, b) {
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return byName != 0 ? byName : a.uuid.compareTo(b.uuid);
    });
    return sorted;
  }

  void _updateResult(int sessionId, FileResult Function(FileResult) patch) {
    if (!mounted) return;
    setState(() {
      _results[sessionId] = patch(_results[sessionId] ?? const FileResult());
    });
  }

  /// Mint the per-user Plaud JWT that `initSDK` requires. In production this
  /// is an app/backend concern; for local dev it comes from `.env` via
  /// `--dart-define-from-file`.
  String _userAccessToken() {
    if (PlaudConfig.accessToken.isEmpty) {
      throw Exception(
        'No Plaud access token — run with --dart-define-from-file=.env '
        '(see .env.example) or wire a mint endpoint in PlaudConfig.',
      );
    }
    return PlaudConfig.accessToken;
  }

  // Initialise the native SDK once, after minting the per-user token.
  Future<void> _initSdk() async {
    if (!isPlaudSdkAvailable) {
      setState(() {
        _error = 'Plaud native module unavailable — run on a physical iOS device.';
      });
      return;
    }
    try {
      final token = _userAccessToken();
      await PlaudSdk.initSDK(
        userAccessToken: token,
        customDomain: PlaudConfig.domain,
        userId: PlaudConfig.userId,
      );
      if (mounted) setState(() => _tokenReady = true);
    } catch (e) {
      if (mounted) setState(() => _error = 'SDK init failed: $e');
    }
  }

  // Subscribe to the native event stream. Every listener drives screen state.
  void _subscribeToEvents() {
    if (!isPlaudSdkAvailable) return;

    _subs.addAll([
      PlaudSdk.onScanResult.listen((found) => setState(() => _devices = _sortDevices(found))),
      PlaudSdk.onScanTimeout.listen((reason) {
        setState(() {
          _scanning = false;
          if (reason == 'bluetoothNotPoweredOn') {
            _error = 'Bluetooth isn’t available — enable Bluetooth and grant '
                'the app permission, then try again.';
          }
        });
      }),
      PlaudSdk.onConnectState.listen((s) {
        if (s.connected) {
          setState(() {
            _connected = true;
            _scanning = false;
          });
          PlaudSdk.getFileList().catchError(
            (Object e) => setState(() => _error = 'getFileList failed: $e'),
          );
        } else if (s.failed) {
          setState(() {
            _scanning = false;
            _error = 'Connection failed — move the device closer and try again.';
          });
        } else {
          setState(() => _connected = false);
        }
      }),
      PlaudSdk.onFileList.listen((found) => setState(() => _files = found)),
      PlaudSdk.onRecordStart.listen((e) {
        setState(() {
          _isLive = true;
          _recording = 'Recording · session ${e.sessionId} · scene ${e.scene}';
        });
      }),
      PlaudSdk.onRecordResume.listen((e) {
        setState(() {
          _isLive = true;
          _recording = 'Recording · session ${e.sessionId}';
        });
      }),
      PlaudSdk.onRecordStop.listen((e) {
        setState(() {
          _isLive = false;
          _recording =
              'Stopped · session ${e.sessionId} · ${(e.fileSize / 1024).toStringAsFixed(0)} KB';
        });
        // A new recording just landed — refresh the on-device list.
        PlaudSdk.getFileList().catchError((_) {});
      }),
      PlaudSdk.onRecordPause.listen((e) {
        setState(() {
          _isLive = false;
          _recording = 'Paused · session ${e.sessionId}';
        });
      }),
      PlaudSdk.onExportProgress.listen((e) {
        _updateResult(
          e.sessionId,
          (r) => r.copyWith(exportInfo: '${e.progress}% ${e.message}'),
        );
      }),
      PlaudSdk.onDepair.listen((_) {
        setState(() {
          _connected = false;
          _devices = [];
          _files = [];
          _recording = null;
          _isLive = false;
          _results.clear();
          _openSessionId = null;
        });
      }),
    ]);
  }

  void _handleScan() {
    setState(() => _error = null);
    if (!_tokenReady) {
      setState(() => _error = 'User token not ready yet — try again in a moment.');
      return;
    }
    setState(() {
      _devices = [];
      _scanning = true;
    });
    PlaudSdk.startScan().catchError((Object e) {
      setState(() {
        _scanning = false;
        _error = 'Scan failed: $e';
      });
    });
  }

  void _handleConnect(PlaudScanDevice d) {
    setState(() => _error = null);
    // Connection progress arrives via `connectState` (which flips `connected`
    // and loads the file list). Identify the device by uuid from the scan.
    PlaudSdk.connectBleDevice(uuid: d.uuid).catchError(
      (Object e) => setState(() => _error = 'Connect failed: $e'),
    );
  }

  void _handleDepair() {
    showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Unpair device'),
        content: const Text('Unpair this device and clear local pairing state?'),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.of(ctx).pop();
              // State resets when the native `depair` event arrives.
              PlaudSdk.depair(clear: true).catchError(
                (Object e) => setState(() => _error = 'Unpair failed: $e'),
              );
            },
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportAndTranscribe(PlaudFile f) async {
    setState(() => _error = null);
    _updateResult(
      f.sessionId,
      (_) => const FileResult(status: FileResultStatus.exporting, exportInfo: 'starting…'),
    );
    try {
      // Native: decode the recording to an mp3 in Documents/PlaudExports.
      // `exportProgress` events update exportInfo along the way.
      final export = await PlaudSdk.exportAudio(
        sessionId: f.sessionId,
        format: PlaudAudioFormat.mp3,
      );
      final path = export.outputPath.startsWith('file://')
          ? export.outputPath.substring('file://'.length)
          : export.outputPath;
      final name = path.split('/').last;
      var sizeLabel = '';
      try {
        final size = File(path).lengthSync();
        sizeLabel = ' (${(size / 1024).toStringAsFixed(0)} KB)';
      } catch (_) {
        // size is best-effort; the export itself already succeeded.
      }
      _updateResult(
        f.sessionId,
        (r) => r.copyWith(
          status: FileResultStatus.transcribing,
          src: path,
          exportInfo: 'saved → $name$sizeLabel',
          transcribeStatus: 'preparing upload…',
        ),
      );

      // Upload the exported file to Plaud and poll for the transcript.
      // ⚠️ DEMO ONLY — calls the platform API straight from the device with
      // baked-in credentials; in production this belongs behind a backend.
      final transcript = await transcribeExportedFile(
        path,
        _userAccessToken(),
        onStatus: (msg) =>
            _updateResult(f.sessionId, (r) => r.copyWith(transcribeStatus: msg)),
      );
      _updateResult(
        f.sessionId,
        (r) => r.copyWith(
          status: FileResultStatus.ready,
          transcribeStatus: 'transcription complete',
          transcript: transcript,
        ),
      );
    } catch (e) {
      _updateResult(
        f.sessionId,
        (r) => r.copyWith(status: FileResultStatus.error, error: '$e'),
      );
    }
  }

  void _handleFileClick(PlaudFile f) {
    setState(() => _openSessionId = f.sessionId);
    if (_results[f.sessionId]?.status == FileResultStatus.ready) return;
    _exportAndTranscribe(f);
  }

  void _handleRefreshFiles() {
    setState(() => _error = null);
    PlaudSdk.getFileList().catchError(
      (Object e) => setState(() => _error = 'getFileList failed: $e'),
    );
  }

  @override
  Widget build(BuildContext context) {
    PlaudFile? openFile;
    if (_openSessionId != null) {
      for (final f in _files) {
        if (f.sessionId == _openSessionId) openFile = f;
      }
    }

    return Scaffold(
      backgroundColor: PlaudColors.surface,
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: SafeArea(
                  bottom: false,
                  child: SingleChildScrollView(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: maxContentWidth),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                              20, Spacing.five, 20, Spacing.six),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            spacing: Spacing.four,
                            children: [
                              _intro(),
                              _actions(),
                              if (_recording != null) _recordingBanner(),
                              if (_error != null) _errorBanner(),
                              if (_devices.isNotEmpty && !_connected && _scanning)
                                _devicesSection(),
                              if (_connected) _recordingsSection(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              _footer(),
            ],
          ),
          if (openFile != null)
            FileModal(
              file: openFile,
              result: _results[openFile.sessionId],
              onClose: () => setState(() => _openSessionId = null),
              onRetry: () => _exportAndTranscribe(openFile!),
            ),
        ],
      ),
    );
  }

  Widget _intro() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: const [
        Text(
          'Connect. Record. Transcribe.',
          style: TextStyle(
            fontSize: 32,
            height: 34 / 32,
            color: PlaudColors.textWhite,
            letterSpacing: -0.3,
          ),
        ),
        SizedBox(height: 12),
        Text(
          'Pair a Plaud recorder over Bluetooth, capture on-device, then export '
          'and transcribe — straight from the native bridge.',
          style: TextStyle(fontSize: 15, height: 21 / 15, color: PlaudColors.textDim),
        ),
      ],
    );
  }

  Widget _actions() {
    return Row(
      children: [
        Expanded(
          child: !_connected
              ? DevButton(
                  label: _scanning ? 'Scanning…' : 'Init & scan',
                  icon: PlaudIcons.radar,
                  disabled: _scanning,
                  onPressed: _handleScan,
                )
              : DevButton(
                  label: 'Unpair',
                  icon: PlaudIcons.unlink,
                  variant: DevButtonVariant.destructive,
                  onPressed: _handleDepair,
                ),
        ),
      ],
    );
  }

  Widget _recordingBanner() {
    return DevCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      borderColor: _isLive ? PlaudColors.liveBorder : PlaudColors.borderSubtle,
      child: Row(
        spacing: 12,
        children: [
          if (_isLive)
            const WaveBars()
          else
            const Icon(PlaudIcons.fileAudio, size: 20, color: PlaudColors.textLight),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Overline(_isLive ? 'Live' : 'Last capture'),
                const SizedBox(height: 2),
                Mono(_recording ?? '', size: 13, maxLines: 1),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: PlaudColors.surfaceCard,
        border: Border.all(color: PlaudColors.errorBorder),
        borderRadius: BorderRadius.circular(PlaudRadius.sm),
      ),
      child: Text(
        _error ?? '',
        style: const TextStyle(fontSize: 13, color: PlaudColors.statusError),
      ),
    );
  }

  Widget _devicesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Overline('Devices'),
            Mono('${_devices.length} found', size: 12, color: PlaudColors.textFaint),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            for (final d in _devices)
              DevRow(
                onTap: () => _handleConnect(d),
                child: Row(
                  spacing: 12,
                  children: [
                    Expanded(
                      child: Text(
                        d.name.isNotEmpty
                            ? d.name
                            : (d.serialNumber.isNotEmpty ? d.serialNumber : d.uuid),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15, color: PlaudColors.textLight),
                      ),
                    ),
                    const Mono('Connect', size: 12),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _recordingsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Overline('Recordings'),
            InkWell(
              onTap: _handleRefreshFiles,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 6,
                  children: [
                    Icon(PlaudIcons.refresh, size: 14, color: PlaudColors.accentBlue),
                    Text(
                      'Refresh',
                      style: TextStyle(fontSize: 12, color: PlaudColors.accentBlue),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (_files.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: PlaudColors.surfaceCard,
              border: Border.all(color: PlaudColors.borderSubtle),
              borderRadius: BorderRadius.circular(PlaudRadius.sm),
            ),
            child: const Text(
              'No recordings yet. Record on the device, then refresh.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: PlaudColors.textDim),
            ),
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              for (final f in _files) _fileRow(f),
            ],
          ),
      ],
    );
  }

  Widget _fileRow(PlaudFile f) {
    final r = _results[f.sessionId];
    final busy = r?.status == FileResultStatus.exporting ||
        r?.status == FileResultStatus.transcribing;
    return DevRow(
      onTap: () => _handleFileClick(f),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        spacing: 12,
        children: [
          Flexible(
            child: Row(
              spacing: 12,
              children: [
                const Icon(PlaudIcons.fileAudio,
                    size: 18, color: PlaudColors.textLight),
                Flexible(child: Mono('#${f.sessionId}', maxLines: 1)),
                if (r?.status == FileResultStatus.ready)
                  const Row(
                    spacing: 4,
                    children: [
                      Icon(PlaudIcons.fileText, size: 12, color: PlaudColors.statusOk),
                      Text(
                        'transcribed',
                        style: TextStyle(fontSize: 11, color: PlaudColors.statusOk),
                      ),
                    ],
                  ),
                if (busy)
                  const Text(
                    'processing…',
                    style: TextStyle(fontSize: 11, color: PlaudColors.accentBlue),
                  ),
              ],
            ),
          ),
          Flexible(
            child: Mono(
              '${f.duration}s · ${(f.size / 1024).toStringAsFixed(0)} KB',
              size: 12,
              color: PlaudColors.textFaint,
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, bottomTabInset),
      decoration: const BoxDecoration(
        color: PlaudColors.surfaceFooter,
        border: Border(top: BorderSide(color: PlaudColors.borderSubtle)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Mono(
            '${PlaudConfig.userId}@${PlaudConfig.domain}',
            size: 12,
            color: PlaudColors.textFaint,
          ),
          Pill(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: _tokenReady ? PlaudColors.statusOk : PlaudColors.textFaint,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Mono(
                'token ${_tokenReady ? 'ready' : 'loading…'}',
                size: 12,
                color: PlaudColors.textMuted,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
