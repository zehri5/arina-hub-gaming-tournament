import 'dart:math' as math;
import 'dart:typed_data';

/// Pure-Dart 16-bit PCM WAV decoder that outputs 48 kHz mono normalized
/// floating-point samples in the range [-1.0, 1.0].
class WavDecoder {
  static const int targetSampleRate = 48000;

  const WavDecoder._();

  /// Decodes a 16-bit PCM WAV file into a 48 kHz mono [Float32List].
  ///
  /// Supports any positive sample rate and 1+ channels (stereo/multi-channel
  /// audio is downmixed to mono by averaging channels, then linearly resampled
  /// to 48,000 Hz). Throws [FormatException] if [bytes] is not a valid 16-bit
  /// PCM WAV.
  static Float32List decodeToMono48k(Uint8List bytes) {
    if (bytes.lengthInBytes < 44) {
      throw FormatException(
        'WAV file too short (${bytes.lengthInBytes} bytes).',
      );
    }

    final ByteData view = ByteData.sublistView(bytes);

    if (!_matchesTag(bytes, 0, 'RIFF') || !_matchesTag(bytes, 8, 'WAVE')) {
      throw const FormatException('Invalid RIFF/WAVE header.');
    }

    int? audioFormat;
    int? channels;
    int? sampleRate;
    int? bitsPerSample;
    int? dataOffset;
    int dataLength = 0;

    int offset = 12;
    while (offset + 8 <= bytes.lengthInBytes) {
      final int chunkSize = view.getUint32(offset + 4, Endian.little);
      final int payloadStart = offset + 8;
      if (payloadStart > bytes.lengthInBytes) {
        break;
      }

      final int payloadEnd = (payloadStart + chunkSize > bytes.lengthInBytes)
          ? bytes.lengthInBytes
          : payloadStart + chunkSize;
      final int availableSize = payloadEnd - payloadStart;

      if (_matchesTag(bytes, offset, 'fmt ')) {
        if (availableSize < 16) {
          throw const FormatException('Truncated WAV fmt chunk.');
        }
        int formatCode = view.getUint16(payloadStart, Endian.little);
        final int ch = view.getUint16(payloadStart + 2, Endian.little);
        final int sr = view.getUint32(payloadStart + 4, Endian.little);
        final int bps = view.getUint16(payloadStart + 14, Endian.little);

        // Handle WAVE_FORMAT_EXTENSIBLE (0xFFFE) when SubFormat is PCM (0x0001).
        if (formatCode == 0xFFFE && availableSize >= 40) {
          final int subFormat = view.getUint32(payloadStart + 24, Endian.little);
          if (subFormat == 1) {
            formatCode = 1;
          }
        }

        audioFormat = formatCode;
        channels = ch;
        sampleRate = sr;
        bitsPerSample = bps;
      } else if (_matchesTag(bytes, offset, 'data')) {
        dataOffset = payloadStart;
        dataLength = availableSize;
      }

      // RIFF chunks are word-aligned (padded to an even byte boundary).
      final int paddedSize = chunkSize + (chunkSize & 1);
      offset = payloadStart + paddedSize;
    }

    if (audioFormat == null ||
        channels == null ||
        sampleRate == null ||
        bitsPerSample == null) {
      throw const FormatException('Missing WAV fmt chunk.');
    }
    if (audioFormat != 1) {
      throw FormatException(
        'Unsupported WAV format ($audioFormat); expected PCM (1).',
      );
    }
    if (bitsPerSample != 16) {
      throw FormatException(
        'Unsupported WAV bit depth ($bitsPerSample); expected 16-bit.',
      );
    }
    if (channels < 1) {
      throw FormatException('Invalid WAV channel count ($channels).');
    }
    if (sampleRate <= 0) {
      throw FormatException('Invalid WAV sample rate ($sampleRate).');
    }
    if (dataOffset == null || dataLength <= 0) {
      throw const FormatException('Missing or empty WAV data chunk.');
    }

    final int bytesPerFrame = channels * 2;
    final int frameCount = dataLength ~/ bytesPerFrame;
    if (frameCount <= 0) {
      throw const FormatException('WAV data chunk contains no audio frames.');
    }

    final Float32List mono = Float32List(frameCount);
    final double invScale = 1.0 / (channels * 32768.0);

    int bytePos = dataOffset;
    if (channels == 1) {
      for (int i = 0; i < frameCount; i++) {
        mono[i] = view.getInt16(bytePos, Endian.little) * invScale;
        bytePos += 2;
      }
    } else if (channels == 2) {
      for (int i = 0; i < frameCount; i++) {
        final int left = view.getInt16(bytePos, Endian.little);
        final int right = view.getInt16(bytePos + 2, Endian.little);
        mono[i] = (left + right) * invScale;
        bytePos += 4;
      }
    } else {
      for (int i = 0; i < frameCount; i++) {
        int sum = 0;
        for (int c = 0; c < channels; c++) {
          sum += view.getInt16(bytePos, Endian.little);
          bytePos += 2;
        }
        mono[i] = sum * invScale;
      }
    }

    if (sampleRate == targetSampleRate) {
      return mono;
    }

    if (sampleRate > targetSampleRate) {
      // DOWNSAMPLING FIX (review 2026-11-22): linear interpolation alone
      // does not suppress content above the 24 kHz target Nyquist — for
      // an integer ratio it is pure decimation (every sample lands on an
      // integer source position, frac = 0), so a 30 kHz tone in a 96 kHz
      // file aliased into the output at FULL amplitude (measured 0.80
      // for a 0.8 input with the pre-fix code). Pre-filter with a
      // two-pass moving average (triangular kernel) before
      // interpolating. Upsampling needs no filter (no new content is
      // created above the source Nyquist).
      final int ratio = (sampleRate / targetSampleRate).round();
      final int width = math.max(2, (ratio * 1.5).round()).clamp(2, 64);
      return _resampleLinear(
        _antiAliasFilter(mono, width),
        sampleRate,
        targetSampleRate,
      );
    }

    return _resampleLinear(mono, sampleRate, targetSampleRate);
  }

  /// Two-pass moving average (triangular kernel) used as a cheap
  /// anti-alias filter before decimation. Edges replicate the nearest
  /// sample (clamped indices) so DC and the clip start/end are not
  /// dipped. Runs in O(n) per pass via a sliding window sum.
  static Float32List _antiAliasFilter(Float32List input, int width) {
    final int n = input.length;
    Float32List current = input;
    for (int pass = 0; pass < 2; pass++) {
      final Float32List out = Float32List(n);
      final int half = width ~/ 2;
      double sum = 0.0;
      for (int k = 0; k < width; k++) {
        sum += current[_clampIndex(k - half, n)];
      }
      for (int i = 0; i < n; i++) {
        out[i] = sum / width;
        sum -= current[_clampIndex(i - half, n)];
        sum += current[_clampIndex(i - half + width, n)];
      }
      current = out;
    }
    return current;
  }

  static int _clampIndex(int i, int n) => i < 0 ? 0 : (i >= n ? n - 1 : i);

  static Float32List _resampleLinear(
    Float32List input,
    int sourceRate,
    int destRate,
  ) {
    final int inputLength = input.length;
    // A valid but tiny high-rate clip (e.g. 1 sample at 192 kHz) used to
    // round to 0 output samples and decode as an empty clip; clamp to at
    // least 1 sample so a decodable WAV never decodes empty.
    final int outputLength =
        math.max(1, ((inputLength * destRate) / sourceRate).round());

    final Float32List output = Float32List(outputLength);
    final double step = sourceRate / destRate;

    for (int i = 0; i < outputLength; i++) {
      final double srcPos = i * step;
      final int idx0 = srcPos.floor();
      if (idx0 >= inputLength - 1) {
        output[i] = input[inputLength - 1];
      } else {
        final double frac = srcPos - idx0;
        final double s0 = input[idx0];
        final double s1 = input[idx0 + 1];
        output[i] = s0 + (s1 - s0) * frac;
      }
    }

    return output;
  }

  static bool _matchesTag(Uint8List bytes, int offset, String tag) {
    if (offset + 4 > bytes.lengthInBytes) return false;
    return bytes[offset] == tag.codeUnitAt(0) &&
        bytes[offset + 1] == tag.codeUnitAt(1) &&
        bytes[offset + 2] == tag.codeUnitAt(2) &&
        bytes[offset + 3] == tag.codeUnitAt(3);
  }
}
