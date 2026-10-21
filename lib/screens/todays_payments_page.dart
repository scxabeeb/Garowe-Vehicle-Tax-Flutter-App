import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/session.dart';
import '../services/api_service.dart';
import '../theme/brand_theme.dart';
import '../utils/receipt_id_formatter.dart';
import '../widgets/app_bottom_nav.dart';
import 'dashboard_page.dart';
import 'invoice_preview_page.dart';
import 'payment_page.dart';
import 'printer_settings_page.dart';
import 'profile_page.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class TodaysPaymentsPage extends StatefulWidget {
  final List<dynamic> payments;
  final DateTime? selectedDate;

  const TodaysPaymentsPage({
    super.key,
    required this.payments,
    this.selectedDate,
  });

  @override
  State<TodaysPaymentsPage> createState() => _TodaysPaymentsPageState();
}

class _TodaysPaymentsPageState extends State<TodaysPaymentsPage> {
  static const Duration _eatOffset = Duration(hours: 3);

  String selectedCollector = 'All';
  String searchQuery = '';

  bool loading = false;
  String? error;

  // For loading payments from the API by date
  DateTime _selectedDate = DateTime.now();
  List<dynamic> _loadedPayments = [];
  bool _hasLoadedForSelectedDate = false;
  final Map<String, List<dynamic>> _paymentsByDateCache = {};
  int? _resolvedCollectorId;

  @override
  void initState() {
    super.initState();
    _selectedDate = DateUtils.dateOnly(DateTime.now());
    _initAndLoad();
  }

  String _dateKey(DateTime value) {
    final d = DateUtils.dateOnly(value);
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Future<void> _initAndLoad() async {
    _resolvedCollectorId = Session.userId;
    if (_resolvedCollectorId == null) {
      final prefs = await SharedPreferences.getInstance();
      _resolvedCollectorId = prefs.getInt('userId') ?? prefs.getInt('collectorId');
    }
    if (!mounted) return;
    await _loadPaymentsForDate(_selectedDate);
  }

  bool get isAdmin => (Session.role ?? '').toLowerCase() == 'admin';

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

  Future<Map<String, String>> _authHeaders() async {
    final headers = <String, String>{'Accept': 'application/json'};
    final token = await _getAccessToken();
    if (token != null) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  DateTime _toEat(DateTime input) => input.toUtc().add(_eatOffset);


  DateTime? _parseDate(dynamic payment) {
    if (payment is! Map<String, dynamic>) return null;

    final candidates = [
      payment['paidAt'],
      payment['date'],
      payment['createdAt'],
      payment['time'],
    ];

    for (final candidate in candidates) {
      if (candidate is String && candidate.trim().isNotEmpty) {
        final parsed = DateTime.tryParse(candidate.trim());
        if (parsed != null) {
          return _toEat(parsed);
        }
      }
    }

    return null;
  }

  String _formatEatTime(dynamic payment) {
    final parsed = _parseDate(payment);
    if (parsed != null) {
      return DateFormat('MMM dd, HH:mm').format(parsed);
    }
    return (payment['time'] ?? '-').toString();
  }

  int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  String _collectorName(dynamic payment) {
    if (payment is! Map<String, dynamic>) return '-';

    final direct = payment['collectorName'];
    if (direct is String && direct.trim().isNotEmpty) {
      return direct.trim();
    }

    final collector = payment['collector'];
    if (collector is Map<String, dynamic>) {
      final username = collector['username'];
      if (username is String && username.trim().isNotEmpty) {
        return username.trim();
      }
    }

    return '-';
  }

  List<String> get collectors {
    final set = <String>{'All'};
    for (final payment in widget.payments) {
      final name = _collectorName(payment);
      if (name != '-') set.add(name);
    }
    return set.toList();
  }

  // 🔴 Ignore reverted payments at UI level as a safety net
  List<dynamic> get validPayments =>
      widget.payments.where((p) => p['isReverted'] != true).toList();

  bool _matchesCollector(dynamic payment) {
    if (!isAdmin || selectedCollector == 'All') return true;
    return _collectorName(payment) == selectedCollector;
  }

  bool _matchesSearch(dynamic payment) {
    if (searchQuery.trim().isEmpty) return true;
    if (payment is! Map<String, dynamic>) return false;

    final query = searchQuery.trim().toLowerCase();
    final plate = (payment['plate'] ?? payment['plateNumber'] ?? '')
        .toString()
        .toLowerCase();
    final paymentId = (payment['paymentId'] ?? payment['id'] ?? '')
        .toString()
        .toLowerCase();

    return plate.contains(query) || paymentId.contains(query);
  }

  List<dynamic> get filteredPayments {
    final source = _hasLoadedForSelectedDate ? _loadedPayments : widget.payments;
    return source
        .where((p) => p['isReverted'] != true)
        .where((p) => p is Map<String, dynamic> && _isPaidPayment(p))
        .where((p) => _matchesCollector(p) && _matchesSearch(p))
        .toList();
  }

  double get totalCollected {
    double sum = 0;
    for (final p in filteredPayments) {
      final amount = (p['amount'] as num?)?.toDouble() ?? 0;
      sum += amount;
    }
    return sum;
  }

  int get selectedDateVehicleCount {
    final plates = <String>{};
    for (final p in filteredPayments) {
      final plate = (p['plate'] ?? p['plateNumber'] ?? '').toString().trim();
      if (plate.isNotEmpty && plate != '-') {
        plates.add(plate.toUpperCase());
      }
    }
    return plates.length;
  }

  // ── Load payments for a specific date from the API ─────────────
  Future<void> _loadPaymentsForDate(DateTime date) async {
    final normalizedDate = DateUtils.dateOnly(date);
    final dateKey = _dateKey(normalizedDate);
    final cached = _paymentsByDateCache[dateKey];

    if (cached != null) {
      setState(() {
        _selectedDate = normalizedDate;
        _loadedPayments = cached;
        _hasLoadedForSelectedDate = true;
        loading = false;
        error = null;
        searchQuery = '';
      });
      return;
    }

    setState(() {
      loading = true;
      error = null;
      _selectedDate = normalizedDate;
      searchQuery = '';
    });

    final targetDate = DateUtils.dateOnly(_toEat(normalizedDate));
    final collectorId = _resolvedCollectorId;

    // For today, always use the payments passed from the Dashboard so the
    // totals match exactly.  Avoid a separate API call that might return
    // different filtering or fail due to missing auth.
    final isToday = DateUtils.isSameDay(targetDate, DateUtils.dateOnly(_toEat(DateTime.now())));
    if (isToday) {
      final todayMatching = widget.payments.where((item) {
        if (item is! Map<String, dynamic>) return false;
        if (item['isReverted'] == true) return false;

        final parsed = _parseDate(item);
        if (parsed == null) return false;

        return DateUtils.isSameDay(
          DateUtils.dateOnly(parsed),
          targetDate,
        );
      }).toList();

      setState(() {
        _paymentsByDateCache[dateKey] = todayMatching;
        _loadedPayments = todayMatching;
        _hasLoadedForSelectedDate = true;
        loading = false;
        error = null;
      });
      return;
    }

    if (collectorId != null) {
      try {
        final headers = await _authHeaders();
        final res = await http
            .get(
              Uri.parse('${ApiService.baseUrl}/payments/collector/$collectorId'),
              headers: headers,
            )
            .timeout(const Duration(seconds: 20));

        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final items = data['items'] ?? data;

          if (items is List) {
            final matching = items.where((item) {
              if (item is! Map<String, dynamic>) return false;
              if (item['isReverted'] == true) return false;

              final parsed = _parseDate(item);
              if (parsed == null) return false;

              return DateUtils.isSameDay(
                DateUtils.dateOnly(parsed),
                targetDate,
              );
            }).toList();

            setState(() {
              _paymentsByDateCache[dateKey] = matching;
              _loadedPayments = matching;
              _hasLoadedForSelectedDate = true;
              loading = false;
            });
            return;
          }
        }
      } catch (e) {
        // fall through
      }
    }

    // Fallback to the passed-in payments filtered to selected date.
    final fallbackMatching = widget.payments.where((item) {
      if (item is! Map<String, dynamic>) return false;
      if (item['isReverted'] == true) return false;

      final parsed = _parseDate(item);
      if (parsed == null) return false;

      return DateUtils.isSameDay(
        DateUtils.dateOnly(parsed),
        targetDate,
      );
    }).toList();

    setState(() {
      _paymentsByDateCache[dateKey] = fallbackMatching;
      _loadedPayments = fallbackMatching;
      _hasLoadedForSelectedDate = true;
      loading = false;
      if (collectorId == null) {
        error = 'Collector ID not available. Please log in again.';
      }
    });
  }


  // ── Pick a specific date to view payments ──────────────────────
  Future<void> _pickPaymentDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );

    if (date == null) return;
    await _loadPaymentsForDate(date);
  }

  Future<void> _shiftDateByDays(int days) async {
    final nextDate = DateUtils.dateOnly(_selectedDate.add(Duration(days: days)));
    await _loadPaymentsForDate(nextDate);
  }

  Future<void> _loadToday() async {
    await _loadPaymentsForDate(DateUtils.dateOnly(DateTime.now()));
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
    final sourcePayments = _hasLoadedForSelectedDate ? _loadedPayments : widget.payments;

    return Scaffold(
      backgroundColor: BrandColors.background,
      appBar: buildBrandAppBar(
        title: isAdmin ? 'All Payments' : 'My Payments',
      ),
      body: sourcePayments.isEmpty && loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // ── Date filter toolbar ─────────────────────────
                _buildDateToolbar(),

                // ── Summary bar ───────────────────────────────────
                _buildSummaryBar(),

                // ── Payment list ──────────────────────────────────
                Expanded(
                  child: filteredPayments.isEmpty
                      ? _buildEmptyState()
                      : ListView.separated(
                          padding: const EdgeInsets.all(12),
                          itemCount: filteredPayments.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final p = filteredPayments[index];
                            return _buildPaymentTile(p);
                          },
                        ),
                ),
              ],
            ),
      bottomNavigationBar: AppBottomNav(
        currentIndex: 0,
        onTap: _onNavBarTap,
      ),
    );
  }

  Widget _buildDateToolbar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(color: Colors.blueGrey.shade100),
        ),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: const Color(0xFFF8FAFC),
              border: Border.all(color: BrandColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Previous day',
                  onPressed: loading ? null : () => _shiftDateByDays(-1),
                  icon: const Icon(Icons.chevron_left),
                  color: BrandColors.primary,
                ),
                OutlinedButton.icon(
                  onPressed: loading ? null : _pickPaymentDate,
                  icon: const Icon(Icons.calendar_month, size: 18),
                  label: Text(
                    DateFormat('EEE, dd MMM yyyy').format(_selectedDate),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: BrandColors.primary,
                  ),
                ),
                IconButton(
                  tooltip: 'Next day',
                  onPressed: loading ? null : () => _shiftDateByDays(1),
                  icon: const Icon(Icons.chevron_right),
                  color: BrandColors.primary,
                ),
              ],
            ),
          ),

          ActionChip(
            label: const Text('Yesterday'),
            onPressed: loading ? null : () => _shiftDateByDays(-1),
            avatar: const Icon(Icons.history, size: 16),
          ),
          ActionChip(
            label: const Text('Today'),
            onPressed: loading ? null : _loadToday,
            avatar: const Icon(Icons.today, size: 16),
          ),

          if (isAdmin)
            DropdownButton<String>(
              value: selectedCollector,
              items: collectors
                  .map(
                    (name) => DropdownMenuItem<String>(
                      value: name,
                      child: Text('Collector: $name'),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                setState(() => selectedCollector = value);
              },
              style: const TextStyle(
                color: BrandColors.primary,
                fontWeight: FontWeight.w600,
              ),
              dropdownColor: Colors.white,
            ),

          SizedBox(
            width: 320,
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search by plate or payment ID',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: searchQuery.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          setState(() => searchQuery = '');
                        },
                        icon: const Icon(Icons.clear, size: 18),
                      ),
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onChanged: (value) {
                setState(() => searchQuery = value);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryBar() {
    final filtered = filteredPayments;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Details for ${DateFormat('EEEE, dd MMM yyyy').format(_selectedDate)}',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: BrandColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Vehicles: $selectedDateVehicleCount',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: BrandColors.primary,
                ),
              ),
              Text(
                'Payments: ${filtered.length}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: BrandColors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${filtered.length} record${filtered.length != 1 ? 's' : ''} found',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: BrandColors.primary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Total: \$${totalCollected.toStringAsFixed(2)}',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Colors.green.shade700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentTile(dynamic p) {
    final plate = (p['plate'] ?? p['plateNumber'] ?? '-').toString();
    final movement =
        (p['movement'] ?? p['movementType'] ?? '-').toString();
    final time = _formatEatTime(p);
    final amount = (p['amount'] as num?)?.toDouble() ?? 0;
    final isReverted = p['isReverted'] == true;
    final isPaid = p is Map<String, dynamic> ? _isPaidPayment(p) : false;
    final collector = _collectorName(p);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.blueGrey.shade50),
      ),
      child: ListTile(
        onTap: () => _openPaymentReceipt(p),
        contentPadding: EdgeInsets.zero,
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0xFFEEF4FF),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            isReverted ? Icons.undo : Icons.directions_car_filled,
            color: BrandColors.primary,
            size: 22,
          ),
        ),
        title: Text(
          plate,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            color: BrandColors.textPrimary,
          ),
        ),
        subtitle: Text(
          '$movement • $time\nCollector: $collector\nStatus: ${isPaid ? 'Paid' : 'Pending'}',
          style: const TextStyle(
            fontSize: 12,
            color: BrandColors.textSecondary,
          ),
        ),
        isThreeLine: true,
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: isReverted
                ? Colors.red.shade50
                : const Color(0xFFECFDF0),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '\$${amount.toStringAsFixed(2)}',
            style: TextStyle(
              color: isReverted
                  ? Colors.red.shade700
                  : Colors.green.shade700,
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
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

  String _readDeepScalarString(
    Map<String, dynamic> map,
    List<String> keys, {
    String fallback = '',
  }) {
    final direct = _readScalarString(map, keys);
    if (direct.isNotEmpty) {
      return direct;
    }

    for (final containerKey in ['receipt', 'data', 'result', 'payment']) {
      final nested = map[containerKey];
      if (nested is! Map<String, dynamic>) continue;
      final nestedValue = _readScalarString(nested, keys);
      if (nestedValue.isNotEmpty) {
        return nestedValue;
      }

      final nestedReceipt = nested['receipt'];
      if (nestedReceipt is Map<String, dynamic>) {
        final nestedReceiptValue = _readScalarString(nestedReceipt, keys);
        if (nestedReceiptValue.isNotEmpty) {
          return nestedReceiptValue;
        }
      }
    }

    return fallback;
  }

  bool _asBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized == 'true' ||
          normalized == '1' ||
          normalized == 'paid' ||
          normalized == 'success' ||
          normalized == 'completed';
    }
    return false;
  }

  bool _isPaidPayment(Map<String, dynamic> payment) {
    final status = _readDeepScalarString(
      payment,
      ['status', 'paymentStatus', 'state'],
      fallback: '',
    ).toLowerCase();

    if (status == 'paid' || status == 'completed') {
      return true;
    }

    final deepIsPaid = _asBool(payment['isPaid']) ||
        _asBool(payment['paid']) ||
        _asBool((payment['receipt'] as Map<String, dynamic>?)?['isPaid']) ||
        _asBool((payment['receipt'] as Map<String, dynamic>?)?['paid']);

    if (deepIsPaid) {
      return true;
    }

    final paidAtText =
        _readDeepScalarString(payment, ['paidAt', 'paidAtUtc']);
    if (paidAtText.isNotEmpty) {
      return true;
    }

    return false;
  }

  Map<String, dynamic> _receiptPayloadOnly(Map<String, dynamic> payload) {
    final receipt = payload['receipt'];
    if (receipt is Map<String, dynamic>) return receipt;
    final data = payload['data'];
    if (data is Map<String, dynamic>) return data;
    final result = payload['result'];
    if (result is Map<String, dynamic>) return result;
    return payload;
  }

  /// Loads the official backend receipt for the given numeric payment id.
  /// Uses the authenticated ApiService so requests that require a token
  /// do not fail with 401.
  Future<Map<String, dynamic>?> _loadReceipt(int paymentId) async {
    final token = await _getAccessToken();
    final response = await ApiService.getPaymentReceipt(
      paymentId,
      accessToken: token,
    );
    if (response == null) return null;

    final receipt = response['receipt'];
    if (receipt is Map<String, dynamic>) return receipt;
    return response;
  }


  Future<void> _openPaymentReceipt(dynamic payment) async {
    if (payment is! Map<String, dynamic>) return;

    final invoiceId = _readScalarString(
      payment,
      [
        'invoiceId',
        'invoiceNumber',
        'invoice_no',
        'invoiceNo',
        'invoice',
      ],
    );
    final paymentId = _readScalarString(
      payment,
      ['paymentId', 'payment_id', 'paymentID', 'id'],
    );
    final billNo = _readScalarString(
      payment,
      ['golisBillNo', 'transactionId', 'billNo', 'referenceNumber', 'bill_no'],
    );
    final rawShortCode = _readScalarString(
      payment,
      ['shortCode', 'short_code'],
      fallback: '',
    );
    final shortCode = ReceiptIdFormatter.resolveShortCode(
      paymentId,
      provided: rawShortCode,
    );
    final plate = _readScalarString(payment, ['plate', 'plateNumber', 'plate_number'], fallback: '-');
    final owner = _readScalarString(payment, ['owner', 'ownerName', 'owner_name'], fallback: '-');
    final movement = _readScalarString(payment, ['movement', 'movementType', 'movement_type'], fallback: '-');
    final amount = (payment['amount'] as num?)?.toDouble() ?? 0;
    final quantity = (_toInt(payment['quantity']) ?? 1).clamp(1, 999999);
    final unitAmount = quantity > 0 ? amount / quantity : amount;
    final paidAtFallback = _parseDate(payment) ?? _toEat(DateTime.now());

    // The receipt ID may be the same as the invoice ID (a string like
    // "INV-42") which cannot be parsed directly.  Try several strategies
    // to find the numeric payment ID from the backend.
    int? lookupId = ReceiptIdFormatter.extractNumericId(paymentId);
    if ((lookupId == null || lookupId <= 0) && payment['id'] != null) {
      lookupId = ReceiptIdFormatter.extractNumericId(payment['id']);
    }
    if ((lookupId == null || lookupId <= 0) && payment['paymentId'] != null) {
      lookupId = ReceiptIdFormatter.extractNumericId(payment['paymentId']);
    }

    final receipt = (lookupId != null && lookupId > 0)
        ? await _loadReceipt(lookupId)
        : null;
    if (receipt == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to load official backend receipt IDs.')),
        );
      }
      return;
    }
    final receiptSource = _receiptPayloadOnly(receipt);

    final resolvedInvoiceId = _readScalarString(
      receiptSource,
      [
        'invoiceId',
        'invoiceNumber',
        'invoice_no',
        'invoiceNo',
        'invoice',
      ],
      fallback: invoiceId,
    );
    final resolvedPaymentId = _readScalarString(
      receiptSource,
      ['paymentId', 'payment_id', 'paymentID', 'id'],
      fallback: paymentId,
    );
    final resolvedBillNo = _readScalarString(
      receiptSource,
      [
        'receiptId',
        'receiptNumber',
        'golisBillNo',
        'transactionId',
        'billNo',
        'referenceNumber',
        'bill_no',
        'refNo',
        'refId',
      ],
      fallback: billNo,
    );
    final resolvedShortCodeRaw = _readScalarString(
      receiptSource,
      ['shortCode', 'short_code'],
      fallback: shortCode,
    );
    final resolvedShortCode = ReceiptIdFormatter.resolveShortCode(
      resolvedPaymentId,
      provided: resolvedShortCodeRaw,
    );
    final paidAt = _parseDate(receiptSource) ?? paidAtFallback;
    final isPaid = _isPaidPayment(receiptSource) || _isPaidPayment(payment);
    final safeBillNo =
      resolvedBillNo.trim().toLowerCase() == resolvedInvoiceId.trim().toLowerCase()
        ? ''
        : resolvedBillNo;

    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => InvoicePreviewPage(
          invoiceNumber: resolvedInvoiceId,
          billNo: safeBillNo,
          paymentId: resolvedPaymentId,
          shortCode: resolvedShortCode,
          plateNumber: plate,
          ownerName: owner,
          movementName: movement,
          quantity: quantity,
          unitAmount: unitAmount,
          totalAmount: amount,
          collectorName: _collectorName(payment),
          paidAt: paidAt,
          isPaid: isPaid,
          canRecordPayment: false,
          canPrintInvoice: isAdmin,
        ),
      ),
    );
  }


  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: Colors.blueGrey.shade50,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.receipt_long,
                size: 36,
                color: Colors.blueGrey.shade300,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'No collected data for ${DateFormat('MMM d, yyyy').format(_selectedDate)}',
              style: const TextStyle(
                fontSize: 15,
                color: BrandColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pickPaymentDate,
              icon: const Icon(Icons.calendar_today, size: 18),
              label: const Text('Pick Another Date'),
            ),
          ],
        ),
      ),
    );
  }
}
