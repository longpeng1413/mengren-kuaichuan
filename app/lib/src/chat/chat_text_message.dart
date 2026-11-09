import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Uses the same selection gestures for links and ordinary chat text.
/// A drag/long press selects; only a completed single tap opens a link.
class ChatTextMessage extends StatelessWidget {
  const ChatTextMessage({
    required this.text,
    this.onOpenLink,
    this.extraActions = const [],
    super.key,
  });

  final String text;
  final Future<void> Function(Uri uri)? onOpenLink;

  /// Message actions (转发、引用、删除) appended to the long-press / right-click
  /// menu, WeChat style. The menu closes before each runs.
  final List<ChatMessageAction> extraActions;

  Uri? get _link {
    final uri = Uri.tryParse(text.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return null;
    }
    return uri;
  }

  Future<void> _openLink(BuildContext context, Uri uri) async {
    try {
      if (onOpenLink != null) {
        await onOpenLink!(uri);
      } else if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw Exception('未找到可打开链接的应用');
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开链接，可以复制后在浏览器中打开')));
      }
    }
  }

  Future<void> _copyAll(BuildContext context, EditableTextState state) async {
    state.hideToolbar();
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('复制失败，请重试')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final uri = _link;
    return SelectableText(
      text,
      onTap: uri == null ? null : () => unawaited(_openLink(context, uri)),
      style: uri == null
          ? null
          : TextStyle(
              color: Theme.of(context).colorScheme.primary,
              decoration: TextDecoration.underline,
            ),
      contextMenuBuilder: (context, state) {
        final selection = state.textEditingValue.selection;
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: state.contextMenuAnchors,
          buttonItems: [
            if (selection.isValid && !selection.isCollapsed)
              ContextMenuButtonItem(
                label: '复制选中内容',
                onPressed: () =>
                    state.copySelection(SelectionChangedCause.toolbar),
              ),
            ContextMenuButtonItem(
              label: '复制',
              onPressed: () => unawaited(_copyAll(context, state)),
            ),
            for (final action in extraActions)
              ContextMenuButtonItem(
                label: action.label,
                onPressed: () {
                  state.hideToolbar();
                  action.onSelected();
                },
              ),
            ContextMenuButtonItem(
              label: '全选',
              onPressed: () => state.selectAll(SelectionChangedCause.toolbar),
            ),
            if (uri != null)
              ContextMenuButtonItem(
                label: '打开链接',
                onPressed: () {
                  state.hideToolbar();
                  unawaited(_openLink(context, uri));
                },
              ),
          ],
        );
      },
    );
  }
}

class ChatMessageAction {
  const ChatMessageAction(this.label, this.onSelected, {this.icon});

  final String label;
  final VoidCallback onSelected;
  final IconData? icon;
}
