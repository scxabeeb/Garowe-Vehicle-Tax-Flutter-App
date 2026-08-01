import 'package:flutter_test/flutter_test.dart';
import 'package:vehicle_tax_collector/utils/payment_recording_parser.dart';

void main() {
  group('PaymentRecordingParser', () {
    test('reads invoice and payment ids from nested ASP.NET style payloads', () {
      final payload = {
        'success': true,
        'invoice': {
          'invoiceNumber': 'INV-1001',
          'id': 123,
        },
        'payment': {
          'id': 456,
        },
      };

      final parsed = PaymentRecordingParser.parse(payload);

      expect(parsed.invoiceNumber, 'INV-1001');
      expect(parsed.paymentId, '456');
    });

    test('falls back to receipt payload when collect response is shallow', () {
      final payload = {
        'success': true,
        'paymentId': '789',
        'receipt': {
          'invoiceId': 'INV-202',
          'paymentId': '790',
          'billNo': 'B-11',
        },
      };

      final parsed = PaymentRecordingParser.parse(payload);

      expect(parsed.invoiceNumber, 'INV-202');
      expect(parsed.paymentId, '790');
      expect(parsed.billNo, 'B-11');
    });

    test('uses direct receipt payload from the backend root object', () {
      final payload = {
        'success': true,
        'invoiceNumber': 'INV-303',
        'paymentId': '991',
        'billNo': 'B-22',
      };

      final parsed = PaymentRecordingParser.parse(payload);

      expect(parsed.invoiceNumber, 'INV-303');
      expect(parsed.paymentId, '991');
      expect(parsed.billNo, 'B-22');
    });
  });
}
