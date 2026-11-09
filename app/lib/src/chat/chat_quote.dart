import 'package:path/path.dart' as path;

import '../voice/voice_store.dart';
import 'chat_message.dart';

/// A quote travels inside the text itself, in the format WeChat uses when a
/// quoted message is copied. The LAN/relay protocols stay unchanged and an
/// older client simply shows readable plain text.
///
/// ```
/// 「华为手机：原来的内容」
/// - - - - - - - - - - - - - - -
/// 回复内容
/// ```
const quoteSeparator = '- - - - - - - - - - - - - - -';
const _maximumSnippetLength = 60;

final RegExp _quotePattern = RegExp(
  '^「([^：\\n]{1,60})：([\\s\\S]*?)」\\n${RegExp.escape(quoteSeparator)}\\n([\\s\\S]+)\$',
);

class ChatQuote {
  const ChatQuote({required this.senderName, required this.snippet});

  final String senderName;
  final String snippet;
}

class QuotedText {
  const QuotedText({required this.reply, this.quote});

  final String reply;
  final ChatQuote? quote;
}

bool isImageFileName(String value) {
  const extensions = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'};
  return extensions.contains(path.extension(value).toLowerCase());
}

/// One line describing [message] for a quote: the reply text of a text
/// message (without its own quote), or "[图片] name"/"[文件] name". The
/// name lets a tap on the quote find the exact picture again.
String quoteSnippetFor(ChatMessage message) {
  final String raw;
  if (message.kind == ChatMessageKind.text) {
    raw = parseQuotedText(message.text ?? '').reply;
  } else {
    final name = message.fileName ?? '文件';
    final voiceSeconds = voiceSecondsFromName(name);
    raw = voiceSeconds != null
        ? '[语音] $voiceSeconds″'
        : isImageFileName(name)
        ? '[图片] $name'
        : '[文件] $name';
  }
  final collapsed = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.length <= _maximumSnippetLength) return collapsed;
  return '${collapsed.substring(0, _maximumSnippetLength)}…';
}

ChatQuote quoteFor(ChatMessage message) => ChatQuote(
  // "：" and line breaks would break parsing on the other side.
  senderName: _safeName(message.senderName),
  snippet: quoteSnippetFor(message).replaceAll('」', '’'),
);

String composeQuotedText(ChatQuote quote, String reply) =>
    '「${quote.senderName}：${quote.snippet}」\n$quoteSeparator\n$reply';

QuotedText parseQuotedText(String text) {
  final match = _quotePattern.firstMatch(text);
  if (match == null) return QuotedText(reply: text);
  return QuotedText(
    reply: match.group(3)!,
    quote: ChatQuote(senderName: match.group(1)!, snippet: match.group(2)!),
  );
}

String _safeName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[：\n\r]'), ' ').trim();
  if (cleaned.isEmpty) return '对方';
  return cleaned.length <= 40 ? cleaned : cleaned.substring(0, 40);
}

/// The message a quote in `messages[replyIndex]` refers to: the nearest
/// earlier message with the same sender and snippet. Quotes carry no message
/// id (the protocol is unchanged), so a renamed sender falls back to the
/// nearest message with the same snippet. Returns null when it is gone.
int? findQuotedMessage(
  List<ChatMessage> messages,
  int replyIndex,
  ChatQuote quote,
) {
  int? sameSnippet;
  for (var index = replyIndex - 1; index >= 0; index--) {
    final candidate = quoteFor(messages[index]);
    final matches =
        candidate.snippet == quote.snippet ||
        // Test builds quoted pictures as a bare "[图片]".
        (quote.snippet == '[图片]' && candidate.snippet.startsWith('[图片] '));
    if (!matches) continue;
    if (candidate.senderName == quote.senderName) return index;
    sameSnippet ??= index;
  }
  return sameSnippet;
}
