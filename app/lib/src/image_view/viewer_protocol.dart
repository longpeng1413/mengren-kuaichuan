import 'dart:convert';

/// Windows only: pictures open in a separate "图片查看" window, like WeChat
/// for PC. It is the same program started again with [imageViewerArgument];
/// the chat process talks to it over stdin/stdout, one JSON command per
/// line prefixed with [viewerLinePrefix] (anything else on the pipes is
/// ignored). When the chat process exits the pipe closes and the viewer
/// closes with it.
const imageViewerArgument = '--image-viewer';
const viewerLinePrefix = 'MRKC:';

bool isImageViewerLaunch(List<String> arguments) =>
    arguments.contains(imageViewerArgument);

class ViewerImage {
  const ViewerImage({
    required this.id,
    required this.path,
    required this.name,
    required this.sentAt,
  });

  final String id;
  final String path;
  final String name;
  final DateTime sentAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'path': path,
    'name': name,
    'sentAt': sentAt.millisecondsSinceEpoch,
  };

  static ViewerImage? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final path = value['path'];
    final name = value['name'];
    final sentAt = value['sentAt'];
    if (id is! String || path is! String || name is! String || sentAt is! int) {
      return null;
    }
    return ViewerImage(
      id: id,
      path: path,
      name: name,
      sentAt: DateTime.fromMillisecondsSinceEpoch(sentAt),
    );
  }
}

/// Chat → viewer: show [images] at [index] (and open the editor when
/// [edit]). The conversation's peer is where 发送 sends edited pictures.
class ViewerShowCommand {
  const ViewerShowCommand({
    required this.images,
    required this.index,
    required this.peerId,
    required this.peerName,
    this.edit = false,
  });

  final List<ViewerImage> images;
  final int index;
  final String peerId;
  final String peerName;
  final bool edit;

  String encode() =>
      viewerLinePrefix +
      jsonEncode({
        'cmd': 'show',
        'images': [for (final image in images) image.toJson()],
        'index': index,
        'peerId': peerId,
        'peerName': peerName,
        'edit': edit,
      });
}

/// Viewer → chat: send an edited picture (a file in the outgoing cache).
class ViewerSendCommand {
  const ViewerSendCommand({required this.peerId, required this.path});

  final String peerId;
  final String path;

  String encode() =>
      viewerLinePrefix +
      jsonEncode({'cmd': 'send', 'peerId': peerId, 'path': path});
}

/// Parses one line from the pipe; null for anything that is not ours.
Object? decodeViewerLine(String line) {
  final trimmed = line.trim();
  if (!trimmed.startsWith(viewerLinePrefix)) return null;
  try {
    final value = jsonDecode(trimmed.substring(viewerLinePrefix.length));
    if (value is! Map) return null;
    switch (value['cmd']) {
      case 'show':
        final images = [
          for (final raw in (value['images'] as List? ?? const []))
            ?ViewerImage.fromJson(raw),
        ];
        final index = value['index'];
        final peerId = value['peerId'];
        final peerName = value['peerName'];
        if (images.isEmpty ||
            index is! int ||
            peerId is! String ||
            peerName is! String) {
          return null;
        }
        return ViewerShowCommand(
          images: images,
          index: index.clamp(0, images.length - 1),
          peerId: peerId,
          peerName: peerName,
          edit: value['edit'] == true,
        );
      case 'send':
        final peerId = value['peerId'];
        final path = value['path'];
        if (peerId is! String || path is! String) return null;
        return ViewerSendCommand(peerId: peerId, path: path);
    }
  } on FormatException {
    return null;
  }
  return null;
}
