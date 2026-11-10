import '../models/products.dart';
import 'account_service.dart';

class PurchaseOutcome {
  const PurchaseOutcome({required this.success, this.message});
  final bool success;
  final String? message;
}

/// Store abstraction. Today only [TestBillingService] exists (no money
/// moves). A `PlayBillingService` (in_app_purchase / Play Billing Library)
/// can implement the same interface later: launch the Play purchase flow,
/// verify the token on the server, then the server grants credits.
abstract class BillingService {
  /// True for the fake store — UI must show a clear "TEST MODE" label.
  bool get isTestMode;

  List<Product> get products;

  Future<PurchaseOutcome> buy(Product product);
}

class TestBillingService implements BillingService {
  TestBillingService({AccountService? account}) : _override = account;

  final AccountService? _override;

  AccountService get _account => _override ?? AccountService.instance;

  @override
  bool get isTestMode => true;

  @override
  List<Product> get products => kProducts;

  @override
  Future<PurchaseOutcome> buy(Product product) async {
    try {
      await _account.grantPurchase(product);
      return PurchaseOutcome(
        success: true,
        message: 'TEST purchase done: ${product.title} (no money charged)',
      );
    } catch (e) {
      return PurchaseOutcome(success: false, message: 'Purchase failed: $e');
    }
  }
}

/// Single place to swap the store implementation.
BillingService billingService = TestBillingService();
