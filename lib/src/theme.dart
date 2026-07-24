import 'package:flutter/material.dart';

/// Plaud "dev" design language — dark-surface tokens lifted from the RN demo's
/// `constants/theme.ts` (originally plaud-design-system/dev/colors_and_type.css).
/// The Plaud screen is dark-only, so these are used directly.
abstract final class PlaudColors {
  static const black = Color(0xFF000000);
  static const white = Color(0xFFFFFFFF);

  static const surface = Color(0xFF0F0F0F);
  static const surfaceFooter = Color(0xFF090909);
  static const surfaceInput = Color(0xFF1D1D1D);
  static const surfaceCard = Color(0xB31D1D1D); // rgba(29,29,29,0.7)

  static const textWhite = Color(0xFFFFFFFF);
  static const textLight = Color(0xFFEBEBEB);
  static const textMuted = Color(0xFFADADAD);
  static const textDim = Color(0xFF858585);
  static const textFaint = Color(0xFF5C5C5C);

  static const borderSubtle = Color(0xFF333333);
  static const borderFocus = Color(0xFF5C5C5C);

  static const accentBlue = Color(0xFF00D0FF);
  static const statusError = Color(0xFFF15042);
  static const statusOk = Color(0xFF36D96C);
  static const statusWarn = Color(0xFFFABE3E);

  static const errorBorder = Color(0x66F15042); // rgba(241,80,66,0.4)
  static const liveBorder = Color(0x73F15042); // rgba(241,80,66,0.45)
  static const backdrop = Color(0x99000000); // rgba(0,0,0,0.6)
}

abstract final class PlaudRadius {
  static const sm = 5.0;
  static const pill = 999.0;
}

abstract final class Spacing {
  static const half = 2.0;
  static const one = 4.0;
  static const two = 8.0;
  static const three = 16.0;
  static const four = 24.0;
  static const five = 32.0;
  static const six = 64.0;
}

const maxContentWidth = 800.0;
const bottomTabInset = 50.0;

/// System monospace stack (the RN demo uses `ui-monospace` → SF Mono; Menlo is
/// the closest face addressable by name on iOS).
const monoFontFamily = 'Menlo';
