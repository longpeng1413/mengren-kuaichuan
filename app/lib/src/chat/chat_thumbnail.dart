import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Thumbnails for images Android saved through 系统下载: those messages only
/// have a content URI, which Image.file cannot read. Kept in memory only
/// (at most [_maximumEntries]), so nothing is written to disk.
class ContentUriThumbnails {
  ContentUriThumbnails._();

  static final ContentUriThumbnails instance = ContentUriThumbnails._();
  static const _channel = MethodChannel(
    'com.personal.lantransfer.lan_transfer/files',
  );
  static const _maximumEntries = 60;
  static const thumbnailPixels = 480;

  final LinkedHashMap<String, Uint8List?> _cache = LinkedHashMap();
  final Map<String, Future<Uint8List?>> _pending = {};

  Uint8List? cached(String uri) => _cache[uri];

  bool isCached(String uri) => _cache.containsKey(uri);

  Future<Uint8List?> load(String uri) {
    if (_cache.containsKey(uri)) {
      final value = _cache.remove(uri);
      _cache[uri] = value; // most recently used last
      return Future.value(value);
    }
    return _pending.putIfAbsent(uri, () async {
      Uint8List? bytes;
      try {
        bytes = await _channel.invokeMethod<Uint8List>('loadThumbnail', {
          'uri': uri,
          'size': thumbnailPixels,
        });
      } on PlatformException {
        bytes = null;
      } on MissingPluginException {
        bytes = null;
      }
      _cache[uri] = bytes;
      while (_cache.length > _maximumEntries) {
        _cache.remove(_cache.keys.first);
      }
      _pending.remove(uri);
      return bytes;
    });
  }

  void clear() => _cache.clear();
}

/// A WeChat-style picture message: only the picture, scaled down to a small
/// thumbnail. [fallback] is shown when the file cannot be read any more.
class ChatImageThumbnail extends StatefulWidget {
  const ChatImageThumbnail({
    required this.fallback,
    this.filePath,
    this.contentUri,
    this.maxWidth = 180,
    this.maxHeight = 200,
    this.footer,
    this.alignEnd = false,
    super.key,
  });

  final String? filePath;
  final String? contentUri;
  final double maxWidth;
  final double maxHeight;
  final Widget fallback;

  /// Shown under the picture (the message time); not shown with [fallback].
  final Widget? footer;
  final bool alignEnd;

  @override
  State<ChatImageThumbnail> createState() => _ChatImageThumbnailState();
}

class _ChatImageThumbnailState extends State<ChatImageThumbnail> {
  ImageProvider? _provider;
  bool _failed = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant ChatImageThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath ||
        oldWidget.contentUri != widget.contentUri) {
      _provider = null;
      _failed = false;
      _resolve();
    }
  }

  void _resolve() {
    final filePath = widget.filePath;
    if (filePath != null && File(filePath).existsSync()) {
      _provider = ResizeImage(
        FileImage(File(filePath)),
        width: ContentUriThumbnails.thumbnailPixels,
        height: ContentUriThumbnails.thumbnailPixels,
        policy: ResizeImagePolicy.fit,
      );
      return;
    }
    final uri = widget.contentUri;
    if (uri == null || !Platform.isAndroid) {
      _failed = true;
      return;
    }
    final thumbnails = ContentUriThumbnails.instance;
    if (thumbnails.isCached(uri)) {
      final bytes = thumbnails.cached(uri);
      if (bytes == null) {
        _failed = true;
      } else {
        _provider = MemoryImage(bytes);
      }
      return;
    }
    _loading = true;
    unawaited(
      thumbnails.load(uri).then((bytes) {
        if (!mounted || widget.contentUri != uri) return;
        setState(() {
          _loading = false;
          if (bytes == null) {
            _failed = true;
          } else {
            _provider = MemoryImage(bytes);
          }
        });
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.fallback;
    final colors = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: 120,
      height: 120,
      color: colors.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(Icons.image_outlined, color: colors.onSurfaceVariant),
    );
    final provider = _provider;
    final picture = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: 60,
          minHeight: 60,
          maxWidth: widget.maxWidth,
          maxHeight: widget.maxHeight,
        ),
        child: provider == null || _loading
            ? placeholder
            : Image(
                image: provider,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
                frameBuilder: (context, child, frame, synchronous) =>
                    frame == null && !synchronous ? placeholder : child,
                errorBuilder: (_, _, _) {
                  // Unreadable picture: show the normal file card instead,
                  // outside the thumbnail's size limit.
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && !_failed) setState(() => _failed = true);
                  });
                  return placeholder;
                },
              ),
      ),
    );
    final footer = widget.footer;
    if (footer == null) return picture;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: widget.alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [picture, const SizedBox(height: 3), footer],
    );
  }
}
