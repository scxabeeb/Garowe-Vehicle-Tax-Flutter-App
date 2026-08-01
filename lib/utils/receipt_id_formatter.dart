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

    return formatted.length > 9 ? formatted.substring(0, 9) : formatted;
  }

  static bool hasValue(String value) => value.trim().isNotEmpty;

  static String trimValue(String value) {
    final trimmed = value.trim();
    return trimmed;
  }
}
