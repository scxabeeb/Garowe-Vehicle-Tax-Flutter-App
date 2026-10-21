import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_service.dart';
import '../services/session.dart';
import '../theme/brand_theme.dart';
import '../utils/receipt_id_formatter.dart';
import 'invoice_preview_page.dart';
import 'login_page.dart';
import 'payment_page.dart';
import 'printer_settings_page.dart';
import 'profile_page.dart';
import 'todays_payments_page.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  static const Duration _eatOffset = Duration(hours: 3);
  static const int _pageSize = 2;

  bool loading = true;
  String? error;
  List<dynamic> todaysPayments = [];
  int? _currentUserId;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _initCollectorId();
  }

  Future<void> _initCollectorId() async {
    _currentUserId = Session.userId;
    if (_currentUserId == null) {
      final prefs = await SharedPreferences.getInstance();
      _currentUserId = prefs.getInt('userId') ?? prefs.getInt('collectorId');
    }
    if (!mounted) return;
    await loadDashboard();
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

  int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  bool _isMyRecord(dynamic payment) {
    if (payment is! Map<String, dynamic>) return false;
    if (isAdmin) return true;

    final myId = Session.userId;
    if (myId != null) {
      final collectorId = _toInt(payment['collectorId']);
      final userId = _toInt(payment['userId']);
      final collectorMap = payment['collector'];
      final collectorMapId = collectorMap is Map<String, dynamic>
          ? _toInt(collectorMap['id'])
          : null;

      if (collectorId == myId || userId == myId || collectorMapId == myId) {
        return true;
      }
    }

    final myUsername = (Session.username ?? '').trim().toLowerCase();
    if (myUsername.isEmpty) return false;

    final collectorName = (payment['collectorName'] ?? payment['collector'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (collectorName == myUsername) return true;

    final collectorUsername = (payment['collectorUsername'] ?? payment['username'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (collectorUsername == myUsername) return true;

    final collectorMap = payment['collector'];
    if (collectorMap is Map<String, dynamic>) {
      final username = (collectorMap['username'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (username == myUsername) return true;

      final name = (collectorMap['name'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      return name == myUsername;
    }

    return false;
  }

  List<dynamic> get visiblePayments {
    final filtered = isAdmin ? todaysPayments : todaysPayments.where(_isMyRecord).toList();
    return filtered
        .where((p) => p is Map<String, dynamic> && p['isReverted'] != true)
        .where((p) => p is Map<String, dynamic> && _isPaidPayment(p))
        .toList();
  }

  int get todayVehicleCount {
    final plates = <String>{};
    for (final payment in visiblePayments) {
      final plate = (payment['plate'] ?? payment['plateNumber'] ?? '').toString().trim();
      if (plate.isNotEmpty && plate != '-') {
        plates.add(plate.toUpperCase());
      }
    }
    return plates.length;
  }

  int get todayPaymentCount => visiblePayments.length;

  double get todayTotalAmount {
    double sum = 0;
    for (final payment in visiblePayments) {
      sum += (payment['amount'] as num?)?.toDouble() ?? 0;
    }
    return sum;
  }

  List<dynamic> get pagedPayments {
    final start = _currentPage * _pageSize;
    if (start >= visiblePayments.length) return const [];
    return visiblePayments.skip(start).take(_pageSize).toList();
  }

  int get pageCount {
    if (visiblePayments.isEmpty) return 1;
    return (visiblePayments.length / _pageSize).ceil();
  }

  void _changePage(int delta) {
    final next = _currentPage + delta;
    if (next < 0 || next >= pageCount) return;
    setState(() => _currentPage = next);
  }

  String _formatEatTime(dynamic payment) {
    if (payment is! Map<String, dynamic>) return '-';

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
          return DateFormat('MMM dd, HH:mm').format(_toEat(parsed));
        }
      }
    }

    return (payment['time'] ?? '-').toString();
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

  Map<String, dynamic> _receiptPayloadOnly(Map<String, dynamic> payload) {
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
          normalized == 'success' ||
          normalized == 'completed';
    }
    return false;
  }

  bool _isPaidPayment(Map<String, dynamic> payment) {
    final status = _readScalarString(
      payment,
      ['status', 'paymentStatus', 'state'],
      fallback: '',
    ).toLowerCase();

    if (status == 'paid' || status == 'completed') {
      return true;
    }

    if (_asBool(payment['isPaid']) || _asBool(payment['paid'])) {
      return true;
    }

    final paidAtText = _readScalarString(payment, ['paidAt', 'paidAtUtc']);
    if (paidAtText.isNotEmpty) {
      return true;
    }

    return false;
  }

  DateTime? _parseDate(Map<String, dynamic> payment) {
    final candidates = [
      payment['paidAt'],
      payment['date'],
      payment['createdAt'],
      payment['time'],
      payment['paidAtUtc'],
    ];

    for (final candidate in candidates) {
      if (candidate is String && candidate.trim().isNotEmpty) {
        final parsed = DateTime.tryParse(candidate.trim());
        if (parsed != null) return _toEat(parsed);
      }
    }

    return null;
  }

  String _collectorName(dynamic payment) {
    if (payment is! Map<String, dynamic>) return '-';

    final direct = payment['collectorName'];
    if (direct is String && direct.trim().isNotEmpty) {
      return direct.trim();
    }

    final collector = payment['collector'];
    if (collector is String && collector.trim().isNotEmpty) {
      return collector.trim();
    }
    if (collector is Map<String, dynamic>) {
      final fullName = collector['fullName'];
      if (fullName is String && fullName.trim().isNotEmpty) {
        return fullName.trim();
      }
      final username = collector['username'];
      if (username is String && username.trim().isNotEmpty) {
        return username.trim();
      }
    }

    return '-';
  }

  Future<void> loadDashboard() async {
    setState(() {
      loading = true;
      error = null;
    });

    try {
      final res = await http
          .get(
            Uri.parse('${ApiService.baseUrl}/Dashboard'),
            headers: await _authHeaders(),
          )
          .timeout(const Duration(seconds: 20));


      if (res.statusCode != 200) {
        setState(() {
          loading = false;
          error = 'Failed to load dashboard data. Status: ${res.statusCode}';
        });
        return;
      }

      final data = jsonDecode(res.body);
      final payments = data is Map<String, dynamic> ? data['todaysPayments'] : null;

      setState(() {
        todaysPayments = payments is List ? payments : <dynamic>[];
        _currentPage = 0;
        loading = false;
      });
    } catch (_) {
      setState(() {
        loading = false;
        error = 'Network error. Please check your connection.';
      });
    }
  }

  Future<Map<String, dynamic>?> _loadReceipt(int paymentId) async {
    final res = await http
        .get(Uri.parse('${ApiService.baseUrl}/payments/$paymentId/receipt'))
        .timeout(const Duration(seconds: 20));

    if (res.statusCode != 200) return null;
    final decoded = jsonDecode(res.body);
    if (decoded is Map<String, dynamic>) {
      final receipt = decoded['receipt'];
      if (receipt is Map<String, dynamic>) return receipt;
      return decoded;
    }
    return null;
  }

  Future<void> _openPaymentReceipt(dynamic payment) async {
    if (payment is! Map<String, dynamic>) return;

    final invoiceId = _readScalarString(
      payment,
      [
        'invoiceId',
        'invoiceNumber',
        'invoiceNo',
        'invoice_no',
        'invoice',
      ],
    );
    final paymentId = _readScalarString(
      payment,
      ['paymentId', 'paymentID', 'payment_id', 'id'],
    );
    final billNo = _readScalarString(
      payment,
      [
        'golisBillNo',
        'transactionId',
        'billNo',
        'billNumber',
        'referenceNumber',
        'refNo',
        'refId',
      ],
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

    final parsedPaymentId = int.tryParse(paymentId);
    final receipt = (parsedPaymentId != null && parsedPaymentId > 0)
        ? await _loadReceipt(parsedPaymentId)
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
        'invoiceNo',
        'invoice_no',
        'invoice',
      ],
      fallback: invoiceId,
    );
    final resolvedPaymentId = _readScalarString(
      receiptSource,
      ['paymentId', 'paymentID', 'payment_id', 'id'],
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
        'billNumber',
        'referenceNumber',
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
        ),
      ),
    );

    await loadDashboard();
  }

  void logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    Session.clear();

    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  void _onNavBarTap(int index) {
    switch (index) {
      case 0:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TodaysPaymentsPage(
              payments: visiblePayments,
              selectedDate: DateTime.now(),
            ),
          ),
        ).then((_) => loadDashboard());
        break;
      case 1:
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PaymentPage()),
        ).then((_) => loadDashboard());
        break;
      case 2:
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ProfilePage()),
        );
        break;
      case 3:
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PrinterSettingsPage()),
        );
        break;
    }
  }

  Widget _buildStatCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
    String? subtitle,
    IconData? trendIcon,
    Color? trendColor,
  }) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: Colors.blueGrey.shade50),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, color: color, size: 26),
                ),
                if (trendIcon != null)
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: (trendColor ?? Colors.green).withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(trendIcon, color: trendColor ?? Colors.green, size: 18),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: BrandColors.textSecondary,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: BrandColors.textPrimary,
                height: 1.1,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(fontSize: 12, color: BrandColors.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(String dateStr) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [BrandColors.primary, BrandColors.primaryDark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.blue.shade100.withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.asset(
              'assets/images/Logo.jpeg',
              width: 44,
              height: 44,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Hello, ${Session.username ?? ''}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(dateStr, style: const TextStyle(fontSize: 13, color: Colors.white70)),
              ],
            ),
          ),
          ElevatedButton.icon(
            onPressed: logout,
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Logout', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white.withValues(alpha: 0.18),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCards() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                title: 'Served Cars',
                value: '$todayVehicleCount',
                icon: Icons.directions_car,
                color: BrandColors.primary,
                subtitle: 'Today',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildStatCard(
                title: 'Payments',
                value: '$todayPaymentCount',
                icon: Icons.receipt_long,
                color: Colors.blue.shade600,
                subtitle: 'Today',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildStatCard(
          title: 'Today Total',
          value: '\$${todayTotalAmount.toStringAsFixed(2)}',
          icon: Icons.attach_money,
          color: BrandColors.accent,
          subtitle: '$todayPaymentCount payments today',
          trendIcon: Icons.trending_up,
          trendColor: Colors.green.shade600,
        ),
      ],
    );
  }

  Widget _buildPaymentRow(dynamic payment) {
    final plate = (payment['plate'] ?? payment['plateNumber'] ?? '-').toString();
    final movement = (payment['movement'] ?? payment['movementType'] ?? '-').toString();
    final time = _formatEatTime(payment);
    final amount = (payment['amount'] as num?)?.toDouble() ?? 0;
    final isReverted = payment['isReverted'] == true;

    return GestureDetector(
      onTap: () => _openPaymentReceipt(payment),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.blueGrey.shade50),
          boxShadow: [
            BoxShadow(
              color: BrandColors.primary.withValues(alpha: 0.05),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFFEEF4FF),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                isReverted ? Icons.undo : Icons.directions_car_filled,
                color: BrandColors.primary,
                size: 24,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    plate,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: BrandColors.textPrimary,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    movement,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: BrandColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(time, style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade500)),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: isReverted ? Colors.red.shade50 : const Color(0xFFECFDF0),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '\$${amount.toStringAsFixed(2)}',
                style: TextStyle(
                  color: isReverted ? Colors.red.shade700 : Colors.green.shade700,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPager() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        OutlinedButton.icon(
          onPressed: _currentPage > 0 ? () => _changePage(-1) : null,
          icon: const Icon(Icons.chevron_left),
          label: const Text('Prev'),
        ),
        Text(
          'Page ${_currentPage + 1} of $pageCount',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: Colors.blueGrey.shade800,
            fontSize: 13,
          ),
        ),
        OutlinedButton.icon(
          onPressed: _currentPage + 1 < pageCount ? () => _changePage(1) : null,
          icon: const Icon(Icons.chevron_right),
          label: const Text('Next'),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: Colors.blueGrey.shade50,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.receipt_long, size: 36, color: Colors.blueGrey.shade300),
            ),
            const SizedBox(height: 16),
            Text(
              'No payments found today',
              style: TextStyle(fontSize: 15, color: Colors.blueGrey.shade500),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error ?? '',
              style: TextStyle(color: Colors.red.shade700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomNavBar() {
    return BottomNavigationBar(
      type: BottomNavigationBarType.fixed,
      backgroundColor: Colors.white,
      selectedItemColor: BrandColors.primary,
      unselectedItemColor: Colors.blueGrey.shade500,
      selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
      unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 12),
      elevation: 4,
      onTap: _onNavBarTap,
      items: const [
        BottomNavigationBarItem(icon: Icon(Icons.receipt_long), label: 'Payments'),
        BottomNavigationBarItem(icon: Icon(Icons.payments), label: 'New Payment'),
        BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
        BottomNavigationBarItem(icon: Icon(Icons.print), label: 'Printer'),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final dateStr = DateFormat('EEEE, MMMM d').format(DateTime.now());

    return Scaffold(
      backgroundColor: BrandColors.background,
      body: SafeArea(
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: loadDashboard,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildHeader(dateStr),
                      const SizedBox(height: 20),
                      _buildStatCards(),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          const Text(
                            'Today\'s Payments',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: BrandColors.textPrimary,
                            ),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => TodaysPaymentsPage(
                                    payments: visiblePayments,
                                    selectedDate: DateTime.now(),
                                  ),
                                ),
                              ).then((_) => loadDashboard());
                            },
                            child: const Text('View All'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (error != null)
                        _buildErrorBanner()
                      else if (visiblePayments.isEmpty)
                        _buildEmptyState()
                      else ...[
                        ...pagedPayments.map(_buildPaymentRow),
                        const SizedBox(height: 16),
                        _buildPager(),
                      ],
                    ],
                  ),
                ),
              ),
      ),
      bottomNavigationBar: _buildBottomNavBar(),
    );
  }
}
