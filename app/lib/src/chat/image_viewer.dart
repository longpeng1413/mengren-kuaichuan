import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat_message.dart';
import 'chat_thumbnail.dart';

typedef ImageViewerAction = Future<void> Function(ChatMessage message);

/// Whether the picture of [message] can be shown in the viewer.
bool canViewPicture(ChatMessage message) {
  final filePath = message.filePath;
  if (filePath != null && File(filePath).existsSync()) return true;
  return Platform.isAndroid && message.contentUri != null;
}

/// The picture's bytes for the editor: the local file, or (Android, saved
/// to a chosen folder) a large preview of the content URI.
Future<Uint8List> loadPictureBytes(ChatMessage message) async {
  final filePath = message.filePath;
  if (filePath != null && File(filePath).existsSync()) {
    return File(filePath).readAsBytes();
  }
  final uri = message.contentUri;
  if (uri != null && Platform.isAndroid) {
    final bytes = await ContentUriThumbnails.instance.loadLarge(uri);
    if (bytes != null) return bytes;
  }
  throw const FileSystemException('图片已被移动或删除');
}

/// WeChat-style picture viewer inside the app: one at a time (it is a full
/// screen page, so a second tap cannot open another), zoom with the mouse
/// wheel / pinch / double tap, and browse the conversation's other pictures
/// with ← → or a swipe. Replaces handing every tap to the system viewer,
/// which opened a new window each time.
class ChatImageViewer extends StatefulWidget {
  const ChatImageViewer({
    required this.images,
    required this.initialIndex,
    this.onOpenExternal,
    this.onReveal,
    this.onEdit,
    bool? closeOnTap,
    super.key,
  }) : closeOnTap = closeOnTap ?? false;

  final List<ChatMessage> images;
  final int initialIndex;

  /// 用其他应用打开 (the system photo app).
  final ImageViewerAction? onOpenExternal;

  /// 在文件夹中显示 (Windows).
  final ImageViewerAction? onReveal;

  /// 编辑 (opens the picture editor).
  final ImageViewerAction? onEdit;

  /// Phone WeChat style: tap the picture once to open it, tap again to
  /// close (double tap still zooms).
  final bool closeOnTap;

  @override
  State<ChatImageViewer> createState() => _ChatImageViewerState();
}

class _ChatImageViewerState extends State<ChatImageViewer> {
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;
  bool _zoomed = false;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final target = _index + delta;
    if (target < 0 || target >= widget.images.length) return;
    unawaited(
      _pages.animateToPage(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.images[_index];
    final many = widget.images.length > 1;
    const white = Colors.white;
    return Scaffold(
      key: const Key('image_viewer'),
      backgroundColor: Colors.black,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).maybePop(),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
        },
        child: Focus(
          autofocus: true,
          child: Stack(
            children: [
              PageView.builder(
                controller: _pages,
                // While zoomed, dragging pans the picture instead of paging.
                physics: _zoomed
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                itemCount: widget.images.length,
                onPageChanged: (index) => setState(() {
                  _index = index;
                  _zoomed = false;
                }),
                itemBuilder: (context, index) => _ZoomablePicture(
                  key: ValueKey('viewer_${widget.images[index].id}'),
                  message: widget.images[index],
                  onTap: widget.closeOnTap
                      ? () => Navigator.of(context).maybePop()
                      : null,
                  onZoomChanged: (zoomed) {
                    if (index == _index && zoomed != _zoomed) {
                      setState(() => _zoomed = zoomed);
                    }
                  },
                ),
              ),
              SafeArea(
                child: Container(
                  height: 52,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x99000000), Color(0x00000000)],
                    ),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: '关闭（Esc）',
                        color: white,
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                      Expanded(
                        child: Text(
                          many ? '${_index + 1} / ${widget.images.length}' : '',
                          key: const Key('viewer_counter'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: white),
                        ),
                      ),
                      if (widget.onEdit != null)
                        IconButton(
                          key: const Key('viewer_edit'),
                          tooltip: '编辑',
                          color: white,
                          onPressed: () => unawaited(widget.onEdit!(current)),
                          icon: const Icon(Icons.edit_outlined),
                        ),
                      if (widget.onReveal != null && current.filePath != null)
                        IconButton(
                          tooltip: '在文件夹中显示',
                          color: white,
                          onPressed: () => unawaited(widget.onReveal!(current)),
                          icon: const Icon(Icons.folder_open_outlined),
                        ),
                      if (widget.onOpenExternal != null)
                        IconButton(
                          tooltip: '用其他应用打开',
                          color: white,
                          onPressed: () =>
                              unawaited(widget.onOpenExternal!(current)),
                          icon: const Icon(Icons.open_in_new_rounded),
                        ),
                    ],
                  ),
                ),
              ),
              if (many && !Platform.isAndroid) ...[
                if (_index > 0)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      tooltip: '上一张（←）',
                      color: white,
                      iconSize: 36,
                      onPressed: () => _go(-1),
                      icon: const Icon(Icons.chevron_left_rounded),
                    ),
                  ),
                if (_index < widget.images.length - 1)
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      tooltip: '下一张（→）',
                      color: white,
                      iconSize: 36,
                      onPressed: () => _go(1),
                      icon: const Icon(Icons.chevron_right_rounded),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ZoomablePicture extends StatefulWidget {
  const _ZoomablePicture({
    required this.message,
    required this.onZoomChanged,
    this.onTap,
    super.key,
  });

  final ChatMessage message;
  final ValueChanged<bool> onZoomChanged;
  final VoidCallback? onTap;

  @override
  State<_ZoomablePicture> createState() => _ZoomablePictureState();
}

class _ZoomablePictureState extends State<_ZoomablePicture> {
  final TransformationController _transform = TransformationController();
  ImageProvider? _provider;
  bool _failed = false;
  bool _zoomed = false;
  Offset? _doubleTapAt;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_transformChanged);
    _resolve();
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _transformChanged() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed == _zoomed) return;
    _zoomed = zoomed;
    widget.onZoomChanged(zoomed);
  }

  void _resolve() {
    final filePath = widget.message.filePath;
    if (filePath != null && File(filePath).existsSync()) {
      // Bounded decode: a 50 MP photo would otherwise take ~200 MB.
      _provider = ResizeImage(
        FileImage(File(filePath)),
        width: 4096,
        height: 4096,
        policy: ResizeImagePolicy.fit,
      );
      return;
    }
    final uri = widget.message.contentUri;
    if (uri == null || !Platform.isAndroid) {
      _failed = true;
      return;
    }
    unawaited(
      ContentUriThumbnails.instance.loadLarge(uri).then((Uint8List? bytes) {
        if (!mounted) return;
        setState(() {
          if (bytes == null) {
            _failed = true;
          } else {
            _provider = MemoryImage(bytes);
          }
        });
      }),
    );
  }

  void _toggleZoom() {
    if (_zoomed) {
      _transform.value = Matrix4.identity();
      return;
    }
    final at = _doubleTapAt ?? Offset.zero;
    const scale = 2.5;
    _transform.value = Matrix4.identity()
      ..translateByDouble(-at.dx * (scale - 1), -at.dy * (scale - 1), 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    const hint = TextStyle(color: Colors.white70);
    if (_failed) {
      return const Center(child: Text('图片已被移动或删除', style: hint));
    }
    final provider = _provider;
    if (provider == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTapDown: (details) => _doubleTapAt = details.localPosition,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 1,
        maxScale: 6,
        child: SizedBox.expand(
          child: Image(
            image: provider,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            loadingBuilder: (context, child, progress) => progress == null
                ? child
                : const Center(child: CircularProgressIndicator()),
            errorBuilder: (_, _, _) =>
                const Center(child: Text('图片无法显示', style: hint)),
          ),
        ),
      ),
    );
  }
}
