import 'dart:io';

import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unified_esc_pos_printer/unified_esc_pos_printer.dart';

import '../utils/receipt_id_formatter.dart';

class ReceiptPrintData {
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

  const ReceiptPrintData({
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
  });
}

class EscPosPrinterService {
  final PrinterManager _manager = PrinterManager();
  static const Duration _eatOffset = Duration(hours: 3);
  static const String _prefPrinterType = 'printer.default.type';
  static const String _prefPrinterKey = 'printer.default.key';
  static const String _prefPaperWidthMm = 'printer.paper_width_mm';

  Future<List<PrinterDevice>> scanSupportedPrinters() async {
    await _ensurePermissions();
    final all = await _manager.scanPrinters(
      timeout: const Duration(seconds: 6),
      types: const {
        PrinterConnectionType.bluetooth,
        PrinterConnectionType.usb,
      },
    );

    return all;
  }

  Future<void> printReceipt({
    required PrinterDevice printer,
    required ReceiptPrintData data,
  }) async {
    await _ensurePermissions();
    await _manager.connect(printer, timeout: const Duration(seconds: 12));

    try {
      final paperWidthMm = await getPreferredPaperWidthMm();
      final paperSize = paperWidthMm == 58 ? PaperSize.mm58 : PaperSize.mm80;
      final ticket = await Ticket.create(paperSize);
      final dateText = _formatDate(data.paidAt);
      final invoiceId = ReceiptIdFormatter.displayInvoiceId(data.invoiceNumber);
      final paymentId = ReceiptIdFormatter.displayPaymentId(data.paymentId);

      ticket.text(
        'Garowe Local Government',
        align: PrintAlign.center,
        style: const PrintTextStyle(
          bold: true,
          height: TextSize.size2,
          width: TextSize.size2,
        ),
      );
      ticket.text('Vehicle Tax Receipt', align: PrintAlign.center);
      ticket.separator();
      ticket.text('Invoice ID: $invoiceId');
      if (ReceiptIdFormatter.hasValue(data.billNo)) {
        ticket.text('Bill No: ${ReceiptIdFormatter.trimValue(data.billNo)}');
      }
      ticket.text('Payment ID: $paymentId');
      ticket.text('Status: ${data.isPaid ? 'PAID' : 'NOT PAID'}');
      ticket.text('Date: $dateText');
      ticket.feed(1);
      ticket.text('Plate: ${data.plateNumber}');
      ticket.text('Owner: ${data.ownerName}');
      ticket.text('Movement: ${data.movementName}');
      ticket.text('Collector: ${data.collectorName}');
      ticket.feed(1);
      ticket.row([
        PrintColumn(text: 'Unit', flex: 4),
        PrintColumn(
            text: _amount(data.unitAmount), flex: 8, align: PrintAlign.right),
      ]);
      ticket.row([
        PrintColumn(text: 'Qty', flex: 4),
        PrintColumn(text: '${data.quantity}', flex: 8, align: PrintAlign.right),
      ]);
      ticket.row([
        PrintColumn(
          text: 'TOTAL',
          flex: 4,
          style: const PrintTextStyle(bold: true),
        ),
        PrintColumn(
          text: _amount(data.totalAmount),
          flex: 8,
          align: PrintAlign.right,
          style: const PrintTextStyle(bold: true),
        ),
      ]);
      if (ReceiptIdFormatter.hasValue(data.shortCode)) {
        ticket.feed(1);
        ticket
            .text('Shortcode: ${ReceiptIdFormatter.trimValue(data.shortCode)}');
      }
      ticket.separator(char: '=');
      ticket.text('Thank you', align: PrintAlign.center);
      ticket.feed(2);
      ticket.cut();

      await _manager.printTicket(ticket);
    } finally {
      await _manager.disconnect();
    }
  }

  Future<void> savePreferredPrinter(PrinterDevice device) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefPrinterType, _typeKey(device.connectionType));
    await prefs.setString(_prefPrinterKey, printerStableKey(device));
  }

  Future<PrinterDevice?> resolvePreferredPrinter(
      List<PrinterDevice> scanned) async {
    final saved = await getSavedPrinterIdentity();
    final savedType = saved?['type'];
    final savedKey = saved?['key'];

    if (savedType == null || savedKey == null) {
      return null;
    }

    for (final device in scanned) {
      if (_typeKey(device.connectionType) == savedType &&
          printerStableKey(device) == savedKey) {
        return device;
      }
    }

    return null;
  }

  Future<Map<String, String>?> getSavedPrinterIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    final type = prefs.getString(_prefPrinterType);
    final key = prefs.getString(_prefPrinterKey);
    if (type == null || key == null) {
      return null;
    }

    return {
      'type': type,
      'key': key,
    };
  }

  Future<bool> isSavedPrinter(PrinterDevice device) async {
    final saved = await getSavedPrinterIdentity();
    if (saved == null) return false;

    return saved['type'] == _typeKey(device.connectionType) &&
        saved['key'] == printerStableKey(device);
  }

  Future<void> clearPreferredPrinter() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefPrinterType);
    await prefs.remove(_prefPrinterKey);
  }

  Future<int> getPreferredPaperWidthMm() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_prefPaperWidthMm);
    if (saved == 58 || saved == 80) {
      return saved!;
    }
    return 80;
  }

  Future<void> setPreferredPaperWidthMm(int mm) async {
    final value = mm == 58 ? 58 : 80;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefPaperWidthMm, value);
  }

  String printerLabel(PrinterDevice device) {
    String type;
    switch (device.connectionType) {
      case PrinterConnectionType.usb:
        type = 'USB';
        break;
      case PrinterConnectionType.bluetooth:
        type = 'Bluetooth';
        break;
      case PrinterConnectionType.ble:
        type = 'BLE';
        break;
      case PrinterConnectionType.network:
        type = 'Network';
        break;
    }

    if (device is UsbPrinterDevice) {
      return '$type • ${device.name} • ${device.identifier}';
    }
    if (device is BluetoothPrinterDevice) {
      return '$type • ${device.name} • ${device.address}';
    }
    return '$type • ${device.name}';
  }

  String printerStableKey(PrinterDevice device) {
    return _deviceKey(device);
  }

  Future<void> dispose() => _manager.dispose();

  Future<void> _ensurePermissions() async {
    if (!Platform.isAndroid) {
      return;
    }

    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  String _formatDate(DateTime input) {
    final dt = input.toUtc().add(_eatOffset);
    final yyyy = dt.year.toString().padLeft(4, '0');
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$yyyy-$mm-$dd $hh:$min EAT';
  }

  String _amount(double value) {
    final fixed = value.toStringAsFixed(2);
    return fixed
        .replaceFirst(RegExp(r'\\.00$'), '')
        .replaceFirst(RegExp(r'0$'), '');
  }

  String _typeKey(PrinterConnectionType type) {
    switch (type) {
      case PrinterConnectionType.usb:
        return 'usb';
      case PrinterConnectionType.bluetooth:
        return 'bluetooth';
      case PrinterConnectionType.ble:
        return 'ble';
      case PrinterConnectionType.network:
        return 'network';
    }
  }

  String _deviceKey(PrinterDevice device) {
    if (device is UsbPrinterDevice) {
      return device.identifier;
    }
    if (device is BluetoothPrinterDevice) {
      return device.address;
    }
    if (device is BlePrinterDevice) {
      return device.deviceId;
    }
    if (device is NetworkPrinterDevice) {
      return '${device.host}:${device.port}';
    }
    return device.name;
  }
}
