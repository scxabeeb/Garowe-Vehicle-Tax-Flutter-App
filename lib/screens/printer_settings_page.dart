import 'package:flutter/material.dart';
import 'package:unified_esc_pos_printer/unified_esc_pos_printer.dart';

import '../services/esc_pos_printer_service.dart';

class PrinterSettingsPage extends StatefulWidget {
  const PrinterSettingsPage({super.key});

  @override
  State<PrinterSettingsPage> createState() => _PrinterSettingsPageState();
}

class _PrinterSettingsPageState extends State<PrinterSettingsPage> {
  final EscPosPrinterService _printerService = EscPosPrinterService();

  bool _loading = true;
  bool _scanning = false;
  int _paperWidthMm = 80;
  String? _savedPrinterType;
  String? _savedPrinterKey;
  List<PrinterDevice> _printers = const [];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _printerService.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final paper = await _printerService.getPreferredPaperWidthMm();
    final saved = await _printerService.getSavedPrinterIdentity();

    if (!mounted) return;
    setState(() {
      _paperWidthMm = paper;
      _savedPrinterType = saved?['type'];
      _savedPrinterKey = saved?['key'];
      _loading = false;
    });
  }

  Future<void> _scanPrinters() async {
    if (_scanning) return;

    setState(() => _scanning = true);
    try {
      final printers = await _printerService.scanSupportedPrinters();
      if (!mounted) return;
      setState(() => _printers = printers);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to scan printers: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _scanning = false);
      }
    }
  }

  Future<void> _setPaperWidth(int? value) async {
    if (value == null) return;
    await _printerService.setPreferredPaperWidthMm(value);

    if (!mounted) return;
    setState(() => _paperWidthMm = value);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Paper width set to ${value}mm.')),
    );
  }

  Future<void> _setDefaultPrinter(PrinterDevice printer) async {
    await _printerService.savePreferredPrinter(printer);
    final saved = await _printerService.getSavedPrinterIdentity();

    if (!mounted) return;
    setState(() {
      _savedPrinterType = saved?['type'];
      _savedPrinterKey = saved?['key'];
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Default printer saved: ${_printerService.printerLabel(printer)}'),
      ),
    );
  }

  Future<void> _clearDefaultPrinter() async {
    await _printerService.clearPreferredPrinter();
    if (!mounted) return;

    setState(() {
      _savedPrinterType = null;
      _savedPrinterKey = null;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Default printer cleared.')),
    );
  }

  bool _isSavedDevice(PrinterDevice printer) {
    return _savedPrinterType == _typeKey(printer.connectionType) &&
        _savedPrinterKey == _printerService.printerStableKey(printer);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Printer Settings'),
        backgroundColor: const Color(0xFF0B57D0),
        foregroundColor: Colors.white,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  elevation: 0,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Paper Width',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 10),
                        DropdownButtonFormField<int>(
                          value: _paperWidthMm,
                          items: const [
                            DropdownMenuItem(value: 80, child: Text('80mm (recommended)')),
                            DropdownMenuItem(value: 58, child: Text('58mm')),
                          ],
                          onChanged: _setPaperWidth,
                          decoration: const InputDecoration(
                            labelText: 'Receipt paper size',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  elevation: 0,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Default Printer',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _savedPrinterKey == null
                              ? 'No default printer selected.'
                              : 'Saved printer key: $_savedPrinterType / $_savedPrinterKey',
                          style: TextStyle(color: Colors.blueGrey.shade700),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: _scanning ? null : _scanPrinters,
                                icon: _scanning
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Icon(Icons.search),
                                label: Text(_scanning ? 'Scanning...' : 'Scan Printers'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            OutlinedButton.icon(
                              onPressed: _savedPrinterKey == null ? null : _clearDefaultPrinter,
                              icon: const Icon(Icons.delete_outline),
                              label: const Text('Clear'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (_printers.isEmpty)
                          const Text('No scanned printers yet.')
                        else
                          Column(
                            children: _printers.map((printer) {
                              final isSaved = _isSavedDevice(printer);
                              return ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  printer.connectionType == PrinterConnectionType.usb
                                      ? Icons.usb
                                      : Icons.bluetooth,
                                ),
                                title: Text(_printerService.printerLabel(printer)),
                                trailing: isSaved
                                    ? const Chip(
                                        label: Text('Default'),
                                        visualDensity: VisualDensity.compact,
                                      )
                                    : TextButton(
                                        onPressed: () => _setDefaultPrinter(printer),
                                        child: const Text('Set Default'),
                                      ),
                              );
                            }).toList(),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
