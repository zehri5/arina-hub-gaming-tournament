import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../audio/soundboard.dart';

/// Row of 4 square live-on-air soundboard pads for the RJ Studio panel.
class SoundboardPads extends StatelessWidget {
  const SoundboardPads({
    super.key,
    required this.soundboard,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    this.spacing = 10,
  });

  final Soundboard soundboard;
  final EdgeInsetsGeometry padding;
  final double spacing;

  static const Color _bgBlack = Color(0xFF000000);
  static const Color _padDarkGrey = Color(0xFF1A1A1A);
  static const Color _padActiveGrey = Color(0xFF242424);
  static const Color _padDisabledGrey = Color(0xFF121212);
  static const Color _goldAccent = Color(0xFFFDC903);
  static const Color _labelWhite = Color(0xFFEAEAEA);
  static const Color _disabledGrey = Color(0xFF5A5A5A);

  static const List<_PadMeta> _pads = <_PadMeta>[
    _PadMeta(
      pad: SoundPad.applause,
      label: 'APPLAUSE',
      icon: Icons.celebration_rounded,
    ),
    _PadMeta(
      pad: SoundPad.airHorn,
      label: 'AIR HORN',
      icon: Icons.campaign_rounded,
    ),
    _PadMeta(
      pad: SoundPad.laugh,
      label: 'LAUGH',
      icon: Icons.sentiment_very_satisfied_rounded,
    ),
    _PadMeta(
      pad: SoundPad.drumRoll,
      label: 'DRUM',
      icon: Icons.graphic_eq_rounded,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _bgBlack,
      padding: padding,
      child: ListenableBuilder(
        listenable: soundboard,
        builder: (BuildContext context, _) {
          final SoundPad? activePad = soundboard.activePad;

          return Row(
            children: <Widget>[
              for (int i = 0; i < _pads.length; i++) ...<Widget>[
                if (i > 0) SizedBox(width: spacing),
                Expanded(
                  child: AspectRatio(
                    aspectRatio: 1.0,
                    child: _SoundPadTile(
                      meta: _pads[i],
                      available: soundboard.isPadAvailable(_pads[i].pad),
                      active: activePad == _pads[i].pad,
                      onTap: () {
                        HapticFeedback.lightImpact();
                        soundboard.play(_pads[i].pad);
                      },
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _PadMeta {
  const _PadMeta({
    required this.pad,
    required this.label,
    required this.icon,
  });

  final SoundPad pad;
  final String label;
  final IconData icon;
}

class _SoundPadTile extends StatelessWidget {
  const _SoundPadTile({
    required this.meta,
    required this.available,
    required this.active,
    required this.onTap,
  });

  final _PadMeta meta;
  final bool available;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color surfaceColor = !available
        ? SoundboardPads._padDisabledGrey
        : (active
            ? SoundboardPads._padActiveGrey
            : SoundboardPads._padDarkGrey);

    final Color iconColor = !available
        ? SoundboardPads._disabledGrey
        : SoundboardPads._goldAccent;

    final Color labelColor = !available
        ? SoundboardPads._disabledGrey
        : (active ? SoundboardPads._goldAccent : SoundboardPads._labelWhite);

    return Opacity(
      opacity: available ? 1.0 : 0.45,
      child: Material(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: available ? onTap : null,
          splashColor: SoundboardPads._goldAccent.withValues(alpha: 0.22),
          highlightColor: SoundboardPads._goldAccent.withValues(alpha: 0.12),
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(
                      meta.icon,
                      size: 26,
                      color: iconColor,
                    ),
                    const SizedBox(height: 6),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        meta.label,
                        maxLines: 1,
                        style: TextStyle(
                          color: labelColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (active && available)
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 0,
                  child: Container(
                    height: 3,
                    decoration: const BoxDecoration(
                      color: SoundboardPads._goldAccent,
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(2),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
