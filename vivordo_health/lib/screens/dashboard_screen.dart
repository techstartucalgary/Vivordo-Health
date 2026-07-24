import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show listEquals;
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
  static const Color greenColor = Color(0xFF34C759);
  static const Color bgColor = Color(0xFFF2F2F7);
  static const Color cardWhite = Colors.white;
  static const Color textDark = Color(0xFF1C1C1E);
  static const Color textGrey = Color(0xFF8E8E93);
  static const List<String> _defaultMetricOrder = [
    'stress',
    'mood',
    'wellness',
    'steps',
    'active_calories',
    'exercise_time',
    'distance',
    'flights_climbed',
    'heart_rate_scan',
    'resting_heart_rate',
    'hrv',
    'blood_oxygen',
    'respiratory_rate',
    'sleep',
    'weight',
    'body_fat',
    'mindfulness',
    'vo2max',
  ];

  // 0 = Day, 1 = Week (default), 2 = Month
  int _filterIndex = 1;
  static const _filterLabels = ['Day', 'Week', 'Month'];
  int get _daysBack => _filterIndex == 0
      ? 1
      : _filterIndex == 1
      ? 7
      : 30;

  // ── ONE combined stream for all metrics_daily docs in the date window ──────
  late Stream<QuerySnapshot<Map<String, dynamic>>> _allMetricsStream;
  // ── Separate consent stream (reads from users/ doc) ───────────────────────
  late Stream<Map<String, bool>> _consentStream;

  bool _refreshingHealthMetrics = false;
  DateTime? _lastManualHealthRefresh;
  List<String> _metricOrder = [..._defaultMetricOrder];
  bool _isLoadingMetricOrder = true;

  @override
  void initState() {
    super.initState();
    _rebuildStreams();
    _loadMetricOrder();
    _refreshHealthMetricsFromHealth();
  }

  Future<void> _loadMetricOrder() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (mounted) setState(() => _isLoadingMetricOrder = false);
      return;
    }

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final preferences = snapshot.data()?['preferences'] as Map?;
      final saved = preferences?['dashboardMetricOrder'] as List?;
      final savedKeys =
          saved
              ?.whereType<String>()
              .where(_defaultMetricOrder.contains)
              .toList() ??
          [];
      final missingKeys = _defaultMetricOrder.where(
        (key) => !savedKeys.contains(key),
      );
      if (mounted) {
        setState(() {
          _metricOrder = [...savedKeys, ...missingKeys];
        });
      }
    } catch (e) {
      debugPrint('DashboardScreen: failed to load metric order: $e');
    } finally {
      if (mounted) setState(() => _isLoadingMetricOrder = false);
    }
  }

  Future<void> _saveMetricOrder(List<String> order) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    await FirebaseFirestore.instance.collection('users').doc(uid).update({
      'preferences.dashboardMetricOrder': order,
    });
  }

  void _rebuildStreams() {
    _allMetricsStream = _buildCombinedStream();
    _consentStream = HealthService().consentStream();
  }

  Future<void> _refreshHealthMetricsFromHealth({
    bool showFeedback = false,
  }) async {
    if (_refreshingHealthMetrics) return;
    if (mounted) setState(() => _refreshingHealthMetrics = true);

    try {
      await HealthService().syncToFirestore(daysBack: _daysBack);
      if (!mounted) return;
      setState(() => _lastManualHealthRefresh = DateTime.now());
      if (showFeedback) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Apple Health metrics refreshed.')),
        );
      }
    } catch (e) {
      debugPrint(
        'DashboardScreen: failed to refresh metrics from Apple Health: $e',
      );
      if (showFeedback && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Apple Health refresh failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _refreshingHealthMetrics = false);
    }
  }

  String _manualRefreshLabel() {
    final refreshed = _lastManualHealthRefresh;
    if (refreshed == null) return 'Refresh';
    final hour = refreshed.hour % 12 == 0 ? 12 : refreshed.hour % 12;
    final minute = refreshed.minute.toString().padLeft(2, '0');
    final suffix = refreshed.hour >= 12 ? 'PM' : 'AM';
    return 'Updated $hour:$minute $suffix';
  }

  /// Single Firestore query that fetches all daily docs in the date window from
  /// the user's subcollection. Each doc holds all metrics for that day.
  Stream<QuerySnapshot<Map<String, dynamic>>> _buildCombinedStream() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const Stream.empty();
    final now = DateTime.now();
    final oldest = now.subtract(Duration(days: _daysBack - 1));
    String fmt(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('metrics_daily')
        .where(FieldPath.documentId, isGreaterThanOrEqualTo: fmt(oldest))
        .where(FieldPath.documentId, isLessThanOrEqualTo: fmt(now))
        .orderBy(FieldPath.documentId)
        .snapshots();
  }

  // ── Per-metric helpers ─────────────────────────────────────────────────────

  /// Filter docs by metricType from the combined daily snapshot.
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _docsFor(
    QuerySnapshot<Map<String, dynamic>>? snap,
    String metricType,
  ) {
    if (snap == null) return [];
    return snap.docs.where((d) => d.data().containsKey(metricType)).toList();
  }

  List<double> _vals(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    String metricType,
    String field,
  ) => docs
      .map(
        (d) =>
            ((d.data()[metricType] as Map?)?[field] as num?)?.toDouble() ?? 0.0,
      )
      .toList();

  List<String> _dayLabels(
    QuerySnapshot<Map<String, dynamic>>? snap,
    String metricType,
  ) {
    if (snap == null) return [];
    return snap.docs.where((d) => d.data().containsKey(metricType)).map((d) {
      final dt = DateTime.tryParse(d.id);
      if (dt == null) return '';
      const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return names[dt.weekday - 1];
    }).toList();
  }

  /// Month view: only label Mondays to avoid x-axis crowding.
  List<String> _monthLabels(
    QuerySnapshot<Map<String, dynamic>>? snap,
    String metricType,
  ) {
    if (snap == null) return [];
    return snap.docs.where((d) => d.data().containsKey(metricType)).map((d) {
      final dt = DateTime.tryParse(d.id);
      if (dt == null || dt.weekday != DateTime.monday) return '';
      return '${dt.day}/${dt.month}';
    }).toList();
  }

  // ── Daily mood helpers ─────────────────────────────────────────────────────
  List<Map<String, dynamic>> _dailyMoodPoints(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final points = <Map<String, dynamic>>[];

    for (final doc in docs) {
      final moodMap = doc.data()['mood'] as Map?;
      if (moodMap == null) continue;
      final period = doc.id;
      final entries = moodMap['entries'];
      final scores = <double>[];

      if (entries is List && entries.isNotEmpty) {
        for (final entry in entries) {
          if (entry is! Map) continue;
          final score = entry['score'];
          if (score is num) scores.add(score.toDouble());
        }
      }

      if (scores.isEmpty) {
        final avg = moodMap['avg'];
        if (avg is num) scores.add(avg.toDouble());
      }

      if (scores.isEmpty) continue;
      points.add({
        'score': _avg(scores),
        'dateTime':
            DateTime.tryParse(period) ?? DateTime.fromMillisecondsSinceEpoch(0),
      });
    }

    points.sort(
      (a, b) =>
          (a['dateTime'] as DateTime).compareTo(b['dateTime'] as DateTime),
    );
    return points;
  }

  List<double> _dailyMoodValues(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) => _dailyMoodPoints(docs).map((point) => point['score'] as double).toList();

  List<String> _dailyMoodLabels(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final points = _dailyMoodPoints(docs);
    const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    return points.map((point) {
      final dateTime = point['dateTime'] as DateTime;

      if (_filterIndex == 2 && dateTime.weekday != DateTime.monday) {
        return '';
      }

      return dayNames[dateTime.weekday - 1];
    }).toList();
  }

  List<Map<String, dynamic>> _todayMoodEntries(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final entries = <Map<String, dynamic>>[];

    for (final doc in docs) {
      final moodMap = doc.data()['mood'] as Map?;
      final rawEntries = moodMap?['entries'];
      if (rawEntries is! List) continue;

      for (final entry in rawEntries) {
        if (entry is! Map || entry['score'] is! num) continue;
        final timestamp = entry['timestamp'];
        entries.add({
          'score': (entry['score'] as num).toDouble(),
          'dateTime': timestamp is Timestamp
              ? timestamp.toDate()
              : DateTime.tryParse(doc.id),
        });
      }
    }

    entries.sort((a, b) {
      final aTime = a['dateTime'] as DateTime?;
      final bTime = b['dateTime'] as DateTime?;
      if (aTime == null) return -1;
      if (bTime == null) return 1;
      return aTime.compareTo(bTime);
    });
    return entries;
  }

  String _formatMoodEntryTime(DateTime? dateTime) {
    if (dateTime == null) return '';
    final hour = dateTime.hour % 12 == 0 ? 12 : dateTime.hour % 12;
    final minute = dateTime.minute.toString().padLeft(2, '0');
    final suffix = dateTime.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $suffix';
  }

  List<Map<String, dynamic>> _bpmScanEntries(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final points = <Map<String, dynamic>>[];
    for (final doc in docs) {
      final scan = doc.data()['heart_rate_scan'] as Map?;
      final rawEntries = scan?['entries'];
      if (rawEntries is List && rawEntries.isNotEmpty) {
        for (final entry in rawEntries) {
          if (entry is! Map || entry['bpm'] is! num) continue;
          final timestamp = entry['timestamp'];
          points.add({
            'bpm': (entry['bpm'] as num).toDouble(),
            'dateTime': timestamp is Timestamp
                ? timestamp.toDate()
                : DateTime.tryParse(doc.id),
          });
        }
      } else if (scan?['avg'] is num) {
        final timestamp = scan?['syncedAt'];
        points.add({
          'bpm': (scan!['avg'] as num).toDouble(),
          'dateTime': timestamp is Timestamp
              ? timestamp.toDate()
              : DateTime.tryParse(doc.id),
        });
      }
    }
    points.sort((a, b) {
      final aTime = a['dateTime'] as DateTime?;
      final bTime = b['dateTime'] as DateTime?;
      if (aTime == null) return -1;
      if (bTime == null) return 1;
      return aTime.compareTo(bTime);
    });
    return points;
  }

  List<Map<String, dynamic>> _dailyBpmScanPoints(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final points = <Map<String, dynamic>>[];
    for (final doc in docs) {
      final entries = _bpmScanEntries([doc]);
      if (entries.isEmpty) continue;
      points.add({
        'bpm': _avg(entries.map((entry) => entry['bpm'] as double).toList()),
        'dateTime': DateTime.tryParse(doc.id),
      });
    }
    return points;
  }

  double _avg(List<double> vals) =>
      vals.isEmpty ? 0 : vals.reduce((a, b) => a + b) / vals.length;

  String _trend(List<double> vals) {
    if (vals.length < 2) return '';
    final half = vals.length ~/ 2;
    final old = _avg(vals.sublist(0, half));
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
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Metrics',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: textDark,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh Apple Health',
                    onPressed: _refreshingHealthMetrics
                        ? null
                        : () => _refreshHealthMetricsFromHealth(
                            showFeedback: true,
                          ),
                    icon: _refreshingHealthMetrics
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.4),
                          )
                        : const Icon(Icons.refresh_rounded),
                    color: accentPurple,
                  ),
                  TextButton.icon(
                    onPressed: _isLoadingMetricOrder ? null : _showLayoutEditor,
                    icon: const Icon(Icons.tune_rounded, size: 18),
                    label: const Text('Layout'),
                    style: TextButton.styleFrom(
                      foregroundColor: accentPurple,
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _lastManualHealthRefresh == null
                    ? 'Your health trends • Tap refresh to sync now'
                    : 'Your health trends • ${_manualRefreshLabel()}',
                style: const TextStyle(fontSize: 14, color: textGrey),
              ),
              const SizedBox(height: 16),
              _buildFilter(),
              const SizedBox(height: 20),

              // ── Everything driven by the two cached streams ────────────────
              StreamBuilder<Map<String, bool>>(
                stream: _consentStream,
                builder: (_, consentSnap) {
                  final consentLoaded = consentSnap.hasData;
                  final consent = consentSnap.data ?? {};
                  final anyConsented =
                      consentLoaded && consent.values.any((v) => v);

                  return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _allMetricsStream,
                    builder: (_, metricsSnap) {
                      final snap = metricsSnap.data;

                      // ── Summary row ────────────────────────────────────────
                      final stressVals = _vals(
                        _docsFor(snap, 'stress'),
                        'stress',
                        'avg',
                      );
                      final hrvVals = _vals(
                        _docsFor(snap, 'hrv'),
                        'hrv',
                        'avg',
                      );
                      final sleepVals = _vals(
                        _docsFor(snap, 'sleep'),
                        'sleep',
                        'avg',
                      );
                      final moodVals = _vals(
                        _docsFor(snap, 'mood'),
                        'mood',
                        'avg',
                      );
                      final wellnessVals = _vals(
                        _docsFor(snap, 'wellness'),
                        'wellness',
                        'avg',
                      );

                      bool hasMetricData(String metricType) =>
                          _docsFor(snap, metricType).isNotEmpty;

                      final hasAnyHealthData = [
                        'steps',
                        'active_calories',
                        'exercise_time',
                        'distance',
                        'flights_climbed',
                        'heart_rate',
                        'resting_heart_rate',
                        'hrv',
                        'blood_oxygen',
                        'respiratory_rate',
                        'sleep',
                        'weight',
                        'body_fat',
                        'mindfulness',
                        'vo2max',
                      ].any(hasMetricData);

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!consentLoaded && !hasAnyHealthData) ...[
                            _buildHealthConsentLoadingCard(),
                            const SizedBox(height: 16),
                          ],

                          // Summary cards — only shown when a watch/Health is connected
                          if (anyConsented ||
                              stressVals.isNotEmpty ||
                              hrvVals.isNotEmpty ||
                              sleepVals.isNotEmpty ||
                              moodVals.isNotEmpty ||
                              wellnessVals.isNotEmpty) ...[
                            Row(
                              children: [
                                Expanded(
                                  child: _buildStatCard(
                                    label: 'Avg Stress',
                                    value: stressVals.isEmpty
                                        ? '--'
                                        : _avg(stressVals).toInt().toString(),
                                    change: _trend(stressVals),
                                    trendUp: !_trend(
                                      stressVals,
                                    ).startsWith('+'),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _buildStatCard(
                                    label: 'Avg HRV',
                                    value: hrvVals.isEmpty
                                        ? '--'
                                        : '${_avg(hrvVals).toInt()}ms',
                                    change: _trend(hrvVals),
                                    trendUp: _trend(hrvVals).startsWith('+'),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _buildStatCard(
                                    label: 'Avg Sleep',
                                    value: sleepVals.isEmpty
                                        ? '--'
                                        : '${_avg(sleepVals).toStringAsFixed(1)}h',
                                    change: _trend(sleepVals),
                                    trendUp: _trend(sleepVals).startsWith('+'),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            _buildWellnessCard(wellnessVals),
                            const SizedBox(height: 20),
                          ],

                          ..._metricOrder.map(
                            (metric) =>
                                _buildOrderedMetric(snap, consent, metric),
                          ),

                          // ── Apple Health CTA when nothing is consented ──────
                          if (snap == null || snap.docs.isEmpty)
                            _buildEmptyState()
                          else if (consentLoaded &&
                              !anyConsented &&
                              !hasAnyHealthData)
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

  bool _isManualMetric(String key) =>
      key == 'stress' ||
      key == 'mood' ||
      key == 'wellness' ||
      key == 'heart_rate_scan';

  String _metricTitle(String key) {
    switch (key) {
      case 'stress':
        return 'Stress Levels';
      case 'mood':
        return 'Mood';
      case 'wellness':
        return 'Wellness';
      case 'steps':
        return 'Daily Steps';
      case 'active_calories':
        return 'Active Calories (kcal)';
      case 'exercise_time':
        return 'Exercise Time (min)';
      case 'distance':
        return 'Distance (km)';
      case 'flights_climbed':
        return 'Flights Climbed';
      case 'heart_rate':
        return 'Heart Rate (bpm)';
      case 'heart_rate_scan':
        return 'Heart Rate';
      case 'resting_heart_rate':
        return 'Resting Heart Rate (bpm)';
      case 'hrv':
        return 'HRV (ms)';
      case 'blood_oxygen':
        return 'Blood Oxygen SpO2 (%)';
      case 'respiratory_rate':
        return 'Respiratory Rate (brpm)';
      case 'sleep':
        return 'Sleep (hours)';
      case 'weight':
        return 'Weight (kg)';
      case 'body_fat':
        return 'Body Fat (%)';
      case 'mindfulness':
        return 'Mindfulness (min)';
      case 'vo2max':
        return 'VO2 Max (ml/kg/min)';
      default:
        return key;
    }
  }

  Color _metricColor(String key) {
    switch (key) {
      case 'stress':
        return accentPurple;
      case 'mood':
        return const Color(0xFFF97316);
      case 'wellness':
        return Colors.teal;
      case 'steps':
        return Colors.blueAccent;
      case 'active_calories':
        return const Color(0xFFF97316);
      case 'exercise_time':
        return const Color(0xFFFF9500);
      case 'distance':
        return const Color(0xFF3B82F6);
      case 'flights_climbed':
        return const Color(0xFF14B8A6);
      case 'heart_rate':
      case 'heart_rate_scan':
        return Colors.redAccent;
      case 'resting_heart_rate':
        return const Color(0xFFFF6B6B);
      case 'hrv':
        return greenColor;
      case 'blood_oxygen':
        return const Color(0xFF06B6D4);
      case 'respiratory_rate':
        return const Color(0xFF0EA5E9);
      case 'sleep':
        return const Color(0xFF8B5CF6);
      case 'weight':
        return const Color(0xFFA78BFA);
      case 'body_fat':
        return const Color(0xFFFBBF24);
      case 'mindfulness':
        return const Color(0xFF7C3AED);
      case 'vo2max':
        return greenColor;
      default:
        return accentPurple;
    }
  }

  String _metricField(String key) {
    const summed = {
      'steps',
      'active_calories',
      'exercise_time',
      'distance',
      'flights_climbed',
      'mindfulness',
    };
    return summed.contains(key) ? 'sum' : 'avg';
  }

  double _metricMaxY(String key) {
    switch (key) {
      case 'stress':
      case 'mood':
      case 'wellness':
      case 'blood_oxygen':
        return 100;
      case 'steps':
        return 20000;
      case 'active_calories':
        return 1000;
      case 'exercise_time':
      case 'resting_heart_rate':
      case 'hrv':
        return 120;
      case 'distance':
        return 20;
      case 'flights_climbed':
        return 30;
      case 'heart_rate':
      case 'heart_rate_scan':
        return 200;
      case 'respiratory_rate':
        return 30;
      case 'sleep':
        return 12;
      case 'body_fat':
        return 50;
      case 'mindfulness':
        return 60;
      case 'vo2max':
        return 70;
      default:
        return 0;
    }
  }

  Widget _buildOrderedMetric(
    QuerySnapshot<Map<String, dynamic>>? snap,
    Map<String, bool> consent,
    String metric,
  ) {
    final hasData = _docsFor(snap, metric).isNotEmpty;
    return KeyedSubtree(
      key: ValueKey('dashboard-metric-$metric'),
      child: !_isManualMetric(metric) && consent[metric] != true && !hasData
          ? const SizedBox.shrink()
          : _maybeChart(
              snap,
              metric,
              _metricTitle(metric),
              _metricColor(metric),
              _metricField(metric),
              _metricMaxY(metric),
            ),
    );
  }

  Future<void> _showLayoutEditor() async {
    Map<String, bool> consent;
    try {
      consent = await HealthService().getConsent();
    } catch (e) {
      debugPrint('DashboardScreen: failed to load layout permissions: $e');
      consent = const {};
    }
    if (!mounted) return;

    bool isVisibleOption(String metric) =>
        _isManualMetric(metric) || consent[metric] == true;
    final draftOrder = _metricOrder.where(isVisibleOption).toList();
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          height: MediaQuery.sizeOf(context).height * 0.78,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 10),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Edit dashboard layout',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: textDark,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, draftOrder),
                        child: const Text('Done'),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    buildDefaultDragHandles: false,
                    itemCount: draftOrder.length,
                    onReorderItem: (oldIndex, newIndex) {
                      setModalState(() {
                        final item = draftOrder.removeAt(oldIndex);
                        draftOrder.insert(newIndex, item);
                      });
                    },
                    itemBuilder: (context, index) {
                      final metric = draftOrder[index];
                      final color = _metricColor(metric);
                      return ListTile(
                        key: ValueKey(metric),
                        leading: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            _metricIcon(metric),
                            size: 18,
                            color: color,
                          ),
                        ),
                        title: Text(
                          _metricTitle(metric),
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        trailing: ReorderableDragStartListener(
                          index: index,
                          child: const Padding(
                            padding: EdgeInsets.all(10),
                            child: Icon(
                              Icons.drag_handle_rounded,
                              color: textGrey,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (!mounted) return;
    // A drag changes the layout even when the sheet is dismissed with Back,
    // a swipe, or a tap outside instead of the Done button.
    final visibleOrder = result ?? draftOrder;
    final visibleIterator = visibleOrder.iterator;
    final updatedOrder = _metricOrder.map((metric) {
      if (!isVisibleOption(metric)) return metric;
      visibleIterator.moveNext();
      return visibleIterator.current;
    }).toList();
    if (listEquals(updatedOrder, _metricOrder)) return;
    setState(() => _metricOrder = [...updatedOrder]);
    try {
      await _saveMetricOrder(updatedOrder);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save dashboard layout.')),
      );
    }
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
    final docs = _docsFor(snap, metricType);
    if (metricType == 'heart_rate_scan') {
      final points = _filterIndex == 0
          ? _bpmScanEntries(docs)
          : _dailyBpmScanPoints(docs);
      if (points.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: _buildChartCard(
          title: title,
          icon: _metricIcon(metricType),
          color: color,
          values: points.map((point) => point['bpm'] as double).toList(),
          maxY: maxY,
          labels: points.map((point) {
            final dateTime = point['dateTime'] as DateTime?;
            if (_filterIndex == 0) return _formatMoodEntryTime(dateTime);
            if (dateTime == null) return '';
            if (_filterIndex == 2 && dateTime.weekday != DateTime.monday) {
              return '';
            }
            const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
            return names[dateTime.weekday - 1];
          }).toList(),
        ),
      );
    }
    if (metricType == 'mood' && _filterIndex == 0) {
      final entries = _todayMoodEntries(docs);
      if (entries.isEmpty) return const SizedBox.shrink();

      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: _buildChartCard(
          title: title,
          icon: _metricIcon(metricType),
          color: color,
          values: entries.map((entry) => entry['score'] as double).toList(),
          maxY: maxY,
          labels: entries
              .map(
                (entry) => _formatMoodEntryTime(entry['dateTime'] as DateTime?),
              )
              .toList(),
        ),
      );
    }

    final values = metricType == 'mood'
        ? _dailyMoodValues(docs)
        : _vals(docs, metricType, field);
    final labels = metricType == 'mood'
        ? _dailyMoodLabels(docs)
        : _filterIndex == 2
        ? _monthLabels(snap, metricType)
        : _dayLabels(snap, metricType);
    if (values.isEmpty) return const SizedBox.shrink();

    if (_filterIndex == 0) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: _buildDailyMetricTile(
          title: title,
          icon: _metricIcon(metricType),
          color: color,
          metricType: metricType,
          field: field,
          values: values,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: _buildChartCard(
        title: title,
        icon: _metricIcon(metricType),
        color: color,
        values: values,
        maxY: maxY > 0
            ? maxY
            : (values.reduce((a, b) => a > b ? a : b) * 1.2).clamp(
                1,
                double.infinity,
              ),
        labels: labels,
      ),
    );
  }

  Widget _buildDailyMetricTile({
    required String title,
    required IconData icon,
    required Color color,
    required String metricType,
    required String field,
    required List<double> values,
  }) {
    final primaryValue = field == 'sum'
        ? values.fold<double>(0, (total, value) => total + value)
        : values.last;
    final avgValue = _avg(values);
    final hasMultipleValues = values.length > 1;

    final primaryLabel = _formatMetricValue(metricType, primaryValue);
    final subtitle = hasMultipleValues
        ? field == 'sum'
              ? '${values.length} entries today'
              : 'avg ${_formatMetricValue(metricType, avgValue)} today'
        : 'today';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: cardWhite,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E5EA)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: textDark,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(fontSize: 12, color: textGrey),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            primaryLabel,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  String _formatMetricValue(String metricType, double value) {
    String number({int decimals = 0}) => decimals == 0
        ? value.round().toString()
        : value.toStringAsFixed(decimals);

    switch (metricType) {
      case 'steps':
        return number();
      case 'active_calories':
        return '${number()} kcal';
      case 'exercise_time':
      case 'mindfulness':
        return '${number()} min';
      case 'distance':
        return '${number(decimals: value >= 10 ? 1 : 2)} km';
      case 'heart_rate':
      case 'heart_rate_scan':
      case 'resting_heart_rate':
        return '${number()} bpm';
      case 'hrv':
        return '${number()} ms';
      case 'blood_oxygen':
        return '${number()}%';
      case 'respiratory_rate':
        return '${number()} brpm';
      case 'sleep':
        return '${number(decimals: 1)}h';
      case 'weight':
        return '${number(decimals: 1)} kg';
      case 'body_fat':
        return '${number(decimals: 1)}%';
      case 'vo2max':
        return number(decimals: 1);
      case 'stress':
      case 'mood':
      case 'wellness':
        return number();
      default:
        return value == value.roundToDouble() ? number() : number(decimals: 1);
    }
  }

  IconData _metricIcon(String key) {
    switch (key) {
      case 'steps':
        return Icons.directions_walk_rounded;
      case 'active_calories':
        return Icons.local_fire_department_rounded;
      case 'exercise_time':
        return Icons.fitness_center_rounded;
      case 'distance':
        return Icons.straighten_rounded;
      case 'flights_climbed':
        return Icons.stairs_rounded;
      case 'heart_rate':
      case 'heart_rate_scan':
        return Icons.favorite_rounded;
      case 'resting_heart_rate':
        return Icons.favorite_border_rounded;
      case 'hrv':
        return Icons.show_chart_rounded;
      case 'blood_oxygen':
        return Icons.air_rounded;
      case 'respiratory_rate':
        return Icons.wind_power_rounded;
      case 'sleep':
        return Icons.bedtime_rounded;
      case 'weight':
        return Icons.monitor_weight_rounded;
      case 'body_fat':
        return Icons.percent_rounded;
      case 'mindfulness':
        return Icons.self_improvement_rounded;
      case 'vo2max':
        return Icons.speed_rounded;
      case 'stress':
        return Icons.psychology_rounded;
      case 'mood':
        return Icons.mood_rounded;
      case 'wellness':
        return Icons.spa_rounded;
      default:
        return Icons.monitor_heart_outlined;
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
            onTap: () {
              setState(() {
                _filterIndex = i;
                _rebuildStreams();
              });
              _refreshHealthMetricsFromHealth();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(
                color: active ? accentPurple : cardWhite,
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
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
                  color: trend.startsWith('+')
                      ? greenColor
                      : const Color(0xFFFF3B30),
                ),
                const SizedBox(width: 4),
                Text(
                  trend,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: trend.startsWith('+')
                        ? greenColor
                        : const Color(0xFFFF3B30),
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
          const Icon(
            Icons.bar_chart_rounded,
            size: 48,
            color: Color(0xFFE5E5EA),
          ),
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

  Widget _buildHealthConsentLoadingCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardWhite,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E5EA)),
      ),
      child: const Row(
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: accentPurple,
            ),
          ),
          SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Checking Apple Health permissions',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: textDark,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Loading your connected health data…',
                  style: TextStyle(fontSize: 12, color: textGrey, height: 1.4),
                ),
              ],
            ),
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
            const Icon(
              Icons.health_and_safety_outlined,
              size: 36,
              color: Color(0xFF7B6EF6),
            ),
            const SizedBox(height: 12),
            const Text(
              'Apple Health not connected',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: textDark,
              ),
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
    final avg = values.isEmpty
        ? 0.0
        : values.reduce((a, b) => a + b) / values.length;
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
  int? _selectedIndex;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _controller.forward();
  }

  @override
  void didUpdateWidget(_AreaChart old) {
    super.didUpdateWidget(old);
    if (!listEquals(old.values, widget.values)) {
      if (_selectedIndex != null && _selectedIndex! >= widget.values.length) {
        _selectedIndex = null;
      }
      _controller.forward(from: 0);
    }
  }

  void _selectPoint(double localX, double width) {
    if (widget.values.isEmpty) return;
    const leftPad = _AreaChartPainter.leftPad;
    final chartWidth = width - leftPad;
    final index = widget.values.length == 1
        ? 0
        : (((localX - leftPad) / chartWidth) * (widget.values.length - 1))
              .round()
              .clamp(0, widget.values.length - 1);
    if (index != _selectedIndex) setState(() => _selectedIndex = index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) =>
            _selectPoint(details.localPosition.dx, constraints.maxWidth),
        onHorizontalDragStart: (details) =>
            _selectPoint(details.localPosition.dx, constraints.maxWidth),
        onHorizontalDragUpdate: (details) =>
            _selectPoint(details.localPosition.dx, constraints.maxWidth),
        child: AnimatedBuilder(
          animation: _animation,
          builder: (_, __) => CustomPaint(
            painter: _AreaChartPainter(
              values: widget.values,
              maxY: widget.maxY,
              color: widget.color,
              labels: widget.labels,
              progress: _animation.value,
              selectedIndex: _selectedIndex,
            ),
            size: Size.infinite,
          ),
        ),
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
  final int? selectedIndex;

  static const double labelHeight = 22;
  static const double leftPad = 36;

  _AreaChartPainter({
    required this.values,
    required this.maxY,
    required this.color,
    required this.labels,
    required this.progress,
    required this.selectedIndex,
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
      canvas.drawLine(Offset(leftPad, y), Offset(size.width, y), gridPaint);
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
      final x = n == 1 ? leftPad + chartW / 2 : leftPad + chartW * i / (n - 1);
      final y = chartH * (1 - (values[i] / maxY).clamp(0.0, 1.0));
      return Offset(x, y);
    });

    if (pts.length == 1) {
      canvas.drawCircle(pts.first, 6, Paint()..color = color);
    } else {
      final linePath = _smoothPath(pts);
      final pathMetrics = linePath.computeMetrics().toList();
      if (pathMetrics.isEmpty) return;
      final animatedLine = pathMetrics.first.extractPath(
        0,
        pathMetrics.first.length * progress,
      );

      final fillPath = Path.from(animatedLine)
        ..lineTo(pts.last.dx, chartH)
        ..lineTo(leftPad, chartH)
        ..close();
      canvas.drawPath(
        fillPath,
        Paint()
          ..shader = ui.Gradient.linear(Offset.zero, Offset(0, chartH), [
            color.withValues(alpha: 0.28),
            color.withValues(alpha: 0.0),
          ])
          ..style = PaintingStyle.fill,
      );

      canvas.drawPath(
        animatedLine,
        Paint()
          ..color = color
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // X-axis labels — skip empty strings (used for month view non-Monday points)
    if (labels.length == n) {
      final labelStyle = TextStyle(fontSize: 10, color: Colors.grey.shade500);
      for (int i = 0; i < n; i++) {
        if (labels[i].isEmpty) continue;
        final tp = TextPainter(
          text: TextSpan(text: labels[i], style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(pts[i].dx - tp.width / 2, chartH + 6));
      }
    }

    final selected = selectedIndex;
    if (selected != null && selected >= 0 && selected < pts.length) {
      _drawSelection(canvas, size, chartH, pts[selected], selected);
    }
  }

  void _drawSelection(
    Canvas canvas,
    Size size,
    double chartH,
    Offset point,
    int index,
  ) {
    canvas.drawLine(
      Offset(point.dx, 0),
      Offset(point.dx, chartH),
      Paint()
        ..color = color.withValues(alpha: 0.35)
        ..strokeWidth = 1,
    );
    canvas.drawCircle(point, 7, Paint()..color = Colors.white);
    canvas.drawCircle(point, 4.5, Paint()..color = color);

    final value = values[index];
    final valueText = value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toStringAsFixed(1);
    final label = labels.length == values.length && labels[index].isNotEmpty
        ? labels[index]
        : 'Day ${index + 1}';
    final painter = TextPainter(
      text: TextSpan(
        text: '$label: $valueText',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    const horizontalPadding = 9.0;
    const tooltipHeight = 26.0;
    final tooltipWidth = painter.width + horizontalPadding * 2;
    final left = (point.dx - tooltipWidth / 2).clamp(
      leftPad,
      size.width - tooltipWidth,
    );
    final top = (point.dy - 34).clamp(2.0, chartH - tooltipHeight);
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, tooltipWidth, tooltipHeight),
      const Radius.circular(6),
    );
    canvas.drawRRect(rect, Paint()..color = const Color(0xEB1C1C1E));
    painter.paint(
      canvas,
      Offset(
        left + horizontalPadding,
        top + (tooltipHeight - painter.height) / 2,
      ),
    );
  }

  Path _smoothPath(List<Offset> pts) {
    if (pts.length == 1) {
      return Path()..moveTo(pts[0].dx, pts[0].dy);
    }
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (int i = 0; i < pts.length - 1; i++) {
      final cp1 = Offset((pts[i].dx + pts[i + 1].dx) / 2, pts[i].dy);
      final cp2 = Offset((pts[i].dx + pts[i + 1].dx) / 2, pts[i + 1].dy);
      path.cubicTo(
        cp1.dx,
        cp1.dy,
        cp2.dx,
        cp2.dy,
        pts[i + 1].dx,
        pts[i + 1].dy,
      );
    }
    return path;
  }

  @override
  bool shouldRepaint(_AreaChartPainter old) =>
      old.progress != progress ||
      old.selectedIndex != selectedIndex ||
      !listEquals(old.values, values) ||
      !listEquals(old.labels, labels);
}
