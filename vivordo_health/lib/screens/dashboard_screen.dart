import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:vivordo_health/src/services/health_service.dart';
import 'profile_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// DashboardScreen
//
// Uses ONE combined Firestore listener for all metrics (instead of 9 separate
// ones) to avoid Firestore's internal watch-stream assertion errors that occur
// when too many concurrent listeners are open at the same time.
//
// Consent is a second listener on the users/ doc (already open app-wide).
// Total listeners: 2 instead of the previous ~13.
// ─────────────────────────────────────────────────────────────────────────────

class DashboardScreen extends StatefulWidget {
  final VoidCallback? onScanTap;
  const DashboardScreen({super.key, this.onScanTap});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  static const Color accentPurple = Color(0xFF7B6EF6);
  static const Color greenColor  = Color(0xFF34C759);
  static const Color bgColor     = Color(0xFFF2F2F7);
  static const Color cardWhite   = Colors.white;
  static const Color textDark    = Color(0xFF1C1C1E);
  static const Color textGrey    = Color(0xFF8E8E93);

  // 0 = Day, 1 = Week (default), 2 = Month
  int _filterIndex = 1;
  static const _filterLabels = ['Day', 'Week', 'Month'];
  int get _daysBack => _filterIndex == 0 ? 1 : _filterIndex == 1 ? 7 : 30;

  // ── ONE combined stream for all metrics_daily docs in the date window ──────
  late Stream<QuerySnapshot<Map<String, dynamic>>> _allMetricsStream;
  // ── Separate consent stream (reads from users/ doc) ───────────────────────
  late Stream<Map<String, bool>> _consentStream;

  @override
  void initState() {
    super.initState();
    _rebuildStreams();
  }

  void _rebuildStreams() {
    _allMetricsStream = _buildCombinedStream();
    _consentStream    = HealthService().consentStream();
  }

  /// Single Firestore query that fetches ALL metric types for the user in the
  /// current date window. We split by metricType in Dart — no extra listeners.
  Stream<QuerySnapshot<Map<String, dynamic>>> _buildCombinedStream() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const Stream.empty();
    final now    = DateTime.now();
    final oldest = now.subtract(Duration(days: _daysBack - 1));
    String fmt(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return FirebaseFirestore.instance
        .collection('metrics_daily')
        .where('userId', isEqualTo: uid)
        .where('period', isGreaterThanOrEqualTo: fmt(oldest))
        .where('period', isLessThanOrEqualTo: fmt(now))
        .orderBy('period')
        .snapshots();
  }

  // ── Per-metric helpers ─────────────────────────────────────────────────────

  /// Filter docs by metricType from the combined snapshot.
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _docsFor(
    QuerySnapshot<Map<String, dynamic>>? snap,
    String metricType,
  ) {
    if (snap == null) return [];
    return snap.docs
        .where((d) => d['metricType'] == metricType)
        .toList()
      ..sort((a, b) =>
          (a['period'] as String).compareTo(b['period'] as String));
  }

  List<double> _vals(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    String field,
  ) =>
      docs.map((d) => (d[field] as num?)?.toDouble() ?? 0.0).toList();

  List<String> _dayLabels(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) =>
      docs.map((d) {
        final p  = d['period'] as String? ?? '';
        final dt = p.length >= 10 ? DateTime.tryParse(p) : null;
        if (dt == null) return '';
        const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
        return names[dt.weekday - 1];
      }).toList();

  /// Month view: only label Mondays to avoid x-axis crowding.
  List<String> _monthLabels(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) =>
      docs.map((d) {
        final p  = d['period'] as String? ?? '';
        final dt = p.length >= 10 ? DateTime.tryParse(p) : null;
        if (dt == null || dt.weekday != DateTime.monday) return '';
        return '${dt.day}/${dt.month}';
      }).toList();

  double _avg(List<double> vals) =>
      vals.isEmpty ? 0 : vals.reduce((a, b) => a + b) / vals.length;

  String _trend(List<double> vals) {
    if (vals.length < 2) return '';
    final half   = vals.length ~/ 2;
    final old    = _avg(vals.sublist(0, half));
    final recent = _avg(vals.sublist(half));
    if (old == 0) return '';
    final pct = ((recent - old) / old * 100).round();
    return pct >= 0 ? '+$pct%' : '$pct%';
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 48),
              const Text(
                'Metrics',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: textDark,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Your health trends',
                style: TextStyle(fontSize: 14, color: textGrey),
              ),
              const SizedBox(height: 16),
              _buildFilter(),
              const SizedBox(height: 20),

              // ── Everything driven by the two cached streams ────────────────
              StreamBuilder<Map<String, bool>>(
                stream: _consentStream,
                builder: (_, consentSnap) {
                  final consent     = consentSnap.data ?? {};
                  final anyConsented = consent.values.any((v) => v);

                  return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _allMetricsStream,
                    builder: (_, metricsSnap) {
                      final snap = metricsSnap.data;

                      // ── Summary row ────────────────────────────────────────
                      final stressVals = _vals(_docsFor(snap, 'stress'), 'avg');
                      final hrvVals    = _vals(_docsFor(snap, 'hrv'),    'avg');
                      final sleepVals  = _vals(_docsFor(snap, 'sleep'),  'avg');
                      final moodVals   = _vals(_docsFor(snap, 'mood'),   'avg');
                      final wellnessVals = _vals(_docsFor(snap, 'wellness'), 'avg');

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Summary cards — only shown when a watch/Health is connected
                            if (anyConsented || stressVals.isNotEmpty || hrvVals.isNotEmpty || sleepVals.isNotEmpty || moodVals.isNotEmpty || wellnessVals.isNotEmpty) ...[
                            Row(
                              children: [
                                Expanded(child: _buildStatCard(
                                  label: 'Avg Stress',
                                  value: stressVals.isEmpty ? '--' : _avg(stressVals).toInt().toString(),
                                  change: _trend(stressVals),
                                  trendUp: !_trend(stressVals).startsWith('+'),
                                )),
                                const SizedBox(width: 10),
                                Expanded(child: _buildStatCard(
                                  label: 'Avg HRV',
                                  value: hrvVals.isEmpty ? '--' : '${_avg(hrvVals).toInt()}ms',
                                  change: _trend(hrvVals),
                                  trendUp: _trend(hrvVals).startsWith('+'),                                )),
                                const SizedBox(width: 10),
                                Expanded(child: _buildStatCard(
                                  label: 'Avg Sleep',
                                  value: sleepVals.isEmpty ? '--' : '${_avg(sleepVals).toStringAsFixed(1)}h',
                                  change: _trend(sleepVals),
                                  trendUp: _trend(sleepVals).startsWith('+'),
                                )),
                              ],
                            ),
                            const SizedBox(height: 10),
                            _buildWellnessCard(wellnessVals),
                            const SizedBox(height: 20),
                          ],

                          // ── Manual metrics — shown only when data exists ────
                          _maybeChart(snap, 'stress',  'Stress Levels',          accentPurple,                'avg', 100),
                          _maybeChart(snap, 'mood',    'Mood',                   const Color(0xFFF97316),     'avg', 100),
                          _maybeChart(snap, 'wellness','Wellness',               Colors.teal,                 'avg', 100),

                          // ── HealthKit metrics — consent-gated ───────────────
                          // Activity
                          if (consent['steps']              == true)
                            _maybeChart(snap, 'steps',              'Daily Steps',                  Colors.blueAccent,           'sum',  20000),
                          if (consent['active_calories']    == true)
                            _maybeChart(snap, 'active_calories',    'Active Calories (kcal)',       const Color(0xFFF97316),     'sum',  1000),
                          if (consent['exercise_time']      == true)
                            _maybeChart(snap, 'exercise_time',      'Exercise Time (min)',          const Color(0xFFFF9500),     'sum',  120),
                          if (consent['distance']           == true)
                            _maybeChart(snap, 'distance',           'Distance (km)',                const Color(0xFF3B82F6),     'sum',  20),
                          if (consent['flights_climbed']    == true)
                            _maybeChart(snap, 'flights_climbed',    'Flights Climbed',              const Color(0xFF14B8A6),     'sum',  30),
                          // Heart
                          if (consent['heart_rate']         == true)
                            _maybeChart(snap, 'heart_rate',         'Heart Rate (bpm)',             Colors.redAccent,            'avg',  200),
                          if (consent['resting_heart_rate'] == true)
                            _maybeChart(snap, 'resting_heart_rate', 'Resting Heart Rate (bpm)',     const Color(0xFFFF6B6B),     'avg',  120),
                          if (consent['hrv']                == true)
                            _maybeChart(snap, 'hrv',                'HRV (ms)',                     greenColor,                  'avg',  120),
                          // Breathing / Vitals
                          if (consent['blood_oxygen']       == true)
                            _maybeChart(snap, 'blood_oxygen',       'Blood Oxygen SpO₂ (%)',        const Color(0xFF06B6D4),     'avg',  100),
                          if (consent['respiratory_rate']   == true)
                            _maybeChart(snap, 'respiratory_rate',   'Respiratory Rate (brpm)',      const Color(0xFF0EA5E9),     'avg',  30),
                          // Sleep
                          if (consent['sleep']              == true)
                            _maybeChart(snap, 'sleep',              'Sleep (hours)',                const Color(0xFF8B5CF6),     'avg',  12),
                          // Body
                          if (consent['weight']             == true)
                            _maybeChart(snap, 'weight',             'Weight (kg)',                  const Color(0xFFA78BFA),     'avg',  0),
                          if (consent['body_fat']           == true)
                            _maybeChart(snap, 'body_fat',           'Body Fat (%)',                 const Color(0xFFFBBF24),     'avg',  50),
                          // Mind
                          if (consent['mindfulness']        == true)
                            _maybeChart(snap, 'mindfulness',        'Mindfulness (min)',            const Color(0xFF7C3AED),     'sum',  60),
                          // Fitness
                          if (consent['vo2max']             == true)
                            _maybeChart(snap, 'vo2max',             'VO₂ Max (ml/kg/min)',          greenColor,                  'avg',  70),

                          // ── Apple Health CTA when nothing is consented ──────
                          if (snap == null || snap.docs.isEmpty)
                            _buildEmptyState()
                          else if (!anyConsented) 
                            _buildConnectCard(),

                          const SizedBox(height: 120),
                        ],
                      );
                    },
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Returns a chart card if the metric has data, otherwise SizedBox.shrink().
  Widget _maybeChart(
    QuerySnapshot<Map<String, dynamic>>? snap,
    String metricType,
    String title,
    Color color,
    String field,
    double maxY,
  ) {
    final docs   = _docsFor(snap, metricType);
    final values = _vals(docs, field);
    final labels = _filterIndex == 2 ? _monthLabels(docs) : _dayLabels(docs);
    if (values.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: _buildChartCard(
        title: title,
        icon: _metricIcon(metricType),
        color: color,
        values: values,
        maxY: maxY > 0
            ? maxY
            : (values.reduce((a, b) => a > b ? a : b) * 1.2)
                .clamp(1, double.infinity),
        labels: labels,
      ),
    );
  }

  IconData _metricIcon(String key) {
    switch (key) {
      case 'steps':              return Icons.directions_walk_rounded;
      case 'active_calories':    return Icons.local_fire_department_rounded;
      case 'exercise_time':      return Icons.fitness_center_rounded;
      case 'distance':           return Icons.straighten_rounded;
      case 'flights_climbed':    return Icons.stairs_rounded;
      case 'heart_rate':         return Icons.favorite_rounded;
      case 'resting_heart_rate': return Icons.favorite_border_rounded;
      case 'hrv':                return Icons.show_chart_rounded;
      case 'blood_oxygen':       return Icons.air_rounded;
      case 'respiratory_rate':   return Icons.wind_power_rounded;
      case 'sleep':              return Icons.bedtime_rounded;
      case 'weight':             return Icons.monitor_weight_rounded;
      case 'body_fat':           return Icons.percent_rounded;
      case 'mindfulness':        return Icons.self_improvement_rounded;
      case 'vo2max':             return Icons.speed_rounded;
      case 'stress':             return Icons.psychology_rounded;
      case 'mood':               return Icons.mood_rounded;
      case 'wellness':           return Icons.spa_rounded;
      default:                   return Icons.monitor_heart_outlined;
    }
  }

  // ── Filter chips ───────────────────────────────────────────────────────────

  Widget _buildFilter() {
    return Row(
      children: List.generate(_filterLabels.length, (i) {
        final active = _filterIndex == i;
        return Padding(
          padding: EdgeInsets.only(right: i < _filterLabels.length - 1 ? 8 : 0),
          child: GestureDetector(
            onTap: () => setState(() {
              _filterIndex = i;
              _rebuildStreams();
            }),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(
                color:  active ? accentPurple : cardWhite,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: active ? accentPurple : const Color(0xFFE5E5EA),
                ),
              ),
              child: Text(
                _filterLabels[i],
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: active ? Colors.white : textGrey,
                ),
              ),
            ),
          ),
        );
      }),
    );
  }

  // ── Shared UI widgets (from dev — unchanged) ──────────────────────────────

  Widget _buildStatCard({
    required String label,
    required String value,
    required String change,
    required bool trendUp,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      decoration: BoxDecoration(
        color: cardWhite,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E5EA)),
      ),
      child: Column(
        children: [
          Text(
            label.toUpperCase(),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 9,
              color: textGrey,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: textDark,
            ),
          ),
          const SizedBox(height: 4),
          if (change.isNotEmpty)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  change.startsWith('+')
                      ? Icons.trending_up_rounded
                      : Icons.trending_down_rounded,
                  size: 13,
                  color: trendUp ? greenColor : const Color(0xFFFF3B30),
                ),
                const SizedBox(width: 3),
                Text(
                  change,
                  style: TextStyle(
                    fontSize: 10,
                    color: trendUp ? greenColor : const Color(0xFFFF3B30),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildWellnessCard(List<double> vals) {
    final avg = vals.isEmpty ? null : _avg(vals);
    final trend = _trend(vals);

    Color labelColor;
    String labelText;
    if (avg == null) {
      labelColor = textGrey;
      labelText = 'No data yet';
    } else if (avg >= 70) {
      labelColor = greenColor;
      labelText = 'Good';
    } else if (avg >= 50) {
      labelColor = const Color(0xFFFF9500);
      labelText = 'Fair';
    } else {
      labelColor = const Color(0xFFFF3B30);
      labelText = 'Needs attention';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: cardWhite,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E5EA)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: labelColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.spa_rounded, size: 18, color: labelColor),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'WELLNESS SCORE',
                  style: TextStyle(
                    fontSize: 9,
                    color: textGrey,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      avg == null ? '--' : avg.toInt().toString(),
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: textDark,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: labelColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        labelText,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: labelColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (trend.isNotEmpty)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  trend.startsWith('+')
                      ? Icons.trending_up_rounded
                      : Icons.trending_down_rounded,
                  size: 16,
                  color: trend.startsWith('+') ? greenColor : const Color(0xFFFF3B30),
                ),
                const SizedBox(width: 4),
                Text(
                  trend,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: trend.startsWith('+') ? greenColor : const Color(0xFFFF3B30),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
  
  Widget _buildEmptyState() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: cardWhite,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E5EA)),
      ),
      child: Column(
        children: [
          const Icon(Icons.bar_chart_rounded, size: 48, color: Color(0xFFE5E5EA)),
          const SizedBox(height: 16),
          const Text(
            'No data for this period',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: textDark,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Complete a scan, log your mood, or connect Apple Health to see your metrics here.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: textGrey, height: 1.5),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => widget.onScanTap?.call(),
                    
                  icon: const Icon(Icons.fingerprint, size: 16),
                  label: const Text('Take a Scan'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accentPurple,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                  icon: const Icon(Icons.health_and_safety_outlined, size: 16),
                  label: const Text('Connect Health'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: accentPurple,
                    side: const BorderSide(color: accentPurple),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildConnectCard() {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SettingsScreen()),
      ),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: cardWhite,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFE5E5EA)),
        ),
        child: Column(
          children: [
            const Icon(Icons.health_and_safety_outlined,
                size: 36, color: Color(0xFF7B6EF6)),
            const SizedBox(height: 12),
            const Text(
              'Apple Health not connected',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: textDark),
            ),
            const SizedBox(height: 6),
            const Text(
              'Tap to go to Profile → Health Data Permissions',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: textGrey, height: 1.5),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: accentPurple,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'Enable Health Data',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChartCard({
    required String title,
    required Color color,
    required List<double> values,
    required double maxY,
    required List<String> labels,
    IconData? icon,
  }) {
    // Compute a quick summary value for the subtitle
    final avg = values.isEmpty ? 0.0 : values.reduce((a, b) => a + b) / values.length;
    final latest = values.isNotEmpty ? values.last : 0.0;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
      decoration: BoxDecoration(
        color: cardWhite,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E5EA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 16, color: color),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: textDark,
                  ),
                ),
              ),
              // Latest value badge
              Text(
                latest == latest.roundToDouble()
                    ? latest.toInt().toString()
                    : latest.toStringAsFixed(1),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
          if (values.length > 1) ...[
            const SizedBox(height: 2),
            Padding(
              padding: EdgeInsets.only(left: icon != null ? 42 : 0),
              child: Text(
                'avg ${avg == avg.roundToDouble() ? avg.toInt() : avg.toStringAsFixed(1)}',
                style: const TextStyle(fontSize: 11, color: textGrey),
              ),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            height: 160,
            child: _AreaChart(
              values: values,
              maxY: maxY,
              color: color,
              labels: labels,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _AreaChart — from dev, unchanged
// ─────────────────────────────────────────────────────────────────────────────

class _AreaChart extends StatefulWidget {
  final List<double> values;
  final double maxY;
  final Color color;
  final List<String> labels;

  const _AreaChart({
    required this.values,
    required this.maxY,
    required this.color,
    required this.labels,
  });

  @override
  State<_AreaChart> createState() => _AreaChartState();
}

class _AreaChartState extends State<_AreaChart>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _animation =
        CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _controller.forward();
  }

  @override
  void didUpdateWidget(_AreaChart old) {
    super.didUpdateWidget(old);
    if (old.values != widget.values) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (_, __) => CustomPaint(
        painter: _AreaChartPainter(
          values: widget.values,
          maxY: widget.maxY,
          color: widget.color,
          labels: widget.labels,
          progress: _animation.value,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _AreaChartPainter extends CustomPainter {
  final List<double> values;
  final double maxY;
  final Color color;
  final List<String> labels;
  final double progress;

  static const double labelHeight = 22;
  static const double leftPad     = 36;

  _AreaChartPainter({
    required this.values,
    required this.maxY,
    required this.color,
    required this.labels,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final chartH = size.height - labelHeight;
    final chartW = size.width - leftPad;

    // Grid lines — light translucent for a modern look
    final gridPaint = Paint()
      ..color = Colors.black.withOpacity(0.06)
      ..strokeWidth = 0.8;
    const gridLines = 4;
    for (int i = 0; i <= gridLines; i++) {
      final y = chartH * i / gridLines;
      canvas.drawLine(
          Offset(leftPad, y), Offset(size.width, y), gridPaint);
      final tp = TextPainter(
        text: TextSpan(
          text: '${(maxY * (1 - i / gridLines)).round()}',
          style: TextStyle(fontSize: 9, color: Colors.grey.shade400),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(0, y - 5));
    }

    if (values.isEmpty) return;

    final n = values.length;
    final pts = List.generate(n, (i) {
      final x = n == 1
          ? leftPad + chartW / 2
          : leftPad + chartW * i / (n - 1);
      final y = chartH * (1 - (values[i] / maxY).clamp(0.0, 1.0));
      return Offset(x, y);
    });

     // Single data point — draw a dot instead of a line
    if (pts.length == 1) {
      canvas.drawCircle(
        pts.first,
        6,
        Paint()..color = color,
      );
      return;
    }

    final linePath    = _smoothPath(pts);
    final pathMetrics = linePath.computeMetrics().toList();
    if (pathMetrics.isEmpty) return;
    final animatedLine = pathMetrics.first
        .extractPath(0, pathMetrics.first.length * progress);

    // Gradient fill
    final fillPath = Path.from(animatedLine)
      ..lineTo(pts.last.dx, chartH)
      ..lineTo(leftPad, chartH)
      ..close();
    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(0, chartH),
          [color.withValues(alpha: 0.28), color.withValues(alpha: 0.0)],
        )
        ..style = PaintingStyle.fill,
    );

    // Single data point — draw a dot instead of a line
    if (values.length == 1) {
      canvas.drawCircle(
        pts.first,
        6,
        Paint()..color = color,
      );
      return;
    }

    // Stroke
    canvas.drawPath(
      animatedLine,
      Paint()
        ..color = color
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // X-axis labels — skip empty strings (used for month view non-Monday points)
    if (labels.length == n) {
      final labelStyle =
          TextStyle(fontSize: 10, color: Colors.grey.shade500);
      for (int i = 0; i < n; i++) {
        if (labels[i].isEmpty) continue;
        final tp = TextPainter(
          text: TextSpan(text: labels[i], style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas,
            Offset(pts[i].dx - tp.width / 2, chartH + 6));
      }
    }
  }

  Path _smoothPath(List<Offset> pts) {
    if (pts.length == 1) {
      return Path()..moveTo(pts[0].dx, pts[0].dy);
    }
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (int i = 0; i < pts.length - 1; i++) {
      final cp1 =
          Offset((pts[i].dx + pts[i + 1].dx) / 2, pts[i].dy);
      final cp2 =
          Offset((pts[i].dx + pts[i + 1].dx) / 2, pts[i + 1].dy);
      path.cubicTo(
          cp1.dx, cp1.dy, cp2.dx, cp2.dy, pts[i + 1].dx, pts[i + 1].dy);
    }
    return path;
  }

  @override
  bool shouldRepaint(_AreaChartPainter old) =>
      old.progress != progress || old.values != values;
}
