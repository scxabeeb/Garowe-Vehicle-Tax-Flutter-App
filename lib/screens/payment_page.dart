import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_service.dart';
import '../services/session.dart';
import '../utils/payment_recording_parser.dart';
import '../utils/receipt_id_formatter.dart';
import 'invoice_preview_page.dart';

class PaymentPage extends StatefulWidget {
  const PaymentPage({super.key});

  @override
  State<PaymentPage> createState() => _PaymentPageState();
}

class _PaymentPageState extends State<PaymentPage> {
  static const Duration _eatOffset = Duration(hours: 3);

  final plateCtrl = TextEditingController();
  final ownerCtrl = TextEditingController();
  final mobileCtrl = TextEditingController();
  final qtyCtrl = TextEditingController(text: '1');

  bool loading = false;
  bool showRegister = false;

  String? successLabel;
  DateTime? paidAt;
  String? previewInvoiceNumber;
  String? previewBillNo;
  String? previewPaymentId;
  String? previewShortCode;
  bool invoiceGenerated = false;
  bool invoicePaid = false;
  bool paidToday = false;
  String? paidTodayTime;

  double unitAmount = 0;
  double totalAmount = 0;

  Map<String, dynamic>? vehicle;

  List<Map<String, dynamic>> carTypes = [];
  List<Map<String, dynamic>> movements = [];

  int? selectedCarTypeId;
  int? selectedMovementId;

  bool get isAdmin => (Session.role ?? '').toLowerCase() == 'admin';

  DateTime _toEat(DateTime input) => input.toUtc().add(_eatOffset);

  String _formatEatTime(DateTime input) =>
      '${DateFormat('HH:mm').format(_toEat(input))} EAT';

  String _toEatIsoString(DateTime input) {
    final eat = _toEat(input);
    return "${DateFormat("yyyy-MM-dd'T'HH:mm:ss").format(eat)}+03:00";
  }

  @override
  void dispose() {
    plateCtrl.dispose();
    ownerCtrl.dispose();
    mobileCtrl.dispose();
    qtyCtrl.dispose();
    super.dispose();
  }

  Future<String?> _getAccessToken() async {
    if (Session.accessToken != null && Session.accessToken!.isNotEmpty) {
      return Session.accessToken;
    }

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('accessToken');
    if (token != null && token.isNotEmpty) {
      Session.accessToken = token;
      return token;
    }

    return null;
  }

  Future<Map<String, String>> _authHeaders({bool json = false}) async {
    final headers = <String, String>{'Accept': 'application/json'};
    if (json) {
      headers['Content-Type'] = 'application/json';
    }

    final token = await _getAccessToken();
    if (token != null) {
      headers['Authorization'] = 'Bearer $token';
    }

    return headers;
  }

  int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  String _readString(
    Map<String, dynamic> map,
    List<String> keys, {
    String fallback = '',
  }) {
    for (final key in keys) {
      final value = map[key];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return fallback;
  }

  String _readScalarString(
    Map<String, dynamic> map,
    List<String> keys, {
    String fallback = '',
  }) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty && text.toLowerCase() != 'null') {
        return text;
      }
    }

    return fallback;
  }

  Map<String, dynamic>? _extractReceiptPayload(Map<String, dynamic> source) {
    return PaymentRecordingParser.extractReceiptPayload(source);
  }

  Future<Map<String, dynamic>?> _loadBackendReceipt(String paymentId) async {
    final parsedPaymentId = _toInt(paymentId);
    if (parsedPaymentId == null) {
      return null;
    }

    final token = await _getAccessToken();
    final response = await ApiService.getPaymentReceipt(
      parsedPaymentId,
      accessToken: token,
    );
    if (response == null) {
      return null;
    }

    return _extractReceiptPayload(response);
  }

  String _extractErrorMessage(
    Map<String, dynamic> error, {
    String fallback = 'Payment failed',
  }) {
    final direct = _readString(
      error,
      ['message', 'error', 'detail', 'title'],
      fallback: '',
    );
    if (direct.isNotEmpty) {
      return direct;
    }

    final errors = error['errors'];
    if (errors is Map<String, dynamic>) {
      for (final value in errors.values) {
        if (value is List && value.isNotEmpty) {
          return value.first.toString();
        }
        if (value is String && value.trim().isNotEmpty) {
          return value.trim();
        }
      }
    }

    return fallback;
  }

  List<Map<String, dynamic>> _asMapList(dynamic body) {
    if (body is List) {
      return body.whereType<Map<String, dynamic>>().toList();
    }

    if (body is Map<String, dynamic>) {
      final payload = body['data'] ?? body['items'] ?? body['results'];
      if (payload is List) {
        return payload.whereType<Map<String, dynamic>>().toList();
      }
    }

    return <Map<String, dynamic>>[];
  }

  List<Map<String, dynamic>> _normalizeTypes(
    List<Map<String, dynamic>> raw, {
    required String kind,
  }) {
    final normalized = raw
        .map((item) {
          final id = _toInt(item['id'] ?? item['${kind}Id']);
          final name = _readString(
            item,
            ['name', '${kind}Name', 'title', 'label'],
          );

          return {
            ...item,
            'id': id,
            'name': name,
          };
        })
        .where(
            (item) => item['id'] != null && (item['name'] as String).isNotEmpty)
        .toList();

    final byId = <int, Map<String, dynamic>>{};
    for (final item in normalized) {
      byId[item['id'] as int] = item;
    }

    return byId.values.toList();
  }

  void showMsg(String msg, {bool isError = true}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: isError ? Colors.red : Colors.green,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
  }

  void resetAfterPayment() {
    ownerCtrl.clear();
    mobileCtrl.clear();
    qtyCtrl.text = '1';

    setState(() {
      vehicle = null;
      showRegister = false;
      paidAt = null;
      previewInvoiceNumber = null;
      previewBillNo = null;
      previewPaymentId = null;
      previewShortCode = null;
      invoiceGenerated = false;
      invoicePaid = false;
      paidToday = false;
      paidTodayTime = null;
      unitAmount = 0;
      totalAmount = 0;
      selectedMovementId = null;
    });
  }

  void backToSearch() {
    ownerCtrl.clear();
    mobileCtrl.clear();

    setState(() {
      showRegister = false;
      vehicle = null;
      paidAt = null;
      previewInvoiceNumber = null;
      previewBillNo = null;
      previewPaymentId = null;
      previewShortCode = null;
      invoiceGenerated = false;
      invoicePaid = false;
      paidToday = false;
      paidTodayTime = null;
      unitAmount = 0;
      totalAmount = 0;
      selectedMovementId = null;
    });
  }

  DateTime? _parsePaymentDate(Map<String, dynamic> payment) {
    final candidates = [
      payment['paidAt'],
      payment['date'],
      payment['createdAt'],
      payment['time'],
    ];

    for (final candidate in candidates) {
      if (candidate is String && candidate.trim().isNotEmpty) {
        final parsed = DateTime.tryParse(candidate.trim());
        if (parsed != null) return _toEat(parsed);
      }
    }

    return null;
  }

  Future<void> _checkPaidTodayStatus(String plate) async {
    try {
      final res = await http.get(
        Uri.parse('${ApiService.baseUrl}/Dashboard'),
        headers: await _authHeaders(),
      );

      if (res.statusCode != 200) {
        setState(() {
          paidToday = false;
          paidTodayTime = null;
        });
        return;
      }

      final body = jsonDecode(res.body);
      final list = body is Map<String, dynamic> ? body['todaysPayments'] : null;
      if (list is! List) {
        setState(() {
          paidToday = false;
          paidTodayTime = null;
        });
        return;
      }

      Map<String, dynamic>? latest;
      DateTime? latestDate;
      final targetPlate = plate.trim().toUpperCase();

      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        if (item['isReverted'] == true) continue;

        final itemPlate = (item['plate'] ?? item['plateNumber'] ?? '')
            .toString()
            .toUpperCase();
        if (itemPlate != targetPlate) continue;

        final parsedDate = _parsePaymentDate(item);
        if (parsedDate == null) continue;

        if (latestDate == null || parsedDate.isAfter(latestDate)) {
          latestDate = parsedDate;
          latest = item;
        }
      }

      if (latest != null && latestDate != null) {
        setState(() {
          paidToday = true;
          paidTodayTime = _formatEatTime(latestDate!);
        });
      } else {
        setState(() {
          paidToday = false;
          paidTodayTime = null;
        });
      }
    } catch (_) {
      setState(() {
        paidToday = false;
        paidTodayTime = null;
      });
    }
  }

  Future<void> _loadMovementsForCarType(int carTypeId) async {
    final token = await _getAccessToken();
    final raw = await ApiService.getMovementsByCarType(
      carTypeId,
      accessToken: token,
    );
    final normalized = _normalizeTypes(raw, kind: 'movement');

    if (normalized.isEmpty) {
      setState(() {
        movements = [];
        selectedMovementId = null;
      });
      return;
    }

    final compatible = <Map<String, dynamic>>[];
    for (final movement in normalized) {
      final movementId = movement['id'] as int?;
      if (movementId == null) continue;
      final amount = await ApiService.getTaxAmountByMovement(
        carTypeId,
        movementId,
        accessToken: token,
      );
      if (amount != null) {
        compatible.add({
          ...movement,
          'taxAmount': amount,
        });
      }
    }

    final nextSelected =
        compatible.any((item) => item['id'] == selectedMovementId)
            ? selectedMovementId
            : null;

    setState(() {
      movements = compatible;
      selectedMovementId = nextSelected;
      if (nextSelected == null) {
        unitAmount = 0;
        totalAmount = 0;
      }
    });
  }

  Future<void> _openReceiptPreview({
    required String receiptNumber,
    required String billNo,
    required String paymentId,
    required String shortCode,
  }) async {
    if (vehicle == null || selectedMovementId == null) return;

    final quantity = int.tryParse(qtyCtrl.text.trim()) ?? 1;
    final movement = movements.firstWhere((m) => m['id'] == selectedMovementId);
    final now = paidAt ?? DateTime.now();

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => InvoicePreviewPage(
          invoiceNumber: receiptNumber,
          billNo: billNo,
          paymentId: paymentId,
          shortCode: shortCode,
          plateNumber: _readString(vehicle!, ['plateNumber', 'plate']),
          ownerName: _readString(vehicle!, ['ownerName', 'owner']),
          movementName: movement['name'].toString(),
          quantity: quantity,
          unitAmount: unitAmount,
          totalAmount: totalAmount,
          collectorName: Session.username ?? '-',
          paidAt: now,
          isPaid: invoicePaid,
          canRecordPayment: isAdmin,
          onRecordPayment: _recordPaymentFromInvoice,
        ),
      ),
    );
  }

  Future<void> _generateInvoicePreview() async {
    if (invoiceGenerated) {
      if (!invoicePaid &&
          previewInvoiceNumber != null &&
          previewBillNo != null &&
          previewPaymentId != null &&
          previewShortCode != null) {
        await _openReceiptPreview(
          receiptNumber: previewInvoiceNumber!,
          billNo: previewBillNo!,
          paymentId: previewPaymentId!,
          shortCode: previewShortCode!,
        );
        return;
      }

      showMsg('Preview already generated. Open it again or change details.');
      return;
    }

    if (vehicle == null || selectedMovementId == null) {
      showMsg('Select vehicle and movement first.');
      return;
    }

    final quantity = int.tryParse(qtyCtrl.text.trim()) ?? 1;
    if (quantity <= 0) {
      showMsg('Quantity must be at least 1.');
      return;
    }

    calcTotal();

    setState(() {
      previewInvoiceNumber = '';
      previewBillNo = '';
      previewPaymentId = '';
      previewShortCode = '';
      invoiceGenerated = true;
      invoicePaid = false;
    });

    if (!mounted) return;

    await _openReceiptPreview(
      receiptNumber: '',
      billNo: '',
      paymentId: '',
      shortCode: '',
    );
  }

  Future<void> pickPaidAt() async {
    final now = DateTime.now();
    final initial = paidAt ?? now;

    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (date == null) return;
    if (!mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return;
    if (!mounted) return;

    setState(() {
      paidAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
      invoiceGenerated = false;
      invoicePaid = false;
      previewInvoiceNumber = null;
      previewBillNo = null;
      previewPaymentId = null;
      previewShortCode = null;
    });
  }

  Future<void> loadCarTypes() async {
    final res = await http.get(
      Uri.parse('${ApiService.baseUrl}/cartypes'),
      headers: await _authHeaders(),
    );
    if (res.statusCode == 200) {
      final raw = _asMapList(jsonDecode(res.body));
      carTypes = _normalizeTypes(raw, kind: 'carType');
      if (carTypes.isNotEmpty) selectedCarTypeId = carTypes.first['id'];
    }
  }

  Future<void> loadMovements() async {
    final res = await http.get(
      Uri.parse('${ApiService.baseUrl}/movements'),
      headers: await _authHeaders(),
    );
    if (res.statusCode == 200) {
      final raw = _asMapList(jsonDecode(res.body));
      final normalized = _normalizeTypes(raw, kind: 'movement');
      final uniqueByName = <String, Map<String, dynamic>>{};
      for (final item in normalized) {
        final name = item['name'].toString().trim().toLowerCase();
        if (name.isNotEmpty && !uniqueByName.containsKey(name)) {
          uniqueByName[name] = item;
        }
      }
      movements = uniqueByName.values.toList();
      selectedMovementId = null;
    }
  }

  Future<void> searchVehicle() async {
    final plate = plateCtrl.text.trim().toUpperCase();

    if (plate.isEmpty) {
      showMsg('Enter plate number');
      return;
    }

    try {
      setState(() {
        loading = true;
        successLabel = null;
      });

      final token = await _getAccessToken();
      final result = await ApiService.getVehicle(plate, accessToken: token);

      if (result == null) {
        await loadCarTypes();
        setState(() {
          vehicle = null;
          showRegister = true;
          paidToday = false;
          paidTodayTime = null;
          invoiceGenerated = false;
          invoicePaid = false;
          previewInvoiceNumber = null;
          previewBillNo = null;
          previewPaymentId = null;
          previewShortCode = null;
          loading = false;
        });
        showMsg('Vehicle not found. Please register.');
        return;
      }

      unitAmount = 0;
      totalAmount = 0;
      final vehicleCarTypeId =
          _toInt(result['carTypeId'] ?? result['carType']?['id']);

      setState(() {
        vehicle = result;
        showRegister = false;
        ownerCtrl.text = _readString(result, ['ownerName', 'owner']);
        mobileCtrl.text =
            _readString(result, ['mobile', 'phone', 'phoneNumber']);
        selectedCarTypeId = vehicleCarTypeId;
        movements = [];
        selectedMovementId = null;
        invoiceGenerated = false;
        invoicePaid = false;
        previewInvoiceNumber = null;
        previewBillNo = null;
        previewPaymentId = null;
        previewShortCode = null;
      });

      if (vehicleCarTypeId != null) {
        await _loadMovementsForCarType(vehicleCarTypeId);
      }

      await _checkPaidTodayStatus(plate);

      if (mounted) {
        setState(() {
          loading = false;
        });
      }
    } catch (_) {
      setState(() => loading = false);
      showMsg('Failed loading payment screen');
    }
  }

  Future<void> registerVehicle() async {
    if (ownerCtrl.text.trim().isEmpty ||
        mobileCtrl.text.trim().isEmpty ||
        selectedCarTypeId == null) {
      showMsg('Fill all fields');
      return;
    }

    setState(() => loading = true);

    final res = await http.post(
      Uri.parse('${ApiService.baseUrl}/vehicles'),
      headers: await _authHeaders(json: true),
      body: jsonEncode({
        'plateNumber': plateCtrl.text.trim(),
        'plate': plateCtrl.text.trim(),
        'ownerName': ownerCtrl.text.trim(),
        'owner': ownerCtrl.text.trim(),
        'mobile': mobileCtrl.text.trim(),
        'phone': mobileCtrl.text.trim(),
        'phoneNumber': mobileCtrl.text.trim(),
        'carTypeId': selectedCarTypeId,
      }),
    );

    if (res.statusCode != 200 && res.statusCode != 201) {
      showMsg('Registration failed');
      setState(() => loading = false);
      return;
    }

    final v = jsonDecode(res.body);
    final registeredVehicle = Map<String, dynamic>.from(v as Map);
    final registeredCarTypeId = _toInt(
        registeredVehicle['carTypeId'] ?? registeredVehicle['carType']?['id']);

    if (registeredCarTypeId != null) {
      await _loadMovementsForCarType(registeredCarTypeId);
    }

    if (selectedMovementId != null && movements.isNotEmpty) {
      final movementName =
          movements.firstWhere((m) => m['id'] == selectedMovementId)['name'];
      if (registeredCarTypeId != null) {
        final token = await _getAccessToken();
        unitAmount = await ApiService.getTaxAmount(
          registeredCarTypeId,
          movementName,
          accessToken: token,
        );
        calcTotal();
      }
    }

    setState(() {
      vehicle = registeredVehicle;
      showRegister = false;
      selectedCarTypeId = registeredCarTypeId;
      invoiceGenerated = false;
      invoicePaid = false;
      previewInvoiceNumber = null;
      previewBillNo = null;
      previewPaymentId = null;
      previewShortCode = null;
      loading = false;
    });
  }

  void calcTotal() {
    final q = int.tryParse(qtyCtrl.text) ?? 1;
    totalAmount = unitAmount * q;
  }

  Future<dynamic> _submitPaymentRequest() async {
    if (vehicle == null) {
      showMsg('Vehicle is required');
      return {'message': 'Vehicle is required'};
    }

    if (selectedMovementId == null) {
      showMsg('Select movement');
      return {'message': 'Select movement'};
    }

    if (!invoiceGenerated) {
      showMsg('Generate receipt before recording payment.');
      return {'message': 'Generate receipt before recording payment.'};
    }

    final token = await _getAccessToken();
    if (token == null || token.isEmpty) {
      showMsg('Login required');
      return {'message': 'Login required'};
    }

    final quantity = int.tryParse(qtyCtrl.text.trim()) ?? 1;
    final plate = _readString(
      vehicle!,
      ['plateNumber', 'plate'],
      fallback: plateCtrl.text.trim(),
    );
    final movement = movements.firstWhere((m) => m['id'] == selectedMovementId);
    final movementName = movement['name'].toString();
    final vehicleId = _toInt(vehicle!['id'] ?? vehicle!['vehicleId']);
    final prefs = await SharedPreferences.getInstance();
    final collectorId = Session.userId ?? prefs.getInt('userId');
    final collectorUsername =
        (Session.username ?? prefs.getString('username') ?? '').trim();

    setState(() => loading = true);
    final effectivePaidAt =
        isAdmin && paidAt != null ? paidAt! : DateTime.now();

    final payload = <String, dynamic>{
      'plateNumber': plate,
      'movementId': selectedMovementId,
      'quantity': quantity,
      'paidAt': _toEatIsoString(effectivePaidAt),
      'plate': plate,
      'vehicleId': vehicleId,
      'movement': movementName,
      'movementName': movementName,
      'unitAmount': unitAmount,
      'amount': totalAmount,
      'totalAmount': totalAmount,
      'paidAtEat': _toEatIsoString(effectivePaidAt),
      'collectorId': collectorId,
      'userId': collectorId,
      'collectorUsername': collectorUsername,
      'collectorName': collectorUsername,
      'username': collectorUsername,
    };

    final referenceNumber = ReceiptIdFormatter.trimValue(previewBillNo ?? '');
    if (referenceNumber.isNotEmpty) {
      payload['referenceNumber'] = referenceNumber;
      payload['billNo'] = referenceNumber;
      payload['billNumber'] = referenceNumber;
    }

    final result = await ApiService.pay(payload, accessToken: token);

    setState(() => loading = false);

    return result;
  }

  Future<Map<String, String>?> _recordPaymentFromInvoice() async {
    final result = await _submitPaymentRequest();

    if (result is Map<String, dynamic> && result['success'] == true) {
      final paymentIdFromCreate = _readScalarString(
        result,
        ['paymentId'],
      );
      final receipt = paymentIdFromCreate.isEmpty
          ? null
          : await _loadBackendReceipt(paymentIdFromCreate);
      final source = receipt ?? result;
      final parsedRecord = PaymentRecordingParser.parse(
        source,
        fallbackInvoice: previewInvoiceNumber ?? '',
        fallbackPayment: paymentIdFromCreate.isEmpty
            ? (previewPaymentId ?? '')
            : paymentIdFromCreate,
        fallbackBillNo: previewBillNo ?? '',
        fallbackShortCode: ReceiptIdFormatter.buildShortCode(
          previewInvoiceNumber ?? '',
        ),
      );

      final savedInvoiceId = parsedRecord.invoiceNumber;
      final savedPaymentId = parsedRecord.paymentId;
      final savedBillNo = parsedRecord.billNo;
      final savedShortCode = parsedRecord.shortCode;

      if (mounted) {
        setState(() {
          previewInvoiceNumber = savedInvoiceId;
          previewPaymentId = savedPaymentId;
          previewBillNo = savedBillNo;
          previewShortCode = savedShortCode;
          invoicePaid = true;
          paidToday = true;
          paidTodayTime = _formatEatTime(DateTime.now());
        });
      }
      showMsg('Payment saved', isError: false);
      return {
        'invoiceNumber': savedInvoiceId,
        'paymentId': savedPaymentId,
        'billNo': savedBillNo,
        'shortCode': savedShortCode,
      };
    }

    if (result is Map<String, dynamic>) {
      showMsg(_extractErrorMessage(result));
      return null;
    }

    showMsg('Payment failed');
    return null;
  }

  Future<void> _onMovementChanged(int? value) async {
    setState(() {
      selectedMovementId = value;
      invoiceGenerated = false;
      invoicePaid = false;
      previewInvoiceNumber = null;
      previewBillNo = null;
      previewPaymentId = null;
      previewShortCode = null;
    });

    if (value == null || vehicle == null) {
      return;
    }

    final movementName = movements.firstWhere((x) => x['id'] == value)['name'];
    final carTypeId =
        _toInt(vehicle!['carTypeId'] ?? vehicle!['carType']?['id']);
    if (carTypeId == null) {
      showMsg('Vehicle does not include car type.');
      return;
    }

    setState(() => loading = true);
    final token = await _getAccessToken();
    unitAmount = await ApiService.getTaxAmountByMovement(
          carTypeId,
          value,
          accessToken: token,
        ) ??
        await ApiService.getTaxAmount(
          carTypeId,
          movementName,
          accessToken: token,
        );

    if (!mounted) return;
    setState(() {
      calcTotal();
      loading = false;
    });
  }

  Widget _sectionCard({required Widget child}) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    );
  }

  Widget _readOnlyField(String label, TextEditingController controller) {
    return TextField(
      controller: controller,
      readOnly: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final invoiceDisplay = previewInvoiceNumber == null
        ? null
        : ReceiptIdFormatter.displayInvoiceId(previewInvoiceNumber!);
    final paymentDisplay = previewPaymentId == null
        ? null
        : ReceiptIdFormatter.displayPaymentId(previewPaymentId!);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Collect Vehicle Tax and Generate Receipt'),
        actions: [
          if (vehicle != null || showRegister)
            IconButton(
              onPressed: loading ? null : backToSearch,
              icon: const Icon(Icons.refresh),
              tooltip: 'Start over',
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: plateCtrl,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Plate Number',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) {
                      setState(() {
                        invoiceGenerated = false;
                        invoicePaid = false;
                        previewInvoiceNumber = null;
                        previewBillNo = null;
                        previewPaymentId = null;
                        previewShortCode = null;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: loading ? null : searchVehicle,
                    icon: loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search),
                    label: Text(loading ? 'SEARCHING...' : 'SEARCH VEHICLE'),
                  ),
                  if (successLabel != null) ...[
                    const SizedBox(height: 8),
                    Text(successLabel!),
                  ],
                ],
              ),
            ),
            if (paidToday) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: Text(
                  paidTodayTime == null
                      ? 'This vehicle already has a payment recorded today.'
                      : 'This vehicle was already paid today at $paidTodayTime.',
                  style: TextStyle(
                    color: Colors.orange.shade900,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            if (showRegister) ...[
              const SizedBox(height: 12),
              _sectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Vehicle not found. Register it to continue.',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: ownerCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Owner Name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: mobileCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Mobile Number',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      initialValue: carTypes
                              .any((item) => item['id'] == selectedCarTypeId)
                          ? selectedCarTypeId
                          : null,
                      items: carTypes
                          .map(
                            (item) => DropdownMenuItem<int>(
                              value: item['id'] as int,
                              child: Text(item['name'].toString()),
                            ),
                          )
                          .toList(),
                      decoration: const InputDecoration(
                        labelText: 'Car Type',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: loading
                          ? null
                          : (value) =>
                              setState(() => selectedCarTypeId = value),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: loading ? null : registerVehicle,
                      icon: const Icon(Icons.app_registration),
                      label: const Text('REGISTER VEHICLE'),
                    ),
                  ],
                ),
              ),
            ],
            if (vehicle != null) ...[
              const SizedBox(height: 12),
              _sectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Payment Details',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    _readOnlyField('Owner Name', ownerCtrl),
                    const SizedBox(height: 12),
                    _readOnlyField('Mobile Number', mobileCtrl),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      initialValue: movements
                              .any((item) => item['id'] == selectedMovementId)
                          ? selectedMovementId
                          : null,
                      items: movements
                          .map(
                            (item) => DropdownMenuItem<int>(
                              value: item['id'] as int,
                              child: Text(item['name'].toString()),
                            ),
                          )
                          .toList(),
                      decoration: const InputDecoration(
                        labelText: 'Movement',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: loading ? null : _onMovementChanged,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: qtyCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Quantity',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() {
                        calcTotal();
                        invoiceGenerated = false;
                        invoicePaid = false;
                        previewInvoiceNumber = null;
                        previewBillNo = null;
                        previewPaymentId = null;
                        previewShortCode = null;
                      }),
                    ),
                    if (isAdmin) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: loading ? null : pickPaidAt,
                        icon: const Icon(Icons.schedule),
                        label: Text(
                          paidAt == null
                              ? 'Choose Paid Time'
                              : 'Paid At: ${DateFormat('dd MMM yyyy HH:mm').format(_toEat(paidAt!))} EAT',
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      'Unit Amount: \$${unitAmount.toStringAsFixed(2)}',
                      style: const TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Total Amount: \$${totalAmount.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (previewInvoiceNumber != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Invoice ID: ${invoiceDisplay ?? ''}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text('Payment ID: ${paymentDisplay ?? ''}'),
                      if ((previewBillNo ?? '').trim().isNotEmpty)
                        Text('Bill No: ${previewBillNo ?? ''}'),
                      if ((previewShortCode ?? '').trim().isNotEmpty)
                        Text('Shortcode: ${previewShortCode ?? ''}'),
                    ],
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: loading ||
                              selectedMovementId == null ||
                              invoiceGenerated
                          ? null
                          : _generateInvoicePreview,
                      icon: const Icon(Icons.receipt_long),
                      label: const Text('GENERATE RECEIPT'),
                    ),
                    if (invoicePaid) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: loading ? null : resetAfterPayment,
                        icon: const Icon(Icons.done_all),
                        label: const Text('NEW PAYMENT'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
