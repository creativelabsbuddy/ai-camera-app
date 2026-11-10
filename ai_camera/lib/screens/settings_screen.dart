import '../services/ai_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/ai_config.dart';
import '../services/account_service.dart';
import '../services/enhance_settings.dart';
import '../services/entitlements.dart';
import '../services/optical_profile.dart';
import '../services/steady.dart' show kDebugOverlayKey;
import '../services/zoom_info.dart';
import '../services/zoom_range.dart';
import '../theme/app_theme.dart';
import '../widgets/pro_upgrade_sheet.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = EnhanceSettings();
  final _urlController = TextEditingController();
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final url = await _settings.getServerUrl();
    if (!mounted) return;
    setState(() {
      _urlController.text = url;
      _loading = false;
    });
  }

  Future<void> _saveUrl() async {
    setState(() => _saving = true);
    await _settings.setServerUrl(_urlController.text);
    // Switch credits ledger to the server (or back to local).
    await AccountService.instance.refresh();
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Enhance server URL saved')));
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final aiMode = _urlController.text.trim().isNotEmpty
        ? 'Enhance server (key + credits on server)'
        : (AiConfig.hasEmbeddedApiKey
              ? 'OpenRouter direct (embedded key — TEST BUILD, local credits)'
              : 'AI off — Local filters only (set server URL)');

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _SectionCard(
                  children: [
                    ListTile(
                      leading: const Icon(
                        Icons.workspace_premium,
                        color: AppColors.proGold,
                      ),
                      title: const Text('Pro'),
                      subtitle: const Text(
                        '₹99/month · 100 credits · credit packs (TEST MODE)',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => showProUpgradeSheet(context),
                    ),
                    const Divider(height: 1, color: AppColors.surface),
                    const _AccountTile(),
                  ],
                ),
                const SizedBox(height: 12),
                _SectionCard(
                  children: [
                    ListTile(
                      leading: const Icon(
                        Icons.auto_awesome,
                        color: AppColors.accent,
                      ),
                      title: const Text('AI Enhance'),
                      subtitle: Text('Model: ${AiConfig.model}\n$aiMode'),
                      isThreeLine: true,
                    ),
                    const Divider(height: 1, color: AppColors.surface),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        'Enhance server URL (FastAPI / ngrok)',
                        style: TextStyle(
                          color: AppColors.textSecondary.withValues(
                            alpha: 0.95,
                          ),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: TextField(
                        controller: _urlController,
                        decoration: const InputDecoration(
                          hintText: 'https://your-ngrok.example',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: FilledButton(
                        onPressed: _saving ? null : _saveUrl,
                        child: Text(_saving ? 'Saving…' : 'Save server URL'),
                      ),
                    ),
                    const Divider(height: 1, color: AppColors.surface),
                    ListTile(
                      leading: const Icon(
                        Icons.info_outline,
                        color: AppColors.textSecondary,
                      ),
                      title: const Text('About'),
                      subtitle: const Text(
                        'v11.36 (1.11.36) · Macro levels + Zoom mode',
                      ),
                      onTap: () {
                        showAboutDialog(
                          context: context,
                          applicationName: 'AI Camera',
                          applicationVersion: '1.11.35 (v11.35)',
                          applicationLegalese:
                              'Ankush · India · OpenRouter GPT Image 2.5 Flare',
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const _CameraZoomInfoSection(),
                const _AskBeforeEnhanceSwitch(),
                if (AiConfig.hasEmbeddedApiKey) const _DebugOverlaySwitch(),
                if (AiConfig.hasEmbeddedApiKey)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      '⚠ This build embeds an OpenRouter key via dart-define. '
                      'For testing only — do not distribute.',
                      style: TextStyle(
                        color: Colors.orange.shade300,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Live credits / Pro / starter-trial status + ledger backend.
class _AccountTile extends StatelessWidget {
  const _AccountTile();

  @override
  Widget build(BuildContext context) {
    final account = AccountService.instance;
    return ValueListenableBuilder<CreditState?>(
      valueListenable: account.state,
      builder: (context, s, _) {
        final now = account.now;
        final backend = account.backend.value == AccountBackend.server
            ? 'server ledger'
            : 'local ledger (test / offline)';
        final lines = <String>[
          if (s == null) 'Loading…',
          if (s != null) ...[
            'Total: ${s.total(now)} · Free HD today: ${s.freeDaily} · '
                'Pro: ${s.isPro(now) ? s.subCredits : 0} · Packs: ${s.packCredits}',
            s.isPro(now)
                ? 'Pro active (until ${s.proUntil!.toLocal().toString().substring(0, 16)})'
                : 'Free plan · 2 free HD per day (resets at midnight IST)',
            'Starter trials left: ${StarterTrial.values.where(s.trialAvailable).map((t) => t.label).join(', ').ifEmpty('none')}',
          ],
          'Ledger: $backend',
          if (account.lastError != null) 'Server error: ${account.lastError}',
        ];
        return Column(
          children: [
            ListTile(
              leading: const Icon(Icons.bolt_rounded, color: AppColors.proGold),
              title: const Text('Credits'),
              subtitle: Text(lines.join('\n')),
              isThreeLine: true,
              trailing: IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: () => account.refresh(),
              ),
            ),
            FutureBuilder<String>(
              future: account.deviceId(),
              builder: (context, snap) => Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Device id: ${snap.data ?? '…'}',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            ),
            if (AiConfig.hasEmbeddedApiKey &&
                account.backend.value == AccountBackend.local)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: OutlinedButton(
                  onPressed: () async {
                    account.state.value = await account.ledger
                        .resetForTesting();
                  },
                  child: const Text('TEST: reset local credits / trials'),
                ),
              ),
          ],
        );
      },
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

/// Debug: per-lens Camera2 numbers + computed deviceMax / displayMax, so the
/// zoom range can be verified on a real phone (e.g. S24 Ultra).
class _CameraZoomInfoSection extends StatefulWidget {
  const _CameraZoomInfoSection();

  @override
  State<_CameraZoomInfoSection> createState() => _CameraZoomInfoSectionState();
}

class _CameraZoomInfoSectionState extends State<_CameraZoomInfoSection> {
  late Future<NativeZoomInfo?> _future = ZoomInfoService.load();

  static String _n(double? v, {int digits = 2, String suffix = ''}) =>
      v == null ? '—' : '${v.toStringAsFixed(digits)}$suffix';

  _Computed _compute(NativeZoomInfo? info) {
    final last = ZoomInfoService.lastBackRange;
    final controllerMax = last?.controllerMax;
    final deviceMax = computeDeviceMax(
      controllerMax: controllerMax ?? info?.reportedMaxZoom ?? 1.0,
      nativeReportedMax: info?.reportedMaxZoom,
    );
    final displayMax = computeDisplayMax(
      deviceMax: deviceMax,
      target: kMaxUserZoom,
    );
    final optical = computeOpticalProfile(info, controllerMax: controllerMax);
    return _Computed(controllerMax, deviceMax, displayMax, optical);
  }

  static String _factors(List<double> f) =>
      f.map((v) => '${formatZoom(v)}x').join(', ');

  List<String> _opticalLines(OpticalProfile o) => [
    'Usable lenses (app): ${_factors(o.usableFactors)}',
    'All back lenses: ${_factors(o.allFactors)}',
    'Best usable lens: ${formatZoom(o.bestOptical)}x'
        '${o.sensorCropFactor > 1 ? ' · main ≥40MP → 2x crop' : ''}',
    'Optical limit (free AI ≤): ${formatZoom(o.opticalLimit)}x',
    'AI-recoverable (warning >): ${formatZoom(o.aiRecoverableLimit)}x',
    if (o.appMaxZoom != null)
      'Max zoom exposed to apps: ${formatZoom(o.appMaxZoom!)}x',
    if (o.teleNotExposed)
      'Note: a longer tele exists but is not exposed to third-party apps',
    if (!o.fromCamera2) 'Camera2 probe unavailable → conservative 1x',
    'Last capture: ${ZoomInfoService.lastCaptureCalibration ?? '— (take a photo)'}',
    'Night extension (Camera2): ${switch (ZoomInfoService.cached?.nightExtension) {
      true => 'available on this phone (app uses its own burst night mode)',
      false => 'not offered → app burst night mode',
      null => 'unknown',
    }}',
  ];

  String _cameraLine(CameraLensInfo c) {
    final kind = c.isLogical
        ? 'logical${c.physicalIds.isEmpty ? '' : ' (phys ${c.physicalIds.join(',')})'}'
        : (c.parentId != null ? 'physical of ${c.parentId}' : 'physical');
    return '$kind · ${c.source}';
  }

  String _cameraDetails(CameraLensInfo c) {
    final focal = c.focalLengths.map((f) => f.toStringAsFixed(2)).join('/');
    return [
      '35mm-eq: ${_n(c.eqFocalMm, digits: 1, suffix: ' mm')}'
          '  (f ${focal.isEmpty ? '—' : focal} mm, sensor '
          '${_n(c.sensorWidthMm)}×${_n(c.sensorHeightMm)} mm)',
      'Optical multiplier: ${_n(c.opticalMultiplier, suffix: 'x')}'
          '${c.isMain ? '  (main 1x)' : ''}',
      'Reported max zoom: ${_n(c.reportedMaxZoom, digits: 1, suffix: 'x')}'
          '  (ratio ${_n(c.zoomRatioMin)}–${_n(c.zoomRatioMax)}, '
          'digital ${_n(c.maxDigitalZoom, digits: 1)})',
      'Active array: ${c.activeArrayWidth ?? '—'}×${c.activeArrayHeight ?? '—'}'
          '${c.megapixels == null ? '' : '  (${c.megapixels!.toStringAsFixed(1)} MP)'}',
    ].join('\n');
  }

  String _asText(NativeZoomInfo? info) {
    final b = StringBuffer('AI Camera zoom info\n');
    if (info == null) {
      b.writeln('Native probe unavailable');
    } else {
      b.writeln('${info.manufacturer} ${info.model} · SDK ${info.sdkInt}');
      b.writeln('cameraIdList: ${info.cameraIdList.join(',')}');
      for (final c in info.backCameras) {
        b.writeln('— id ${c.id}: ${_cameraLine(c)}');
        b.writeln(_cameraDetails(c));
      }
      b.writeln(
        'Primary back: ${info.primaryBackId ?? '—'} · main lens: '
        '${info.mainCameraId ?? '—'}',
      );
      b.writeln('Multipliers: ${info.opticalMultipliers.join(', ')}');
      b.writeln(
        'Tele: ${_n(info.rawTeleMultiplier)} → '
        '${_n(info.teleMultiplier, digits: 1, suffix: 'x')}',
      );
      if (info.error != null) b.writeln('Error: ${info.error}');
      for (final e in info.errors) {
        b.writeln('Err: $e');
      }
    }
    final k = _compute(info);
    b.writeln('CameraX max: ${_n(k.controllerMax, digits: 1)}');
    b.writeln('Native reported max: ${_n(info?.reportedMaxZoom, digits: 1)}');
    b.writeln('deviceMax: ${formatZoom(k.deviceMax)}x');
    b.writeln('displayMax: ${formatZoom(k.displayMax)}x');
    for (final l in _opticalLines(k.optical)) {
      b.writeln(l);
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    const label = TextStyle(color: AppColors.textSecondary, fontSize: 12);
    return _SectionCard(
      children: [
        FutureBuilder<NativeZoomInfo?>(
          future: _future,
          builder: (context, snap) {
            final loading = snap.connectionState != ConnectionState.done;
            final info = snap.data;
            final k = _compute(info);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  leading: const Icon(Icons.zoom_in, color: AppColors.accent),
                  title: const Text('Camera zoom info'),
                  subtitle: Text(
                    info == null
                        ? (loading
                              ? 'Reading Camera2…'
                              : 'Native probe unavailable')
                        : '${info.manufacturer} ${info.model} · SDK ${info.sdkInt}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Copy',
                        icon: const Icon(Icons.copy, size: 20),
                        onPressed: loading
                            ? null
                            : () async {
                                await Clipboard.setData(
                                  ClipboardData(text: _asText(info)),
                                );
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Zoom info copied'),
                                  ),
                                );
                              },
                      ),
                      IconButton(
                        tooltip: 'Refresh',
                        icon: const Icon(Icons.refresh, size: 20),
                        onPressed: () => setState(() {
                          _future = ZoomInfoService.load(refresh: true);
                        }),
                      ),
                    ],
                  ),
                ),
                if (info != null)
                  for (final c in info.backCameras) ...[
                    const Divider(height: 1, color: AppColors.surface),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Back id ${c.id} · ${_cameraLine(c)}',
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(_cameraDetails(c), style: label),
                        ],
                      ),
                    ),
                  ],
                const Divider(height: 1, color: AppColors.surface),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                  child: Text(
                    [
                      'CameraX max (open camera first): '
                          '${_n(k.controllerMax, digits: 1, suffix: 'x')}',
                      'Native reported max: '
                          '${_n(info?.reportedMaxZoom, digits: 1, suffix: 'x')}',
                      'Optical multipliers: '
                          '${info == null || info.opticalMultipliers.isEmpty ? '—' : info.opticalMultipliers.map((m) => '${m.toStringAsFixed(2)}x').join(', ')}',
                      'Tele multiplier: ${_n(info?.rawTeleMultiplier)} → '
                          '${_n(info?.teleMultiplier, digits: 1, suffix: 'x')}',
                      'deviceMax: ${formatZoom(k.deviceMax)}x   ·   '
                          'displayMax: ${formatZoom(k.displayMax)}x',
                      ..._opticalLines(k.optical),
                      if (info?.error != null) 'Error: ${info!.error}',
                      if (info != null && info.errors.isNotEmpty)
                        'Probe errors: ${info.errors.length}',
                    ].join('\n'),
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _Computed {
  const _Computed(
    this.controllerMax,
    this.deviceMax,
    this.displayMax,
    this.optical,
  );

  final double? controllerMax;
  final double deviceMax;
  final double displayMax;
  final OpticalProfile optical;
}

/// v11.52: Cross / Tick before AI instead of the 3-second Cancel window.
class _AskBeforeEnhanceSwitch extends StatefulWidget {
  const _AskBeforeEnhanceSwitch();

  @override
  State<_AskBeforeEnhanceSwitch> createState() =>
      _AskBeforeEnhanceSwitchState();
}

class _AskBeforeEnhanceSwitchState extends State<_AskBeforeEnhanceSwitch> {
  bool _on = false;

  @override
  void initState() {
    super.initState();
    AiGate.askBeforeEnhancing().then((v) {
      if (mounted) setState(() => _on = v);
    });
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
    key: const ValueKey('ask_before_enhance_switch'),
    title: const Text('Ask before enhancing'),
    subtitle: const Text(
      'On: tick or cross after each AI shot. Off: AI starts after a '
      '3-second window with Cancel.',
    ),
    value: _on,
    onChanged: (v) async {
      setState(() => _on = v);
      await AiGate.setAskBeforeEnhancing(v);
    },
  );
}

/// v11.42 test builds: camera debug overlay (fps, analysis size, gyro).
class _DebugOverlaySwitch extends StatefulWidget {
  const _DebugOverlaySwitch();

  @override
  State<_DebugOverlaySwitch> createState() => _DebugOverlaySwitchState();
}

class _DebugOverlaySwitchState extends State<_DebugOverlaySwitch> {
  bool _on = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _on = p.getBool(kDebugOverlayKey) ?? false);
    });
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
    key: const ValueKey('debug_overlay_switch'),
    title: const Text('Camera debug overlay'),
    subtitle: const Text('Preview fps, analysis size, gyro (test builds)'),
    value: _on,
    onChanged: (v) async {
      setState(() => _on = v);
      final p = await SharedPreferences.getInstance();
      await p.setBool(kDebugOverlayKey, v);
    },
  );
}
