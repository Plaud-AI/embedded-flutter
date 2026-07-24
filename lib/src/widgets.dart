import 'package:flutter/material.dart';

import 'theme.dart';

/// SF-symbol stand-ins from the RN demo's `icon.tsx`, mapped to Material icons.
abstract final class PlaudIcons {
  static const radar = Icons.radar; // dot.radiowaves.left.and.right
  static const unlink = Icons.link_off; // bolt.horizontal.circle
  static const refresh = Icons.refresh; // arrow.clockwise
  static const fileAudio = Icons.graphic_eq; // waveform
  static const fileText = Icons.description_outlined; // doc.text
  static const close = Icons.close; // xmark
}

/* ---------- Text ---------- */

class Mono extends StatelessWidget {
  const Mono(
    this.text, {
    super.key,
    this.size = 14,
    this.color = PlaudColors.textLight,
    this.maxLines,
  });

  final String text;
  final double size;
  final Color color;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: maxLines,
      overflow: maxLines != null ? TextOverflow.ellipsis : null,
      style: TextStyle(fontFamily: monoFontFamily, fontSize: size, color: color),
    );
  }
}

class Overline extends StatelessWidget {
  const Overline(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        letterSpacing: 1.5,
        color: PlaudColors.textFaint,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/* ---------- Card ---------- */

class DevCard extends StatelessWidget {
  const DevCard({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.borderColor = PlaudColors.borderSubtle,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: PlaudColors.surfaceCard,
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(PlaudRadius.sm),
      ),
      child: child,
    );
  }
}

/* ---------- Button ---------- */

enum DevButtonVariant { primary, destructive, secondary }

class DevButton extends StatelessWidget {
  const DevButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.variant = DevButtonVariant.primary,
    this.disabled = false,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final DevButtonVariant variant;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final tint = switch (variant) {
      DevButtonVariant.primary => PlaudColors.black,
      DevButtonVariant.destructive => PlaudColors.statusError,
      DevButtonVariant.secondary => PlaudColors.textWhite,
    };
    final background = switch (variant) {
      DevButtonVariant.primary => PlaudColors.white,
      _ => Colors.transparent,
    };
    final borderColor = switch (variant) {
      DevButtonVariant.primary => Colors.transparent,
      DevButtonVariant.destructive => PlaudColors.errorBorder,
      DevButtonVariant.secondary => PlaudColors.borderSubtle,
    };

    return Opacity(
      opacity: disabled ? 0.3 : 1,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(PlaudRadius.sm),
        child: InkWell(
          onTap: disabled ? null : onPressed,
          borderRadius: BorderRadius.circular(PlaudRadius.sm),
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: BoxDecoration(
              border: Border.all(color: borderColor),
              borderRadius: BorderRadius.circular(PlaudRadius.sm),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: tint),
                  const SizedBox(width: 8),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: tint,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/* ---------- Tappable list row ---------- */

class DevRow extends StatelessWidget {
  const DevRow({super.key, required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: PlaudColors.surfaceInput,
      borderRadius: BorderRadius.circular(PlaudRadius.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(PlaudRadius.sm),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          decoration: BoxDecoration(
            border: Border.all(color: PlaudColors.borderSubtle),
            borderRadius: BorderRadius.circular(PlaudRadius.sm),
          ),
          child: child,
        ),
      ),
    );
  }
}

/* ---------- Status pill ---------- */

class Pill extends StatelessWidget {
  const Pill({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: PlaudColors.borderSubtle),
        borderRadius: BorderRadius.circular(PlaudRadius.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, spacing: 6, children: children),
    );
  }
}

/* ---------- Waveform (live recording) ---------- */

class WaveBars extends StatefulWidget {
  const WaveBars({super.key});

  @override
  State<WaveBars> createState() => _WaveBarsState();
}

class _WaveBarsState extends State<WaveBars> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 22,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              for (var i = 0; i < 5; i++) _bar(i),
            ],
          );
        },
      ),
    );
  }

  Widget _bar(int index) {
    // Staggered 0.35 → 1 → 0.35 scale, offset per bar (RN: 120 ms delay/bar).
    final t = (_controller.value + index * 0.12) % 1.0;
    final wave = t < 0.5 ? t * 2 : (1 - t) * 2;
    final scale = 0.35 + wave * 0.65;
    return Container(
      width: 3,
      height: 22 * scale,
      decoration: BoxDecoration(
        color: PlaudColors.statusError,
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }
}
