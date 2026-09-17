import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transfer/src/app_version.dart';

void main() {
  test('displayed versions match pubspec and Windows title', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*([^+\s]+)\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);

    expect(match, isNotNull);
    expect(appVersion, match!.group(1));
    expect(appBuildNumber, int.parse(match.group(2)!));
    expect(appVersionLabel, '猛人快传 v${match.group(1)}');

    final windowsMain = File('windows/runner/main.cpp').readAsStringSync();
    expect(windowsMain, contains('v${match.group(1)}";'));
  });
}
