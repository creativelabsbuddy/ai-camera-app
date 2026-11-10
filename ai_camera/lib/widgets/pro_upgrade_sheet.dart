import 'package:flutter/material.dart';

import '../models/products.dart';
import '../services/account_service.dart';
import '../services/billing.dart';
import '../services/entitlements.dart';
import '../theme/app_theme.dart';
import 'credit_icon.dart';

/// Store sheet: Pro ₹99/month + credit packs, balance and starter-trial
/// status. Purchases go through [billingService] (TEST MODE today).
Future<void> showProUpgradeSheet(BuildContext context, {String? reason}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _StoreSheet(reason: reason),
  );
}

class _StoreSheet extends StatefulWidget {
  const _StoreSheet({this.reason});

  final String? reason;

  @override
  State<_StoreSheet> createState() => _StoreSheetState();
}

class _StoreSheetState extends State<_StoreSheet> {
  bool _buying = false;

  Future<void> _buy(Product p) async {
    final billing = billingService;
    if (billing.isTestMode) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('TEST MODE purchase'),
          content: Text(
            '${p.title} · ${p.priceLabel}\n\n'
            'This is a test only — no real money is charged. '
            'Google Play Billing will be added later.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Test buy'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _buying = true);
    final r = await billing.buy(p);
    if (!mounted) return;
    setState(() => _buying = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(r.message ?? (r.success ? 'Done' : 'Failed'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final account = AccountService.instance;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: ValueListenableBuilder<CreditState?>(
          valueListenable: account.state,
          builder: (context, s, _) {
            final now = account.now;
            final pro = s?.isPro(now) ?? false;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (billingService.isTestMode)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.orange.shade300),
                    ),
                    child: Text(
                      'TEST MODE — purchases are simulated, no money is charged',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.orange.shade200,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                if (widget.reason != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      widget.reason!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppColors.proGold,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                Row(
                  children: [
                    const Icon(
                      Icons.workspace_premium,
                      color: AppColors.proGold,
                      size: 30,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        pro ? 'You are Pro' : 'Get Pro',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    CreditsPill(state: s, onTap: null),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  _balanceLine(s, now),
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(height: 14),
                const _ProPerk(text: 'AI zoom beyond optical (up to 100x)'),
                const _ProPerk(text: '100 credits every month'),
                const _ProPerk(text: 'AI filters'),
                const _ProPerk(text: 'Full style library'),
                const _ProPerk(text: 'Custom prompts and your own styles'),
                const _ProPerk(text: 'No ads'),
                const SizedBox(height: 8),
                _ProductTile(
                  product: kProMonthly,
                  highlight: true,
                  trailingNote: pro ? 'Active · renew' : null,
                  onTap: _buying ? null : () => _buy(kProMonthly),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Credit packs (never expire)',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
                const SizedBox(height: 8),
                for (final p in kProducts.where(
                  (p) => p.kind == ProductKind.pack,
                ))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _ProductTile(
                      product: p,
                      onTap: _buying ? null : () => _buy(p),
                    ),
                  ),
                const SizedBox(height: 6),
                const Text(
                  'HD 1 · Full HD 2 · Ultra HD 4 · 4K 8 credits. '
                  '2 free HD per day (reset at midnight IST, they do not add up). '
                  'Credits are used only for successful AI photos.',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                if (s != null && !pro) ...[
                  const SizedBox(height: 12),
                  _StarterStatus(state: s),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

String _balanceLine(CreditState? s, DateTime now) {
  if (s == null) return 'Loading balance…';
  final pro = s.isPro(now);
  final parts = <String>[
    'Free HD today: ${s.freeDaily}',
    if (pro) 'Pro: ${s.subCredits}',
    'Packs: ${s.packCredits}',
  ];
  if (pro && s.proUntil != null) {
    final d = s.proUntil!.toLocal();
    parts.add('Pro until ${d.day}/${d.month}/${d.year}');
  }
  return parts.join(' · ');
}

class _StarterStatus extends StatelessWidget {
  const _StarterStatus({required this.state});

  final CreditState state;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Starter pack (free, once)',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          for (final t in StarterTrial.values)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    state.trialAvailable(t)
                        ? Icons.card_giftcard
                        : Icons.check_circle,
                    size: 16,
                    color: state.trialAvailable(t)
                        ? AppColors.proGold
                        : AppColors.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${t.label} — ${state.trialAvailable(t) ? 'available' : 'used'}',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({
    required this.product,
    required this.onTap,
    this.highlight = false,
    this.trailingNote,
  });

  final Product product;
  final VoidCallback? onTap;
  final bool highlight;
  final String? trailingNote;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: highlight
          ? AppColors.proGold.withValues(alpha: 0.14)
          : AppColors.card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: ValueKey('buy_${product.id}'),
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product.title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    if (trailingNote != null)
                      Text(
                        trailingNote!,
                        style: const TextStyle(
                          color: AppColors.success,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              Text(
                product.kind == ProductKind.subscription
                    ? '${product.priceLabel}/month'
                    : product.priceLabel,
                style: TextStyle(
                  color: highlight ? AppColors.proGold : AppColors.textPrimary,
                  fontWeight: FontWeight.w800,
                  fontSize: 17,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProPerk extends StatelessWidget {
  const _ProPerk({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: AppColors.success, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 14.5))),
        ],
      ),
    );
  }
}

/// Compact bolt + number credit balance pill (e.g. "🪙 12").
class CreditsPill extends StatelessWidget {
  const CreditsPill({super.key, required this.state, this.onTap});

  final CreditState? state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final now = AccountService.instance.now;
    final total = state?.total(now);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        key: const ValueKey('credits_pill'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
            color: AppColors.accentSoft.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CreditIcon(size: 15),
            const SizedBox(width: 3),
            Text(
              total == null ? '…' : '$total',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

/// Live credits pill bound to [AccountService.state]; tap opens the store.
class LiveCreditsPill extends StatelessWidget {
  const LiveCreditsPill({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CreditState?>(
      valueListenable: AccountService.instance.state,
      builder: (context, s, _) =>
          CreditsPill(state: s, onTap: () => showProUpgradeSheet(context)),
    );
  }
}

/// Small "Liked it? Get Pro ₹99/month" upsell shown after a starter trial.
class TrialUpsellChip extends StatelessWidget {
  const TrialUpsellChip({super.key});

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      key: const ValueKey('trial_upsell'),
      avatar: const Icon(
        Icons.workspace_premium,
        size: 16,
        color: AppColors.proGold,
      ),
      label: const Text('Liked it? Get Pro ₹99/month'),
      labelStyle: const TextStyle(
        color: AppColors.proGold,
        fontWeight: FontWeight.w700,
        fontSize: 12.5,
      ),
      backgroundColor: AppColors.proGold.withValues(alpha: 0.12),
      side: BorderSide(color: AppColors.proGold.withValues(alpha: 0.6)),
      onPressed: () => showProUpgradeSheet(context),
    );
  }
}

class ProBadgeButton extends StatelessWidget {
  const ProBadgeButton({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap ?? () => showProUpgradeSheet(context),
        borderRadius: BorderRadius.circular(99),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(99),
            gradient: LinearGradient(
              colors: [
                AppColors.proGold.withValues(alpha: 0.25),
                AppColors.accent.withValues(alpha: 0.2),
              ],
            ),
            border: Border.all(color: AppColors.proGold.withValues(alpha: 0.7)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.workspace_premium, color: AppColors.proGold, size: 15),
              SizedBox(width: 3),
              Text(
                'PRO',
                style: TextStyle(
                  color: AppColors.proGold,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
