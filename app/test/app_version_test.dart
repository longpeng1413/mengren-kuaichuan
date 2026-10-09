import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transfer/src/app_version.dart';

void main() {
  test(
    'Windows package exposes Chinese executable and matching firewall path',
    () {
      final root = Directory.current.parent.path;
      final packaging = File('$root/scripts/package_windows.ps1')
          .readAsStringSync();
      final firewall = File('$root/packaging/windows/enable_lan_access.ps1')
          .readAsStringSync();
      final resource = File('windows/runner/Runner.rc').readAsStringSync();
      expect(packaging, contains("-NewName '猛人快传.exe'"));
      expect(firewall, contains("Join-Path \u0024PSScriptRoot '猛人快传.exe'"));
      expect(
        firewall,
        contains("Join-Path \u0024PSScriptRoot 'lan_transfer.exe'"),
      );
      expect(resource, contains('"OriginalFilename", "猛人快传.exe"'));
      // Both preferences and secure storage derive their directory from these.
      expect(resource, contains('"ProductName", "lan_transfer"'));
      expect(resource, contains('"CompanyName", "com.personal.lantransfer"'));
      expect(resource, contains('"FileDescription", "猛人快传"'));
    },
  );

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
