import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_service.dart';
import '../services/session.dart';
import '../utils/receipt_id_formatter.dart';
import '../widgets/app_bottom_nav.dart';
import 'dashboard_page.dart';
import 'invoice_preview_page.dart';
import 'printer_settings_page.dart';
import 'profile_page.dart';

class PaymentPage extends StatefulWidget {
  const PaymentPage({super.key});

  @override
  State<PaymentPage> createState() => _PaymentPageState();
}

class _PaymentPageState extends State<PaymentPage> {
  static const Duration _eatOffset = Duration(hours: 3);
  static const Duration _refreshInterval = Duration(seconds: 5);

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

  Timer? _refreshTimer;

  DateTime _toEat(DateTime input) => input.toUtc().add(_eatOffset);

  String _formatEatTime(DateTime input) =>
      '${DateFormat('HH:mm').format(_toEat(input))} EAT';

  String _toEatIsoString(DateTime input) {
    final eat = _toEat(input);
    return "${DateFormat("yyyy-MM-dd'T'HH:mm:ss").format(eat)}+03:00";
  }

  @override
  void initState() {
    super.initState();
    _startAutoRefresh();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    plateCtrl.dispose();
    ownerCtrl.dispose();
    mobileCtrl.dispose();
    qtyCtrl.dispose();
    super.dispose();
  }

  void _startAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(_refreshInterval, (_) {
      if (!mounted || !invoiceGenerated) return;
      if (ReceiptIdFormatter.trimValue(previewPaymentId ?? '').isEmpty) return;
      unawaited(_refreshGeneratedInvoiceStatus());
    });
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

  Map<String, dynamic>? _extractReceiptPayload(dynamic payload) {
    if (payload is! Map<String, dynamic>) return null;

    final receipt = payload['receipt'];
    if (receipt is Map<String, dynamic>) return receipt;

    final data = payload['data'];
    if (data is Map<String, dynamic>) return data;

    final result = payload['result'];
    if (result is Map<String, dynamic>) return result;

    return payload;
  }

  bool _asBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized == 'true' ||
          normalized == '1' ||
          normalized == 'paid' ||
          normalized == 'success';
    }
    return false;
  }

  bool _isPaidFromPayload(Map<String, dynamic> payload) {
    final status = _readScalarString(
      payload,
      ['status', 'paymentStatus', 'state'],
      fallback: '',
    ).toLowerCase();

    if (status == 'paid' || status == 'completed') {
      return true;
    }

    if (_asBool(payload['isPaid']) || _asBool(payload['paid'])) {
      return true;
    }

    final paidAtText = _readScalarString(payload, ['paidAt', 'paidAtUtc']);
    if (paidAtText.isNotEmpty) {
      return true;
    }

    return false;
  }

  Map<String, dynamic> _paymentPayloadOnly(Map<String, dynamic> payload) {
    return _extractReceiptPayload(payload) ?? payload;
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

    return response;
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
        if (!_isPaidFromPayload(item)) continue;

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
          onRefreshPaymentStatus: _refreshInvoicePreviewSnapshot,
          autoPrintWhenPaid: true,
        ),
      ),
    );

    await _refreshGeneratedInvoiceStatus();
  }

  Future<Map<String, String>?> _refreshInvoicePreviewSnapshot() async {
    await _refreshGeneratedInvoiceStatus();
    if (!mounted) return null;

    final invoiceId = ReceiptIdFormatter.trimValue(previewInvoiceNumber ?? '');
    final paymentId = ReceiptIdFormatter.trimValue(previewPaymentId ?? '');
    final billNo = ReceiptIdFormatter.trimValue(previewBillNo ?? '');
    final shortCode = ReceiptIdFormatter.resolveShortCode(
      paymentId,
      provided: previewShortCode,
    );

    if (invoiceId.isEmpty && paymentId.isEmpty && billNo.isEmpty && shortCode.isEmpty) {
      return null;
    }

    return {
      'invoiceNumber': invoiceId,
      'paymentId': paymentId,
      'billNo': billNo,
      'refId': billNo,
      'shortCode': shortCode,
      'isPaid': invoicePaid ? 'true' : 'false',
    };
  }

  Future<void> _refreshGeneratedInvoiceStatus() async {
    final existingPaymentId = ReceiptIdFormatter.trimValue(previewPaymentId ?? '');
    if (existingPaymentId.isEmpty) {
      return;
    }

    final latest = await _loadBackendReceipt(existingPaymentId);
    if (latest == null || !mounted) {
      return;
    }

    final payload = _paymentPayloadOnly(latest);
    final invoiceId = _readScalarString(payload, ['invoiceId', 'invoiceNumber']);
    final paymentId = _readScalarString(payload, ['paymentId', 'id']);
    final refNo = _readScalarString(
      payload,
      [
        'receiptId',
        'receiptNumber',
        'golisBillNo',
        'transactionId',
        'billNo',
        'billNumber',
        'referenceNumber',
        'refNo',
        'refId',
      ],
    );
    final shortCode = _readScalarString(payload, ['shortCode']);
    final paidStatus = refNo.isNotEmpty && _isPaidFromPayload(payload);

    setState(() {
      if (invoiceId.isNotEmpty) {
        previewInvoiceNumber = invoiceId;
      }
      if (paymentId.isNotEmpty) {
        previewPaymentId = paymentId;
      }
      final normalizedInvoice = invoiceId.trim().toLowerCase();
      final normalizedRef = refNo.trim().toLowerCase();
      if (refNo.isNotEmpty && normalizedRef != normalizedInvoice) {
        previewBillNo = refNo;
      }
      final effectivePaymentId =
          paymentId.isNotEmpty ? paymentId : (previewPaymentId ?? '');
      previewShortCode =
          ReceiptIdFormatter.resolveShortCode(effectivePaymentId, provided: shortCode);
      invoicePaid = invoicePaid || paidStatus;
      paidToday = paidToday || invoicePaid;
      if (invoicePaid && paidTodayTime == null) {
        paidTodayTime = _formatEatTime(DateTime.now());
      }
    });
  }

  Future<void> _generateInvoicePreview() async {
    if (invoiceGenerated) {
      if (previewInvoiceNumber != null &&
          previewBillNo != null &&
          previewPaymentId != null &&
          previewShortCode != null) {
        await _refreshGeneratedInvoiceStatus();
        if (!mounted) return;
        await _openReceiptPreview(
          receiptNumber: previewInvoiceNumber ?? '',
          billNo: previewBillNo ?? '',
          paymentId: previewPaymentId ?? '',
          shortCode: previewShortCode ??
              ReceiptIdFormatter.buildPaymentShortCode(previewPaymentId ?? ''),
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

    final token = await _getAccessToken();
    if (token == null || token.isEmpty) {
      showMsg('Login required');
      return;
    }

    final vehicleId = _toInt(vehicle!['id'] ?? vehicle!['vehicleId']);
    if (vehicleId == null) {
      showMsg('Vehicle not found');
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final collectorId = Session.userId ?? prefs.getInt('userId');
    final collectorUsername =
        (Session.username ?? prefs.getString('username') ?? '').trim();

    final previewResponse = await ApiService.createPaymentPreview(
      {
        'vehicleId': vehicleId,
        'movementId': selectedMovementId,
        'quantity': int.tryParse(qtyCtrl.text.trim()) ?? 1,
        'collectorId': collectorId,
        'userId': collectorId,
        'collectorUsername': collectorUsername,
        'collectorName': collectorUsername,
        'username': collectorUsername,
      },
      accessToken: token,
    );

    final receipt = _extractReceiptPayload(previewResponse ?? {}) ?? <String, dynamic>{};
    final previewInvoice = _readScalarString(
      receipt,
      ['invoiceId', 'invoiceNumber', 'invoiceNo', 'invoice_no'],
      fallback: '',
    );
    final previewPayment = _readScalarString(
      receipt,
      ['paymentId', 'paymentID', 'id'],
      fallback: '',
    );
    final previewBill = _readScalarString(
      receipt,
      [
        'golisBillNo',
        'transactionId',
        'billNo',
        'billNumber',
        'referenceNumber',
        'refNo',
        'refId',
      ],
      fallback: '',
    );
    final previewShort = _readScalarString(receipt, ['shortCode'], fallback: '');

    if (previewInvoice.isEmpty || previewPayment.isEmpty) {
      showMsg('Failed to generate preview from server');
      return;
    }

    setState(() {
      previewInvoiceNumber = previewInvoice;
      previewBillNo = previewBill;
      previewPaymentId = previewPayment;
      previewShortCode = ReceiptIdFormatter.resolveShortCode(
        previewPayment,
        provided: previewShort,
      );
      invoiceGenerated = true;
      invoicePaid = false;
    });

    if (!mounted) return;

    await _openReceiptPreview(
      receiptNumber: previewInvoice,
      billNo: previewBill,
      paymentId: previewPayment,
      shortCode:
          previewShortCode ?? ReceiptIdFormatter.buildPaymentShortCode(previewPayment),
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

    final invoiceNumber = ReceiptIdFormatter.trimValue(previewInvoiceNumber ?? '');
    if (invoiceNumber.isNotEmpty) {
      payload['invoiceId'] = invoiceNumber;
      payload['invoiceNumber'] = invoiceNumber;
    }

    final generatedPaymentId = _toInt(previewPaymentId);
    if (generatedPaymentId != null) {
      payload['paymentId'] = generatedPaymentId;
    }

    final referenceNumber = ReceiptIdFormatter.trimValue(previewBillNo ?? '');
    if (referenceNumber.isNotEmpty) {
      payload['referenceNumber'] = referenceNumber;
      payload['billNo'] = referenceNumber;
      payload['billNumber'] = referenceNumber;
    }

    final result = generatedPaymentId != null
        ? await ApiService.collectGeneratedInvoice(
            generatedPaymentId,
            payload,
            accessToken: token,
          )
        : await ApiService.pay(payload, accessToken: token);

    setState(() => loading = false);

    return result;
  }

  Future<Map<String, String>?> _recordPaymentFromInvoice() async {
    final result = await _submitPaymentRequest();

    if (result is Map<String, dynamic> && result['success'] == true) {
      final existingInvoiceId = ReceiptIdFormatter.trimValue(previewInvoiceNumber ?? '');
      final existingPaymentId = ReceiptIdFormatter.trimValue(previewPaymentId ?? '');
      final existingBillNo = ReceiptIdFormatter.trimValue(previewBillNo ?? '');
      final existingShortCode = ReceiptIdFormatter.trimValue(previewShortCode ?? '');

      final resultPayload = _paymentPayloadOnly(result);
      final paymentIdFromCreate = _readScalarString(
        resultPayload,
        ['paymentId', 'id'],
      );
      final receipt = paymentIdFromCreate.isEmpty
          ? null
          : await _loadBackendReceipt(paymentIdFromCreate);
      final source = receipt != null ? _paymentPayloadOnly(receipt) : resultPayload;

      final savedInvoiceId = _readScalarString(
        source,
        ['invoiceId', 'invoiceNumber'],
      );
      final savedPaymentId = _readScalarString(source, ['paymentId', 'id']);
      final savedBillNo = _readScalarString(
        source,
        [
          'receiptId',
          'receiptNumber',
          'golisBillNo',
          'transactionId',
          'billNo',
          'billNumber',
          'referenceNumber',
          'refNo',
          'refId',
        ],
      );
      final savedShortCode = _readScalarString(source, ['shortCode']);

      final effectiveInvoiceId =
          savedInvoiceId.isNotEmpty ? savedInvoiceId : existingInvoiceId;
      final effectivePaymentId =
          savedPaymentId.isNotEmpty ? savedPaymentId : existingPaymentId;
      final effectiveBillNo =
          savedBillNo.isNotEmpty ? savedBillNo : existingBillNo;
      final preferredShortCode =
          savedShortCode.isNotEmpty ? savedShortCode : existingShortCode;
      final effectiveShortCode = ReceiptIdFormatter.resolveShortCode(
        effectivePaymentId,
        provided: preferredShortCode,
      );
            final paidStatus = result['success'] == true ||
              (effectiveBillNo.isNotEmpty && _isPaidFromPayload(source));

      if (mounted) {
        setState(() {
          previewInvoiceNumber = effectiveInvoiceId;
          previewPaymentId = effectivePaymentId;
          previewBillNo = effectiveBillNo;
          previewShortCode = effectiveShortCode;
          invoicePaid = paidStatus;
          paidToday = paidStatus;
          paidTodayTime = paidStatus ? _formatEatTime(DateTime.now()) : null;
        });
      }
      showMsg(
        paidStatus ? 'Payment saved as paid' : 'Payment saved',
        isError: false,
      );
      return {
        'invoiceNumber': effectiveInvoiceId,
        'paymentId': effectivePaymentId,
        'billNo': effectiveBillNo,
        'refId': effectiveBillNo,
        'shortCode': effectiveShortCode,
        'isPaid': paidStatus ? 'true' : 'false',
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
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
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
    final invoiceDisplay = previewInvoiceNumber == null
        ? null
        : ReceiptIdFormatter.displayInvoiceId(previewInvoiceNumber!);
    final paymentDisplay = previewPaymentId == null
        ? null
        : ReceiptIdFormatter.displayPaymentId(previewPaymentId!);

    return Scaffold(
      appBar: AppBar(
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF0B57D0), Color(0xFF1E40AF)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.asset(
                'assets/images/Logo.jpeg',
                width: 28,
                height: 28,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 10),
            const Text('Collect Vehicle Tax'),
          ],
        ),
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
      bottomNavigationBar: AppBottomNav(
        currentIndex: 1,
        onTap: _onNavBarTap,
      ),
    );
  }
}
