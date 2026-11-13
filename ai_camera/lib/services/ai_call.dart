import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'enhance_policy.dart' show kEnhanceOnlyTip;

/// Per-request timeout for AI image calls (Flare normally answers in
/// 10–30 s). A stalled request fails after this instead of spinning.
const Duration kAiRequestTimeout = Duration(seconds: 90);

/// Lets the UI cancel an in-flight AI call. Cancelling closes the request's
/// own HTTP client (aborting the socket) and guarantees no charge.
class AiCancelToken {
  final Completer<void> _done = Completer<void>();
  final List<void Function()> _listeners = [];

  bool get isCancelled => _done.isCompleted;
  Future<void> get whenCancelled => _done.future;

  void cancel() {
    if (_done.isCompleted) return;
    _done.complete();
    for (final f in List.of(_listeners)) {
      try {
        f();
      } catch (_) {}
    }
    _listeners.clear();
  }

  /// Runs [f] on cancel (immediately if already cancelled).
  void onCancel(void Function() f) {
    if (isCancelled) {
      f();
    } else {
      _listeners.add(f);
    }
  }

  void throwIfCancelled() {
    if (isCancelled) throw const AiCancelledException();
  }
}

class AiCancelledException implements Exception {
  const AiCancelledException();
  @override
  String toString() => 'Cancelled';
}

/// Completes with [f] or throws [AiCancelledException] as soon as [token]
/// is cancelled (whichever happens first).
Future<T> raceCancel<T>(Future<T> f, AiCancelToken? token) {
  if (token == null) return f;
  token.throwIfCancelled();
  final c = Completer<T>();
  f.then(
    (v) {
      if (!c.isCompleted) c.complete(v);
    },
    onError: (Object e, StackTrace s) {
      if (!c.isCompleted) c.completeError(e, s);
    },
  );
  token.whenCancelled.then((_) {
    if (!c.isCompleted) c.completeError(const AiCancelledException());
  });
  return c.future;
}

/// v11.59 offline message (= network_check.kCheckInternet).
const String kCheckInternetMessage = 'Check your internet connection';

/// v11.59 (= zoom_source.kZoomNoSharpSource).
const String kNoSharpSourceMessage =
    'Hold steady: no sharp photo matched this zoom. Zoom in slowly and try '
    'again. No credits used.';

/// Why an AI call produced no image (nothing is ever charged for these).
/// v11.31 shown when the zoom result framing check fails.
const String kFramingChangedMessage =
    "Couldn't enhance this zoom — credit refunded";

enum AiFailureKind {
  /// No answer within [kAiRequestTimeout].
  timeout,

  /// The model answered without an image (text-only / empty data).
  noImage,

  /// Safety / moderation refusal by the model.
  refused,

  /// Blocked by our own tiny safety list before any AI call.
  blocked,

  /// Custom text only asked for "enhance / HD / sharp" — enhance happens at
  /// capture time (PRO AI), so no AI call is made (v10).
  enhanceOnly,

  /// Offline / DNS / socket problems.
  network,

  /// User tapped Cancel.
  cancelled,

  /// v11 Pro Night: merged frame too dark → AI not called (no charge).
  tooDark,

  /// v11 Pro Night: AI result changed the scene structure → rejected.
  structureChanged,

  /// v11.31 zoom ladder: the result's framing does not match the final
  /// photo (model copied a reference) → not shown, nothing charged.
  framingChanged,

  /// v11.59 zoom past the clear limit with no matching sharp source → AI
  /// not called (nothing charged).
  noSharpSource,

  /// Anything else (HTTP 5xx, bad JSON …).
  other,
}

/// Structured AI failure (thrown by the OpenRouter / server clients).
class AiFailure implements Exception {
  const AiFailure(this.kind, this.message);
  final AiFailureKind kind;
  final String message;
  @override
  String toString() => message;
}

final RegExp _refusalPattern = RegExp(
  r'moderation|safety|content[_ ]policy|policy_violation|refus|not allowed to|cannot help|can.t help|unable to (create|generate|edit)',
  caseSensitive: false,
);

/// True when an upstream error / text answer looks like a safety refusal.
bool looksLikeRefusal(String text) => _refusalPattern.hasMatch(text);

AiFailureKind classifyAiError(Object e) {
  if (e is AiFailure) return e.kind;
  if (e is AiCancelledException) return AiFailureKind.cancelled;
  if (e is TimeoutException) return AiFailureKind.timeout;
  if (e.toString() == kCheckInternetMessage) return AiFailureKind.network;
  if (e is SocketException || e is HandshakeException) {
    return AiFailureKind.network;
  }
  if (e is http.ClientException) {
    // A closed client (cancel / timeout abort) also surfaces here.
    return AiFailureKind.network;
  }
  return AiFailureKind.other;
}

/// One clear, English status line per failure (always "no credits used").
/// [isStyle]: library style (person look) vs custom "Prompt".
String aiFailureMessage(AiFailureKind kind, {bool isStyle = false}) {
  switch (kind) {
    case AiFailureKind.timeout:
      return 'The AI took too long (over ${kAiRequestTimeout.inSeconds}s). '
          'No credits used — tap Retry.';
    case AiFailureKind.noImage:
      return isStyle
          ? "Couldn't apply this style. Try a photo with a person. "
                'No credits used.'
          : "Couldn't apply this change. Try a photo with a person or "
                'different words. No credits used.';
    case AiFailureKind.refused:
      return 'The AI declined this request. Try something else. '
          'No credits used.';
    case AiFailureKind.blocked:
      return "This change isn't allowed. Try something else — "
          'no credits used.';
    case AiFailureKind.enhanceOnly:
      return kEnhanceOnlyTip;
    case AiFailureKind.network:
      // v11.59: exact wording (no credits are ever used offline).
      return kCheckInternetMessage;
    case AiFailureKind.cancelled:
      return 'Cancelled — no credits used.';
    case AiFailureKind.tooDark:
      return 'Too dark for Pro Night. Use Normal Night or turn on flash.';
    case AiFailureKind.structureChanged:
      return 'AI changed the scene, so the result was rejected. '
          'No credits used — tap Retry.';
    case AiFailureKind.framingChanged:
      return kFramingChangedMessage;
    case AiFailureKind.noSharpSource:
      return kNoSharpSourceMessage;
    case AiFailureKind.other:
      return 'Could not apply — no credits used. Tap Retry.';
  }
}
