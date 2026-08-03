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

  group('ApiService receipt response normalization', () {
    test('flattens nested data and receipt payloads', () {
      final result = ApiService.normalizeReceiptResponse({
        'status': 'success',
        'data': {
          'receipt': {
            'paymentId': 88,
            'invoiceId': 'INV-88',
            'receiptNumber': 'RCPT-88',
            'golisBillNo': 'GB-88',
          },
        },
      });

      expect(result['paymentId'], 88);
      expect(result['invoiceId'], 'INV-88');
      expect(result['receiptNumber'], 'RCPT-88');
      expect(result['golisBillNo'], 'GB-88');
    });

    test('keeps top-level values while filling missing nested fields', () {
      final result = ApiService.normalizeReceiptResponse({
        'paymentId': 14,
        'data': {
          'payment': {
            'invoiceId': 'INV-14',
            'shortCode': 'P000014',
          },
        },
      });

      expect(result['paymentId'], 14);
      expect(result['invoiceId'], 'INV-14');
      expect(result['shortCode'], 'P000014');
    });
  });
}
