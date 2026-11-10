import 'package:flutter/material.dart';

class AppColors {
  static const bg = Color(0xFF0B0B0F);
  static const surface = Color(0xFF16161D);
  static const surfaceElevated = Color(0xFF1E1E28);
  static const card = Color(0xFF22222E);
  static const accent = Color(0xFF7C5CFF);
  static const accentSoft = Color(0xFF9B84FF);
  static const proGold = Color(0xFFFFC857);
  static const textPrimary = Color(0xFFF5F5F7);
  static const textSecondary = Color(0xFFA0A0B0);
  static const danger = Color(0xFFFF5C7A);
  static const success = Color(0xFF3DDC97);
}

ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: 'Roboto',
    colorScheme: const ColorScheme.dark(
      primary: AppColors.accent,
      secondary: AppColors.accentSoft,
      surface: AppColors.surface,
      error: AppColors.danger,
    ),
  );

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      foregroundColor: AppColors.textPrimary,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surfaceElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.card,
      contentTextStyle: const TextStyle(color: AppColors.textPrimary),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}
