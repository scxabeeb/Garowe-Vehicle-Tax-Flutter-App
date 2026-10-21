import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:unified_esc_pos_printer/unified_esc_pos_printer.dart';

import '../services/esc_pos_printer_service.dart';
import '../theme/brand_theme.dart';
import '../utils/receipt_id_formatter.dart';
import '../widgets/app_bottom_nav.dart';
import 'dashboard_page.dart';
import 'payment_page.dart';
import 'printer_settings_page.dart';
import 'profile_page.dart';

class InvoicePreviewPage extends StatefulWidget {
  final String invoiceNumber;
  final String billNo;
  final String paymentId;
  final String shortCode;
  final String plateNumber;
  final String ownerName;
  final String movementName;
  final int quantity;
  final double unitAmount;
  final double totalAmount;
  final String collectorName;
  final DateTime paidAt;
  final bool isPaid;
  final bool canRecordPayment;
  final bool canPrintInvoice;
  final Future<Map<String, String>?> Function()? onRecordPayment;
  final Future<Map<String, String>?> Function()? onRefreshPaymentStatus;
  final bool autoPrintWhenPaid;


  const InvoicePreviewPage({
    super.key,
    required this.invoiceNumber,
    required this.billNo,
    required this.paymentId,
    required this.shortCode,
    required this.plateNumber,
    required this.ownerName,
    required this.movementName,
    required this.quantity,
    required this.unitAmount,
    required this.totalAmount,
    required this.collectorName,
    required this.paidAt,
    required this.isPaid,
    required this.canRecordPayment,
    this.canPrintInvoice = false,
    this.onRecordPayment,

    this.onRefreshPaymentStatus,
    this.autoPrintWhenPaid = false,
  });

  @override
  State<InvoicePreviewPage> createState() => _InvoicePreviewPageState();
}

class _InvoicePreviewPageState extends State<InvoicePreviewPage> {
  static const Duration _eatOffset = Duration(hours: 3);

  final EscPosPrinterService _printerService = EscPosPrinterService();
  late bool _isPaid;
  late String _invoiceNumber;
  late String _billNo;
  late String _paymentId;
  late String _shortCode;
  bool _savingPayment = false;
  bool _printingDirect = false;
  bool _hasAutoPrintedAfterPaid = false;
  Timer? _refreshTimer;

  DateTime _toEat(DateTime input) => input.toUtc().add(_eatOffset);

  @override
  void initState() {
    super.initState();
    _isPaid = widget.isPaid;
    _invoiceNumber = widget.invoiceNumber;
    _billNo = widget.billNo;
    _paymentId = widget.paymentId;
    _shortCode = widget.shortCode;
    _hasAutoPrintedAfterPaid = _isPaid;
    _startAutoRefresh();
    unawaited(_refreshFromBackendStatus());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _printerService.dispose();
    super.dispose();
  }

  void _startAutoRefresh() {
    _refreshTimer?.cancel();
    if (widget.onRefreshPaymentStatus == null) {
      return;
    }

    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      unawaited(_refreshFromBackendStatus());
    });
  }

  Future<void> _refreshFromBackendStatus() async {
    final callback = widget.onRefreshPaymentStatus;
    if (callback == null) return;

    final result = await callback.call();
    if (!mounted || result == null) return;

    final nextInvoice = (result['invoiceNumber'] ?? '').trim();
    final nextPayment = (result['paymentId'] ?? '').trim();
    final nextBillNo = (result['refId'] ?? result['billNo'] ?? '').trim();
    final nextShortCode = (result['shortCode'] ?? '').trim();
    final nextPaid = (result['isPaid'] ?? 'false').toString().toLowerCase() == 'true';
    final resolvedPaid = _isPaid || nextPaid;
    final becamePaid = !_isPaid && resolvedPaid;

    setState(() {
      if (nextInvoice.isNotEmpty) {
        _invoiceNumber = nextInvoice;
      }
      if (nextPayment.isNotEmpty) {
        _paymentId = nextPayment;
      }
      if (nextBillNo.isNotEmpty) {
        _billNo = nextBillNo;
      }
      if (nextShortCode.isNotEmpty) {
        _shortCode = nextShortCode;
      }
      _isPaid = resolvedPaid;
    });

    if (becamePaid && widget.autoPrintWhenPaid && !_hasAutoPrintedAfterPaid) {
      _hasAutoPrintedAfterPaid = true;
      await _printInvoice();
    }
  }

  String _amount(double value) {
    final fixed = value.toStringAsFixed(2);
    return fixed
        .replaceFirst(RegExp(r'\\.00$'), '')
        .replaceFirst(RegExp(r'0$'), '');
  }

  Future<Uint8List> _buildPdf() async {
    final doc = pw.Document();
    final dateText =
        '${DateFormat('dd MMM yyyy HH:mm').format(_toEat(widget.paidAt))} EAT';
    final invoiceId = ReceiptIdFormatter.displayInvoiceId(_invoiceNumber);
    final paymentId = ReceiptIdFormatter.displayPaymentId(_paymentId);

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'Garowe Local Government',
                style:
                    pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
              ),
              pw.Text('Vehicle Tax Receipt',
                  style: const pw.TextStyle(fontSize: 12)),
              pw.SizedBox(height: 16),
              pw.Divider(),
              pw.SizedBox(height: 10),
              pw.Text('Invoice ID: $invoiceId'),
              if (_isPaid) pw.Text('Receipt No: $invoiceId'),
              if (ReceiptIdFormatter.hasValue(_billNo))
                pw.Text('Bill No: ${ReceiptIdFormatter.trimValue(_billNo)}'),
              if (ReceiptIdFormatter.hasValue(_billNo))
                pw.Text('Ref ID: ${ReceiptIdFormatter.trimValue(_billNo)}'),
              pw.Text('Payment ID: $paymentId'),
              pw.Text('Status: ${_isPaid ? 'Paid' : 'Not Paid'}'),
              pw.Text('Date: $dateText'),
              pw.SizedBox(height: 10),
              pw.Text('Plate: ${widget.plateNumber}'),
              pw.Text('Owner: ${widget.ownerName}'),
              pw.Text('Movement: ${widget.movementName}'),
              pw.Text('Collector: ${widget.collectorName}'),
              pw.SizedBox(height: 16),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Unit Amount: ${_amount(widget.unitAmount)}'),
                  pw.Text('Quantity: ${widget.quantity}'),
                  pw.Text(
                    'Total: ${_amount(widget.totalAmount)}',
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                ],
              ),
              pw.SizedBox(height: 16),
              if (ReceiptIdFormatter.hasValue(_shortCode))
                pw.Text(
                    'Shortcode: ${ReceiptIdFormatter.trimValue(_shortCode)}'),
            ],
          );
        },
      ),
    );

    return doc.save();
  }

  Future<void> _printInvoice() async {
    if (_printingDirect) return;

    setState(() => _printingDirect = true);
    try {
      final scanned = await _printerService.scanSupportedPrinters();
      if (scanned.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No printer found. Configure a printer in Printer Settings.')),
        );
        return;
      }

      final preferred = await _printerService.resolvePreferredPrinter(scanned);
      final PrinterDevice printer = preferred ?? scanned.first;

      final data = ReceiptPrintData(
        invoiceNumber: _invoiceNumber,
        billNo: _billNo,
        paymentId: _paymentId,
        shortCode: _shortCode,
        plateNumber: widget.plateNumber,
        ownerName: widget.ownerName,
        movementName: widget.movementName,
        quantity: widget.quantity,
        unitAmount: widget.unitAmount,
        totalAmount: widget.totalAmount,
        collectorName: widget.collectorName,
        paidAt: widget.paidAt,
        isPaid: _isPaid,
      );

      await _printerService.printReceipt(printer: printer, data: data);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Receipt printed to ${_printerService.printerLabel(printer)}.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Direct print failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _printingDirect = false);
      }
    }
  }

  Future<void> _saveAsPdf() async {
    final bytes = await _buildPdf();
    await Printing.sharePdf(
        bytes: bytes,
        filename:
            'receipt_${ReceiptIdFormatter.trimValue(_invoiceNumber).isEmpty ? 'preview' : ReceiptIdFormatter.trimValue(_invoiceNumber)}.pdf');
  }

  Future<void> _recordPayment() async {
    if (_isPaid || _savingPayment || widget.onRecordPayment == null) {
      return;
    }

    final wasPaidBefore = _isPaid;
    setState(() => _savingPayment = true);
    final result = await widget.onRecordPayment!.call();
    if (!mounted) return;

    setState(() {
      _savingPayment = false;
      if (result != null) {
        _isPaid = (result['isPaid'] ?? 'true').toString().toLowerCase() == 'true';
        _invoiceNumber = (result['invoiceNumber'] ?? '').trim().isNotEmpty
            ? (result['invoiceNumber'] ?? _invoiceNumber)
            : _invoiceNumber;
        _billNo = ((result['refId'] ?? result['billNo'] ?? '').trim().isNotEmpty)
            ? (result['refId'] ?? result['billNo'] ?? _billNo)
            : _billNo;
        _paymentId = (result['paymentId'] ?? '').trim().isNotEmpty
            ? (result['paymentId'] ?? _paymentId)
            : _paymentId;
        _shortCode = (result['shortCode'] ?? '').trim().isNotEmpty
            ? (result['shortCode'] ?? _shortCode)
            : _shortCode;
      }
    });

    if (result == null || !mounted) {
      return;
    }

    final becamePaidFromManualCollect = !wasPaidBefore && _isPaid;
    if (becamePaidFromManualCollect && widget.autoPrintWhenPaid && !_hasAutoPrintedAfterPaid) {
      _hasAutoPrintedAfterPaid = true;
      await _printInvoice();
    }

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Payment recorded successfully.')),
    );
  }

  void _onNavBarTap(int index) {
    switch (index) {
      case 0:
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const DashboardPage()),
        );
        break;
      case 1:
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const PaymentPage()),
        );
        break;
      case 2:
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const ProfilePage()),
        );
        break;
      case 3:
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const PrinterSettingsPage()),
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateText =
        '${DateFormat('dd MMM yyyy HH:mm').format(_toEat(widget.paidAt))} EAT';
    final invoiceId = ReceiptIdFormatter.displayInvoiceId(_invoiceNumber);
    final paymentId = ReceiptIdFormatter.displayPaymentId(_paymentId);

    return Scaffold(
      backgroundColor: BrandColors.background,
      appBar: buildBrandAppBar(title: 'Receipt Preview'),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Card(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: BrandColors.border),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(100),
                      child: Image.asset(
                        'assets/images/Logo.jpeg',
                        height: 56,
                        width: 56,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Garowe Local Government',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: BrandColors.textPrimary,
                            ),
                          ),
                          Text(
                            'Vehicle Tax Receipt',
                            style: TextStyle(color: BrandColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Divider(),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text(
                      'Status: ',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: _isPaid
                            ? Colors.green.shade100
                            : Colors.orange.shade100,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: _isPaid
                              ? Colors.green.shade300
                              : Colors.orange.shade300,
                        ),
                      ),
                      child: Text(
                        _isPaid ? 'PAID' : 'NOT PAID',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: _isPaid
                              ? Colors.green.shade800
                              : Colors.orange.shade800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('Invoice ID: $invoiceId'),
                if (_isPaid) Text('Receipt No: $invoiceId'),
                if (ReceiptIdFormatter.hasValue(_billNo))
                  Text('Bill No: ${ReceiptIdFormatter.trimValue(_billNo)}'),
                if (ReceiptIdFormatter.hasValue(_billNo))
                  Text('Ref ID: ${ReceiptIdFormatter.trimValue(_billNo)}'),
                Text('Payment ID: $paymentId'),
                Text('Date: $dateText'),
                const SizedBox(height: 8),
                Text('Plate: ${widget.plateNumber}'),
                Text('Owner: ${widget.ownerName}'),
                Text('Movement: ${widget.movementName}'),
                Text('Collector: ${widget.collectorName}'),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Unit: ${_amount(widget.unitAmount)}'),
                    Text('Qty: ${widget.quantity}'),
                    Text(
                      'Total: ${_amount(widget.totalAmount)}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (ReceiptIdFormatter.hasValue(_shortCode))
                  Text(
                      'Shortcode: ${ReceiptIdFormatter.trimValue(_shortCode)}'),
                const SizedBox(height: 20),
                if (widget.canRecordPayment) ...[
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed:
                          _isPaid || _savingPayment ? null : _recordPayment,
                      icon: _savingPayment
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check_circle),
                      label: Text(_isPaid ? 'PAID' : 'RECORD PAYMENT'),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _printingDirect ? null : _printInvoice,
                    icon: _printingDirect
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.print),
                    label: Text(
                      _printingDirect
                          ? 'PRINTING...'
                          : widget.canPrintInvoice
                              ? 'Print Invoice'
                              : 'Print Receipt',
                    ),
                  ),
                ),
                if (widget.canPrintInvoice) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _saveAsPdf,
                      icon: const Icon(Icons.picture_as_pdf),
                      label: const Text('Save as PDF'),
                    ),
                  ),
                ],
              ],

            ),
          ),
        ),
      ),
      bottomNavigationBar: AppBottomNav(
        currentIndex: 0,
        onTap: _onNavBarTap,
      ),
    );
  }
}
