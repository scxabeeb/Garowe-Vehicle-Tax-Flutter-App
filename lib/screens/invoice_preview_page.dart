import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:unified_esc_pos_printer/unified_esc_pos_printer.dart';

import '../services/esc_pos_printer_service.dart';
import '../utils/receipt_id_formatter.dart';

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
  final Future<Map<String, String>?> Function()? onRecordPayment;

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
    this.onRecordPayment,
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

  DateTime _toEat(DateTime input) => input.toUtc().add(_eatOffset);

  @override
  void initState() {
    super.initState();
    _isPaid = widget.isPaid;
    _invoiceNumber = widget.invoiceNumber;
    _billNo = widget.billNo;
    _paymentId = widget.paymentId;
    _shortCode = widget.shortCode;
  }

  @override
  void dispose() {
    _printerService.dispose();
    super.dispose();
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
              if (ReceiptIdFormatter.hasValue(_billNo))
                pw.Text('Bill No: ${ReceiptIdFormatter.trimValue(_billNo)}'),
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
      final printers = await _printerService.scanSupportedPrinters();

      if (!mounted) return;
      if (printers.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'No USB/Bluetooth printer found. Turn on and pair/connect printer first.'),
          ),
        );
        return;
      }

      var selected = await _printerService.resolvePreferredPrinter(printers);
      if (!mounted) return;
      if (selected == null) {
        selected = await _pickPrinter(printers);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Using saved printer: ${_printerService.printerLabel(selected)}'),
            duration: const Duration(seconds: 2),
          ),
        );
      }

      if (!mounted || selected == null) return;
      await _printerService.savePreferredPrinter(selected);

      await _printerService.printReceipt(
        printer: selected,
        data: ReceiptPrintData(
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
        ),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Printed successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Print failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _printingDirect = false);
      }
    }
  }

  Future<PrinterDevice?> _pickPrinter(List<PrinterDevice> printers) {
    return showModalBottomSheet<PrinterDevice>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: printers.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final printer = printers[index];
              return ListTile(
                leading: Icon(
                  printer.connectionType == PrinterConnectionType.usb
                      ? Icons.usb
                      : Icons.bluetooth,
                ),
                title: Text(_printerService.printerLabel(printer)),
                onTap: () => Navigator.of(context).pop(printer),
              );
            },
          ),
        );
      },
    );
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

    setState(() => _savingPayment = true);
    final result = await widget.onRecordPayment!.call();
    if (!mounted) return;

    setState(() {
      _savingPayment = false;
      if (result != null) {
        _isPaid = true;
        _invoiceNumber = result['invoiceNumber'] ?? _invoiceNumber;
        _billNo = result['billNo'] ?? _billNo;
        _paymentId = result['paymentId'] ?? _paymentId;
        _shortCode = result['shortCode'] ?? _shortCode;
      }
    });

    if (result == null || !mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Payment recorded. Printing receipt...')),
    );

    await _printInvoice();
  }

  @override
  Widget build(BuildContext context) {
    final dateText =
        '${DateFormat('dd MMM yyyy HH:mm').format(_toEat(widget.paidAt))} EAT';
    final invoiceId = ReceiptIdFormatter.displayInvoiceId(_invoiceNumber);
    final paymentId = ReceiptIdFormatter.displayPaymentId(_paymentId);

    return Scaffold(
      appBar: AppBar(title: const Text('Receipt Preview')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Card(
          elevation: 3,
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
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text('Vehicle Tax Receipt'),
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
                if (ReceiptIdFormatter.hasValue(_billNo))
                  Text('Bill No: ${ReceiptIdFormatter.trimValue(_billNo)}'),
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
                    label: Text(_printingDirect
                        ? 'PRINTING...'
                        : 'Print (USB/Bluetooth)'),
                  ),
                ),
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
            ),
          ),
        ),
      ),
    );
  }
}
