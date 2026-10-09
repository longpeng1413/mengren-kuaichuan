import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transfer/src/chat/chat_text_message.dart';

void main() {
  const link = 'https://example.com/download/app.apk?version=25';
  String? clipboard;
  final opened = <Uri>[];

  void messageTest(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        // Restore before testWidgets verifies Flutter's debug invariants.
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  setUp(() {
    clipboard = null;
    opened.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> showMessage(
    WidgetTester tester,
    TargetPlatform platform, [
    String text = link,
  ]) async {
    debugDefaultTargetPlatformOverride = platform;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 600,
              child: ChatTextMessage(
                text: text,
                onOpenLink: (uri) async => opened.add(uri),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  EditableTextState state(WidgetTester tester) =>
      tester.state<EditableTextState>(find.byType(EditableText));

  Offset position(WidgetTester tester, int offset) {
    final render = state(tester).renderEditable;
    return render.localToGlobal(
      render.getLocalRectForCaret(TextPosition(offset: offset)).center,
    );
  }

  Future<void> rightClick(WidgetTester tester, Offset at) async {
    await tester.tapAt(
      at,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
  }

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    messageTest('$platform single tap still opens HTTP link', (tester) async {
      await showMessage(tester, platform);
      await tester.tapAt(
        position(tester, 15),
        kind: platform == TargetPlatform.windows
            ? PointerDeviceKind.mouse
            : PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();
      expect(opened, [Uri.parse(link)]);
    });
  }

  messageTest('Windows right click copies whole link without selection', (
    tester,
  ) async {
    await showMessage(tester, TargetPlatform.windows);
    await rightClick(tester, position(tester, 15));
    expect(find.text('复制全部'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);
    expect(opened, isEmpty);
    await tester.tap(find.text('复制全部'));
    await tester.pumpAndSettle();
    expect(clipboard, link);
    expect(opened, isEmpty);
  });

  messageTest('Windows drag and right click copy only selected URL range', (
    tester,
  ) async {
    await showMessage(tester, TargetPlatform.windows);
    final gesture = await tester.startGesture(
      position(tester, 8),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(position(tester, 19));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    final selection = state(tester).textEditingValue.selection;
    expect(selection.isCollapsed, isFalse);
    final selected = selection.textInside(link);
    expect(selected.length, lessThan(link.length));
    expect(opened, isEmpty);
    await rightClick(tester, position(tester, 12));
    await tester.tap(find.text('复制选中内容'));
    await tester.pumpAndSettle();
    expect(clipboard, selected);
    expect(opened, isEmpty);
  });

  messageTest('Android long press offers full copy and never opens URL', (
    tester,
  ) async {
    await showMessage(tester, TargetPlatform.android);
    await tester.longPressAt(position(tester, 15));
    await tester.pumpAndSettle();
    expect(state(tester).textEditingValue.selection.isCollapsed, isFalse);
    expect(find.text('复制选中内容'), findsOneWidget);
    await tester.tap(find.text('复制全部'));
    await tester.pumpAndSettle();
    expect(clipboard, link);
    expect(opened, isEmpty);
  });

  messageTest('Android adjusted selection copies exact partial URL', (
    tester,
  ) async {
    await showMessage(tester, TargetPlatform.android);
    await tester.longPressAt(position(tester, 15));
    await tester.pumpAndSettle();
    // Same selection update path used by the draggable selection handles.
    state(tester).userUpdateTextEditingValue(
      state(tester).textEditingValue.copyWith(
        selection: const TextSelection(baseOffset: 8, extentOffset: 19),
      ),
      SelectionChangedCause.drag,
    );
    await tester.pumpAndSettle();
    state(tester).showToolbar();
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制选中内容'));
    await tester.pumpAndSettle();
    expect(clipboard, 'example.com');
    expect(opened, isEmpty);
  });

  messageTest('ordinary multiline text can select all and copy unchanged', (
    tester,
  ) async {
    const text = '你好\n第二行文字';
    await showMessage(tester, TargetPlatform.windows, text);
    await rightClick(tester, position(tester, 1));
    expect(find.text('打开链接'), findsNothing);
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(state(tester).textEditingValue.selection.textInside(text), text);
    await rightClick(tester, position(tester, 1));
    await tester.tap(find.text('复制选中内容'));
    await tester.pumpAndSettle();
    expect(clipboard, text);
    expect(opened, isEmpty);
  });

  messageTest('non HTTP schemes remain text and do not launch', (tester) async {
    await showMessage(tester, TargetPlatform.windows, 'file:///C:/test.txt');
    await tester.tap(find.byType(SelectableText));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
  });
}
