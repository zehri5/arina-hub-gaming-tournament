import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

class MusicPlayerPanel extends StatefulWidget {
  const MusicPlayerPanel({
    super.key,
    required this.title,
    required this.artist,
    required this.statusLine,
    required this.isDucked,
    required this.position,
    required this.duration,
    required this.onSeek,
    required this.isPlaying,
    required this.isRepeat,
    required this.onPlayPause,
    required this.onRepeat,
    required this.onPrevious,
    required this.onNext,
    required this.onPlaylist,
    required this.onStop,
    required this.volume,
    required this.onVolumeChanged,
    this.micLevel = 0.8,
    this.onMicLevelChanged,
    required this.broadcastOn,
    required this.isHost,
    required this.reverb,
    required this.echo,
    required this.delayMs,
    required this.bassDb,
    required this.onReverb,
    required this.onEcho,
    required this.onDelayMs,
    required this.onBassDb,
    required this.preset,
    required this.onPreset,
    required this.noiseCancellation,
    required this.onNoiseCancellation,
    required this.noiseGateEnabled,
    required this.noiseGateThresholdDb,
    required this.onNoiseGateEnabled,
    required this.onNoiseGateThreshold,
    required this.compressorEnabled,
    required this.compressorThresholdDb,
    required this.compressorRatio,
    required this.onCompressorEnabled,
    required this.onCompressorThreshold,
    required this.onCompressorRatio,
    required this.listenerCount,
    required this.listenerAvatarUrls,
    required this.onListenersPressed,
    this.levelStream,
  });

  final String title;
  final String artist;
  final String statusLine;
  final bool isDucked;
  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;
  final bool isPlaying;
  final bool isRepeat;
  final VoidCallback onPlayPause;
  final VoidCallback onRepeat;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onPlaylist;
  // FIX 22 item 22: NO onSettings — the player's Settings
  // button + hosting dialog are removed (GO LIVE owns
  // hosting now, item 21).
  final VoidCallback onStop;
  final double volume;
  final ValueChanged<double> onVolumeChanged;
  /// FIX 22 item 11 — mic level (0..1) + its change callback (the
  /// mount's _micFaderLevel, shared with the RJ console MIC
  /// fader — single source of truth, both controls stay in sync).
  /// Null callback = the mic stepper is not shown.
  final double micLevel;
  final ValueChanged<double>? onMicLevelChanged;
  final bool broadcastOn;
  final bool isHost;
  final double reverb;
  final double echo;
  final double delayMs;
  final double bassDb;
  final ValueChanged<double> onReverb;
  final ValueChanged<double> onEcho;
  final ValueChanged<double> onDelayMs;
  final ValueChanged<double> onBassDb;
  final String preset;
  final ValueChanged<String> onPreset;
  final bool noiseCancellation;
  final ValueChanged<bool> onNoiseCancellation;
  final bool noiseGateEnabled;
  final double noiseGateThresholdDb;
  final ValueChanged<bool> onNoiseGateEnabled;
  final ValueChanged<double> onNoiseGateThreshold;
  final bool compressorEnabled;
  final double compressorThresholdDb;
  final double compressorRatio;
  final ValueChanged<bool> onCompressorEnabled;
  final ValueChanged<double> onCompressorThreshold;
  final ValueChanged<double> onCompressorRatio;
  final int listenerCount;
  final List<String> listenerAvatarUrls;
  final VoidCallback onListenersPressed;
  final Stream<double>? levelStream;

  @override
  State<MusicPlayerPanel> createState() => _MusicPlayerPanelState();
}

class _MusicPlayerPanelState extends State<MusicPlayerPanel>
    with TickerProviderStateMixin {
  static const Color _gold = Color(0xFFFDC903);
  static const Color _goldBorder = Color(0x88FDC903);
  static const Color _goldSubtle = Color(0x4DFDC903);
  static const Color _red = Color(0xFFE51919);
  static const Color _white = Color(0xFFFFFFFF);
  static const Color _muted = Color(0xFF94A3B8);
  static const Color _cardFill = Color(0x59000000); // ~35% black
  static const Color _controlFill = Color(0xAA000000);

  late final AnimationController _vinylController;
  late final AnimationController _spectrumController;
  StreamSubscription<double>? _levelSubscription;
  double _liveLevel = 0.0;
  double _smoothedLevel = 0.0;
  // Gate-threshold pill drag anchor (review fix): drag deltas
  // accumulate from the value at drag START, not from the prop —
  // the prop only updates after the parent's async refresh, so
  // reading it per update made fast drags lag/stick.
  double? _gateDragStartValue;
  double _gateDragDx = 0.0;

  @override
  void initState() {
    super.initState();
    _vinylController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    );
    if (widget.isPlaying) {
      _vinylController.repeat();
    }

    _spectrumController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
    _spectrumController.addListener(_tickSpectrum);

    _subscribeLevelStream();
  }

  void _tickSpectrum() {
    if (widget.levelStream != null) {
      final target = widget.isPlaying ? _liveLevel : 0.08;
      _smoothedLevel = _smoothedLevel + (target - _smoothedLevel) * 0.25;
    }
  }

  void _subscribeLevelStream() {
    _levelSubscription?.cancel();
    _levelSubscription = widget.levelStream?.listen((level) {
      _liveLevel = level.clamp(0.0, 1.0);
    });
  }

  @override
  void didUpdateWidget(covariant MusicPlayerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.isPlaying != oldWidget.isPlaying) {
      if (widget.isPlaying) {
        _vinylController.repeat();
      } else {
        _vinylController.stop(canceled: false);
      }
    }

    if (widget.levelStream != oldWidget.levelStream) {
      _liveLevel = 0.0;
      _smoothedLevel = 0.0;
      _subscribeLevelStream();
    }
  }

  @override
  void dispose() {
    _levelSubscription?.cancel();
    _spectrumController.removeListener(_tickSpectrum);
    _spectrumController.dispose();
    _vinylController.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final totalSeconds = d.inSeconds < 0 ? 0 : d.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    final mStr = minutes.toString().padLeft(2, '0');
    final sStr = seconds.toString().padLeft(2, '0');
    return '$mStr:$sStr';
  }

  String _formatRatio(double ratio) {
    final rounded = (ratio * 10).round() / 10;
    if (rounded == rounded.roundToDouble()) {
      return '${rounded.toInt()}:1';
    }
    return '${rounded.toStringAsFixed(1)}:1';
  }

  void _cycleCompressorRatio() {
    const ratios = <double>[1.5, 2.0, 2.5, 3.0, 4.0, 6.0, 8.0, 10.0];
    int nextIdx = 0;
    for (int i = 0; i < ratios.length; i++) {
      if (ratios[i] > widget.compressorRatio + 0.05) {
        nextIdx = i;
        break;
      }
    }
    widget.onCompressorRatio(ratios[nextIdx]);
  }

  @override
  Widget build(BuildContext context) {
    final maxMs = math.max(1.0, widget.duration.inMilliseconds.toDouble());
    final posMs = widget.position.inMilliseconds.toDouble().clamp(0.0, maxMs);

    return Container(
      color: Colors.transparent,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildVinylAndSpectrum(),
            const SizedBox(height: 10),
            _buildTrackHeader(),
            const SizedBox(height: 12),
            _buildProgressSection(posMs, maxMs),
            const SizedBox(height: 12),
            _buildControlsRow(),
            const SizedBox(height: 12),
            _buildVolumeRow(),
            if (widget.isHost && widget.onMicLevelChanged != null) ...[
              const SizedBox(height: 10),
              _buildMicStepper(),
            ],
            if (widget.isHost) ...[
              const SizedBox(height: 12),
              _buildHostEffectsSection(),
            ],
            const SizedBox(height: 10),
            _buildListenersStrip(),
            const SizedBox(height: 10),
            _buildBottomBar(),
            const SizedBox(height: 10),
            _buildBottomNote(),
          ],
        ),
      ),
    );
  }

  Widget _buildVinylAndSpectrum() {
    return SizedBox(
      height: 186,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _spectrumController,
              builder: (context, _) {
                return CustomPaint(
                  painter: _SpectrumPainter(
                    phase: _spectrumController.value * 2 * math.pi,
                    level: widget.levelStream != null ? _smoothedLevel : null,
                    isPlaying: widget.isPlaying,
                    goldColor: _gold,
                  ),
                );
              },
            ),
          ),
          Container(
            width: 170,
            height: 170,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: _gold.withAlpha(widget.isPlaying ? 110 : 55),
                  blurRadius: 28,
                  spreadRadius: 2,
                ),
              ],
            ),
            // Only the grooved disc rotates — the centre label (note
            // + mini EQ) stays upright, as in the design. (Review
            // fix: the label used to sit INSIDE the
            // RotationTransition, so the note spun upside-down.)
            child: Stack(
              alignment: Alignment.center,
              children: [
                RotationTransition(
                  turns: _vinylController,
                  child: CustomPaint(
                    size: const Size(170, 170),
                    painter: _VinylDiscPainter(goldColor: _gold),
                  ),
                ),
                Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF0C0905),
                    border: Border.all(color: _gold, width: 1.8),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(bottom: 10),
                        child: Icon(
                          Icons.music_note_rounded,
                          color: _gold,
                          size: 32,
                        ),
                      ),
                      Positioned(
                        bottom: 8,
                        left: 14,
                        right: 14,
                        height: 14,
                        child: AnimatedBuilder(
                          animation: _spectrumController,
                          builder: (context, _) {
                            return CustomPaint(
                              painter: _MiniEqualiserPainter(
                                phase: _spectrumController.value * 2 * math.pi,
                                level: widget.levelStream != null
                                    ? _smoothedLevel
                                    : null,
                                isPlaying: widget.isPlaying,
                                goldColor: _gold,
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrackHeader() {
    return Column(
      children: [
        Text(
          widget.title,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: _white,
            fontSize: 23,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
            height: 1.18,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          widget.artist,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: _gold,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            if (widget.isDucked) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: _cardFill,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: _gold, width: 1.2),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CustomPaint(
                      size: const Size(14, 11),
                      painter: _CrownPainter(color: _gold),
                    ),
                    const SizedBox(width: 5),
                    const Text(
                      'RJ bed',
                      style: TextStyle(
                        color: _gold,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 1,
                height: 13,
                color: _muted,
              ),
            ],
            Text(
              widget.statusLine,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _white,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildProgressSection(double posMs, double maxMs) {
    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            activeTrackColor: _gold,
            inactiveTrackColor: const Color(0x4D94A3B8),
            thumbColor: _gold,
            overlayColor: const Color(0x33FDC903),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7.5),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            trackShape: const RoundedRectSliderTrackShape(),
          ),
          child: Slider(
            value: posMs,
            min: 0.0,
            max: maxMs,
            onChanged: (val) {
              widget.onSeek(Duration(milliseconds: val.round()));
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(widget.position),
                style: const TextStyle(
                  color: _white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                _formatDuration(widget.duration),
                style: const TextStyle(
                  color: _white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildControlsRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _ControlPillButton(
          icon: Icons.repeat_rounded,
          iconColor: widget.isRepeat ? _gold : _muted,
          borderColor: widget.isRepeat ? _goldBorder : _goldSubtle,
          isPill: true,
          onTap: widget.onRepeat,
        ),
        _ControlPillButton(
          icon: Icons.skip_previous_rounded,
          iconColor: _gold,
          borderColor: _goldBorder,
          onTap: widget.onPrevious,
        ),
        GestureDetector(
          onTap: widget.onPlayPause,
          child: Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xCC000000),
              border: Border.all(color: _gold, width: 3),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x77FDC903),
                  blurRadius: 18,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Icon(
              widget.isPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              color: _gold,
              size: 36,
            ),
          ),
        ),
        _ControlPillButton(
          icon: Icons.skip_next_rounded,
          iconColor: _gold,
          borderColor: _goldBorder,
          onTap: widget.onNext,
        ),
        _ControlPillButton(
          icon: Icons.queue_music_rounded,
          iconColor: _gold,
          borderColor: _goldBorder,
          isPill: true,
          // FIX 22 item 12: the Library button, labelled — the
          // player is the Music entry now, and the Library
          // opens from here (onPlaylist -> _showMusicPanel).
          label: 'Library',
          onTap: widget.onPlaylist,
        ),
      ],
    );
  }

  Widget _buildVolumeRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          const Icon(Icons.volume_down_rounded, color: _gold, size: 22),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3.5,
                activeTrackColor: _gold,
                inactiveTrackColor: const Color(0x4D94A3B8),
                thumbColor: _gold,
                overlayColor: const Color(0x28FDC903),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 13),
              ),
              child: Slider(
                value: widget.volume.clamp(0.0, 1.0),
                min: 0.0,
                max: 1.0,
                onChanged: widget.onVolumeChanged,
              ),
            ),
          ),
          const Icon(Icons.volume_up_rounded, color: _gold, size: 22),
        ],
      ),
    );
  }

  /// FIX 22 item 11 — MIC volume stepper (host-only): +/- buttons
  /// step the mic level by 0.1 (0..1), showing the current mic %
  /// between them. Drives the SAME _micFaderLevel as the RJ
  /// console MIC fader (the mount passes it as [micLevel] and
  /// applies the inverse link in [onMicLevelChanged]) — the two
  /// controls stay in sync both ways. At the 0/1 limits the
  /// spent button dims and does nothing (never past the range).
  Widget _buildMicStepper() {
    final mic = widget.micLevel.clamp(0.0, 1.0);
    final pct = '${(mic * 100).round()}%';
    Widget stepBtn(IconData icon, double delta) {
      final atLimit = (delta < 0 && mic <= 0.0) || (delta > 0 && mic >= 1.0);
      return GestureDetector(
        onTap: atLimit
            ? null
            : () => widget.onMicLevelChanged
                ?.call((mic + delta).clamp(0.0, 1.0)),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: const Color(0xAA000000),
            shape: BoxShape.circle,
            border: Border.all(
                color: atLimit
                    ? _goldBorder.withValues(alpha: 0.35)
                    : _goldBorder,
                width: 1.3),
          ),
          child: Icon(icon,
              color: atLimit ? _gold.withValues(alpha: 0.4) : _gold,
              size: 20),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          const Icon(Icons.mic, color: _gold, size: 22),
          const SizedBox(width: 8),
          const Text('MIC',
              style: TextStyle(
                  color: _gold, fontSize: 12, fontWeight: FontWeight.w800)),
          const Spacer(),
          stepBtn(Icons.remove_rounded, -0.1),
          SizedBox(
            width: 52,
            child: Text(pct,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w800)),
          ),
          stepBtn(Icons.add_rounded, 0.1),
        ],
      ),
    );
  }

  Widget _buildHostEffectsSection() {
    final bassRounded = widget.bassDb.round();
    final bassFormatted =
        bassRounded > 0 ? '+$bassRounded dB' : '$bassRounded dB';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
          decoration: BoxDecoration(
            color: _cardFill,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _goldBorder, width: 1.2),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 1,
                      color: _goldSubtle,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.star_rounded, color: _gold, size: 16),
                        SizedBox(width: 5),
                        Text(
                          'HOST-ONLY MUSIC EFFECTS',
                          style: TextStyle(
                            color: _gold,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.7,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Container(
                      height: 1,
                      color: _goldSubtle,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _RotaryKnob(
                      label: 'REVERB',
                      valueText: '${(widget.reverb * 100).round()}%',
                      value: widget.reverb,
                      min: 0.0,
                      max: 1.0,
                      onChanged: widget.onReverb,
                    ),
                  ),
                  Expanded(
                    child: _RotaryKnob(
                      label: 'ECHO',
                      valueText: '${(widget.echo * 100).round()}%',
                      value: widget.echo,
                      min: 0.0,
                      max: 1.0,
                      onChanged: widget.onEcho,
                    ),
                  ),
                  Expanded(
                    child: _RotaryKnob(
                      label: 'DELAY',
                      valueText: '${widget.delayMs.round()} ms',
                      value: widget.delayMs,
                      min: 0.0,
                      max: 500.0,
                      onChanged: widget.onDelayMs,
                    ),
                  ),
                  Expanded(
                    child: _RotaryKnob(
                      label: 'BASS',
                      valueText: bassFormatted,
                      value: widget.bassDb,
                      min: -12.0,
                      max: 12.0,
                      onChanged: widget.onBassDb,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _buildPresetsAndNoiseCancellationRow(),
        const SizedBox(height: 8),
        _buildGateAndCompressorRow(),
      ],
    );
  }

  Widget _buildPresetsAndNoiseCancellationRow() {
    const presets = <String>['Off', 'Room', 'Hall'];
    final currentPresetLower = widget.preset.trim().toLowerCase();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: _cardFill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _goldSubtle, width: 1),
      ),
      child: Row(
        children: [
          const Text(
            'PRESETS:',
            style: TextStyle(
              color: _white,
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(width: 4),
          ...presets.map((p) {
            final isActive = currentPresetLower == p.toLowerCase();
            return Padding(
              padding: const EdgeInsets.only(right: 3),
              child: GestureDetector(
                onTap: () => widget.onPreset(p),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3.5,
                  ),
                  decoration: BoxDecoration(
                    color: isActive ? _gold : _controlFill,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: isActive ? _gold : _goldBorder,
                      width: 1,
                    ),
                  ),
                  child: Text(
                    p.toUpperCase(),
                    style: TextStyle(
                      color: isActive ? Colors.black : _gold,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            );
          }),
          Container(
            width: 1,
            height: 18,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            color: _goldSubtle,
          ),
          const Expanded(
            child: Text(
              'Noise Cancellation',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _white,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 4),
          _OnOffPillToggle(
            value: widget.noiseCancellation,
            onChanged: widget.onNoiseCancellation,
          ),
        ],
      ),
    );
  }

  Widget _buildGateAndCompressorRow() {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            // 9:12 (review fix): the compressor box carries a
            // slider + ratio pill, so it gets the wider share —
            // at 10:11 its row overflowed by ~53 px.
            flex: 9,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
              decoration: BoxDecoration(
                color: _cardFill,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _goldSubtle, width: 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Flexible(
                        child: Text(
                          'Noise Gate',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      _OnOffPillToggle(
                        value: widget.noiseGateEnabled,
                        onChanged: widget.onNoiseGateEnabled,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      // Flexible + ellipsis (review fix): at 390 px
                      // the label + pill overflowed by ~39 px under
                      // the wide test font (and would under large
                      // text scaling on a real phone) — the value
                      // pill always shows fully, the label yields.
                      const Flexible(
                        child: Text(
                          'Threshold:',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onHorizontalDragStart: (_) {
                          _gateDragStartValue =
                              widget.noiseGateThresholdDb;
                          _gateDragDx = 0.0;
                        },
                        onHorizontalDragUpdate: (details) {
                          _gateDragDx += details.delta.dx;
                          final start = _gateDragStartValue ??
                              widget.noiseGateThresholdDb;
                          widget.onNoiseGateThreshold(
                            (start + _gateDragDx * 0.4).clamp(-80.0, 0.0),
                          );
                        },
                        onHorizontalDragEnd: (_) {
                          _gateDragStartValue = null;
                        },
                        onHorizontalDragCancel: () {
                          _gateDragStartValue = null;
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2.5,
                          ),
                          decoration: BoxDecoration(
                            color: _controlFill,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: _goldSubtle, width: 1),
                          ),
                          child: Text(
                            '${widget.noiseGateThresholdDb.round()} dB',
                            style: const TextStyle(
                              color: _white,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: BoxDecoration(
                color: _cardFill,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _goldSubtle, width: 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Flexible(
                        child: Text(
                          'Compressor',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      _OnOffPillToggle(
                        value: widget.compressorEnabled,
                        onChanged: widget.onCompressorEnabled,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      // Flexible + ellipsis (review fix): same
                      // overflow as the gate row — the label yields,
                      // the slider + ratio pill keep their room.
                      const Flexible(
                        child: Text(
                          'Threshold:',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _white,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Expanded(
                        child: SizedBox(
                          height: 20,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 2.5,
                              activeTrackColor: _gold,
                              inactiveTrackColor: const Color(0x4D94A3B8),
                              thumbColor: _gold,
                              overlayColor: const Color(0x22FDC903),
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 4.5,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 7,
                              ),
                            ),
                            child: Slider(
                              value:
                                  widget.compressorThresholdDb.clamp(-60.0, 0.0),
                              min: -60.0,
                              max: 0.0,
                              onChanged: widget.onCompressorThreshold,
                            ),
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: _cycleCompressorRatio,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2.5,
                          ),
                          decoration: BoxDecoration(
                            color: _controlFill,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: _goldSubtle, width: 1),
                          ),
                          child: Text(
                            'Ratio: ${_formatRatio(widget.compressorRatio)}',
                            style: const TextStyle(
                              color: _white,
                              fontSize: 8,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildListenersStrip() {
    final avatars = widget.listenerAvatarUrls.take(3).toList();
    final avatarCount = avatars.isEmpty ? 3 : avatars.length;

    return InkWell(
      onTap: widget.onListenersPressed,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: _cardFill,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _goldBorder, width: 1.1),
        ),
        child: Row(
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(avatarCount, (index) {
                final url = avatars.isNotEmpty ? avatars[index] : null;
                return Padding(
                  padding: EdgeInsets.only(right: index < avatarCount - 1 ? 5 : 0),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF1A1208),
                      border: Border.all(color: _gold, width: 1.6),
                    ),
                    child: ClipOval(
                      child: url != null && url.isNotEmpty
                          ? Image.network(
                              url,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(
                                Icons.person_rounded,
                                color: _gold,
                                size: 17,
                              ),
                            )
                          : const Icon(
                              Icons.person_rounded,
                              color: _gold,
                              size: 17,
                            ),
                    ),
                  ),
                );
              }),
            ),
            Container(
              width: 1,
              height: 22,
              margin: const EdgeInsets.symmetric(horizontal: 14),
              color: _goldBorder,
            ),
            const Icon(Icons.people_alt_rounded, color: _white, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${widget.listenerCount} listening',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _cardFill,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _goldBorder, width: 1.2),
      ),
      child: Row(
        children: [
          // FIX 22 item 22: the Settings button is gone (see
          // onSettings removal above) — the bottom bar is the
          // broadcast indicator + Stop only.
          Expanded(
            // mainAxisSize.max + Flexible text (review fix): at
            // 14.5 px the 'Broadcast ON' label overflowed by ~9 px
            // under the wide test font — 13.5 px fits, and the
            // ellipsis is the fallback under large text scaling.
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.sensors_rounded,
                  color: widget.broadcastOn ? _gold : _muted,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    widget.broadcastOn ? 'Broadcast ON' : 'Broadcast OFF',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: widget.broadcastOn ? _gold : _muted,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: 1,
            height: 24,
            margin: const EdgeInsets.symmetric(horizontal: 14),
            color: _goldSubtle,
          ),
          GestureDetector(
            onTap: widget.onStop,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _red,
                border: Border.all(
                  color: const Color(0x66FFFFFF),
                  width: 1.4,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x66E51919),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: const Icon(
                Icons.power_settings_new_rounded,
                color: _white,
                size: 22,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomNote() {
    return Row(
      children: [
        Expanded(child: Container(height: 1, color: _goldSubtle)),
        const SizedBox(width: 8),
        const Flexible(
          flex: 8,
          child: Text(
            'Seeking moves only your phone — shared listeners keep their own position.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _muted,
              fontSize: 10.5,
              fontStyle: FontStyle.italic,
              height: 1.3,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: Container(height: 1, color: _goldSubtle)),
      ],
    );
  }
}

class _ControlPillButton extends StatelessWidget {
  const _ControlPillButton({
    required this.icon,
    required this.iconColor,
    required this.borderColor,
    required this.onTap,
    this.isPill = false,
    this.label,
  });

  final IconData icon;
  final Color iconColor;
  final Color borderColor;
  final VoidCallback onTap;
  final bool isPill;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final hasLabel = label != null && label!.isNotEmpty;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: hasLabel ? null : (isPill ? 54 : 46),
        height: isPill ? 40 : 46,
        padding:
            hasLabel ? const EdgeInsets.symmetric(horizontal: 12) : null,
        decoration: BoxDecoration(
          color: const Color(0xAA000000),
          borderRadius: BorderRadius.circular(isPill ? 20 : 23),
          border: Border.all(color: borderColor, width: 1.3),
        ),
        child: hasLabel
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: iconColor, size: 22),
                  const SizedBox(width: 6),
                  Text(label!,
                      style: TextStyle(
                          color: iconColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w800)),
                ],
              )
            : Icon(icon, color: iconColor, size: 22),
      ),
    );
  }
}

class _OnOffPillToggle extends StatelessWidget {
  const _OnOffPillToggle({
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  static const Color _gold = Color(0xFFFDC903);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        // 48 px wide (review fix): at 44 px the OFF label
        // overflowed by ~4 px — the knob + 'OFF' need the room.
        width: 48,
        height: 20,
        padding: const EdgeInsets.symmetric(horizontal: 2.5),
        decoration: BoxDecoration(
          color: value ? _gold : const Color(0xAA000000),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: value ? _gold : const Color(0x66FDC903),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisAlignment:
              value ? MainAxisAlignment.spaceBetween : MainAxisAlignment.start,
          children: value
              ? const [
                  Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Text(
                      'ON',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  CircleAvatar(radius: 7, backgroundColor: Colors.white),
                ]
              : const [
                  CircleAvatar(
                    radius: 7,
                    backgroundColor: Color(0xFF94A3B8),
                  ),
                  Padding(
                    padding: EdgeInsets.only(left: 2),
                    child: Text(
                      'OFF',
                      style: TextStyle(
                        color: Color(0xFF94A3B8),
                        fontSize: 7.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
        ),
      ),
    );
  }
}

class _RotaryKnob extends StatelessWidget {
  const _RotaryKnob({
    required this.label,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final String valueText;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  static const double _knobSize = 60.0;
  static const Color _gold = Color(0xFFFDC903);

  double get _normalized {
    if (max <= min) return 0.0;
    return ((value - min) / (max - min)).clamp(0.0, 1.0);
  }

  void _handleLocalPosition(Offset localPosition) {
    const center = Offset(_knobSize / 2, _knobSize / 2);
    final dx = localPosition.dx - center.dx;
    final dy = localPosition.dy - center.dy;
    if (dx == 0 && dy == 0) return;

    double angle = math.atan2(dy, dx);
    if (angle < 0) {
      angle += 2 * math.pi;
    }

    // Start at 135 deg (3*pi/4), sweep 270 deg (3*pi/2) clockwise.
    double relative = angle - (3 * math.pi / 4);
    if (relative < 0) {
      relative += 2 * math.pi;
    }

    const sweep = 3 * math.pi / 2;
    if (relative > sweep) {
      if (relative < 7 * math.pi / 4) {
        relative = sweep;
      } else {
        relative = 0.0;
      }
    }

    final t = (relative / sweep).clamp(0.0, 1.0);
    onChanged(min + t * (max - min));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _handleLocalPosition(d.localPosition),
          onVerticalDragStart: (d) => _handleLocalPosition(d.localPosition),
          onVerticalDragUpdate: (d) => _handleLocalPosition(d.localPosition),
          onHorizontalDragStart: (d) => _handleLocalPosition(d.localPosition),
          onHorizontalDragUpdate: (d) => _handleLocalPosition(d.localPosition),
          child: SizedBox(
            width: _knobSize,
            height: _knobSize,
            child: CustomPaint(
              painter: _KnobPainter(
                normalizedValue: _normalized,
                goldColor: _gold,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFFFFFFFF),
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 1),
        Text(
          valueText,
          style: const TextStyle(
            color: _gold,
            fontSize: 11.5,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _KnobPainter extends CustomPainter {
  const _KnobPainter({
    required this.normalizedValue,
    required this.goldColor,
  });

  final double normalizedValue;
  final Color goldColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outerRadius = size.width / 2 - 1;
    final knobRadius = outerRadius - 7.5;
    const startAngle = 3 * math.pi / 4;
    const sweepAngle = 3 * math.pi / 2;

    // Gold tick marks radiating around the dial
    const tickCount = 19;
    final activeTickPaint = Paint()
      ..color = goldColor
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final inactiveTickPaint = Paint()
      ..color = const Color(0x55FDC903)
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < tickCount; i++) {
      final frac = i / (tickCount - 1);
      final angle = startAngle + frac * sweepAngle;
      final p1 = Offset(
        center.dx + (knobRadius + 3) * math.cos(angle),
        center.dy + (knobRadius + 3) * math.sin(angle),
      );
      final p2 = Offset(
        center.dx + outerRadius * math.cos(angle),
        center.dy + outerRadius * math.sin(angle),
      );
      canvas.drawLine(
        p1,
        p2,
        frac <= normalizedValue + 0.01 ? activeTickPaint : inactiveTickPaint,
      );
    }

    // Metallic black knob body
    final bodyPaint = Paint()
      ..shader = const SweepGradient(
        colors: [
          Color(0xFF15120E),
          Color(0xFF332D26),
          Color(0xFF0E0B08),
          Color(0xFF2B251E),
          Color(0xFF15120E),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: knobRadius));
    canvas.drawCircle(center, knobRadius, bodyPaint);

    // Gold outer ring
    final ringPaint = Paint()
      ..color = goldColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(center, knobRadius, ringPaint);

    // Subtle inner bevel circle
    final innerBevel = Paint()
      ..color = const Color(0x28FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    canvas.drawCircle(center, knobRadius - 3.5, innerBevel);

    // Gold indicator line
    final indicatorAngle = startAngle + normalizedValue * sweepAngle;
    final innerPt = Offset(
      center.dx + (knobRadius * 0.25) * math.cos(indicatorAngle),
      center.dy + (knobRadius * 0.25) * math.sin(indicatorAngle),
    );
    final outerPt = Offset(
      center.dx + (knobRadius - 2.5) * math.cos(indicatorAngle),
      center.dy + (knobRadius - 2.5) * math.sin(indicatorAngle),
    );
    final glowPaint = Paint()
      ..color = const Color(0x66FDC903)
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(innerPt, outerPt, glowPaint);

    final indicatorPaint = Paint()
      ..color = goldColor
      ..strokeWidth = 2.3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(innerPt, outerPt, indicatorPaint);
  }

  @override
  bool shouldRepaint(covariant _KnobPainter oldDelegate) {
    return oldDelegate.normalizedValue != normalizedValue ||
        oldDelegate.goldColor != goldColor;
  }
}

class _VinylDiscPainter extends CustomPainter {
  const _VinylDiscPainter({required this.goldColor});

  final Color goldColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // Disc base with metallic sheen
    final basePaint = Paint()
      ..shader = const SweepGradient(
        colors: [
          Color(0xFF0A0805),
          Color(0xFF28221A),
          Color(0xFF090704),
          Color(0xFF241E16),
          Color(0xFF0A0805),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius - 1.5, basePaint);

    // Vinyl groove circles
    final groovePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.85;

    for (double r = 38; r < radius - 7; r += 4.8) {
      groovePaint.color =
          r % 9.6 < 4.8 ? const Color(0x36FFFFFF) : const Color(0x28FDC903);
      canvas.drawCircle(center, r, groovePaint);
    }

    // Outer gold ring
    final outerRing = Paint()
      ..color = goldColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6;
    canvas.drawCircle(center, radius - 1.5, outerRing);
  }

  @override
  bool shouldRepaint(covariant _VinylDiscPainter oldDelegate) {
    return oldDelegate.goldColor != goldColor;
  }
}

class _SpectrumPainter extends CustomPainter {
  const _SpectrumPainter({
    required this.phase,
    required this.level,
    required this.isPlaying,
    required this.goldColor,
  });

  final double phase;
  final double? level;
  final bool isPlaying;
  final Color goldColor;

  @override
  void paint(Canvas canvas, Size size) {
    final baselineY = size.height * 0.56;
    final glowLinePaint = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.transparent,
          goldColor.withAlpha(150),
          goldColor.withAlpha(200),
          goldColor.withAlpha(150),
          Colors.transparent,
        ],
      ).createShader(Rect.fromLTWH(0, baselineY - 1, size.width, 2))
      ..strokeWidth = 1.6;
    canvas.drawLine(
      Offset(0, baselineY),
      Offset(size.width, baselineY),
      glowLinePaint,
    );

    const barCount = 30;
    final barSpacing = size.width / barCount;
    final barWidth = math.max(3.0, barSpacing * 0.62);
    const segmentHeight = 3.2;
    const segmentGap = 2.0;
    const maxSegments = 11;

    for (int i = 0; i < barCount; i++) {
      final normX = (i / (barCount - 1)) * 2 - 1; // -1..1
      // Emphasize left/right wings around the center vinyl disc.
      final wingEnvelope =
          normX.abs() < 0.28 ? 0.35 : (1.0 - (normX.abs() - 0.28) * 0.72);

      final wave1 = math.sin(phase + i * 0.62) * 0.5 + 0.5;
      final wave2 = math.cos(phase * 1.35 - i * 0.41) * 0.5 + 0.5;
      final waveMix = wave1 * 0.62 + wave2 * 0.38;

      final double amplitude;
      if (level != null) {
        final dynamicBoost = 0.18 + (level! * 0.82);
        amplitude = (0.16 + waveMix * 0.84) * dynamicBoost * wingEnvelope;
      } else {
        final idleScale = isPlaying ? 0.78 : 0.30;
        amplitude = (0.18 + waveMix * idleScale) * wingEnvelope;
      }

      final activeSegments =
          (amplitude * maxSegments).round().clamp(1, maxSegments);
      final x = i * barSpacing + (barSpacing - barWidth) / 2;

      // Upper segmented LED bars
      for (int s = 0; s < activeSegments; s++) {
        final y = baselineY - 3 - (s + 1) * (segmentHeight + segmentGap);
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, barWidth, segmentHeight),
          const Radius.circular(1),
        );
        final alpha = (130 + (s / maxSegments) * 115).round().clamp(80, 245);
        canvas.drawRRect(rect, Paint()..color = goldColor.withAlpha(alpha));
      }

      // Soft mirrored reflection below baseline
      final reflectSegments = (activeSegments * 0.55).round().clamp(1, 5);
      for (int s = 0; s < reflectSegments; s++) {
        final y = baselineY + 3 + s * (segmentHeight + segmentGap);
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, barWidth, segmentHeight),
          const Radius.circular(1),
        );
        final alpha = (48 - s * 8).clamp(8, 55);
        canvas.drawRRect(rect, Paint()..color = goldColor.withAlpha(alpha));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter oldDelegate) {
    return oldDelegate.phase != phase ||
        oldDelegate.level != level ||
        oldDelegate.isPlaying != isPlaying ||
        oldDelegate.goldColor != goldColor;
  }
}

class _MiniEqualiserPainter extends CustomPainter {
  const _MiniEqualiserPainter({
    required this.phase,
    required this.level,
    required this.isPlaying,
    required this.goldColor,
  });

  final double phase;
  final double? level;
  final bool isPlaying;
  final Color goldColor;

  @override
  void paint(Canvas canvas, Size size) {
    const count = 9;
    final slot = size.width / count;
    final barW = math.max(1.8, slot * 0.58);
    final paint = Paint()..color = goldColor;

    for (int i = 0; i < count; i++) {
      final wave = math.sin(phase * 1.6 + i * 0.85) * 0.5 + 0.5;
      final scale = level != null
          ? (0.2 + level! * 0.8)
          : (isPlaying ? 0.85 : 0.35);
      final h = math.max(2.5, (0.2 + wave * 0.8) * scale * size.height);
      final x = i * slot + (slot - barW) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - h, barW, h),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MiniEqualiserPainter oldDelegate) {
    return oldDelegate.phase != phase ||
        oldDelegate.level != level ||
        oldDelegate.isPlaying != isPlaying ||
        oldDelegate.goldColor != goldColor;
  }
}

class _CrownPainter extends CustomPainter {
  const _CrownPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(0, h * 0.82)
      ..lineTo(w * 0.08, h * 0.25)
      ..lineTo(w * 0.32, h * 0.55)
      ..lineTo(w * 0.5, h * 0.08)
      ..lineTo(w * 0.68, h * 0.55)
      ..lineTo(w * 0.92, h * 0.25)
      ..lineTo(w, h * 0.82)
      ..close();

    canvas.drawPath(path, paint);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, h * 0.86, w, h * 0.14),
        const Radius.circular(1),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _CrownPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
