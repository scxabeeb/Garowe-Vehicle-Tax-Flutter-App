import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/session.dart';
import '../services/api_service.dart';
import 'dashboard_page.dart';
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

  DateTime? startDate;
  DateTime? endDate;
  String selectedCollector = 'All';

  bool loading = false;
  String? error;

  // For loading payments from the API by date
  DateTime _selectedDate = DateTime.now();
  List<dynamic> _loadedPayments = [];
  int? _resolvedCollectorId;

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.selectedDate ?? DateTime.now();
    _initAndLoad();
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

  bool _matchesDate(dynamic payment) {
    if (startDate == null && endDate == null) return true;
    final parsed = _parseDate(payment);
    if (parsed == null) return false;

    final d = DateUtils.dateOnly(parsed);
    if (startDate != null && d.isBefore(DateUtils.dateOnly(startDate!))) {
      return false;
    }
    if (endDate != null && d.isAfter(DateUtils.dateOnly(endDate!))) {
      return false;
    }
    return true;
  }

  bool _matchesCollector(dynamic payment) {
    if (!isAdmin || selectedCollector == 'All') return true;
    return _collectorName(payment) == selectedCollector;
  }

  List<dynamic> get filteredPayments {
    final source = _loadedPayments.isNotEmpty ? _loadedPayments : widget.payments;
    return source
        .where((p) => p['isReverted'] != true)
        .where((p) => _matchesDate(p) && _matchesCollector(p))
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

  // ── Load payments for a specific date from the API ─────────────
  Future<void> _loadPaymentsForDate(DateTime date) async {
    setState(() {
      loading = true;
      error = null;
      _selectedDate = date;
      startDate = null;
      endDate = null;
    });

    final targetDate = DateUtils.dateOnly(_toEat(date));
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

              final parsed = _parseDate(item);
              if (parsed == null) return false;

              return DateUtils.isSameDay(
                DateUtils.dateOnly(parsed),
                targetDate,
              );
            }).toList();

            setState(() {
              _loadedPayments = matching;
              loading = false;
            });
            return;
          }
        }
      } catch (e) {
        // fall through
      }
    }

    // Fallback to the passed-in payments (today's from dashboard)
    setState(() {
      _loadedPayments = widget.payments;
      loading = false;
      if (collectorId == null) {
        error = 'Collector ID not available. Please log in again.';
      }
    });
  }

  Future<void> _pickStartDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: startDate ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );

    if (date == null) return;
    setState(() {
      startDate = date;
      if (endDate != null && endDate!.isBefore(startDate!)) {
        endDate = null;
      }
    });
  }

  Future<void> _pickEndDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: endDate ?? startDate ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );

    if (date == null) return;
    setState(() {
      if (startDate != null && date.isBefore(startDate!)) {
        endDate = startDate;
      } else {
        endDate = date;
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

  @override
  Widget build(BuildContext context) {
    final sourcePayments =
        _loadedPayments.isNotEmpty ? _loadedPayments : widget.payments;

    return Scaffold(
      backgroundColor: BrandColors.background,
      appBar: AppBar(
        title: Text(
          isAdmin
              ? 'All Payments — ${DateFormat('MMM d, yyyy').format(_selectedDate)}'
              : 'My Payments — ${DateFormat('MMM d, yyyy').format(_selectedDate)}',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
        backgroundColor: BrandColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_today, size: 20),
            onPressed: _pickPaymentDate,
          ),
        ],
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
          // Date picker to view payments for a specific date
          OutlinedButton.icon(
            onPressed: _pickPaymentDate,
            icon: const Icon(Icons.calendar_today, size: 18),
            label: Text(
              'Date: ${DateFormat('MMM d, yyyy').format(_selectedDate)}',
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: BrandColors.primary,
            ),
          ),

          // Range date filters (today's payments shown by default)
          OutlinedButton.icon(
            onPressed: _pickStartDate,
            icon: const Icon(Icons.date_range, size: 18),
            label: Text(
              startDate == null
                  ? 'Start Date'
                  : DateFormat('MMM d').format(startDate!),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: BrandColors.primary,
            ),
          ),
          OutlinedButton.icon(
            onPressed: _pickEndDate,
            icon: const Icon(Icons.event, size: 18),
            label: Text(
              endDate == null
                  ? 'End Date'
                  : DateFormat('MMM d').format(endDate!),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: BrandColors.primary,
            ),
          ),

          if (startDate != null || endDate != null)
            TextButton(
              onPressed: () => setState(() {
                startDate = null;
                endDate = null;
              }),
              child: const Text('Clear Dates'),
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
              style: TextStyle(
                color: BrandColors.primary,
                fontWeight: FontWeight.w600,
              ),
              dropdownColor: Colors.white,
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
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '${filtered.length} record${filtered.length != 1 ? 's' : ''}',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: BrandColors.primary,
            ),
          ),
          Text(
            'Total: \$${totalCollected.toStringAsFixed(2)}',
            style: TextStyle(
              fontSize: 15,
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
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: BrandColors.textPrimary,
          ),
        ),
        subtitle: Text(
          '$movement • $time\nCollector: $collector',
          style: TextStyle(
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
              'No payments found for ${DateFormat('MMM d, yyyy').format(_selectedDate)}',
              style: TextStyle(
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
