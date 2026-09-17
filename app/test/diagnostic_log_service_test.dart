import 'dart:io';

import 'package:lan_transfer/src/diagnostics/diagnostic_log_service.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  test(
    'Windows diagnostic export combines rotated logs with privacy notice',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lan-transfer-diagnostics-',
      );
      addTearDown(() => root.delete(recursive: true));
      final current = File(path.join(root.path, 'app-diagnostic.log'));
      final previous = File(
        path.join(root.path, 'app-diagnostic.previous.log'),
      );
      await current.writeAsString('current discovery event\n');
      await previous.writeAsString('previous socket event\n');
      final destination = File(path.join(root.path, 'export.txt'));

      await exportDiagnosticFiles(
        files: [previous, current],
        destination: destination,
        platformDescription: 'Windows test host',
      );

      final exported = await destination.readAsString();
      expect(exported, contains('平台：Windows · Windows test host'));
      expect(exported, contains('app-diagnostic.log'));
      expect(exported, contains('current discovery event'));
      expect(exported, contains('app-diagnostic.previous.log'));
      expect(exported, contains('previous socket event'));
      expect(exported, contains('不包含聊天文字、文件内容、口令或令牌'));
    },
  );
}
