import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../chat/clipboard_files.dart';
import '../image_edit/image_editor_page.dart';
import '../storage/received_file_service.dart';
import '../ui/app_theme.dart';
import 'viewer_protocol.dart';

/// Entry point of the picture window process (Windows, see
/// [imageViewerArgument]). Commands arrive on stdin; when the chat process
/// goes away (pipe closed) this window closes too.
Future<void> runImageViewerProcess() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.setTitleBarStyle(
    TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );
  await windowManager.setMinimumSize(const Size(480, 360));
  final commands = StreamController<ViewerShowCommand>.broadcast();
  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) {
          final command = decodeViewerLine(line);
          if (command is ViewerShowCommand) commands.add(command);
        },
        onDone: () => exit(0),
        onError: (_) => exit(0),
      );
  runApp(
    DesktopViewerApp(
      commands: commands.stream,
      sendToChat: (command) => stdout.writeln(command.encode()),
    ),
  );
}

class DesktopViewerApp extends StatelessWidget {
  const DesktopViewerApp({
    required this.commands,
    required this.sendToChat,
    super.key,
  });

  final Stream<ViewerShowCommand> commands;
  final void Function(ViewerSendCommand command) sendToChat;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '图片查看',
      theme: buildAppTheme(const Color(0xFFB3261E), Brightness.dark),
      home: DesktopViewerPage(commands: commands, sendToChat: sendToChat),
    );
  }
}

class DesktopViewerPage extends StatefulWidget {
  const DesktopViewerPage({
    required this.commands,
    required this.sendToChat,
    this.manageWindow = true,
    super.key,
  });

  final Stream<ViewerShowCommand> commands;
  final void Function(ViewerSendCommand command) sendToChat;

  /// False in widget tests (no native window).
  final bool manageWindow;

  @override
  State<DesktopViewerPage> createState() => _DesktopViewerPageState();
}

class _DesktopViewerPageState extends State<DesktopViewerPage> {
  StreamSubscription<ViewerShowCommand>? _subscription;
  ViewerShowCommand? _command;
  int _index = 0;
  int _turns = 0;
  bool _pinned = false;
  bool _maximized = false;
  bool _fullScreen = false;
  bool _grid = false;
  bool _editing = false;
  Size? _pixels;
  Size _viewport = Size.zero;
  final TransformationController _transform = TransformationController();
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _transform.addListener(() => setState(() {}));
    _subscription = widget.commands.listen(_show);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _transform.dispose();
    _focus.dispose();
    super.dispose();
  }

  ViewerImage? get _current {
    final command = _command;
    if (command == null || command.images.isEmpty) return null;
    return command.images[_index.clamp(0, command.images.length - 1)];
  }

  Future<void> _show(ViewerShowCommand command) async {
    setState(() {
      _command = command;
      _grid = false;
    });
    _goTo(command.index);
    if (widget.manageWindow) {
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
    }
    if (command.edit) {
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_edit()));
    }
  }

  void _goTo(int index) {
    final command = _command;
    if (command == null) return;
    final target = index.clamp(0, command.images.length - 1);
    setState(() {
      _index = target;
      _turns = 0;
      _pixels = null;
      _transform.value = Matrix4.identity();
    });
    final image = command.images[target];
    if (widget.manageWindow) {
      unawaited(windowManager.setTitle('图片查看 - ${image.name}'));
    }
    unawaited(_measure(image.path, target));
  }

  /// Pixel size without decoding the whole picture (for 1:1 and the %).
  Future<void> _measure(String path, int index) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromFilePath(path);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final size = Size(
        descriptor.width.toDouble(),
        descriptor.height.toDouble(),
      );
      descriptor.dispose();
      buffer.dispose();
      if (mounted && index == _index) setState(() => _pixels = size);
    } catch (_) {}
  }

  /// Scale of the fitted picture relative to its real pixels (≤ 1).
  double get _fitScale {
    final pixels = _pixels;
    if (pixels == null || _viewport.isEmpty) return 1;
    final rotated = _turns.isOdd ? pixels.flipped : pixels;
    return math.min(
      1,
      math.min(
        _viewport.width / rotated.width,
        _viewport.height / rotated.height,
      ),
    );
  }

  double get _zoom => _transform.value.getMaxScaleOnAxis();

  int get _percent => (_fitScale * _zoom * 100).round();

  void _zoomBy(double factor) {
    final center = _viewport.center(Offset.zero);
    final target = (_zoom * factor).clamp(0.2, 12.0) / _zoom;
    _transform.value = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(target, target, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1)
      ..multiply(_transform.value);
  }

  /// 1:1 (real pixels) ↔ fit window.
  void _toggleActualSize() {
    final actual = 1 / _fitScale;
    if ((_zoom - 1).abs() > 0.01 || actual <= 1.001) {
      _transform.value = Matrix4.identity();
      return;
    }
    final center = _viewport.center(Offset.zero);
    _transform.value = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(actual, actual, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
  }

  void _rotate() => setState(() {
    _turns = (_turns + 1) % 4;
    _transform.value = Matrix4.identity();
  });

  Future<void> _togglePin() async {
    final pinned = !_pinned;
    if (widget.manageWindow) await windowManager.setAlwaysOnTop(pinned);
    setState(() => _pinned = pinned);
  }

  Future<void> _toggleMaximize() async {
    if (!widget.manageWindow) return;
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
    final maximized = await windowManager.isMaximized();
    if (mounted) setState(() => _maximized = maximized);
  }

  Future<void> _toggleFullScreen() async {
    final full = !_fullScreen;
    if (widget.manageWindow) await windowManager.setFullScreen(full);
    setState(() => _fullScreen = full);
  }

  Future<void> _closeWindow() async {
    if (_fullScreen) {
      await _toggleFullScreen();
      return;
    }
    if (widget.manageWindow) await windowManager.close();
  }

  void _notice(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _copy() async {
    final image = _current;
    if (image == null) return;
    try {
      await PlatformClipboardFiles.instance.copyFiles([image.path]);
      _notice('图片已复制，可以粘贴到微信、QQ、画图或文件夹里');
    } catch (error) {
      _notice('复制失败：$error');
    }
  }

  Future<String?> _pickSavePath(String suggestedName) =>
      FilePicker.platform.saveFile(
        dialogTitle: '另存为',
        fileName: suggestedName,
        lockParentWindow: true,
      );

  Future<void> _saveAs() async {
    final image = _current;
    if (image == null) return;
    final target = await _pickSavePath(image.name);
    if (target == null) return;
    try {
      await File(image.path).copy(target);
      _notice('已保存到 $target');
    } catch (error) {
      _notice('保存失败：$error');
    }
  }

  Future<void> _reveal() async {
    final image = _current;
    if (image == null) return;
    try {
      await Process.start('explorer.exe', ['/select,', image.path]);
    } catch (error) {
      _notice('无法打开文件夹：$error');
    }
  }

  Future<void> _openExternal() async {
    final image = _current;
    if (image == null) return;
    try {
      await ReceivedFileService().openFile(filePath: image.path);
    } catch (error) {
      _notice('无法打开：$error');
    }
  }

  Future<void> _edit() async {
    final image = _current;
    final command = _command;
    if (image == null || command == null || _editing) return;
    final stem = p.basenameWithoutExtension(image.name);
    Future<File> writeEdited(List<int> png) async {
      final file = await OutgoingCache.instance.createFile('${stem}_编辑.png');
      await file.writeAsBytes(png, flush: true);
      return file;
    }

    setState(() => _editing = true);
    try {
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => _EditorFrame(
            title: '编辑图片 - ${image.name}',
            manageWindow: widget.manageWindow,
            child: ImageEditorPage(
              loadPicture: () => File(image.path).readAsBytes(),
              sendLabel: '发送给 ${command.peerName}',
              onSend: (png) async {
                final file = await writeEdited(png);
                widget.sendToChat(
                  ViewerSendCommand(peerId: command.peerId, path: file.path),
                );
                return '已交给猛人快传发送给 ${command.peerName}';
              },
              onCopy: (png) async {
                final file = await writeEdited(png);
                await PlatformClipboardFiles.instance.copyFiles([file.path]);
                return '编辑后的图片已复制';
              },
              onSave: (png) async {
                final target = await _pickSavePath('${stem}_编辑.png');
                if (target == null) return null;
                await File(target).writeAsBytes(png, flush: true);
                return '已保存到 $target';
              },
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _editing = false);
      _focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final command = _command;
    final image = _current;
    final many = (command?.images.length ?? 0) > 1;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            unawaited(_grid ? _closeGrid() : _closeWindow()),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _goTo(_index - 1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _goTo(_index + 1),
        const SingleActivator(LogicalKeyboardKey.f11): () =>
            unawaited(_toggleFullScreen()),
        const SingleActivator(LogicalKeyboardKey.keyC, control: true): () =>
            unawaited(_copy()),
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
            unawaited(_saveAs()),
        const SingleActivator(LogicalKeyboardKey.keyE, control: true): () =>
            unawaited(_edit()),
        const SingleActivator(LogicalKeyboardKey.equal, control: true): () =>
            _zoomBy(1.25),
        const SingleActivator(LogicalKeyboardKey.minus, control: true): () =>
            _zoomBy(0.8),
        const SingleActivator(LogicalKeyboardKey.digit0, control: true): () =>
            _transform.value = Matrix4.identity(),
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Scaffold(
          key: const Key('desktop_viewer'),
          backgroundColor: const Color(0xFF1F1F1F),
          body: Column(
            children: [
              if (!_fullScreen) _titleBar(image, many),
              Expanded(
                child: image == null
                    ? const Center(child: CircularProgressIndicator())
                    : _grid
                    ? _gridView(command!)
                    : _picture(image),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _closeGrid() async => setState(() => _grid = false);

  Widget _titleBar(ViewerImage? image, bool many) {
    final command = _command;
    Widget tool(
      IconData icon,
      String tip,
      VoidCallback? onTap, {
      bool on = false,
      Key? key,
    }) => IconButton(
      key: key,
      tooltip: tip,
      onPressed: image == null ? null : onTap,
      iconSize: 19,
      visualDensity: VisualDensity.compact,
      color: on ? const Color(0xFF4CA3FF) : Colors.white70,
      icon: Icon(icon),
    );
    const gap = SizedBox(
      height: 20,
      child: VerticalDivider(width: 12, color: Colors.white12),
    );
    return Container(
      height: 44,
      color: const Color(0xFF2B2B2B),
      child: Row(
        children: [
          const SizedBox(width: 4),
          tool(
            _pinned ? Icons.push_pin : Icons.push_pin_outlined,
            _pinned ? '取消置顶' : '置顶',
            () => unawaited(_togglePin()),
            on: _pinned,
          ),
          gap,
          tool(
            Icons.arrow_back_rounded,
            '上一张（←）',
            many && _index > 0 ? () => _goTo(_index - 1) : null,
          ),
          tool(
            Icons.arrow_forward_rounded,
            '下一张（→）',
            many && _index < (command?.images.length ?? 1) - 1
                ? () => _goTo(_index + 1)
                : null,
          ),
          tool(
            Icons.grid_view_rounded,
            '全部图片',
            many ? () => setState(() => _grid = !_grid) : null,
            on: _grid,
            key: const Key('viewer_grid'),
          ),
          gap,
          tool(Icons.zoom_in_rounded, '放大（Ctrl+=）', () => _zoomBy(1.25)),
          tool(Icons.zoom_out_rounded, '缩小（Ctrl+-）', () => _zoomBy(0.8)),
          tool(Icons.fit_screen_rounded, '原始大小 / 适应窗口', _toggleActualSize),
          tool(Icons.rotate_right_rounded, '旋转', _rotate),
          gap,
          tool(
            Icons.edit_outlined,
            '编辑（Ctrl+E）',
            () => unawaited(_edit()),
            key: const Key('viewer_edit'),
          ),
          tool(Icons.copy_rounded, '复制（Ctrl+C）', () => unawaited(_copy())),
          tool(
            Icons.save_alt_rounded,
            '另存为（Ctrl+S）',
            () => unawaited(_saveAs()),
          ),
          tool(
            Icons.folder_open_outlined,
            '在文件夹中显示',
            () => unawaited(_reveal()),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(
              Icons.more_horiz_rounded,
              color: Colors.white70,
              size: 19,
            ),
            onSelected: (value) {
              switch (value) {
                case 'open':
                  unawaited(_openExternal());
                case 'full':
                  unawaited(_toggleFullScreen());
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'open', child: Text('用其他应用打开')),
              PopupMenuItem(value: 'full', child: Text('全屏（F11）')),
            ],
          ),
          Expanded(
            child: DragToMoveArea(
              child: Container(
                height: 44,
                alignment: Alignment.center,
                color: Colors.transparent,
                child: Text(
                  [
                    if (many) '${_index + 1} / ${command!.images.length}',
                    if (image != null && !_grid) '$_percent%',
                  ].join('  ·  '),
                  key: const Key('viewer_status'),
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '最小化',
            color: Colors.white70,
            onPressed: widget.manageWindow
                ? () => unawaited(windowManager.minimize())
                : null,
            icon: const Icon(Icons.minimize_rounded, size: 18),
          ),
          IconButton(
            tooltip: _maximized ? '还原' : '最大化',
            color: Colors.white70,
            onPressed: () => unawaited(_toggleMaximize()),
            icon: Icon(
              _maximized
                  ? Icons.filter_none_rounded
                  : Icons.crop_square_rounded,
              size: 16,
            ),
          ),
          IconButton(
            tooltip: '关闭（Esc）',
            color: Colors.white70,
            hoverColor: const Color(0xFFE81123),
            onPressed: () => unawaited(_closeWindow()),
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _picture(ViewerImage image) {
    return LayoutBuilder(
      builder: (context, box) {
        _viewport = box.biggest;
        return GestureDetector(
          onDoubleTap: _toggleActualSize,
          child: InteractiveViewer(
            key: ValueKey('picture_${image.id}'),
            transformationController: _transform,
            minScale: 0.2,
            maxScale: 12,
            boundaryMargin: const EdgeInsets.all(double.infinity),
            child: SizedBox.expand(
              child: RotatedBox(
                quarterTurns: _turns,
                child: Image(
                  image: ResizeImage(
                    FileImage(File(image.path)),
                    width: 8192,
                    height: 8192,
                    policy: ResizeImagePolicy.fit,
                  ),
                  fit: BoxFit.scaleDown,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, _, _) => const Center(
                    child: Text(
                      '图片已被移动或删除',
                      style: TextStyle(color: Colors.white60),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _gridView(ViewerShowCommand command) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: command.images.length,
      itemBuilder: (context, index) {
        final item = command.images[index];
        return InkWell(
          key: ValueKey('grid_${item.id}'),
          onTap: () {
            setState(() => _grid = false);
            _goTo(index);
          },
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: index == _index
                    ? const Color(0xFF4CA3FF)
                    : Colors.white10,
                width: index == _index ? 2 : 1,
              ),
            ),
            child: Image(
              image: ResizeImage(
                FileImage(File(item.path)),
                width: 320,
                height: 320,
                policy: ResizeImagePolicy.fit,
              ),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const Icon(
                Icons.broken_image_outlined,
                color: Colors.white38,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The editor inside the 图片查看 window: the window has no system title
/// bar, so keep a strip to drag it (double click maximizes).
class _EditorFrame extends StatelessWidget {
  const _EditorFrame({
    required this.title,
    required this.manageWindow,
    required this.child,
  });

  final String title;
  final bool manageWindow;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final strip = Container(
      height: 30,
      color: const Color(0xFF2B2B2B),
      alignment: Alignment.center,
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white60, fontSize: 12),
      ),
    );
    return Material(
      color: const Color(0xFF1F1F1F),
      child: Column(
        children: [
          manageWindow ? DragToMoveArea(child: strip) : strip,
          Expanded(child: child),
        ],
      ),
    );
  }
}
