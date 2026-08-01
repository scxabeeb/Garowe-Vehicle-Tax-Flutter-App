import 'receipt_id_formatter.dart';

class PaymentRecordingResult {
  const PaymentRecordingResult({
    required this.invoiceNumber,
    required this.paymentId,
    required this.billNo,
    required this.shortCode,
  });

  final String invoiceNumber;
  final String paymentId;
  final String billNo;
  final String shortCode;
}

class PaymentRecordingParser {
  static Map<String, dynamic>? extractReceiptPayload(Map<String, dynamic> source) {
    final wrapped = _normalizeMap(source['receipt']);
    if (wrapped != null && _looksLikeReceiptPayload(wrapped)) {
      return wrapped;
    }

    final data = _normalizeMap(source['data']);
    if (data != null && _looksLikeReceiptPayload(data)) {
      return data;
    }

    final result = _normalizeMap(source['result']);
    if (result != null && _looksLikeReceiptPayload(result)) {
      return result;
    }

    if (_looksLikeReceiptPayload(source)) {
      return source;
    }

    return null;
  }

  static PaymentRecordingResult parse(
    Map<String, dynamic> source, {
    String fallbackInvoice = '',
    String fallbackPayment = '',
    String fallbackBillNo = '',
    String fallbackShortCode = '',
  }) {
    final effectiveSource = extractReceiptPayload(source) ?? source;

    final invoiceNumber = _readString(
      effectiveSource,
      ['invoiceId', 'invoiceNumber', 'invoiceNo', 'invoice_no', 'id', 'referenceNumber'],
      nestedKeys: ['invoice', 'recordedInvoice', 'receipt', 'data', 'result', 'payment', 'paymentRecord'],
      fallback: fallbackInvoice,
    );
    final paymentId = _readString(
      effectiveSource,
      ['paymentId', 'paymentID', 'id'],
      nestedKeys: ['payment', 'receipt', 'data', 'result', 'invoice', 'paymentRecord'],
      fallback: fallbackPayment,
    );
    final billNo = _readString(
      effectiveSource,
      ['golisBillNo', 'transactionId', 'billNo', 'billNumber', 'referenceNumber'],
      nestedKeys: ['receipt', 'invoice', 'payment', 'data', 'result', 'paymentRecord'],
      fallback: fallbackBillNo,
    );
    final shortCode = _readString(
      effectiveSource,
      ['shortCode'],
      nestedKeys: const [],
      fallback: fallbackShortCode.isNotEmpty
          ? fallbackShortCode
          : ReceiptIdFormatter.buildShortCode(invoiceNumber),
    );

    return PaymentRecordingResult(
      invoiceNumber: invoiceNumber,
      paymentId: paymentId,
      billNo: billNo,
      shortCode: shortCode,
    );
  }

  static String _readString(
    Map<String, dynamic> source,
    List<String> keys, {
    required List<String> nestedKeys,
    String fallback = '',
  }) {
    for (final key in keys) {
      final value = source[key];
      final text = _coerceString(value);
      if (text.isNotEmpty) {
        return text;
      }
    }

    final nestedCandidates = <dynamic>[];
    for (final nestedKey in nestedKeys) {
      final nestedValue = source[nestedKey];
      if (nestedValue != null) {
        nestedCandidates.add(nestedValue);
      }
    }

    for (final candidate in nestedCandidates) {
      final nestedResult = _readValue(candidate, keys, fallback: '');
      if (nestedResult.isNotEmpty) {
        return nestedResult;
      }
    }

    return fallback;
  }

  static String _readValue(
    dynamic value,
    List<String> keys, {
    String fallback = '',
  }) {
    if (value is Map<String, dynamic>) {
      return _readString(value, keys, nestedKeys: const [], fallback: fallback);
    }

    if (value is Map) {
      return _readString(Map<String, dynamic>.from(value), keys, nestedKeys: const [], fallback: fallback);
    }

    if (value is List) {
      for (final item in value) {
        final nestedResult = _readValue(item, keys, fallback: '');
        if (nestedResult.isNotEmpty) {
          return nestedResult;
        }
      }
    }

    return fallback;
  }

  static bool _looksLikeReceiptPayload(Map<String, dynamic> source) {
    final hasInvoiceMarker = _hasAnyKey(source, [
      'invoiceId',
      'invoiceNumber',
      'invoiceNo',
      'invoice_no',
      'invoice',
    ]);
    final hasPaymentMarker = _hasAnyKey(source, [
      'paymentId',
      'paymentID',
      'payment',
    ]);
    final hasBillMarker = _hasAnyKey(source, [
      'golisBillNo',
      'transactionId',
      'billNo',
      'billNumber',
      'referenceNumber',
    ]);

    return hasInvoiceMarker || hasPaymentMarker || hasBillMarker;
  }

  static bool _hasAnyKey(Map<String, dynamic> source, List<String> keys) {
    for (final key in keys) {
      final value = source[key];
      if (value != null) {
        if (value is String && value.trim().isNotEmpty) {
          return true;
        }
        if (value is num || value is bool) {
          return true;
        }
        if (value is Map || value is List) {
          return true;
        }
      }
    }
    return false;
  }

  static Map<String, dynamic>? _normalizeMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return null;
  }

  static String _coerceString(dynamic value) {
    if (value == null) {
      return '';
    }

    if (value is String) {
      return value.trim();
    }

    if (value is num || value is bool) {
      return value.toString();
    }

    return value.toString().trim();
  }
}
