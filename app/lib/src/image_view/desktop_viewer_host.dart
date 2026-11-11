import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import '../diagnostics/diagnostic_log_service.dart';
import 'viewer_protocol.dart';

typedef ViewerSendHandler = Future<void> Function(String peerId, String path);

/// Chat side of the separate picture window (Windows): starts it once and
/// reuses it, so clicking pictures never opens a second window — the open
/// one switches to the clicked picture and comes to the front.
class DesktopImageViewerHost {
  DesktopImageViewerHost._();

  static final DesktopImageViewerHost instance = DesktopImageViewerHost._();

  Process? _process;
  ViewerSendHandler? onSend;

  bool get isRunning => _process != null;

  /// Windows only; widget tests (FLUTTER_TEST) keep the in-app viewer
  /// instead of starting a second program.
  static bool get isAvailable =>
      Platform.isWindows && !Platform.environment.containsKey('FLUTTER_TEST');

  Future<void> show(ViewerShowCommand command) async {
    var process = _process;
    if (process == null) {
      process = await Process.start(Platform.resolvedExecutable, [
        imageViewerArgument,
      ]);
      _process = process;
      unawaited(
        DiagnosticLogService.instance.log(
          'image_viewer_started pid=${process.pid}',
        ),
      );
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onLine, onError: (_) {});
      process.stderr.drain<void>().ignore();
      unawaited(
        process.exitCode.then((_) {
          if (identical(_process, process)) _process = null;
        }),
      );
    }
    _allowForeground(process.pid);
    try {
      process.stdin.writeln(command.encode());
      await process.stdin.flush();
    } catch (error) {
      // The window was closed a moment ago; start a new one.
      if (identical(_process, process)) _process = null;
      await DiagnosticLogService.instance.log(
        'image_viewer_pipe_failed',
        error: error,
      );
      if (_process == null) await show(command);
    }
  }

  void _onLine(String line) {
    final command = decodeViewerLine(line);
    if (command is ViewerSendCommand) {
      final handler = onSend;
      if (handler != null) unawaited(handler(command.peerId, command.path));
    }
  }

  /// Windows only lets the foreground program hand focus to another one:
  /// the chat window (just clicked) allows the viewer to come to the front.
  static void _allowForeground(int pid) {
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final allow = user32
          .lookupFunction<Int32 Function(Uint32), int Function(int)>(
            'AllowSetForegroundWindow',
          );
      allow(pid);
    } catch (_) {}
  }
}
