const appVersion = '1.8.4';
const appBuildNumber = 31;

/// Shown under the icon in Settings.
const appAuthor = 'longpeng1413';

/// Only set for the local "update test" build
/// (`--dart-define=MENGREN_UPDATE_TEST_CURRENT_VERSION=1.7.0`). It makes the
/// updater treat this build as an older version so the real GitHub release can
/// be installed over it. Official builds leave it empty.
const updateTestCurrentVersion = String.fromEnvironment(
  'MENGREN_UPDATE_TEST_CURRENT_VERSION',
);
const isUpdateTestBuild = updateTestCurrentVersion != '';

const appVersionLabel = isUpdateTestBuild
    ? '猛人快传 v$appVersion（更新测试版）'
    : '猛人快传 v$appVersion';
