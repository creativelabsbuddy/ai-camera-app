/// Store catalogue (₹). Purchases go through a [BillingService]; today only
/// the clearly-labelled TEST MODE implementation exists (no real money).
enum ProductKind { subscription, pack }

class Product {
  const Product({
    required this.id,
    required this.title,
    required this.priceInr,
    required this.credits,
    required this.kind,
  });

  final String id;
  final String title;
  final int priceInr;

  /// Credits granted (subscription: per 30-day period, no rollover).
  final int credits;
  final ProductKind kind;

  String get priceLabel => '₹$priceInr';
}

const Product kProMonthly = Product(
  id: 'pro_monthly',
  title: 'Pro · 100 credits / month',
  priceInr: 99,
  credits: 100,
  kind: ProductKind.subscription,
);

const List<Product> kProducts = [
  kProMonthly,
  Product(
    id: 'pack_25',
    title: '25 credits',
    priceInr: 49,
    credits: 25,
    kind: ProductKind.pack,
  ),
  Product(
    id: 'pack_60',
    title: '60 credits',
    priceInr: 99,
    credits: 60,
    kind: ProductKind.pack,
  ),
  Product(
    id: 'pack_140',
    title: '140 credits',
    priceInr: 199,
    credits: 140,
    kind: ProductKind.pack,
  ),
  Product(
    id: 'shot_1',
    title: '1 shot (1 credit)',
    priceInr: 5,
    credits: 1,
    kind: ProductKind.pack,
  ),
];

Product? productById(String id) {
  for (final p in kProducts) {
    if (p.id == id) return p;
  }
  return null;
}
