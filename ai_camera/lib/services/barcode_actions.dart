/// What a scanned QR / barcode is and what tapping its chip does.
enum ScanKind { url, upi, phone, email, wifi, text }

class ScanAction {
  const ScanAction({
    required this.kind,
    required this.raw,
    required this.label,
    required this.actionLabel,
    this.uri,
  });

  final ScanKind kind;
  final String raw;

  /// Chip text (shortened).
  final String label;

  /// "Open link", "Open UPI app", "Call", "Email", "Copy".
  final String actionLabel;

  /// Launchable URI (null → copy to clipboard).
  final Uri? uri;
}

String _short(String s, [int max = 42]) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length <= max ? one : '${one.substring(0, max - 1)}…';
}

ScanAction? classifyScan(String? raw) {
  final v = raw?.trim() ?? '';
  if (v.isEmpty) return null;
  final lower = v.toLowerCase();
  if (lower.startsWith('upi://')) {
    final u = Uri.tryParse(v);
    final pa = u?.queryParameters['pn'] ?? u?.queryParameters['pa'];
    return ScanAction(
      kind: ScanKind.upi,
      raw: v,
      label: _short('UPI: ${pa ?? 'payment'}'),
      actionLabel: 'Open UPI app',
      uri: u,
    );
  }
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    final u = Uri.tryParse(v);
    if (u != null && u.host.isNotEmpty) {
      return ScanAction(
        kind: ScanKind.url,
        raw: v,
        label: _short(u.host + (u.path.length > 1 ? u.path : '')),
        actionLabel: 'Open link',
        uri: u,
      );
    }
  }
  if (RegExp(r'^www\.[^\s]+\.[a-z]{2,}', caseSensitive: false).hasMatch(v)) {
    final u = Uri.tryParse('https://$v');
    if (u != null) {
      return ScanAction(
        kind: ScanKind.url,
        raw: v,
        label: _short(v),
        actionLabel: 'Open link',
        uri: u,
      );
    }
  }
  if (lower.startsWith('tel:')) {
    return ScanAction(
      kind: ScanKind.phone,
      raw: v,
      label: _short(v.substring(4)),
      actionLabel: 'Call',
      uri: Uri.tryParse(v),
    );
  }
  if (lower.startsWith('mailto:')) {
    return ScanAction(
      kind: ScanKind.email,
      raw: v,
      label: _short(v.substring(7)),
      actionLabel: 'Email',
      uri: Uri.tryParse(v),
    );
  }
  if (lower.startsWith('wifi:')) {
    final ssid = RegExp(r'S:([^;]*)').firstMatch(v)?.group(1);
    return ScanAction(
      kind: ScanKind.wifi,
      raw: v,
      label: _short('Wi-Fi: ${ssid ?? 'network'}'),
      actionLabel: 'Copy',
    );
  }
  return ScanAction(
    kind: ScanKind.text,
    raw: v,
    label: _short(v),
    actionLabel: 'Copy',
  );
}
