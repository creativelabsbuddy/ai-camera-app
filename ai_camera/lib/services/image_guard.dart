import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// v11 Pro Night hallucination guard (mirrors enhance-server/image_guard.py).
///
/// 1. [NightSignal.tooDark]: almost no signal in the merged night frame →
///    Pro Night does NOT call the AI (it would invent content), charges
///    nothing and offers Normal Night / flash.
/// 2. [structureSimilarity]: after the AI, compare edge structure of input
///    and output on a small contrast-normalised grayscale proxy. Below
///    [kStructureMin] the result is rejected (no charge, Retry offered).
const double kDarkMeanMax = 0.035;
const double kDarkP99Max = 0.10;
const double kDarkBrightFracMax = 0.004;
const double kBrightLevel = 0.25;
const double kStructureMin = 0.50;
const int kSignalProxyW = 160;
const int kStructureProxyW = 64;

const kTooDarkMessage =
    'Too dark for Pro Night. Use Normal Night or turn on flash.';
const kStructureChangedMessage =
    'AI changed the scene, so the result was rejected. No credits used.';

class NightSignal {
  const NightSignal(this.mean, this.brightFrac, this.p99);
  final double mean;
  final double brightFrac;
  final double p99;

  bool get tooDark =>
      mean < kDarkMeanMax &&
      p99 < kDarkP99Max &&
      brightFrac < kDarkBrightFracMax;

  @override
  String toString() =>
      'NightSignal(mean=${mean.toStringAsFixed(4)}, '
      'bright=${brightFrac.toStringAsFixed(4)}, p99=${p99.toStringAsFixed(3)})';
}

/// [values] = 8-bit grayscale samples.
NightSignal nightSignalFromValues(List<int> values) {
  final n = math.max(1, values.length);
  var sum = 0;
  var bright = 0;
  for (final v in values) {
    sum += v;
    if (v / 255.0 > kBrightLevel) bright++;
  }
  final sorted = [...values]..sort();
  final p99 = sorted.isEmpty
      ? 0.0
      : sorted[math.min(
              sorted.length - 1,
              (0.99 * (sorted.length - 1)).floor(),
            )] /
            255.0;
  return NightSignal(sum / n / 255.0, bright / n, p99);
}

List<double> _normalised(List<double> px) {
  final n = px.length;
  if (n == 0) return px;
  final m = px.reduce((a, b) => a + b) / n;
  var v = 0.0;
  for (final p in px) {
    v += (p - m) * (p - m);
  }
  var sd = math.sqrt(v / n);
  if (sd == 0) sd = 1;
  return [for (final p in px) (p - m) / sd];
}

/// 3×3 box blur (edge-clamped) = Pillow BoxBlur(1).
List<double> boxBlur1(List<double> px, int w, int h) {
  final out = List<double>.filled(px.length, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var s = 0.0;
      for (var dy = -1; dy <= 1; dy++) {
        final yy = (y + dy).clamp(0, h - 1);
        for (var dx = -1; dx <= 1; dx++) {
          s += px[yy * w + (x + dx).clamp(0, w - 1)];
        }
      }
      out[y * w + x] = s / 9;
    }
  }
  return out;
}

/// Cosine similarity of the gradient fields of two same-size grayscale
/// proxies (1 = same structure). Pure → unit tested.
double gradientSimilarity(List<double> a, List<double> b, int w, int h) {
  var num = 0.0, da = 0.0, db = 0.0;
  for (var y = 0; y < h - 1; y++) {
    final r = y * w;
    for (var x = 0; x < w - 1; x++) {
      final i = r + x;
      final ax = a[i + 1] - a[i], ay = a[i + w] - a[i];
      final bx = b[i + 1] - b[i], by = b[i + w] - b[i];
      num += ax * bx + ay * by;
      da += ax * ax + ay * ay;
      db += bx * bx + by * by;
    }
  }
  if (da <= 1e-9 || db <= 1e-9) {
    return da <= 1e-9 && db <= 1e-9 ? 1 : 0;
  }
  return num / math.sqrt(da * db);
}

/// Structure similarity of two grayscale proxies of the same size.
double structureSimilarity(List<double> src, List<double> out, int w, int h) =>
    gradientSimilarity(
      _normalised(boxBlur1(src, w, h)),
      _normalised(boxBlur1(out, w, h)),
      w,
      h,
    );

class GrayProxy {
  const GrayProxy(this.values, this.width, this.height);
  final List<double> values; // 0..255
  final int width;
  final int height;
}

/// Decodes [bytes] (JPEG / PNG) to a grayscale proxy [width] px wide (or
/// exactly [width]×[height] when given) with the platform codec.
Future<GrayProxy> grayProxy(Uint8List bytes, int width, {int? height}) async {
  final codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: width,
    targetHeight: height,
  );
  final frame = await codec.getNextFrame();
  final im = frame.image;
  final data = await im.toByteData(format: ui.ImageByteFormat.rawRgba);
  final w = im.width, h = im.height;
  im.dispose();
  codec.dispose();
  final px = data!.buffer.asUint8List();
  final out = List<double>.filled(w * h, 0);
  for (var i = 0; i < w * h; i++) {
    out[i] = 0.299 * px[i * 4] + 0.587 * px[i * 4 + 1] + 0.114 * px[i * 4 + 2];
  }
  return GrayProxy(out, w, h);
}

/// Darkness signal of an encoded image (160 px proxy, like the server).
Future<NightSignal> nightSignalOf(Uint8List bytes) async {
  final g = await grayProxy(bytes, kSignalProxyW);
  return nightSignalFromValues([for (final v in g.values) v.round()]);
}

/// (ok, similarity) for an AI result vs. its input.
Future<(bool, double)> structureCheck(Uint8List src, Uint8List out) async {
  final a = await grayProxy(src, kStructureProxyW);
  final b = await grayProxy(out, a.width, height: a.height);
  final s = structureSimilarity(a.values, b.values, a.width, a.height);
  return (s >= kStructureMin, s);
}

// ---------------------------------------------------------------------------
// v11.31 zoom framing check (free, on device): does the AI result keep the
// framing of the final zoomed photo? Shift-tolerant edge similarity on a
// small blurred proxy (mirrors image_guard.py framing_similarity).
// ---------------------------------------------------------------------------

const int kFramingProxyW = 48;

/// Max shift tried (proxy px, ≈ ±6 % of the width).
const int kFramingMaxShift = 3;

/// Below this the result is rejected (a reference's wide view scores ~0).
const double kFramingMin = 0.35;

/// Best gradient cosine similarity over shifts of ±[maxShift]. Pure.
double framingSimilarity(
  List<double> src,
  List<double> out,
  int w,
  int h, {
  int maxShift = kFramingMaxShift,
}) {
  final a = _normalised(boxBlur1(boxBlur1(src, w, h), w, h));
  final b = _normalised(boxBlur1(boxBlur1(out, w, h), w, h));
  var best = -1.0;
  for (var dy = -maxShift; dy <= maxShift; dy++) {
    for (var dx = -maxShift; dx <= maxShift; dx++) {
      var num = 0.0, da = 0.0, db = 0.0;
      for (var y = maxShift; y < h - 1 - maxShift; y++) {
        for (var x = maxShift; x < w - 1 - maxShift; x++) {
          final i = y * w + x;
          final j = (y + dy) * w + x + dx;
          final ax = a[i + 1] - a[i], ay = a[i + w] - a[i];
          final bx = b[j + 1] - b[j], by = b[j + w] - b[j];
          num += ax * bx + ay * by;
          da += ax * ax + ay * ay;
          db += bx * bx + by * by;
        }
      }
      final s = da <= 1e-9 || db <= 1e-9
          ? (da <= 1e-9 && db <= 1e-9 ? 1.0 : 0.0)
          : num / math.sqrt(da * db);
      if (s > best) best = s;
    }
  }
  return best;
}

/// (ok, similarity) of an AI zoom result vs. the final photo.
Future<(bool, double)> framingCheck(Uint8List src, Uint8List out) async {
  final a = await grayProxy(src, kFramingProxyW);
  final b = await grayProxy(out, a.width, height: a.height);
  final s = framingSimilarity(a.values, b.values, a.width, a.height);
  return (s >= kFramingMin, s);
}
