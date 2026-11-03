import 'dart:io';

import 'package:flutter/material.dart';

/// One theme for every page: flat tinted cards, rounded controls and the
/// Windows Chinese UI font, so Chinese text renders crisply.
ThemeData buildAppTheme(Color seed, Brightness brightness) {
  final generated = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
    // Keeps the primary colour close to the brand seed instead of washing it
    // out into a pastel.
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  );
  // Fidelity also makes the "container" colours nearly as strong as the seed
  // (dark text on deep red). Containers become a soft tint of the primary.
  final light = brightness == Brightness.light;
  // Dark mode's primary is a light pink, which turns muddy over the dark
  // surface; its inversePrimary is the deep brand red.
  final tint = light
      ? Color.alphaBlend(
          generated.primary.withValues(alpha: 0.12),
          generated.surface,
        )
      : Color.alphaBlend(
          generated.inversePrimary.withValues(alpha: 0.5),
          generated.surface,
        );
  final onTint = light
      ? Color.lerp(generated.primary, Colors.black, 0.25)!
      : generated.onSurface;
  final scheme = generated.copyWith(
    primaryContainer: tint,
    onPrimaryContainer: onTint,
    secondaryContainer: tint,
    onSecondaryContainer: onTint,
  );
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: Platform.isWindows ? 'Microsoft YaHei UI' : null,
    fontFamilyFallback: Platform.isWindows
        ? const ['Microsoft YaHei', 'Segoe UI']
        : null,
  );
  final roundedSmall = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(12),
  );
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.45)),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.primary,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      minVerticalPadding: 10,
      titleTextStyle: base.textTheme.bodyLarge?.copyWith(
        fontWeight: FontWeight.w500,
        color: scheme.onSurface,
      ),
      subtitleTextStyle: base.textTheme.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
        height: 1.35,
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.5),
      thickness: 1,
      space: 1,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: roundedSmall),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(shape: roundedSmall),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: roundedSmall),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        shape: roundedSmall,
        visualDensity: VisualDensity.compact,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      linearTrackColor: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(4),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(8),
      ),
    ),
  );
}
