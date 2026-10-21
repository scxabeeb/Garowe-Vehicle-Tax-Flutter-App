class ReceiptIdFormatter {
  static String formatInvoiceId(String value) => value.trim();

  static String formatPaymentId(String value) => value.trim();

  static String displayInvoiceId(String value) {
    final formatted = formatInvoiceId(value);
    return formatted.isEmpty ? 'Pending until payment is recorded' : formatted;
  }

  static String displayPaymentId(String value) {
    final formatted = formatPaymentId(value);
    return formatted.isEmpty ? 'Pending until payment is recorded' : formatted;
  }

  static String buildShortCode(String invoiceNumber) {
    final formatted = formatInvoiceId(invoiceNumber);
    if (formatted.isEmpty) {
      return '';
    }

    return buildPaymentShortCode(formatted);
  }

  static String buildPaymentShortCode(String paymentId) {
    final formatted = formatPaymentId(paymentId);
    if (formatted.isEmpty) {
      return '';
    }

    return '*3440*$formatted#';
  }

  static String resolveShortCode(String paymentId, {String? provided}) {
    final expected = buildPaymentShortCode(paymentId);
    if (expected.isNotEmpty) {
      return expected;
    }

    return trimValue(provided ?? '');
  }

  /// Extracts the first integer found inside an identifier string.
  /// For example "INV-42", "payment_100", "RC-2024-7" all yield 42 / 100 / 7.
  /// Returns null when no digits are present.
  static int? extractNumericId(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return null;
      final direct = int.tryParse(trimmed);
      if (direct != null) return direct;
      final match = RegExp(r'\d+').firstMatch(trimmed);
      if (match != null) {
        final parsed = int.tryParse(match.group(0)!);
        if (parsed != null && parsed > 0) return parsed;
      }
    }
    return null;
  }


  static bool hasValue(String value) => value.trim().isNotEmpty;

  static String trimValue(String value) {
    final trimmed = value.trim();
    return trimmed;
  }
}
