import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'image_register.dart';
import 'zoom_tracker.dart';

/// v11.60 the zoom tracker OFF the UI isolate. One long-lived worker
/// isolate owns the [ZoomTracker]; the UI sends analysis proxies (~7 KB).
/// • at most ONE update in flight; while busy only the NEWEST frame is
///   kept (older pending frames are dropped, counted);
/// • [reset] / [disable] bump an epoch: replies computed before it are
///   ignored, so a stale chain can never come back after a reset;
/// • the UI reads [snapshot] (last reply) synchronously.

class TrackSnapshot {
  const TrackSnapshot({
    required this.epoch,
    required this.state,
    this.rootToCur,
    this.curAt,
    this.rootAspect,
    this.debugText = 'track idle',
    this.lostReason,
    this.note = '',
  });
  static const idle = TrackSnapshot(epoch: 0, state: TrackState.idle);

  final int epoch;
  final TrackState state;
  final Similarity? rootToCur;
  final DateTime? curAt;
  final double? rootAspect;
  final String debugText;
  final String? lostReason;
  final String note;

  List<Object?> encode() => [
    epoch,
    state.index,
    rootToCur == null
        ? null
        : [rootToCur!.a, rootToCur!.b, rootToCur!.tx, rootToCur!.ty],
    curAt?.microsecondsSinceEpoch,
    rootAspect,
    debugText,
    lostReason,
    note,
  ];

  static TrackSnapshot decode(List<Object?> m) {
    final t = m[2] as List<Object?>?;
    return TrackSnapshot(
      epoch: m[0] as int,
      state: TrackState.values[m[1] as int],
      rootToCur: t == null
          ? null
          : Similarity(
              t[0] as double,
              t[1] as double,
              t[2] as double,
              t[3] as double,
            ),
      curAt: m[3] == null
          ? null
          : DateTime.fromMicrosecondsSinceEpoch(m[3] as int),
      rootAspect: m[4] as double?,
      debugText: m[5] as String,
      lostReason: m[6] as String?,
      note: m[7] as String,
    );
  }
}

class _Pending {
  _Pending(this.f, this.rebase);
  final TrackFrame f;
  final bool rebase;
}

class TrackerWorker {
  TrackerWorker._(this._iso, this._send, this._rx);

  final Isolate _iso;
  final SendPort _send;
  final ReceivePort _rx;
  int _epoch = 0;
  bool _busy = false;
  _Pending? _pending;
  TrackSnapshot _snap = TrackSnapshot.idle;
  bool _closed = false;

  /// Frames dropped because a newer one arrived while busy.
  int dropped = 0;

  /// Updates actually computed by the worker.
  int processed = 0;

  /// Highest number of updates ever in flight (must stay 1).
  int maxInFlight = 0;
  int _inFlight = 0;

  /// Called on every accepted (current-epoch) reply.
  void Function(TrackSnapshot)? onUpdate;

  TrackSnapshot get snapshot => _snap;

  /// Nothing in flight or pending.
  bool get idle => !_busy && _pending == null;
  int get epoch => _epoch;

  static Future<TrackerWorker> start() async {
    final rx = ReceivePort();
    final ready = Completer<SendPort>();
    final iso = await Isolate.spawn(_main, rx.sendPort);
    late TrackerWorker w;
    rx.listen((m) {
      if (m is SendPort) {
        ready.complete(m);
      } else if (m is List) {
        w._onReply(m);
      }
    });
    w = TrackerWorker._(iso, await ready.future, rx);
    return w;
  }

  /// New analysis frame (dropped if a newer one replaces it while busy).
  void submit(TrackFrame f, {bool rebase = false}) {
    if (_closed) return;
    if (_busy) {
      if (_pending != null) dropped++;
      // A pending rebase stays a rebase.
      _pending = _Pending(f, rebase || (_pending?.rebase ?? false));
      return;
    }
    _dispatch(_Pending(f, rebase));
  }

  void _dispatch(_Pending p) {
    _busy = true;
    _inFlight++;
    if (_inFlight > maxInFlight) maxInFlight = _inFlight;
    final g = p.f.grey;
    _send.send([
      'update',
      _epoch,
      g.width,
      g.height,
      TransferableTypedData.fromList([g.data]),
      p.f.cameraZoom,
      p.f.at.microsecondsSinceEpoch,
      p.rebase,
    ]);
  }

  void reset([String why = 'reset']) {
    if (_closed) return;
    _epoch++;
    _pending = null;
    _snap = TrackSnapshot(epoch: _epoch, state: TrackState.idle);
    _send.send(['reset', _epoch, why]);
  }

  void disable(String why) {
    if (_closed) return;
    _epoch++;
    _pending = null;
    _snap = TrackSnapshot(
      epoch: _epoch,
      state: TrackState.unsupported,
      debugText: 'track off ($why)',
      lostReason: why,
    );
    _send.send(['disable', _epoch, why]);
  }

  void _onReply(List<Object?> m) {
    final kind = m[0] as String;
    final s = TrackSnapshot.decode((m[1] as List).cast<Object?>());
    if (kind == 'update') {
      _inFlight--;
      processed++;
      _busy = false;
    }
    if (s.epoch == _epoch) {
      _snap = s;
      if (kind == 'update') onUpdate?.call(s);
    }
    final p = _pending;
    if (!_busy && p != null && !_closed) {
      _pending = null;
      _dispatch(p);
    }
  }

  void dispose() {
    _closed = true;
    _iso.kill(priority: Isolate.immediate);
    _rx.close();
  }

  static void _main(SendPort out) {
    final rx = ReceivePort();
    out.send(rx.sendPort);
    var tr = ZoomTracker();
    var epoch = 0;
    TrackSnapshot snap() => TrackSnapshot(
      epoch: epoch,
      state: tr.state,
      rootToCur: tr.rootToCur,
      curAt: tr.curAt,
      rootAspect: tr.rootAspect,
      debugText: tr.debugText,
      lostReason: tr.lostReason,
      note: tr.lastNote,
    );
    rx.listen((m) {
      final l = m as List;
      final kind = l[0] as String;
      final e = l[1] as int;
      if (kind == 'reset') {
        epoch = e;
        tr = ZoomTracker();
        out.send(['reset', snap().encode()]);
      } else if (kind == 'disable') {
        epoch = e;
        tr = ZoomTracker()..disable(l[2] as String);
        out.send(['disable', snap().encode()]);
      } else if (kind == 'update') {
        if (e == epoch) {
          final w = l[2] as int, h = l[3] as int;
          final data = (l[4] as TransferableTypedData)
              .materialize()
              .asFloat32List();
          final f = TrackFrame(
            GreyImage(w, h, Float32List.fromList(data)),
            l[5] as double,
            DateTime.fromMicrosecondsSinceEpoch(l[6] as int),
          );
          if (l[7] as bool) {
            tr.rebase(f);
          } else {
            tr.update(f);
          }
        }
        out.send(['update', snap().encode()]);
      }
    });
  }
}
