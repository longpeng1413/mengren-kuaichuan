import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Picture editing, modelled on 猛人截图 (猛人桌面助手 F1, `ui/image_canvas.py`)
/// and its port in 猛人学习 (`app/core/shotedit.py`): the original picture is
/// never changed; every stroke, shape and text is a mark replayed on top of
/// it, so undo/redo, mirror and crop are just changes to this data.
///
/// Marks use the coordinates of the whole (mirrored) picture in pixels; the
/// crop is applied last and can be changed at any time.
enum EditTool { pen, arrow, line, ellipse, rect, fill, text, eraser, mosaic }

const editColors = [
  Color(0xFFFF3B30), // 猛人截图 default red
  Color(0xFFFF9500),
  Color(0xFFFFCC00),
  Color(0xFF34C759),
  Color(0xFF007AFF),
  Color(0xFFAF52DE),
  Color(0xFF000000),
  Color(0xFFFFFFFF),
];

/// 猛人截图's menus: 粗细 细 2 / 默认 3 / 中 5 / 粗 8 / 特粗 12 (5 selected
/// by default) and 字号 16 / 24 / 36 / 52.
const editStrokeWidths = {'细': 2.0, '默认': 3.0, '中': 5.0, '粗': 8.0, '特粗': 12.0};
const editTextSizes = {'小号': 16.0, '中号': 24.0, '大号': 36.0, '特大': 52.0};
const defaultStrokeWidth = 5.0;
const defaultTextSize = 24.0;

/// Text line height = size × 1.3, as in 猛人学习 (TEXT_LH).
const textLineHeight = 1.3;

class EditMark {
  const EditMark({
    required this.tool,
    required this.color,
    required this.width,
    required this.points,
    this.text,
    this.textSize = defaultTextSize,
  });

  final EditTool tool;
  final Color color;

  /// Stroke width in picture pixels (already scaled from the screen).
  final double width;

  /// Freehand: every point. Shapes: start and end. Text: top-left.
  final List<Offset> points;
  final String? text;
  final double textSize;

  bool get isText => tool == EditTool.text;
  bool get isFreehand =>
      tool == EditTool.pen ||
      tool == EditTool.eraser ||
      tool == EditTool.mosaic;

  EditMark copyWith({List<Offset>? points, String? text}) => EditMark(
    tool: tool,
    color: color,
    width: width,
    points: points ?? this.points,
    text: text ?? this.text,
    textSize: textSize,
  );

  /// Eraser width as in 猛人截图: max(12, width × 4).
  double get eraserWidth => math.max(12, width * 4);

  /// Mosaic brush is a wide stroke.
  double get mosaicWidth => math.max(24, width * 6);
}

TextStyle editTextStyle(Color color, double size) => TextStyle(
  color: color,
  fontSize: size,
  fontWeight: FontWeight.bold,
  height: textLineHeight,
);

TextPainter layoutEditText(EditMark mark) => TextPainter(
  text: TextSpan(
    text: mark.text ?? '',
    style: editTextStyle(mark.color, mark.textSize),
  ),
  textDirection: TextDirection.ltr,
)..layout();

Rect editTextBounds(EditMark mark) {
  final painter = layoutEditText(mark);
  return mark.points.first & painter.size;
}

/// One snapshot of the edit; undo/redo keep a list of these.
class EditState {
  const EditState({this.marks = const [], this.mirrored = false, this.crop});

  final List<EditMark> marks;
  final bool mirrored;

  /// In picture pixels; null = whole picture.
  final Rect? crop;

  bool get isEmpty => marks.isEmpty && !mirrored && crop == null;

  EditState copyWith({
    List<EditMark>? marks,
    bool? mirrored,
    Rect? crop,
    bool clearCrop = false,
  }) => EditState(
    marks: marks ?? this.marks,
    mirrored: mirrored ?? this.mirrored,
    crop: clearCrop ? null : crop ?? this.crop,
  );
}

/// Undo/redo history (bounded like 猛人截图's).
class EditHistory {
  EditHistory([EditState initial = const EditState()]) : _current = initial;

  static const limit = 100;
  EditState _current;
  final List<EditState> _undo = [];
  final List<EditState> _redo = [];

  EditState get current => _current;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void push(EditState next) {
    _undo.add(_current);
    if (_undo.length > limit) _undo.removeAt(0);
    _redo.clear();
    _current = next;
  }

  bool undo() {
    if (_undo.isEmpty) return false;
    _redo.add(_current);
    _current = _undo.removeLast();
    return true;
  }

  bool redo() {
    if (_redo.isEmpty) return false;
    _undo.add(_current);
    _current = _redo.removeLast();
    return true;
  }
}

/// Mirrors the picture left to right. Marks move with it; text keeps its
/// reading direction and only swaps sides (猛人截图 mirror_horizontal).
EditState mirrorState(EditState state, double pictureWidth) {
  Offset flip(Offset p) => Offset(pictureWidth - p.dx, p.dy);
  final marks = [
    for (final mark in state.marks)
      if (mark.isText)
        mark.copyWith(
          points: [
            Offset(
              pictureWidth - mark.points.first.dx - editTextBounds(mark).width,
              mark.points.first.dy,
            ),
          ],
        )
      else
        mark.copyWith(points: [for (final p in mark.points) flip(p)]),
  ];
  final crop = state.crop;
  return state.copyWith(
    marks: marks,
    mirrored: !state.mirrored,
    crop: crop == null
        ? null
        : Rect.fromLTRB(
            pictureWidth - crop.right,
            crop.top,
            pictureWidth - crop.left,
            crop.bottom,
          ),
  );
}

/// Removes text marks the eraser touched (猛人截图 erases texts too).
List<EditMark> eraseTexts(List<EditMark> marks, EditMark eraser) {
  final reach = eraser.eraserWidth / 2;
  return [
    for (final mark in marks)
      if (!mark.isText ||
          !eraser.points.any(
            (p) => editTextBounds(mark).inflate(reach).contains(p),
          ))
        mark,
  ];
}

/// The text mark under [point], topmost first.
int? textMarkAt(List<EditMark> marks, Offset point, {double slack = 4}) {
  for (var i = marks.length - 1; i >= 0; i--) {
    final mark = marks[i];
    if (mark.isText && editTextBounds(mark).inflate(slack).contains(point)) {
      return i;
    }
  }
  return null;
}

/// A blocky copy of [picture] for the mosaic brush: each block takes the
/// colour of its centre pixel.
Future<ui.Image> pixelate(ui.Image picture) async {
  final width = picture.width;
  final height = picture.height;
  final data = await picture.toByteData(format: ui.ImageByteFormat.rawRgba);
  final block = math.max(8, (math.max(width, height) / 70).round());
  final source = data!.buffer.asUint8List();
  final output = Uint8List(source.length);
  for (var by = 0; by < height; by += block) {
    final cy = math.min(height - 1, by + block ~/ 2);
    for (var bx = 0; bx < width; bx += block) {
      final cx = math.min(width - 1, bx + block ~/ 2);
      final c = (cy * width + cx) * 4;
      for (var y = by; y < math.min(height, by + block); y++) {
        for (var x = bx; x < math.min(width, bx + block); x++) {
          final o = (y * width + x) * 4;
          output[o] = source[c];
          output[o + 1] = source[c + 1];
          output[o + 2] = source[c + 2];
          output[o + 3] = source[c + 3];
        }
      }
    }
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(output);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  return frame.image;
}

/// Draws the picture and all marks in picture coordinates.
/// Layers as in 猛人截图: picture (+ mosaic) → shapes layer (the eraser
/// clears only this layer) → texts on top.
void paintEdit(
  Canvas canvas, {
  required ui.Image picture,
  required EditState state,
  ui.Image? mosaicSource,
  EditMark? pending,
}) {
  final size = Size(picture.width.toDouble(), picture.height.toDouble());
  final whole = Offset.zero & size;
  void drawPicture(ui.Image image, [Paint? paint]) {
    canvas.save();
    if (state.mirrored) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    canvas.drawImage(image, Offset.zero, paint ?? Paint());
    canvas.restore();
  }

  drawPicture(picture);
  final marks = [...state.marks, ?pending];

  if (mosaicSource != null) {
    for (final mark in marks.where((m) => m.tool == EditTool.mosaic)) {
      canvas.saveLayer(whole, Paint());
      _strokePoints(
        canvas,
        mark.points,
        Paint()
          ..color = const Color(0xFFFFFFFF)
          ..strokeWidth = mark.mosaicWidth
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke,
      );
      drawPicture(mosaicSource, Paint()..blendMode = BlendMode.srcIn);
      canvas.restore();
    }
  }

  canvas.saveLayer(whole, Paint());
  for (final mark in marks) {
    if (mark.isText || mark.tool == EditTool.mosaic) continue;
    _paintShape(canvas, mark);
  }
  canvas.restore();

  for (final mark in marks.where((m) => m.isText)) {
    layoutEditText(mark).paint(canvas, mark.points.first);
  }
}

void _strokePoints(Canvas canvas, List<Offset> points, Paint paint) {
  if (points.isEmpty) return;
  if (points.length == 1) {
    canvas.drawPoints(ui.PointMode.points, points, paint);
    return;
  }
  final path = Path()..moveTo(points.first.dx, points.first.dy);
  for (final p in points.skip(1)) {
    path.lineTo(p.dx, p.dy);
  }
  canvas.drawPath(path, paint);
}

void _paintShape(Canvas canvas, EditMark mark) {
  final paint = Paint()
    ..color = mark.color
    ..strokeWidth = mark.width
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  switch (mark.tool) {
    case EditTool.pen:
      _strokePoints(canvas, mark.points, paint);
    case EditTool.eraser:
      _strokePoints(
        canvas,
        mark.points,
        paint
          ..blendMode = BlendMode.clear
          ..strokeWidth = mark.eraserWidth,
      );
    case EditTool.line:
      canvas.drawLine(mark.points.first, mark.points.last, paint);
    case EditTool.arrow:
      _paintArrow(canvas, mark.points.first, mark.points.last, paint);
    case EditTool.ellipse:
      canvas.drawOval(
        Rect.fromPoints(mark.points.first, mark.points.last),
        paint,
      );
    case EditTool.rect:
      canvas.drawRect(
        Rect.fromPoints(mark.points.first, mark.points.last),
        paint..strokeCap = StrokeCap.square,
      );
    case EditTool.fill:
      canvas.drawRect(
        Rect.fromPoints(mark.points.first, mark.points.last),
        Paint()..color = mark.color,
      );
    case EditTool.text:
    case EditTool.mosaic:
      break;
  }
}

/// 猛人截图 `_draw_arrow`: head length max(width × 4, 12), ±0.55 rad.
void _paintArrow(Canvas canvas, Offset start, Offset end, Paint paint) {
  final d = end - start;
  if (d.distanceSquared < 16) return;
  canvas.drawLine(start, end, paint);
  final angle = math.atan2(d.dy, d.dx);
  final head = math.max(paint.strokeWidth * 4, 12.0);
  for (final side in [-0.55, 0.55]) {
    canvas.drawLine(
      end,
      Offset(
        end.dx - head * math.cos(angle + side),
        end.dy - head * math.sin(angle + side),
      ),
      paint,
    );
  }
}

/// The finished picture as PNG: marks drawn in, mirror and crop applied.
Future<Uint8List> renderEditPng(
  ui.Image picture,
  EditState state, {
  ui.Image? mosaicSource,
}) async {
  final full =
      Offset.zero & Size(picture.width.toDouble(), picture.height.toDouble());
  final crop = (state.crop ?? full).intersect(full);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.translate(-crop.left, -crop.top);
  paintEdit(canvas, picture: picture, state: state, mosaicSource: mosaicSource);
  final image = await recorder.endRecording().toImage(
    math.max(1, crop.width.round()),
    math.max(1, crop.height.round()),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}
