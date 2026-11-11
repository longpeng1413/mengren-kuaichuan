import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transfer/src/chat/chat_message.dart';
import 'package:lan_transfer/src/chat/image_viewer.dart';
import 'package:lan_transfer/src/image_edit/edit_model.dart';
import 'package:lan_transfer/src/image_edit/image_editor_page.dart';
import 'package:lan_transfer/src/image_view/desktop_viewer_app.dart';
import 'package:lan_transfer/src/image_view/viewer_protocol.dart';
import 'package:path/path.dart' as p;

/// A plain white picture.
Future<ui.Image> whitePicture(int width, int height) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = Colors.white,
  );
  return recorder.endRecording().toImage(width, height);
}

Future<Uint8List> pngOf(ui.Image image) async =>
    (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();

Future<({int width, int height, Uint8List rgba})> decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final result = (
    width: image.width,
    height: image.height,
    rgba: data!.buffer.asUint8List(),
  );
  image.dispose();
  return result;
}

bool isRed(Uint8List rgba, int width, int x, int y) {
  final i = (y * width + x) * 4;
  return rgba[i] > 200 && rgba[i + 1] < 120 && rgba[i + 2] < 120;
}

bool anyRed(({int width, int height, Uint8List rgba}) image) {
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      if (isRed(image.rgba, image.width, x, y)) return true;
    }
  }
  return false;
}

void main() {
  group('编辑模型', () {
    test('撤销 / 恢复，新操作清空恢复', () {
      final history = EditHistory();
      const a = EditState(mirrored: true);
      const b = EditState(crop: Rect.fromLTWH(0, 0, 10, 10));
      history.push(a);
      history.push(b);
      expect(history.undo(), isTrue);
      expect(history.current, same(a));
      expect(history.redo(), isTrue);
      expect(history.current, same(b));
      history.undo();
      history.push(const EditState());
      expect(history.canRedo, isFalse);
      expect(history.undo(), isTrue);
      expect(history.undo(), isTrue);
      expect(history.canUndo, isFalse);
      expect(history.current.isEmpty, isTrue);
    });

    test('镜像让标注和裁剪框一起左右翻转', () {
      const state = EditState(
        marks: [
          EditMark(
            tool: EditTool.line,
            color: Colors.red,
            width: 3,
            points: [Offset(10, 5), Offset(30, 5)],
          ),
        ],
        crop: Rect.fromLTRB(0, 0, 40, 20),
      );
      final mirrored = mirrorState(state, 100);
      expect(mirrored.mirrored, isTrue);
      expect(mirrored.marks.single.points, [
        const Offset(90, 5),
        const Offset(70, 5),
      ]);
      expect(mirrored.crop, const Rect.fromLTRB(60, 0, 100, 20));
      final back = mirrorState(mirrored, 100);
      expect(back.mirrored, isFalse);
      expect(back.marks.single.points, state.marks.single.points);
    });

    test('文字可以点中，橡皮擦到文字会删掉它', () {
      const text = EditMark(
        tool: EditTool.text,
        color: Colors.red,
        width: 3,
        points: [Offset(20, 20)],
        text: '你好',
        textSize: 24,
      );
      expect(textMarkAt(const [text], const Offset(25, 30)), 0);
      expect(textMarkAt(const [text], const Offset(300, 300)), isNull);
      const eraser = EditMark(
        tool: EditTool.eraser,
        color: Colors.red,
        width: 3,
        points: [Offset(25, 30)],
      );
      expect(eraseTexts(const [text, eraser], eraser), [eraser]);
    });

    test('导出的图片带标注，裁剪后尺寸变小，原图不变', () async {
      final picture = await whitePicture(100, 50);
      const line = EditMark(
        tool: EditTool.line,
        color: Color(0xFFFF3B30),
        width: 6,
        points: [Offset(10, 10), Offset(90, 10)],
      );
      final drawn = await decode(
        await renderEditPng(picture, const EditState(marks: [line])),
      );
      expect((drawn.width, drawn.height), (100, 50));
      expect(isRed(drawn.rgba, 100, 50, 10), isTrue);
      expect(isRed(drawn.rgba, 100, 50, 40), isFalse);

      final cropped = await decode(
        await renderEditPng(
          picture,
          const EditState(marks: [line], crop: Rect.fromLTRB(20, 0, 60, 30)),
        ),
      );
      expect((cropped.width, cropped.height), (40, 30));
      expect(isRed(cropped.rgba, 40, 10, 10), isTrue);

      // The source picture itself is never painted on.
      expect(anyRed(await decode(await pngOf(picture))), isFalse);
      picture.dispose();
    });

    test('马赛克把一块区域变成同一种颜色', () async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      for (var x = 0; x < 64; x++) {
        canvas.drawRect(
          Rect.fromLTWH(x.toDouble(), 0, 1, 64),
          Paint()..color = x.isEven ? Colors.black : Colors.white,
        );
      }
      final picture = await recorder.endRecording().toImage(64, 64);
      final blocky = await pixelate(picture);
      final data = (await blocky.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
      // Neighbouring stripes inside one block now have the same colour.
      expect(data[0], data[4]);
      picture.dispose();
      blocky.dispose();
    });
  });

  group('看图窗口通信', () {
    test('显示和发送命令能原样编码、解码，其他输出被忽略', () {
      final show = ViewerShowCommand(
        images: [
          ViewerImage(
            id: 'a',
            path: r'C:\图片\a.png',
            name: 'a.png',
            sentAt: DateTime.fromMillisecondsSinceEpoch(1000),
          ),
          ViewerImage(
            id: 'b',
            path: r'C:\图片\b.jpg',
            name: 'b.jpg',
            sentAt: DateTime.fromMillisecondsSinceEpoch(2000),
          ),
        ],
        index: 5,
        peerId: 'phone',
        peerName: '手机',
        edit: true,
      );
      final decoded = decodeViewerLine(show.encode()) as ViewerShowCommand;
      expect(decoded.images.map((i) => i.path), [
        r'C:\图片\a.png',
        r'C:\图片\b.jpg',
      ]);
      expect(decoded.index, 1, reason: '超出范围的序号收回到最后一张');
      expect(decoded.peerName, '手机');
      expect(decoded.edit, isTrue);

      final send = decodeViewerLine(
        const ViewerSendCommand(peerId: 'phone', path: 'x.png').encode(),
      ) as ViewerSendCommand;
      expect((send.peerId, send.path), ('phone', 'x.png'));

      expect(decodeViewerLine('flutter: some log'), isNull);
      expect(decodeViewerLine('MRKC:{bad json'), isNull);
      expect(isImageViewerLaunch(['--image-viewer']), isTrue);
      expect(isImageViewerLaunch(['--silent']), isFalse);
    });
  });

  group('编辑器界面', () {
    late Uint8List source;

    setUpAll(() async {
      final picture = await whitePicture(200, 120);
      source = await pngOf(picture);
      picture.dispose();
    });

    Future<void> realWait(WidgetTester tester, [int ms = 300]) async {
      await tester.runAsync(
        () => Future<void>.delayed(Duration(milliseconds: ms)),
      );
      await tester.pump();
    }

    Future<List<Uint8List>> openEditor(WidgetTester tester) async {
      final sent = <Uint8List>[];
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<bool>(
                      builder: (_) => ImageEditorPage(
                        loadPicture: () async => source,
                        onSend: (png) async {
                          sent.add(png);
                          return null;
                        },
                      ),
                    ),
                  ),
                  child: const Text('打开编辑'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开编辑'));
      // A spinner runs while the picture decodes: pump fixed steps.
      await tester.pump(const Duration(milliseconds: 400));
      await realWait(tester);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('edit_canvas')), findsOneWidget);
      return sent;
    }

    Future<void> send(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('edit_send')));
      await tester.pump();
      await realWait(tester, 500);
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('画一笔后发送，得到原尺寸带红色标注的新图并关闭编辑器', (tester) async {
      final sent = await openEditor(tester);
      await tester.drag(
        find.byKey(const Key('edit_canvas')),
        const Offset(120, 30),
      );
      await tester.pump();
      await send(tester);
      expect(sent, hasLength(1));
      expect(find.byType(ImageEditorPage), findsNothing);
      final image = (await tester.runAsync(() => decode(sent.single)))!;
      expect((image.width, image.height), (200, 120));
      expect(anyRed(image), isTrue);
    });

    testWidgets('撤销后发送的图片没有标注', (tester) async {
      final sent = await openEditor(tester);
      await tester.drag(
        find.byKey(const Key('edit_canvas')),
        const Offset(120, 30),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('undo')));
      await tester.pump();
      await send(tester);
      final image = (await tester.runAsync(() => decode(sent.single)))!;
      expect(anyRed(image), isFalse);
    });
  });

  group('看图', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('mengren_edit_');
    });
    tearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    String file(String name) {
      final path = p.join(directory.path, name);
      File(path).writeAsBytesSync([0]);
      return path;
    }

    testWidgets('电脑看图窗口：再次点图片时切到那一张，不开新窗口', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final commands = StreamController<ViewerShowCommand>();
      addTearDown(commands.close);
      final images = [
        for (final name in ['a.png', 'b.png', 'c.png'])
          ViewerImage(
            id: name,
            path: file(name),
            name: name,
            sentAt: DateTime(2026, 11, 11),
          ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopViewerPage(
            commands: commands.stream,
            sendToChat: (_) {},
            manageWindow: false,
          ),
        ),
      );
      ViewerShowCommand show(int index) => ViewerShowCommand(
        images: images,
        index: index,
        peerId: 'phone',
        peerName: '手机',
      );
      commands.add(show(0));
      await tester.pump();
      await tester.pump();
      String status() =>
          tester.widget<Text>(find.byKey(const Key('viewer_status'))).data!;
      expect(status(), startsWith('1 / 3'));

      commands.add(show(2));
      await tester.pump();
      await tester.pump();
      expect(status(), startsWith('3 / 3'));
      expect(find.byType(DesktopViewerPage), findsOneWidget);

      await tester.tap(find.byKey(const Key('viewer_grid')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('grid_b.png')));
      await tester.pump();
      expect(status(), startsWith('2 / 3'));
    });

    testWidgets('手机看图：单击图片关闭，顶部有编辑按钮', (tester) async {
      final message = ChatMessage(
        id: 'a',
        peerId: 'pc',
        peerName: '电脑',
        senderId: 'pc',
        senderName: '电脑',
        kind: ChatMessageKind.file,
        sentAt: DateTime.now(),
        isOutgoing: false,
        fileName: 'a.png',
        filePath: file('a.png'),
      );
      ChatMessage? edited;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ChatImageViewer(
                    images: [message],
                    initialIndex: 0,
                    closeOnTap: true,
                    onEdit: (item) async => edited = item,
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatImageViewer), findsOneWidget);

      await tester.tap(find.byKey(const Key('viewer_edit')));
      await tester.pump();
      expect(edited?.id, 'a');

      await tester.tapAt(tester.getCenter(find.byType(ChatImageViewer)));
      // Single tap waits out the double-tap window, then closes.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byType(ChatImageViewer), findsNothing);
    });
  });
}
