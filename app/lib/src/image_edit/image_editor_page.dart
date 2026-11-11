import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'edit_model.dart';

typedef EditorOutput = Future<String?> Function(Uint8List png);

/// The picture editor (tools and defaults of 猛人截图 F1, plus a mosaic
/// brush): 镜像 裁剪 绘图(画笔/箭头/直线/圆形/方框/实心框) 文字 字号 粗细
/// 橡皮 马赛克 颜色 撤销 恢复 清除, then 复制 / 保存 / 发送. The original file
/// is never changed; outputs get a new PNG.
///
/// Each output callback returns a short note for the user (or null) and
/// throws to report a failure. 发送 closes the editor when it succeeds.
class ImageEditorPage extends StatefulWidget {
  const ImageEditorPage({
    required this.loadPicture,
    this.onSend,
    this.sendLabel = '发送',
    this.onCopy,
    this.onSave,
    super.key,
  });

  final Future<Uint8List> Function() loadPicture;
  final EditorOutput? onSend;
  final String sendLabel;
  final EditorOutput? onCopy;
  final EditorOutput? onSave;

  @override
  State<ImageEditorPage> createState() => _ImageEditorPageState();
}

enum _Mode { draw, crop }

class _ImageEditorPageState extends State<ImageEditorPage> {
  ui.Image? _picture;
  ui.Image? _mosaic;
  String? _loadError;
  final EditHistory _history = EditHistory();

  _Mode _mode = _Mode.draw;
  EditTool _tool = EditTool.pen;
  Color _color = editColors.first;
  double _strokeWidth = defaultStrokeWidth;
  double _textSize = defaultTextSize;

  EditMark? _pending;
  double _scale = 1;
  Rect _visible = Rect.zero;

  // Text being typed (picture coordinates) and the mark it replaces.
  Offset? _textAt;
  int? _textReplaces;
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocus = FocusNode();
  final FocusNode _keys = FocusNode();

  // Moving an existing text with the text tool.
  int? _dragText;
  Offset _dragTextDelta = Offset.zero;

  // Crop draft in picture coordinates while in crop mode.
  Rect? _cropDraft;
  String _cropGrip = '';

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _textFocus.addListener(() {
      if (!_textFocus.hasFocus && _textAt != null) _commitText();
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _textController.dispose();
    _textFocus.dispose();
    _keys.dispose();
    _picture?.dispose();
    _mosaic?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.loadPicture();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) return;
      setState(() => _picture = frame.image);
    } catch (error) {
      if (mounted) setState(() => _loadError = '图片无法打开：$error');
    }
  }

  EditState get _state => _history.current;

  Size get _pictureSize =>
      Size(_picture!.width.toDouble(), _picture!.height.toDouble());

  Rect get _full => Offset.zero & _pictureSize;

  Offset _toPicture(Offset local) => local / _scale + _visible.topLeft;

  void _push(EditState next) => setState(() => _history.push(next));

  // ---- 工具 ----

  void _selectTool(EditTool tool) {
    _commitText();
    setState(() {
      _mode = _Mode.draw;
      _tool = tool;
    });
    if (tool == EditTool.mosaic) unawaited(_prepareMosaic());
  }

  Future<void> _prepareMosaic() async {
    final picture = _picture;
    if (picture == null || _mosaic != null) return;
    final pixelated = await pixelate(picture);
    if (mounted) setState(() => _mosaic = pixelated);
  }

  void _mirror() {
    _commitText();
    if (_picture == null) return;
    _push(mirrorState(_state, _pictureSize.width));
  }

  void _startCrop() {
    _commitText();
    setState(() {
      _mode = _Mode.crop;
      _cropDraft = _state.crop ?? _full.deflate(_full.shortestSide * 0.08);
    });
  }

  void _applyCrop() {
    final draft = _cropDraft;
    setState(() => _mode = _Mode.draw);
    if (draft == null) return;
    final crop = Rect.fromLTRB(
      draft.left.roundToDouble(),
      draft.top.roundToDouble(),
      draft.right.roundToDouble(),
      draft.bottom.roundToDouble(),
    ).intersect(_full);
    if (crop.width < 8 || crop.height < 8) return;
    _push(
      _state.copyWith(
        crop: crop == _full ? null : crop,
        clearCrop: crop == _full,
      ),
    );
  }

  void _cancelCrop() => setState(() => _mode = _Mode.draw);

  void _undo() {
    _commitText();
    setState(_history.undo);
  }

  void _redo() {
    _commitText();
    setState(_history.redo);
  }

  void _clear() {
    _commitText();
    if (_state.marks.isEmpty) return;
    _push(_state.copyWith(marks: const []));
  }

  // ---- 绘制手势 ----

  void _panStart(DragStartDetails details) {
    if (_picture == null || _mode != _Mode.draw) return;
    final point = _toPicture(details.localPosition);
    if (_tool == EditTool.text) {
      final hit = textMarkAt(_state.marks, point);
      if (hit != null) {
        _commitText();
        _dragText = hit;
        _dragTextDelta = Offset.zero;
      }
      return;
    }
    _commitText();
    setState(() {
      _pending = EditMark(
        tool: _tool,
        color: _color,
        width: _strokeWidth / _scale,
        points: [point],
      );
    });
  }

  void _panUpdate(DragUpdateDetails details) {
    if (_dragText != null) {
      setState(() => _dragTextDelta += details.delta / _scale);
      return;
    }
    final pending = _pending;
    if (pending == null) return;
    final point = _toPicture(details.localPosition);
    setState(() {
      _pending = pending.isFreehand
          ? pending.copyWith(points: [...pending.points, point])
          : pending.copyWith(points: [pending.points.first, point]);
    });
  }

  void _panEnd([DragEndDetails? _]) {
    final dragged = _dragText;
    if (dragged != null) {
      _dragText = null;
      if (_dragTextDelta != Offset.zero) {
        final marks = [..._state.marks];
        final mark = marks[dragged];
        marks[dragged] = mark.copyWith(
          points: [mark.points.first + _dragTextDelta],
        );
        _push(_state.copyWith(marks: marks));
      }
      return;
    }
    final pending = _pending;
    setState(() => _pending = null);
    if (pending == null) return;
    if (!pending.isFreehand &&
        (pending.points.length < 2 ||
            (pending.points.last - pending.points.first).distance * _scale <
                3)) {
      return;
    }
    var marks = [..._state.marks, pending];
    if (pending.tool == EditTool.eraser) marks = eraseTexts(marks, pending);
    _push(_state.copyWith(marks: marks));
  }

  void _tapUp(TapUpDetails details) {
    if (_picture == null || _mode != _Mode.draw) return;
    if (_tool != EditTool.text) return;
    final point = _toPicture(details.localPosition);
    _commitText();
    final hit = textMarkAt(_state.marks, point);
    setState(() {
      if (hit != null) {
        final mark = _state.marks[hit];
        _textReplaces = hit;
        _textAt = mark.points.first;
        _textController.text = mark.text ?? '';
      } else {
        _textReplaces = null;
        _textAt = point;
        _textController.clear();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _textFocus.requestFocus();
    });
  }

  void _commitText() {
    final at = _textAt;
    if (at == null) return;
    final text = _textController.text.trimRight();
    final replaces = _textReplaces;
    _textAt = null;
    _textReplaces = null;
    _textController.clear();
    final marks = [..._state.marks];
    EditMark? previous;
    if (replaces != null && replaces < marks.length) {
      previous = marks.removeAt(replaces);
    }
    if (text.isEmpty) {
      if (previous != null) {
        _push(_state.copyWith(marks: marks));
      } else {
        setState(() {});
      }
      return;
    }
    marks.add(
      EditMark(
        tool: EditTool.text,
        color: previous?.color ?? _color,
        width: 0,
        points: [at],
        text: text,
        textSize: previous?.textSize ?? _textSize / _scale,
      ),
    );
    _push(_state.copyWith(marks: marks));
  }

  void _cancelText() => setState(() {
    _textAt = null;
    _textReplaces = null;
    _textController.clear();
  });

  // ---- 裁剪手势 ----

  void _cropPanStart(DragStartDetails details) {
    final draft = _cropDraft;
    if (draft == null) return;
    final p = _toPicture(details.localPosition);
    final reach = 18 / _scale;
    final left = (p.dx - draft.left).abs() < reach;
    final right = (p.dx - draft.right).abs() < reach;
    final top = (p.dy - draft.top).abs() < reach;
    final bottom = (p.dy - draft.bottom).abs() < reach;
    final inside = draft.inflate(reach).contains(p);
    _cropGrip = !inside
        ? 'new'
        : '${top ? 't' : ''}${bottom ? 'b' : ''}${left ? 'l' : ''}${right ? 'r' : ''}';
    if (_cropGrip.isEmpty) _cropGrip = 'move';
    if (_cropGrip == 'new') {
      setState(() => _cropDraft = Rect.fromPoints(p, p));
    }
  }

  void _cropPanUpdate(DragUpdateDetails details) {
    final draft = _cropDraft;
    if (draft == null) return;
    final d = details.delta / _scale;
    final p = _toPicture(details.localPosition);
    Rect next;
    switch (_cropGrip) {
      case 'new':
        next = Rect.fromPoints(draft.topLeft, p);
      case 'move':
        next = draft.shift(d);
        next = next.shift(
          Offset(
            next.left < 0
                ? -next.left
                : next.right > _full.right
                ? _full.right - next.right
                : 0,
            next.top < 0
                ? -next.top
                : next.bottom > _full.bottom
                ? _full.bottom - next.bottom
                : 0,
          ),
        );
      default:
        next = Rect.fromLTRB(
          _cropGrip.contains('l') ? draft.left + d.dx : draft.left,
          _cropGrip.contains('t') ? draft.top + d.dy : draft.top,
          _cropGrip.contains('r') ? draft.right + d.dx : draft.right,
          _cropGrip.contains('b') ? draft.bottom + d.dy : draft.bottom,
        );
    }
    setState(() => _cropDraft = next.intersect(_full));
  }

  void _cropPanEnd([DragEndDetails? _]) {
    final draft = _cropDraft;
    if (draft == null) return;
    setState(
      () => _cropDraft = Rect.fromLTRB(
        math.min(draft.left, draft.right),
        math.min(draft.top, draft.bottom),
        math.max(draft.left, draft.right),
        math.max(draft.top, draft.bottom),
      ),
    );
  }

  // ---- 输出 ----

  Future<void> _output(EditorOutput action, {bool closeAfter = false}) async {
    final picture = _picture;
    if (picture == null || _busy) return;
    _commitText();
    if (_mode == _Mode.crop) _applyCrop();
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      if (_state.marks.any((m) => m.tool == EditTool.mosaic)) {
        await _prepareMosaic();
      }
      final png = await renderEditPng(picture, _state, mosaicSource: _mosaic);
      final note = await action(png);
      if (note != null) {
        messenger.showSnackBar(SnackBar(content: Text(note)));
      }
      if (closeAfter && mounted) navigator.pop(true);
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    _commitText();
    if (_history.canUndo) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('放弃这次编辑？'),
          content: const Text('还没有发送、复制或保存，关掉后画的内容不会保留。原图不受影响。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('放弃'),
            ),
          ],
        ),
      );
      if (leave != true) return;
    }
    if (mounted) Navigator.of(context).pop(false);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final key = event.logicalKey;
    if (ctrl && key == LogicalKeyboardKey.keyZ) {
      shift ? _redo() : _undo();
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyY) {
      _redo();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_mode == _Mode.crop) {
        _cancelCrop();
      } else {
        unawaited(_close());
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---- 界面 ----

  @override
  Widget build(BuildContext context) {
    final picture = _picture;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: Focus(
        focusNode: _keys,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          key: const Key('image_editor'),
          backgroundColor: const Color(0xFF1E1E1E),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: picture == null
                      ? Center(
                          child: _loadError == null
                              ? const CircularProgressIndicator()
                              : Text(
                                  _loadError!,
                                  style: const TextStyle(color: Colors.white70),
                                ),
                        )
                      : LayoutBuilder(
                          builder: (context, box) => _canvas(picture, box),
                        ),
                ),
                _toolbar(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _canvas(ui.Image picture, BoxConstraints box) {
    _visible = _mode == _Mode.crop ? _full : (_state.crop ?? _full);
    final available = Size(box.maxWidth - 24, box.maxHeight - 24);
    _scale = math.min(
      2,
      math.min(
        available.width / _visible.width,
        available.height / _visible.height,
      ),
    );
    final display = _visible.size * _scale;
    final textAt = _textAt;
    return Center(
      child: SizedBox(
        width: display.width,
        height: display.height,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: const Key('edit_canvas'),
                onTapUp: _mode == _Mode.draw ? _tapUp : null,
                onPanStart: _mode == _Mode.crop ? _cropPanStart : _panStart,
                onPanUpdate: _mode == _Mode.crop ? _cropPanUpdate : _panUpdate,
                onPanEnd: _mode == _Mode.crop ? _cropPanEnd : _panEnd,
                child: MouseRegion(
                  cursor: _tool == EditTool.text
                      ? SystemMouseCursors.text
                      : SystemMouseCursors.precise,
                  child: CustomPaint(
                    painter: _EditPainter(
                      picture: picture,
                      state: _dragText == null
                          ? _state
                          : _state.copyWith(
                              marks: [
                                for (var i = 0; i < _state.marks.length; i++)
                                  i == _dragText
                                      ? _state.marks[i].copyWith(
                                          points: [
                                            _state.marks[i].points.first +
                                                _dragTextDelta,
                                          ],
                                        )
                                      : _state.marks[i],
                              ],
                            ),
                      // Hide the text being edited; the field shows it.
                      hidden: _textReplaces,
                      pending: _pending,
                      mosaic: _mosaic,
                      scale: _scale,
                      visible: _visible,
                      cropDraft: _mode == _Mode.crop ? _cropDraft : null,
                      repaintKey: Object.hash(
                        _history.current,
                        _pending,
                        _pending?.points.length,
                        _dragTextDelta,
                        _cropDraft,
                        _mosaic,
                        _textReplaces,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (textAt != null)
              Positioned(
                left: (textAt.dx - _visible.left) * _scale,
                top: (textAt.dy - _visible.top) * _scale,
                child: _textField(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _textField() {
    final replaced = _textReplaces == null
        ? null
        : _state.marks[_textReplaces!];
    final color = replaced?.color ?? _color;
    final size = replaced == null ? _textSize : replaced.textSize * _scale;
    return IntrinsicWidth(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 60, maxWidth: 480),
        child: Focus(
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            if (event.logicalKey == LogicalKeyboardKey.escape) {
              _cancelText();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.enter &&
                !HardwareKeyboard.instance.isShiftPressed) {
              _commitText();
              _keys.requestFocus();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: TextField(
            key: const Key('edit_text_field'),
            controller: _textController,
            focusNode: _textFocus,
            maxLines: null,
            style: editTextStyle(color, size),
            cursorColor: color,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.zero,
              hintText: '输入文字，Enter 完成',
              hintStyle: TextStyle(
                color: color.withValues(alpha: 0.5),
                fontSize: math.min(size, 16),
              ),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: color.withValues(alpha: 0.6)),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: color),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static const _shapeNames = {
    EditTool.pen: '画笔',
    EditTool.arrow: '箭头',
    EditTool.line: '直线',
    EditTool.ellipse: '圆形',
    EditTool.rect: '方框',
    EditTool.fill: '实心框',
  };

  Widget _toolbar() {
    final enabled = _picture != null && !_busy;
    final drawingSelected =
        _mode == _Mode.draw && _shapeNames.containsKey(_tool);
    Widget button(
      String label, {
      VoidCallback? onTap,
      bool selected = false,
      Key? key,
      String? tooltip,
      Color? dot,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Tooltip(
          message: tooltip ?? label,
          child: Material(
            color: selected ? const Color(0xFF0A84FF) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            child: InkWell(
              key: key,
              borderRadius: BorderRadius.circular(6),
              onTap: enabled ? onTap : null,
              child: Container(
                constraints: const BoxConstraints(minWidth: 48),
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (dot != null) ...[
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: dot,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white54),
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      label,
                      style: TextStyle(
                        color: enabled ? Colors.white : Colors.white38,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget menu<T>(
      String label,
      Map<String, T> options,
      void Function(T value) onPick, {
      bool selected = false,
      Key? key,
    }) {
      return PopupMenuButton<T>(
        key: key,
        enabled: enabled,
        tooltip: label,
        position: PopupMenuPosition.over,
        onSelected: onPick,
        itemBuilder: (_) => [
          for (final entry in options.entries)
            PopupMenuItem<T>(value: entry.value, child: Text(entry.key)),
        ],
        child: IgnorePointer(
          child: button('$label ▾', selected: selected, onTap: () {}),
        ),
      );
    }

    const divider = SizedBox(
      height: 22,
      child: VerticalDivider(color: Colors.white24, width: 12),
    );

    final cropping = _mode == _Mode.crop;
    return Container(
      color: const Color(0xFF2B2B2B),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            button('镜像', onTap: _mirror, tooltip: '左右镜像'),
            if (cropping) ...[
              button(
                '完成',
                key: const Key('crop_apply'),
                onTap: _applyCrop,
                selected: true,
                tooltip: '按这个范围裁剪',
              ),
              button('取消裁剪', onTap: _cancelCrop),
            ] else
              button(
                '裁剪',
                key: const Key('crop_tool'),
                onTap: _startCrop,
                tooltip: '拖动边框选择保留的范围',
              ),
            menu<EditTool>(
              drawingSelected ? _shapeNames[_tool]! : '绘图',
              {for (final e in _shapeNames.entries) e.value: e.key},
              _selectTool,
              selected: drawingSelected,
              key: const Key('draw_menu'),
            ),
            button(
              '文字',
              key: const Key('text_tool'),
              selected: !cropping && _tool == EditTool.text,
              onTap: () => _selectTool(EditTool.text),
              tooltip: '点图片输入文字；拖动已有文字可移动，点它可修改',
            ),
            menu<double>('字号', {
              for (final e in editTextSizes.entries)
                '${e.key} ${e.value.round()}': e.value,
            }, (size) => setState(() => _textSize = size)),
            menu<double>('粗细', {
              for (final e in editStrokeWidths.entries)
                '${e.key} ${e.value.round()}': e.value,
            }, (width) => setState(() => _strokeWidth = width)),
            button(
              '橡皮',
              key: const Key('eraser_tool'),
              selected: !cropping && _tool == EditTool.eraser,
              onTap: () => _selectTool(EditTool.eraser),
              tooltip: '只擦画上去的内容，不擦原图',
            ),
            button(
              '马赛克',
              key: const Key('mosaic_tool'),
              selected: !cropping && _tool == EditTool.mosaic,
              onTap: () => _selectTool(EditTool.mosaic),
              tooltip: '涂抹打码，遮住隐私信息',
            ),
            PopupMenuButton<Color>(
              enabled: enabled,
              tooltip: '颜色',
              position: PopupMenuPosition.over,
              onSelected: (color) => setState(() => _color = color),
              itemBuilder: (_) => [
                PopupMenuItem<Color>(
                  enabled: false,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final color in editColors)
                        InkWell(
                          onTap: () => Navigator.pop(context, color),
                          child: Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: color == _color
                                    ? Colors.blue
                                    : Colors.black26,
                                width: color == _color ? 3 : 1,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              child: IgnorePointer(
                child: button('颜色', dot: _color, onTap: () {}),
              ),
            ),
            divider,
            button(
              '撤销',
              key: const Key('undo'),
              onTap: _history.canUndo ? _undo : null,
              tooltip: '撤销（Ctrl+Z）',
            ),
            button(
              '恢复',
              onTap: _history.canRedo ? _redo : null,
              tooltip: '恢复（Ctrl+Y）',
            ),
            button('清除', onTap: _clear, tooltip: '清除全部标注；可以撤销'),
            divider,
            if (widget.onCopy != null)
              button(
                '复制',
                onTap: () => unawaited(_output(widget.onCopy!)),
                tooltip: '复制编辑后的图片，可以粘贴到微信等',
              ),
            if (widget.onSave != null)
              button(
                '保存',
                onTap: () => unawaited(_output(widget.onSave!)),
                tooltip: '另存为新图片，原图不变',
              ),
            if (widget.onSend != null)
              button(
                widget.sendLabel,
                key: const Key('edit_send'),
                selected: true,
                onTap: () =>
                    unawaited(_output(widget.onSend!, closeAfter: true)),
                tooltip: '把编辑后的图片发出去',
              ),
            button(
              '取消',
              onTap: () => unawaited(_close()),
              tooltip: '关闭编辑（Esc）',
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EditPainter extends CustomPainter {
  _EditPainter({
    required this.picture,
    required this.state,
    required this.pending,
    required this.mosaic,
    required this.scale,
    required this.visible,
    required this.cropDraft,
    required this.hidden,
    required this.repaintKey,
  });

  final ui.Image picture;
  final EditState state;
  final EditMark? pending;
  final ui.Image? mosaic;
  final double scale;
  final Rect visible;
  final Rect? cropDraft;
  final int? hidden;
  final Object repaintKey;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    canvas.save();
    canvas.scale(scale);
    canvas.translate(-visible.left, -visible.top);
    final shown = hidden == null
        ? state
        : state.copyWith(
            marks: [
              for (var i = 0; i < state.marks.length; i++)
                if (i != hidden) state.marks[i],
            ],
          );
    paintEdit(
      canvas,
      picture: picture,
      // The crop is shown by `visible`; draw the whole picture.
      state: shown.copyWith(clearCrop: true),
      mosaicSource: mosaic,
      pending: pending,
    );
    canvas.restore();
    final draft = cropDraft;
    if (draft != null) {
      final r = Rect.fromLTRB(
        (draft.left - visible.left) * scale,
        (draft.top - visible.top) * scale,
        (draft.right - visible.left) * scale,
        (draft.bottom - visible.top) * scale,
      );
      final shade = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRect(r);
      canvas.drawPath(shade, Paint()..color = const Color(0x99000000));
      canvas.drawRect(
        r,
        Paint()
          ..color = const Color(0xFF0A84FF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      final handle = Paint()..color = const Color(0xFF0A84FF);
      for (final p in [
        r.topLeft,
        r.topCenter,
        r.topRight,
        r.centerLeft,
        r.centerRight,
        r.bottomLeft,
        r.bottomCenter,
        r.bottomRight,
      ]) {
        canvas.drawRect(
          Rect.fromCenter(center: p, width: 9, height: 9),
          handle,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _EditPainter old) =>
      old.repaintKey != repaintKey ||
      old.scale != scale ||
      old.visible != visible ||
      old.picture != picture;
}
