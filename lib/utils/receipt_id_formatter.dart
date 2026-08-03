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

  static bool hasValue(String value) => value.trim().isNotEmpty;

  static String trimValue(String value) {
    final trimmed = value.trim();
    return trimmed;
  }
}
