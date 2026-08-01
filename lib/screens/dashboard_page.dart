import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';

import '../services/api_service.dart';
import '../services/session.dart';
import 'payment_page.dart';
import 'todays_payments_page.dart';
import 'login_page.dart';
import 'printer_settings_page.dart';
import 'profile_page.dart';

/// Brand color palette for the Garowe Vehicle Tax System.
class BrandColors {
  static const Color primary = Color(0xFF0B57D0);
  static const Color primaryDark = Color(0xFF1E40AF);
  static const Color accent = Color(0xFFE65100);
  static const Color background = Color(0xFFF4F7FC);
  static const Color cardBg = Color(0xFFFFFFFF);
  static const Color textPrimary = Color(0xFF0F172A);
  static const Color textSecondary = Color(0xFF6474A1);

  static const LinearGradient headerGradient = LinearGradient(
    colors: [primaryDark, primary],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  static const Duration _eatOffset = Duration(hours: 3);

  bool loading = true;
  String? error;

  int totalVehicles = 0;
  int totalPayments = 0;
  double todayTotal = 0;

  List<dynamic> todaysPayments = [];
  List<dynamic> filteredPayments = [];

  // ── Date picker state ──────────────────────────────────────────
  DateTime _selectedDate = DateTime.now();

  int? _currentUserId;

  int? _resolvedCollectorId;

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
    _resolvedCollectorId = _currentUserId;

    if (!mounted) return;
    loadDashboard();
    _loadPaymentsForDate(_selectedDate);
  }

  bool get isAdmin => (Session.role ?? '').toLowerCase() == 'admin';

  DateTime _toEat(DateTime input) => input.toUtc().add(_eatOffset);

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
          final eat = _toEat(parsed);
          return DateFormat('MMM dd, HH:mm').format(eat);
        }
      }
    }

    return (payment['time'] ?? '-').toString();
  }

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

    final collectorMap = payment['collector'];
    if (collectorMap is Map<String, dynamic>) {
      final username = (collectorMap['username'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      return username == myUsername;
    }

    return false;
  }

  List<dynamic> get visiblePayments =>
      isAdmin ? todaysPayments : todaysPayments.where(_isMyRecord).toList();

  // ── Date-specific stats (computed from filteredPayments) ────────
  int get selectedDatePaymentCount => filteredPayments.length;

  int get selectedDateVehicleCount {
    final plates = <dynamic>{};
    for (final p in filteredPayments) {
      final plate = p['plate'] ?? p['plateNumber'] ?? p['plate'];
      if (plate != null && plate != '-') plates.add(plate);
    }
    return plates.length;
  }

  double get selectedDateTotal {
    double sum = 0;
    for (final p in filteredPayments) {
      final amount = (p['amount'] as num?)?.toDouble() ?? 0;
      sum += amount;
    }
    return sum;
  }

  // ── Dashboard stats (aggregate from backend) ────────────────────
  Future<void> loadDashboard() async {
    setState(() {
      loading = true;
      error = null;
    });

    try {
      final url = '${ApiService.baseUrl}/Dashboard';
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 20));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() {
          totalVehicles = _toInt(data['totalVehicles']) ?? 0;
          totalPayments = _toInt(data['totalPayments']) ?? 0;
          todayTotal = (data['todayTotal'] as num?)?.toDouble() ?? 0;
          todaysPayments = data['todaysPayments'] ?? [];
          loading = false;
        });
        // Load payments for the selected date after dashboard loads
        _loadPaymentsForDate(_selectedDate);
      } else {
        setState(() {
          loading = false;
          error = 'Failed to load dashboard data. Status: ${res.statusCode}';
        });
      }
    } catch (e) {
      setState(() {
        loading = false;
        error = 'Network error. Please check your connection.';
      });
    }
  }

  // ── Fetch payments for a specific date ─────────────────────────
  Future<void> _loadPaymentsForDate(DateTime date) async {
    setState(() {
      loading = true;
      error = null;
      _selectedDate = date;
    });

    final targetDate = DateUtils.dateOnly(_toEat(date));

    // Try the collector endpoint first (gives us all payments to filter)
    final collectorId = _resolvedCollectorId;
    if (collectorId != null) {
      try {
        final res = await http
            .get(
              Uri.parse('${ApiService.baseUrl}/payments/collector/$collectorId'),
            )
            .timeout(const Duration(seconds: 20));

        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final items = data['items'] ?? data;

          if (items is List) {
            final matching = items.where((item) {
              if (item is! Map<String, dynamic>) return false;
              if (item['isReverted'] == true) return false;

              final candidates = [
                item['paidAt'],
                item['date'],
                item['createdAt'],
              ];

              for (final c in candidates) {
                if (c is String && c.trim().isNotEmpty) {
                  final parsed = DateTime.tryParse(c.trim());
                  if (parsed != null) {
                    final eat = _toEat(parsed);
                    if (DateUtils.isSameDay(
                        DateUtils.dateOnly(eat), targetDate)) {
                      return true;
                    }
                  }
                }
              }
              return false;
            }).toList();

            setState(() {
              filteredPayments = matching;
              loading = false;
            });
            return;
          }
        }
      } catch (e) {
        // fall through to dashboard fallback
      }
    }

    // Fallback: use dashboard today's payments if the date is today
    final now = _toEat(DateTime.now());
    if (DateUtils.isSameDay(targetDate, DateUtils.dateOnly(now))) {
      setState(() {
        filteredPayments = visiblePayments;
        loading = false;
      });
      return;
    }

    // No matching date
    setState(() {
      filteredPayments = [];
      loading = false;
      error = 'No payments found for ${DateFormat('MMM d, yyyy').format(date)}.';
    });
  }

  // ── Date picker ────────────────────────────────────────────────
  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );

    if (date == null) return;
    await _loadPaymentsForDate(date);
  }

  // ── Navigation ─────────────────────────────────────────────────
  void _onNavBarTap(int index) {
    switch (index) {
      case 0:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TodaysPaymentsPage(
              payments: visiblePayments,
              selectedDate: _selectedDate,
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

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    Session.clear();

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  // ── UI BUILDERS ────────────────────────────────────────────────
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
        padding: const EdgeInsets.all(10),
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
                    child: Icon(
                      trendIcon,
                      color: trendColor ?? Colors.green,
                      size: 18,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.blueGrey.shade600,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: Colors.blueGrey.shade900,
                height: 1.1,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.blueGrey.shade500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildQuickAction({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  color.withValues(alpha: 0.2),
                  color.withValues(alpha: 0.1),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withValues(alpha: 0.2)),
            ),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.blueGrey.shade700,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentRow(dynamic payment) {
    final plate =
        (payment['plate'] ?? payment['plateNumber'] ?? '-').toString();
    final movement =
        (payment['movement'] ?? payment['movementType'] ?? '-').toString();
    final time = _formatEatTime(payment);
    final amount = (payment['amount'] as num?)?.toDouble() ?? 0;

    final isReverted = payment['isReverted'] == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.blueGrey.shade50),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
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
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Colors.blueGrey.shade900,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  movement,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.blueGrey.shade600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  time,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.blueGrey.shade500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPager() {
    // Since we now use date-based filtering, show record count info
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blueGrey.shade200),
      ),
      child: Text(
        '${filteredPayments.length} record${filteredPayments.length != 1 ? 's' : ''} for ${DateFormat('MMM d, yyyy').format(_selectedDate)}',
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: Colors.blueGrey.shade800,
          fontSize: 13,
        ),
      ),
    );
  }

  // ── MAIN BUILD ─────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final dateStr = DateFormat('EEEE, MMMM d').format(now);

    return Scaffold(
      backgroundColor: BrandColors.background,
      body: SafeArea(
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: () async {
                  await loadDashboard();
                  await _loadPaymentsForDate(_selectedDate);
                },
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ===== Header =====
                      _buildHeader(dateStr),

                      const SizedBox(height: 20),

                      // ===== Stat Cards =====
                      _buildStatCards(),

                      // ===== Date Picker for Previous Payments =====
                      const SizedBox(height: 24),
                      _buildDateSection(),

                      // ===== Payments List =====
                      if (error != null)
                        _buildErrorBanner()
                      else if (filteredPayments.isEmpty)
                        _buildEmptyState()
                      else
                        Column(
                          children: [
                            ...filteredPayments.map(_buildPaymentRow),
                            const SizedBox(height: 16),
                            _buildPager(),
                          ],
                        ),

                    ],
                  ),
                ),
              ),
      ),
      bottomNavigationBar: _buildBottomNavBar(),
    );
  }

  Widget _buildHeader(String dateStr) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: BrandColors.primary,
              child: Text(
                (Session.username ?? 'U')
                    .substring(0, 1)
                    .toUpperCase(),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Hello, ${Session.username ?? ''}',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: BrandColors.textPrimary,
                  ),
                ),
                Text(
                  dateStr,
                  style: TextStyle(
                    fontSize: 13,
                    color: BrandColors.textSecondary,
                  ),
                ),
              ],
            ),
          ],
        ),
        ElevatedButton.icon(
          onPressed: logout,
          icon: const Icon(Icons.logout, size: 18),
          label: const Text(
            'Logout',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red.shade50,
            foregroundColor: Colors.red.shade700,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            elevation: 0,
            side: BorderSide(color: Colors.red.shade200),
          ),
        ),
      ],
    );
  }

  Widget _buildStatCards() {
    final dateLabel = DateFormat('MMM d, yyyy').format(_selectedDate);

    return Column(
      children: [
        // ── Date-specific stats (Vehicles + Payments) ───────────
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                title: 'Vehicles',
                value: '$selectedDateVehicleCount',
                icon: Icons.directions_car,
                color: BrandColors.primary,
                subtitle: dateLabel,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildStatCard(
                title: 'Payments',
                value: '$selectedDatePaymentCount',
                icon: Icons.receipt_long,
                color: Colors.blue.shade600,
                subtitle: dateLabel,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // ── Date-specific total ──────────────────────────────────
        _buildStatCard(
          title: 'Total Collected',
          value: '\$${selectedDateTotal.toStringAsFixed(2)}',
          icon: Icons.attach_money,
          color: BrandColors.accent,
          subtitle: '$selectedDatePaymentCount payments on $dateLabel',
          trendIcon: Icons.trending_up,
          trendColor: Colors.green.shade600,
        ),
        // ── Overall stats (secondary) ─────────────────────────────
        const SizedBox(height: 12),
        _buildStatCard(
          title: 'All Vehicles',
          value: '$totalVehicles',
          icon: Icons.directions_car_outlined,
          color: BrandColors.primaryDark,
          subtitle: 'Total in system',
          trendIcon: Icons.info_outline,
          trendColor: BrandColors.primary,
        ),
      ],
    );
  }

  Widget _buildDateSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.blueGrey.shade50),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Filter Payments by Date',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: BrandColors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _pickDate,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    decoration: BoxDecoration(
                      color: BrandColors.background,
                      borderRadius: BorderRadius.circular(12),
                      border:
                          Border.all(color: Colors.blueGrey.shade200),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.calendar_today,
                          size: 20,
                          color: BrandColors.primary,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          DateFormat('MMM d, yyyy').format(_selectedDate),
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: BrandColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextButton(
                  onPressed: _pickDate,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text(
                    'Select Date',
                    style: TextStyle(
                      color: BrandColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_selectedDate != null)
            Text(
              'Showing ${filteredPayments.length} record(s) for selected date',
              style: TextStyle(
                fontSize: 12,
                color: BrandColors.textSecondary,
              ),
            ),
        ],
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
              child: Icon(
                Icons.receipt_long,
                size: 36,
                color: Colors.blueGrey.shade300,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'No payments found for selected date',
              style: TextStyle(
                fontSize: 15,
                color: Colors.blueGrey.shade500,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Quick Actions',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: BrandColors.textPrimary,
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildQuickAction(
              icon: Icons.payments,
              label: 'New Payment',
              color: BrandColors.primary,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PaymentPage()),
                ).then((_) => loadDashboard());
              },
            ),
            _buildQuickAction(
              icon: Icons.receipt_long,
              label: 'Today\'s Payments',
              color: Colors.green.shade600,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TodaysPaymentsPage(
                      payments: visiblePayments,
                      selectedDate: _selectedDate,
                    ),
                  ),
                ).then((_) => loadDashboard());
              },
            ),
            _buildQuickAction(
              icon: Icons.person,
              label: 'Profile',
              color: Colors.purple.shade600,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ProfilePage()),
                );
              },
            ),
            _buildQuickAction(
              icon: Icons.print,
              label: 'Printer',
              color: Colors.teal.shade600,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const PrinterSettingsPage()),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBottomNavBar() {
    return BottomNavigationBar(
      type: BottomNavigationBarType.fixed,
      backgroundColor: Colors.white,
      selectedItemColor: BrandColors.primary,
      unselectedItemColor: Colors.blueGrey.shade500,
      selectedLabelStyle:
          const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
      unselectedLabelStyle:
          const TextStyle(fontWeight: FontWeight.w500, fontSize: 12),
      elevation: 4,
      onTap: _onNavBarTap,
      items: const [
       
        BottomNavigationBarItem(
          icon: Icon(Icons.receipt_long),
          label: 'Payments',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.payments),
          label: 'New Payment',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.person),
          label: 'Profile',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.print),
          label: 'Printer',
        ),
      ],
    );
  }
}
