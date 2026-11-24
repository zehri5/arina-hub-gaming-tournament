// ARENA HUB #10 AUDIO — soundboard unit tests (review group, 2026-11-22).
//
// Covers lib/audio/wav_decoder.dart (generated WAVs + the 4 REAL .wav
// files from ~/workspace/arena-hub-audio-dsp-external/assets/sounds/,
// read with dart:io — NOT as assets) and lib/audio/soundboard.dart
// (mixInto math, play/stop lifecycle, availability).
//
// The real .wav files are NOT copied into this tree and are NOT in
// pubspec assets (Sameer is listening for approval — the asset copy +
// pubspec lines + end-to-end pad test happen AFTER approval, at merge
// time). These tests read them from the external dir path; if the
// files move, repoint _soundsDir (see SOUNDBOARD_INTEGRATION.md §6).
//
// The local-monitor AudioPlayer is mocked at the method-channel level
// (xyz.luan/audioplayers + xyz.luan/audioplayers.global): the player
// is created by the Soundboard constructor, and without a mock its
// async _create() completes with an error nobody awaits. The mocks
// make every player call a no-op. The Soundboards under test are
// built with playLocally: false so no monitor playback is attempted.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/audio/soundboard.dart';
import 'package:protournament_user/audio/wav_decoder.dart';

// --- Real .wav files (pre-approval location, external dir) ---------------

String get _soundsDir =>
    '${Platform.environment['HOME']}/workspace/arena-hub-audio-dsp-external/assets/sounds';

const Map<SoundPad, String> _realFiles = <SoundPad, String>{
  SoundPad.applause: 'applause.wav',
  SoundPad.airHorn: 'air_horn.wav',
  SoundPad.laugh: 'laugh.wav',
  SoundPad.drumRoll: 'drum_roll.wav',
};

// Spec durations (sounds spec, Sameer 2026-11-22) + exact frame counts
// measured from the files (48 kHz mono, so frames == samples).
const Map<SoundPad, double> _realDurations = <SoundPad, double>{
  SoundPad.applause: 2.50,
  SoundPad.airHorn: 1.65,
  SoundPad.laugh: 2.50,
  SoundPad.drumRoll: 2.75,
};

const Map<SoundPad, int> _realFrameCounts = <SoundPad, int>{
  // Exact data-chunk sizes (each file also carries a 26-byte LIST
  // chunk between fmt and data — the decoder skips it).
  SoundPad.applause: 120000,
  SoundPad.airHorn: 79200,
  SoundPad.laugh: 120000,
  SoundPad.drumRoll: 132000,
};

Uint8List _readRealFile(SoundPad pad) {
  final File file = File('$_soundsDir/${_realFiles[pad]}');
  if (!file.existsSync()) {
    fail('real sound file missing (pre-approval location): ${file.path}');
  }
  return file.readAsBytesSync();
}

// --- WAV builders (synthesized bytes, never asset files) -----------------

Uint8List _chunk(String tag, Uint8List payload,
    {int? declaredSize, bool pad = true}) {
  final BytesBuilder b = BytesBuilder();
  b.add(tag.codeUnits);
  final ByteData size = ByteData(4)
    ..setUint32(0, declaredSize ?? payload.length, Endian.little);
  b.add(size.buffer.asUint8List());
  b.add(payload);
  if (pad && payload.length.isOdd) b.addByte(0);
  return b.toBytes();
}

Uint8List _fmtPayload({
  int format = 1,
  int channels = 1,
  int sampleRate = 48000,
  int bitsPerSample = 16,
}) {
  final ByteData d = ByteData(16);
  d.setUint16(0, format, Endian.little);
  d.setUint16(2, channels, Endian.little);
  d.setUint32(4, sampleRate, Endian.little);
  d.setUint32(8, sampleRate * channels * bitsPerSample ~/ 8, Endian.little);
  d.setUint16(12, channels * bitsPerSample ~/ 8, Endian.little);
  d.setUint16(14, bitsPerSample, Endian.little);
  return d.buffer.asUint8List();
}

Uint8List _fmtExtensiblePayload({int subFormat = 1}) {
  final BytesBuilder b = BytesBuilder();
  b.add(_fmtPayload(format: 0xFFFE));
  final ByteData tail = ByteData(24);
  tail.setUint16(0, 22, Endian.little); // cbSize
  tail.setUint16(2, 16, Endian.little); // valid bits per sample
  tail.setUint32(4, 0, Endian.little); // channel mask
  tail.setUint32(8, subFormat, Endian.little); // SubFormat GUID (first 4)
  b.add(tail.buffer.asUint8List());
  return b.toBytes();
}

Uint8List _dataPayload(List<int> samples) {
  final Uint8List bytes = Uint8List(samples.length * 2);
  final ByteData view = ByteData.sublistView(bytes);
  for (int i = 0; i < samples.length; i++) {
    view.setInt16(i * 2, samples[i], Endian.little);
  }
  return bytes;
}

/// Builds a minimal WAV. [fmtChunk] / [dataChunk] default to the
/// standard 16-bit PCM chunks; pass null to omit a chunk, or pass a
/// custom chunk (e.g. extensible fmt, odd-sized JUNK) via
/// [extraChunks] / [dataBeforeFmt].
Uint8List _buildWav({
  Uint8List? fmtChunk,
  Uint8List? dataChunk,
  List<Uint8List> extraChunks = const <Uint8List>[],
  bool dataBeforeFmt = false,
}) {
  fmtChunk ??= _chunk('fmt ', _fmtPayload());
  dataChunk ??= _chunk('data', _dataPayload(<int>[0]));
  final List<Uint8List> chunks = <Uint8List>[
    if (dataBeforeFmt) dataChunk else fmtChunk,
    ...extraChunks,
    if (dataBeforeFmt) fmtChunk else dataChunk,
  ];
  int bodyLength = 4; // 'WAVE'
  for (final Uint8List c in chunks) {
    bodyLength += c.length;
  }
  final BytesBuilder b = BytesBuilder();
  b.add('RIFF'.codeUnits);
  final ByteData size = ByteData(4)..setUint32(0, bodyLength, Endian.little);
  b.add(size.buffer.asUint8List());
  b.add('WAVE'.codeUnits);
  for (final Uint8List c in chunks) {
    b.add(c);
  }
  return b.toBytes();
}

/// Interleaved int16 sine samples (same tone on every channel).
List<int> _toneInt16({
  required double freq,
  required int rate,
  required double amp,
  required int frames,
  int channels = 1,
}) {
  final List<int> out = <int>[];
  for (int i = 0; i < frames; i++) {
    final double v = amp * math.sin(2 * math.pi * freq * i / rate);
    final int s = (v * 32767).round().clamp(-32768, 32767);
    for (int c = 0; c < channels; c++) {
      out.add(s);
    }
  }
  return out;
}

/// Single-frequency amplitude estimate (Goertzel).
double _goertzel(Float32List samples, double freq, int rate) {
  final double w = 2 * math.pi * freq / rate;
  final double coeff = 2 * math.cos(w);
  double s1 = 0.0;
  double s2 = 0.0;
  for (final double x in samples) {
    final double s0 = x + coeff * s1 - s2;
    s2 = s1;
    s1 = s0;
  }
  final double power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
  return 2 * math.sqrt(power) / samples.length;
}

double _peak(Float32List samples) {
  double p = 0.0;
  for (final double x in samples) {
    final double a = x.abs();
    if (a > p) p = a;
  }
  return p;
}

// --- PCM frame helpers ---------------------------------------------------

Uint8List _frameFromInt16(List<int> samples) {
  final Uint8List bytes = Uint8List(samples.length * 2);
  final ByteData view = ByteData.sublistView(bytes);
  for (int i = 0; i < samples.length; i++) {
    view.setInt16(i * 2, samples[i], Endian.little);
  }
  return bytes;
}

List<int> _int16FromFrame(Uint8List frame) {
  final ByteData view = ByteData.sublistView(frame);
  return List<int>.generate(
    frame.lengthInBytes ~/ 2,
    (int i) => view.getInt16(i * 2, Endian.little),
  );
}

Float32List _constantClip(double value, int samples) =>
    Float32List.fromList(List<double>.filled(samples, value));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel audioplayersChannel =
      MethodChannel('xyz.luan/audioplayers');
  const MethodChannel audioplayersGlobalChannel =
      MethodChannel('xyz.luan/audioplayers.global');

  setUp(() {
    final TestDefaultBinaryMessengerBinding binding =
        TestDefaultBinaryMessengerBinding.instance;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      audioplayersChannel,
      (MethodCall call) async => null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      audioplayersGlobalChannel,
      (MethodCall call) async => null,
    );
  });

  tearDown(() {
    final TestDefaultBinaryMessengerBinding binding =
        TestDefaultBinaryMessengerBinding.instance;
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(audioplayersChannel, null);
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(audioplayersGlobalChannel, null);
  });

  group('WavDecoder (generated WAVs)', () {
    test('48k mono tone decodes exactly', () {
      final List<int> samples = _toneInt16(
        freq: 1000,
        rate: 48000,
        amp: 0.8,
        frames: 4800,
      );
      final Uint8List wav = _buildWav(
        dataChunk: _chunk('data', _dataPayload(samples)),
      );
      final Float32List out = WavDecoder.decodeToMono48k(wav);
      expect(out.length, 4800);
      for (int i = 0; i < samples.length; i++) {
        expect(out[i], closeTo(samples[i] / 32768.0, 1 / 32768.0));
      }
      expect(_peak(out), closeTo(0.8, 0.01));
    });

    test('44.1k mono resamples to 48k, tone preserved', () {
      final List<int> samples = _toneInt16(
        freq: 1000,
        rate: 44100,
        amp: 0.8,
        frames: 4410,
      );
      final Uint8List wav = _buildWav(
        fmtChunk: _chunk(
          'fmt ',
          _fmtPayload(sampleRate: 44100),
        ),
        dataChunk: _chunk('data', _dataPayload(samples)),
      );
      final Float32List out = WavDecoder.decodeToMono48k(wav);
      expect(out.length, 4800);
      expect(_goertzel(out, 1000, 48000), closeTo(0.8, 0.05));
    });

    test('8k mono upsamples x6', () {
      final List<int> samples = _toneInt16(
        freq: 440,
        rate: 8000,
        amp: 0.5,
        frames: 800,
      );
      final Uint8List wav = _buildWav(
        fmtChunk: _chunk('fmt ', _fmtPayload(sampleRate: 8000)),
        dataChunk: _chunk('data', _dataPayload(samples)),
      );
      final Float32List out = WavDecoder.decodeToMono48k(wav);
      expect(out.length, 4800);
      expect(_goertzel(out, 440, 48000), closeTo(0.5, 0.05));
    });

    test('stereo downmix averages (no clipping above 1.0)', () {
      // L = +0.5, R = -0.5 -> mono 0.0.
      final List<int> samples = <int>[];
      for (int i = 0; i < 100; i++) {
        samples.addAll(<int>[16384, -16384]);
      }
      final Uint8List wav = _buildWav(
        fmtChunk: _chunk('fmt ', _fmtPayload(channels: 2)),
        dataChunk: _chunk('data', _dataPayload(samples)),
      );
      final Float32List out = WavDecoder.decodeToMono48k(wav);
      expect(out.length, 100);
      for (final double x in out) {
        expect(x, 0.0);
      }
      // L = R = max -> mono ~1.0, not 2.0.
      final List<int> loud = <int>[];
      for (int i = 0; i < 100; i++) {
        loud.addAll(<int>[32767, 32767]);
      }
      final Uint8List wavLoud = _buildWav(
        fmtChunk: _chunk('fmt ', _fmtPayload(channels: 2)),
        dataChunk: _chunk('data', _dataPayload(loud)),
      );
      final Float32List outLoud = WavDecoder.decodeToMono48k(wavLoud);
      expect(_peak(outLoud), closeTo(32767 / 32768.0, 0.001));
      expect(_peak(outLoud), lessThanOrEqualTo(1.0));
    });

    test('4-channel downmix averages', () {
      final List<int> samples = <int>[];
      for (int i = 0; i < 50; i++) {
        samples.addAll(<int>[32767, 0, 0, 0]);
      }
      final Uint8List wav = _buildWav(
        fmtChunk: _chunk('fmt ', _fmtPayload(channels: 4)),
        dataChunk: _chunk('data', _dataPayload(samples)),
      );
      final Float32List out = WavDecoder.decodeToMono48k(wav);
      expect(out.length, 50);
      for (final double x in out) {
        expect(x, closeTo(32767 / 32768.0 / 4, 0.001));
      }
    });

    test('8-bit PCM throws FormatException', () {
      final Uint8List wav = _buildWav(
        fmtChunk: _chunk('fmt ', _fmtPayload(bitsPerSample: 8)),
      );
      expect(
        () => WavDecoder.decodeToMono48k(wav),
        throwsA(isA<FormatException>()),
      );
    });

    test('float format (3) throws FormatException', () {
      final Uint8List wav = _buildWav(
        fmtChunk: _chunk('fmt ', _fmtPayload(format: 3)),
      );
      expect(
        () => WavDecoder.decodeToMono48k(wav),
        throwsA(isA<FormatException>()),
      );
    });

    test('truncated file throws FormatException', () {
      expect(
        () => WavDecoder.decodeToMono48k(Uint8List(20)),
        throwsA(isA<FormatException>()),
      );
    });

    test('bad RIFF tag throws FormatException', () {
      final Uint8List wav = _buildWav();
      wav[0] = 'X'.codeUnitAt(0);
      expect(
        () => WavDecoder.decodeToMono48k(wav),
        throwsA(isA<FormatException>()),
      );
    });

    test('missing fmt chunk throws FormatException', () {
      // RIFF + WAVE + data only (no fmt).
      final BytesBuilder b = BytesBuilder();
      final Uint8List data = _chunk('data', _dataPayload(<int>[0, 0]));
      b.add('RIFF'.codeUnits);
      final ByteData size = ByteData(4)
        ..setUint32(0, 4 + data.length, Endian.little);
      b.add(size.buffer.asUint8List());
      b.add('WAVE'.codeUnits);
      b.add(data);
      expect(
        () => WavDecoder.decodeToMono48k(b.toBytes()),
        throwsA(isA<FormatException>()),
      );
    });

    test('missing data chunk throws FormatException', () {
      final BytesBuilder b = BytesBuilder();
      final Uint8List fmt = _chunk('fmt ', _fmtPayload());
      b.add('RIFF'.codeUnits);
      final ByteData size = ByteData(4)
        ..setUint32(0, 4 + fmt.length, Endian.little);
      b.add(size.buffer.asUint8List());
      b.add('WAVE'.codeUnits);
      b.add(fmt);
      expect(
        () => WavDecoder.decodeToMono48k(b.toBytes()),
        throwsA(isA<FormatException>()),
      );
    });

    test('empty data chunk throws FormatException', () {
      final Uint8List wav = _buildWav(
        dataChunk: _chunk('data', Uint8List(0)),
      );
      expect(
        () => WavDecoder.decodeToMono48k(wav),
        throwsA(isA<FormatException>()),
      );
    });

    test('WAVE_FORMAT_EXTENSIBLE with PCM subformat decodes', () {
      final List<int> samples = _toneInt16(
        freq: 1000,
        rate: 48000,
        amp: 0.5,
        frames: 480,
      );
      final Uint8List wav = _buildWav(
        fmtChunk: _chunk('fmt ', _fmtExtensiblePayload(subFormat: 1)),
        dataChunk: _chunk('data', _dataPayload(samples)),
      );
      final Float32List out = WavDecoder.decodeToMono48k(wav);
      expect(out.length, 480);
      expect(_peak(out), closeTo(0.5, 0.01));
    });

    test('WAVE_FORMAT_EXTENSIBLE with float subformat throws', () {
      final Uint8List wav = _buildWav(
        fmtChunk: _chunk('fmt ', _fmtExtensiblePayload(subFormat: 3)),
      );
      expect(
        () => WavDecoder.decodeToMono48k(wav),
        throwsA(isA<FormatException>()),
      );
    });

    test('data chunk before fmt chunk still decodes', () {
      final List<int> samples = _toneInt16(
        freq: 1000,
        rate: 48000,
        amp: 0.5,
        frames: 480,
      );
      final Uint8List wav = _buildWav(
        dataChunk: _chunk('data', _dataPayload(samples)),
        dataBeforeFmt: true,
      );
      final Float32List out = WavDecoder.decodeToMono48k(wav);
      expect(out.length, 480);
    });

    test('unknown chunk (LIST) is skipped', () {
      final List<int> samples = _toneInt16(
        freq: 1000,
        rate: 48000,
        amp: 0.5,
        frames: 480,
      );
      final Uint8List wav = _buildWav(
        extraChunks: <Uint8List>[
          _chunk('LIST', Uint8List.fromList(<int>[1, 2, 3, 4])),
        ],
        dataChunk: _chunk('data', _dataPayload(samples)),
      );
      final Float32List out = WavDecoder.decodeToMono48k(wav);
      expect(out.length, 480);
    });

    test('odd-sized chunk + pad byte is skipped correctly', () {
      final List<int> samples = _toneInt16(
        freq: 1000,
        rate: 48000,
        amp: 0.5,
        frames: 480,
      );
      final Uint8List wav = _buildWav(
        extraChunks: <Uint8List>[
          _chunk('JUNK', Uint8List.fromList(<int>[9, 9, 9])),
        ],
        dataChunk: _chunk('data', _dataPayload(samples)),
      );
      final Float32List out = WavDecoder.decodeToMono48k(wav);
      expect(out.length, 480);
      expect(_peak(out), closeTo(0.5, 0.01));
    });

    test('data chunk size 0xFFFFFFFF clamps to actual bytes', () {
      final List<int> samples = _toneInt16(
        freq: 1000,
        rate: 48000,
        amp: 0.5,
        frames: 480,
      );
      final Uint8List wav = _buildWav(
        dataChunk: _chunk(
          'data',
          _dataPayload(samples),
          declaredSize: 0xFFFFFFFF,
        ),
      );
      final Float32List out = WavDecoder.decodeToMono48k(wav);
      expect(out.length, 480);
    });

    test('1-sample 192kHz WAV decodes to 1 sample (D2 fix)', () {
      final Uint8List wav = _buildWav(
        fmtChunk: _chunk('fmt ', _fmtPayload(sampleRate: 192000)),
        dataChunk: _chunk('data', _dataPayload(<int>[16384])),
      );
      final Float32List out = WavDecoder.decodeToMono48k(wav);
      expect(out.length, 1);
      expect(out[0], closeTo(0.5, 0.01));
    });

    test('downsampling filters aliasing (D1 fix)', () {
      // 96 kHz source, 30 kHz tone: above the 24 kHz target Nyquist,
      // it would alias to 18 kHz. Without the pre-filter the alias
      // measured 0.80 — FULL amplitude (integer-ratio resampling is
      // pure decimation, no filtering at all); with the filter it
      // must be a small fraction of that.
      final List<int> samples = _toneInt16(
        freq: 30000,
        rate: 96000,
        amp: 0.8,
        frames: 9600,
      );
      final Uint8List wav = _buildWav(
        fmtChunk: _chunk('fmt ', _fmtPayload(sampleRate: 96000)),
        dataChunk: _chunk('data', _dataPayload(samples)),
      );
      final Float32List out = WavDecoder.decodeToMono48k(wav);
      expect(out.length, 4800);
      final double alias = _goertzel(out, 18000, 48000);
      expect(alias, lessThan(0.15));
      // And the passband survives: a 1 kHz tone at 96 kHz passes.
      final List<int> low = _toneInt16(
        freq: 1000,
        rate: 96000,
        amp: 0.8,
        frames: 9600,
      );
      final Uint8List wavLow = _buildWav(
        fmtChunk: _chunk('fmt ', _fmtPayload(sampleRate: 96000)),
        dataChunk: _chunk('data', _dataPayload(low)),
      );
      final Float32List outLow = WavDecoder.decodeToMono48k(wavLow);
      expect(_goertzel(outLow, 1000, 48000), greaterThan(0.75));
    });

    test('0 channels and 0 sample rate throw FormatException', () {
      final Uint8List wavCh = _buildWav(
        fmtChunk: _chunk('fmt ', _fmtPayload(channels: 0)),
      );
      expect(
        () => WavDecoder.decodeToMono48k(wavCh),
        throwsA(isA<FormatException>()),
      );
      final Uint8List wavRate = _buildWav(
        fmtChunk: _chunk('fmt ', _fmtPayload(sampleRate: 0)),
      );
      expect(
        () => WavDecoder.decodeToMono48k(wavRate),
        throwsA(isA<FormatException>()),
      );
    });

    test('trailing partial frame is dropped', () {
      // 3 bytes of data = 1 full frame + 1 stray byte.
      final Uint8List wav = _buildWav(
        dataChunk: _chunk(
          'data',
          Uint8List.fromList(<int>[0x00, 0x40, 0x99]),
        ),
      );
      final Float32List out = WavDecoder.decodeToMono48k(wav);
      expect(out.length, 1);
      expect(out[0], closeTo(0.5, 0.001));
    });
  });

  group('WavDecoder (REAL .wav files)', () {
    for (final SoundPad pad in SoundPad.values) {
      test('${_realFiles[pad]} decodes cleanly', () {
        final Uint8List bytes = _readRealFile(pad);
        final Float32List out = WavDecoder.decodeToMono48k(bytes);
        expect(out.length, _realFrameCounts[pad]);
        expect(
          out.length / 48000.0,
          closeTo(_realDurations[pad]!, 0.01),
        );
        double peak = 0.0;
        double first100msPeak = 0.0;
        int firstAudible = -1;
        for (int i = 0; i < out.length; i++) {
          final double x = out[i];
          expect(x.isFinite, isTrue, reason: 'NaN/Inf at sample $i');
          expect(x.abs(), lessThanOrEqualTo(1.0));
          final double a = x.abs();
          if (a > peak) peak = a;
          if (i < 4800 && a > first100msPeak) first100msPeak = a;
          if (firstAudible < 0 && a > 0.01) firstAudible = i;
        }
        // Peak-normalized to -1 dBFS (~0.89): loud but never clipped.
        expect(peak, greaterThan(0.5));
        expect(peak, lessThan(0.95));
        // No leading silence: audible sound starts within 20 ms
        // (measured worst case: air_horn at 8.6 ms — a short onset
        // ramp, not a silent gap; drum_roll builds by design but is
        // audible at 2.2 ms).
        expect(firstAudible, greaterThanOrEqualTo(0));
        expect(firstAudible, lessThan(960));
        expect(first100msPeak, greaterThan(0.1));
      });
    }
  });

  group('Soundboard', () {
    late Soundboard soundboard;

    setUp(() {
      soundboard = Soundboard(playLocally: false);
    });

    tearDown(() async {
      soundboard.dispose();
      // The Soundboard disposes its AudioPlayer fire-and-forget; let
      // that future finish while the channel mocks are still
      // registered — the outer tearDown clears them right after this
      // one returns, and a dispose that lands after that throws
      // MissingPluginException as an unhandled async error.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    });

    test('pads unavailable before load, available after inject', () {
      for (final SoundPad pad in SoundPad.values) {
        expect(soundboard.isPadAvailable(pad), isFalse);
      }
      expect(soundboard.clipDuration(SoundPad.applause), isNull);
      expect(soundboard.decodedClip(SoundPad.applause), isNull);
      soundboard.debugInjectClip(
        SoundPad.applause,
        _constantClip(0.5, 48000),
      );
      expect(soundboard.isPadAvailable(SoundPad.applause), isTrue);
      expect(soundboard.isPadAvailable(SoundPad.laugh), isFalse);
      expect(
        soundboard.clipDuration(SoundPad.applause),
        const Duration(seconds: 1),
      );
      expect(soundboard.decodedClip(SoundPad.applause)!.length, 48000);
    });

    test('init with missing assets marks all pads unavailable, no crash',
        () async {
      // The 4 .wavs ARE in the tree now (approved + baked 2026-11-22),
      // so simulate missing assets by failing the flutter/assets
      // channel — init() must swallow the failure per pad.
      final TestDefaultBinaryMessengerBinding binding =
          TestDefaultBinaryMessengerBinding.instance;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter/assets'),
        (MethodCall call) async => throw MissingPluginException(),
      );
      try {
        await soundboard.init();
        for (final SoundPad pad in SoundPad.values) {
          expect(soundboard.isPadAvailable(pad), isFalse);
        }
      } finally {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('flutter/assets'),
          null,
        );
      }
    });

    test('concurrent init() calls share one decode pass (D3 fix)',
        () async {
      int notifications = 0;
      soundboard.addListener(() {
        notifications++;
      });
      await Future.wait(<Future<void>>[
        soundboard.init(),
        soundboard.init(),
      ]);
      // One decode pass -> exactly one notify at the end.
      expect(notifications, 1);
    });

    test('play + mixInto mixes clip x gain into a silence frame', () {
      soundboard.debugInjectClip(
        SoundPad.applause,
        _constantClip(0.5, 48000),
      );
      soundboard.play(SoundPad.applause);
      expect(soundboard.isPlaying, isTrue);
      expect(soundboard.activePad, SoundPad.applause);
      final Uint8List frame = _frameFromInt16(
        List<int>.filled(480, 0),
      );
      soundboard.mixInto(frame);
      final List<int> mixed = _int16FromFrame(frame);
      // gain = pad 0.8 x master 1.0 = 0.8; 0.5 x 0.8 = 0.4 ->
      // round(0.4 x 32767) = 13107.
      for (final int s in mixed) {
        expect(s, 13107);
      }
    });

    test('mixInto sums with the mic and soft-limits (tanh, not clip)',
        () {
      soundboard.debugInjectClip(
        SoundPad.applause,
        _constantClip(0.5, 48000),
      );
      soundboard.setPadVolume(SoundPad.applause, 1.0);
      soundboard.play(SoundPad.applause);
      final Uint8List frame = _frameFromInt16(
        List<int>.filled(480, 16384), // mic 0.5
      );
      soundboard.mixInto(frame);
      final List<int> mixed = _int16FromFrame(frame);
      // mic 0.5 + clip 0.5 x gain 1.0 = 1.0 -> soft-limit:
      // 0.9 + 0.1 x tanh(1.0) = 0.97616 -> 31986. A hard clip would
      // give 32767, so this pins the tanh knee.
      final double expected =
          (0.9 + 0.1 * _tanh(1.0)) * 32767.0;
      for (final int s in mixed) {
        expect(s, closeTo(expected.round(), 1));
        expect(s, lessThan(32767));
      }
    });

    test('mixInto saturates without wraparound', () {
      soundboard.debugInjectClip(
        SoundPad.airHorn,
        _constantClip(0.9, 48000),
      );
      soundboard.setPadVolume(SoundPad.airHorn, 1.0);
      soundboard.play(SoundPad.airHorn);
      final Uint8List frame = _frameFromInt16(
        List<int>.filled(480, 29491), // mic ~0.9
      );
      soundboard.mixInto(frame);
      final List<int> mixed = _int16FromFrame(frame);
      for (final int s in mixed) {
        expect(s, 32767); // asymptotic, positive, never wrapped
      }
    });

    test('clip ending mid-frame leaves the mic tail untouched', () {
      soundboard.debugInjectClip(
        SoundPad.laugh,
        _constantClip(0.5, 10),
      );
      soundboard.play(SoundPad.laugh);
      final Uint8List frame = _frameFromInt16(
        List<int>.filled(480, 1000),
      );
      soundboard.mixInto(frame);
      final List<int> mixed = _int16FromFrame(frame);
      // First 10 samples mixed (mic 1000 + clip 0.5 x 0.8).
      final int expectedFirst =
          ((1000 / 32768.0 + 0.4) * 32767.0).round();
      for (int i = 0; i < 10; i++) {
        expect(mixed[i], closeTo(expectedFirst, 1));
      }
      // The rest is the untouched mic.
      for (int i = 10; i < 480; i++) {
        expect(mixed[i], 1000);
      }
      expect(soundboard.isPlaying, isFalse);
      expect(soundboard.activePad, isNull);
    });

    test('playhead advances across frames', () {
      // Ramp clip: sample i = i / 960, so frame 2 starts at 0.5.
      final Float32List ramp = Float32List(960);
      for (int i = 0; i < 960; i++) {
        ramp[i] = i / 960.0;
      }
      soundboard.debugInjectClip(SoundPad.drumRoll, ramp);
      soundboard.setPadVolume(SoundPad.drumRoll, 1.0);
      soundboard.play(SoundPad.drumRoll);
      final Uint8List frame0 = _frameFromInt16(
        List<int>.filled(480, 0),
      );
      soundboard.mixInto(frame0);
      expect(_int16FromFrame(frame0)[0], 0);
      final Uint8List frame1 = _frameFromInt16(
        List<int>.filled(480, 0),
      );
      soundboard.mixInto(frame1);
      // Frame 1 starts at ramp sample 480 = 0.5 -> 16383.
      expect(_int16FromFrame(frame1)[0], closeTo(16383, 1));
      expect(soundboard.isPlaying, isFalse); // 960 samples = 2 frames
    });

    test('stop() halts mid-play; next mixInto is a no-op', () {
      soundboard.debugInjectClip(
        SoundPad.applause,
        _constantClip(0.5, 48000),
      );
      soundboard.play(SoundPad.applause);
      soundboard.mixInto(_frameFromInt16(List<int>.filled(480, 0)));
      expect(soundboard.isPlaying, isTrue);
      soundboard.stop();
      expect(soundboard.isPlaying, isFalse);
      expect(soundboard.activePad, isNull);
      final Uint8List frame = _frameFromInt16(
        List<int>.filled(480, 777),
      );
      soundboard.mixInto(frame);
      for (final int s in _int16FromFrame(frame)) {
        expect(s, 777);
      }
    });

    test('play() replaces the active pad', () {
      soundboard.debugInjectClip(
        SoundPad.applause,
        _constantClip(0.5, 48000),
      );
      soundboard.debugInjectClip(
        SoundPad.laugh,
        _constantClip(0.25, 48000),
      );
      soundboard.play(SoundPad.applause);
      soundboard.play(SoundPad.laugh);
      expect(soundboard.activePad, SoundPad.laugh);
      final Uint8List frame = _frameFromInt16(
        List<int>.filled(480, 0),
      );
      soundboard.mixInto(frame);
      // laugh 0.25 x gain 0.8 = 0.2 -> round(0.2 x 32767) = 6553.
      for (final int s in _int16FromFrame(frame)) {
        expect(s, 6553);
      }
    });

    test('play() restarts the same pad from the top', () {
      final Float32List ramp = Float32List(960);
      for (int i = 0; i < 960; i++) {
        ramp[i] = i / 960.0;
      }
      soundboard.debugInjectClip(SoundPad.applause, ramp);
      soundboard.setPadVolume(SoundPad.applause, 1.0);
      soundboard.play(SoundPad.applause);
      soundboard.mixInto(_frameFromInt16(List<int>.filled(480, 0)));
      soundboard.play(SoundPad.applause); // restart
      final Uint8List frame = _frameFromInt16(
        List<int>.filled(480, 0),
      );
      soundboard.mixInto(frame);
      expect(_int16FromFrame(frame)[0], 0); // back at ramp sample 0
    });

    test('volume changes apply live mid-play', () {
      soundboard.debugInjectClip(
        SoundPad.applause,
        _constantClip(0.5, 48000),
      );
      soundboard.play(SoundPad.applause);
      soundboard.setPadVolume(SoundPad.applause, 0.5);
      final Uint8List frame = _frameFromInt16(
        List<int>.filled(480, 0),
      );
      soundboard.mixInto(frame);
      // 0.5 clip x pad 0.5 x master 1.0 = 0.25 -> 8192.
      for (final int s in _int16FromFrame(frame)) {
        expect(s, 8192);
      }
      soundboard.setMasterVolume(0.5);
      final Uint8List frame2 = _frameFromInt16(
        List<int>.filled(480, 0),
      );
      soundboard.mixInto(frame2);
      // 0.5 x 0.5 x 0.5 = 0.125 -> 4096.
      for (final int s in _int16FromFrame(frame2)) {
        expect(s, 4096);
      }
    });

    test('gain 0 leaves the mic bit-identical, clip still finishes (D8)',
        () {
      soundboard.debugInjectClip(
        SoundPad.applause,
        _constantClip(0.5, 480),
      );
      soundboard.setMasterVolume(0.0);
      soundboard.play(SoundPad.applause);
      // Loud mic peaks: the old code soft-limited anything above 0.9
      // even with the soundboard muted. 480-sample frame so the
      // 480-sample clip finishes in this one mixInto.
      const List<int> pattern = <int>[
        30000,
        -30000,
        32767,
        -32768,
        16384,
        -1,
        0,
        12345,
      ];
      final List<int> mic =
          List<int>.generate(480, (int i) => pattern[i % pattern.length]);
      final Uint8List frame = _frameFromInt16(mic);
      final Uint8List before = Uint8List.fromList(frame);
      soundboard.mixInto(frame);
      expect(frame, before);
      expect(soundboard.isPlaying, isFalse); // 480 samples = 1 frame
    });

    test('play() finishes by timer without mixInto (route A, D9 fix)',
        () async {
      // In route A the live mix runs natively and mixInto() is never
      // called — the playback must still finish on its own, or the
      // pad's "playing" state (and underline) would stick forever.
      soundboard.debugInjectClip(
        SoundPad.applause,
        _constantClip(0.5, 480), // 10 ms clip
      );
      soundboard.play(SoundPad.applause);
      expect(soundboard.isPlaying, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(soundboard.isPlaying, isFalse);
      expect(soundboard.activePad, isNull);
    });

    test('stop() cancels the finish timer', () async {
      soundboard.debugInjectClip(
        SoundPad.applause,
        _constantClip(0.5, 480), // 10 ms clip
      );
      soundboard.play(SoundPad.applause);
      soundboard.stop();
      // The timer would have fired by now; nothing crashes and the
      // pad stays stopped (no spurious re-finish notify).
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(soundboard.isPlaying, isFalse);
    });

    test('mixInto when idle is a no-op', () {
      final Uint8List frame = _frameFromInt16(
        List<int>.filled(480, 1234),
      );
      soundboard.mixInto(frame);
      for (final int s in _int16FromFrame(frame)) {
        expect(s, 1234);
      }
    });

    test('play() on an unavailable pad is a no-op', () {
      soundboard.play(SoundPad.applause);
      expect(soundboard.isPlaying, isFalse);
      expect(soundboard.activePad, isNull);
    });

    test('play() with an empty clip is a no-op', () {
      soundboard.debugInjectClip(
        SoundPad.applause,
        Float32List(0),
      );
      // Empty clip: unavailable AND unplayable (available <=> playable).
      expect(soundboard.isPadAvailable(SoundPad.applause), isFalse);
      soundboard.play(SoundPad.applause);
      expect(soundboard.isPlaying, isFalse);
    });

    test('dispose stops playback and clears availability', () {
      soundboard.debugInjectClip(
        SoundPad.applause,
        _constantClip(0.5, 48000),
      );
      soundboard.play(SoundPad.applause);
      expect(soundboard.isPlaying, isTrue);
      soundboard.dispose();
      expect(soundboard.isPadAvailable(SoundPad.applause), isFalse);
      soundboard.play(SoundPad.applause); // no-op after dispose
      expect(soundboard.isPlaying, isFalse);
    });

    test('REAL files load into the Soundboard: all 4 pads available', () {
      for (final SoundPad pad in SoundPad.values) {
        final Float32List decoded =
            WavDecoder.decodeToMono48k(_readRealFile(pad));
        soundboard.debugInjectClip(pad, decoded);
      }
      for (final SoundPad pad in SoundPad.values) {
        expect(soundboard.isPadAvailable(pad), isTrue);
        final Duration? duration = soundboard.clipDuration(pad);
        expect(duration, isNotNull);
        expect(
          duration!.inMicroseconds / 1000000.0,
          closeTo(_realDurations[pad]!, 0.01),
        );
      }
      // And the full Dart path works with a real clip: play applause
      // into a silence frame and the frame carries the applause.
      soundboard.play(SoundPad.applause);
      final Uint8List frame = _frameFromInt16(
        List<int>.filled(480, 0),
      );
      soundboard.mixInto(frame);
      final List<int> mixed = _int16FromFrame(frame);
      int peak = 0;
      for (final int s in mixed) {
        if (s.abs() > peak) peak = s.abs();
      }
      expect(peak, greaterThan(1000));
      expect(soundboard.isPlaying, isTrue);
    });
  });
}

double _tanh(double x) {
  final double e2x = math.exp(2.0 * x);
  return (e2x - 1.0) / (e2x + 1.0);
}
