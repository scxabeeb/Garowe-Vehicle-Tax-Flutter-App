import 'package:flutter_test/flutter_test.dart';
import 'package:vehicle_tax_collector/services/api_service.dart';

void main() {
  group('ApiService payment response normalization', () {
    test('normalizes success payloads from the collect endpoint', () {
      final result = ApiService.normalizePaymentResponse({
        'status': 'success',
        'message': 'Payment recorded successfully',
        'paymentId': 42,
        'invoiceId': 'INV-42',
        'golisBillNo': 'GB-42',
        'receipt': {
          'paymentId': 42,
          'invoiceId': 'INV-42',
        },
      });

      expect(result['success'], isTrue);
      expect(result['paymentId'], 42);
      expect(result['invoiceId'], 'INV-42');
      expect(result['golisBillNo'], 'GB-42');
    });

    test('falls back to nested receipt values when top-level fields are absent', () {
      final result = ApiService.normalizePaymentResponse({
        'status': 'success',
        'receipt': {
          'paymentId': 7,
          'invoiceId': 'INV-7',
          'golisBillNo': 'GB-7',
        },
      });

      expect(result['success'], isTrue);
      expect(result['paymentId'], 7);
      expect(result['invoiceId'], 'INV-7');
      expect(result['golisBillNo'], 'GB-7');
    });
  });
}
