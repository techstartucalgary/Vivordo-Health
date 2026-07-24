import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'profile_screen.dart';
import 'package:vivordo_health/src/services/metrics_service.dart';
import 'package:vivordo_health/src/services/stress_score_service.dart';
import 'package:vivordo_health/src/services/calendar_service.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;
import 'package:vivordo_health/src/services/outlook_calendar_service.dart';
import 'package:vivordo_health/src/services/notification_service.dart';

class HomeScreen extends StatefulWidget {
  final VoidCallback? onScanTap;
  const HomeScreen({super.key, this.onScanTap});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _currentMood = 'Good';
  // _messageCopied removed — smart message card replaced with calendar

  // Single stream for today's unified metrics doc
  late Stream<DocumentSnapshot<Map<String, dynamic>>> _todayStream;
  late Stream<QuerySnapshot<Map<String, dynamic>>> _latestScanStream;
  late Stream<QuerySnapshot<Map<String, dynamic>>> _goalsStreamCached;
  Future<List<gcal.Event>>? _reachableWindowEventsFuture;
  DateTime? _reachableWindowEventsDate;
  Future<_ScheduleInsight?>? _scheduleInsightFuture;
  DateTime? _scheduleInsightDate;
  final GlobalKey<_WeeklyCalendarState> _calendarKey =
      GlobalKey<_WeeklyCalendarState>();

  static const Color bgColor = Color(0xFFF2F2F7);
  static const Color cardWhite = Colors.white;
  static const Color accentPurple = Color(0xFF7B6EF6);
  static const Color textDark = Color(0xFF1C1C1E);
  static const Color textGrey = Color(0xFF8E8E93);
  static const Color greenColor = Color(0xFF34C759);
  static const Color orangeColor = Color(0xFFFF9500);

  @override
  void initState() {
    super.initState();
    // Fire-and-forget: compute BaaS stress score on every home screen load
    StressScoreService.computeAndSave().catchError((_) {});
    // Fire-and-forget: send any complete, mood-labelled days to the BaaS
    // validation/learning loop. No-op when nothing is pending, so it is safe
    // on every load. This is where yesterday's check-in actually gets
    // submitted — by now its day is closed and its metrics are complete.
    StressScoreService.submitPendingFeedback().catchError((_) {});
    final today = _todayPeriod();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    _todayStream = uid != null
        ? FirebaseFirestore.instance
              .collection('users')
              .doc(uid)
              .collection('metrics_daily')
              .doc(today)
              .snapshots()
        : const Stream.empty();
    _latestScanStream = uid != null
        ? FirebaseFirestore.instance
              .collection('users')
              .doc(uid)
              .collection('metrics_daily')
              .snapshots()
        : const Stream.empty();
    _goalsStreamCached = _goalsStream();
  }

  String _getGreeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  String _getFirstName() {
    final user = FirebaseAuth.instance.currentUser;
    final displayName = user?.displayName ?? 'Alex';
    return displayName.split(' ').first;
  }

  Color _getStressColor(double score) {
    if (score < 30) return greenColor;
    if (score < 60) return const Color(0xFFFFCC00);
    return const Color(0xFFFF3B30);
  }

  String _getStressLabel(double score) {
    if (score < 30) return 'Very Low Stress';
    if (score < 60) return "Low Stress — You're in good shape";
    if (score < 80) return 'Moderate Stress';
    return 'High Stress';
  }

  String _todayPeriod() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  int? _latestBpmFrom(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    final sortedDocs = [...docs]..sort((a, b) => b.id.compareTo(a.id));

    for (final doc in sortedDocs) {
      final data = doc.data();
      final savedScan = data['heart_rate_scan'] as Map?;
      if (savedScan != null) {
        final rawEntries = savedScan['entries'];
        if (rawEntries is List && rawEntries.isNotEmpty) {
          Map? latestEntry;
          DateTime? latestTime;
          for (final entry in rawEntries) {
            if (entry is! Map || entry['bpm'] is! num) continue;
            final timestamp = entry['timestamp'];
            final entryTime = timestamp is Timestamp
                ? timestamp.toDate()
                : null;
            if (latestEntry == null ||
                (entryTime != null &&
                    (latestTime == null || entryTime.isAfter(latestTime)))) {
              latestEntry = entry;
              latestTime = entryTime;
            }
          }
          final bpm = latestEntry?['bpm'];
          if (bpm is num) return bpm.round();
        }

        // Records created before scan history was added only have avg.
        final legacyBpm = savedScan['avg'];
        if (legacyBpm is num) return legacyBpm.round();
      }

      final heartRate = data['heart_rate'] as Map?;
      if (heartRate?['source'] == 'camera_ppg' && heartRate?['avg'] is num) {
        return (heartRate!['avg'] as num).round();
      }
    }
    return null;
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _goalsStream() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const Stream.empty();
    return FirebaseFirestore.instance
        .collection('goals')
        .where('userId', isEqualTo: user.uid)
        .where('status', isEqualTo: 'active')
        .limit(1)
        .snapshots();
  }

  @override
  Widget build(BuildContext context) {
    if (FirebaseAuth.instance.currentUser == null) {
      return _buildScaffold(
        stressScore: null,
        stressLoading: false,
        sleepVal: '--',
        sleepLoading: false,
        stepsVal: '--',
        stepsLoading: false,
        hrVal: '--',
        hrLoading: false,
        moodVal: '--',
        moodLoading: false,
        wellnessVal: '--',
        goalTitle: 'No goal set',
        goalProgress: 0,
      );
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _todayStream,
      builder: (context, todaySnap) {
        final bool loading =
            !todaySnap.hasData &&
            todaySnap.connectionState == ConnectionState.waiting;
        final data = todaySnap.data?.data();

        final stressMap = data?['stress'] as Map?;
        final hrvMap = data?['hrv'] as Map?;
        final sleepMap = data?['sleep'] as Map?;
        final stepsMap = data?['steps'] as Map?;
        final moodMap = data?['mood'] as Map?;
        final wellnessMap = data?['wellness'] as Map?;

        // Stress: prefer BaaS result, fall back to HRV-derived score
        final double? stressScore =
            (stressMap?['avg'] as num?)?.toDouble() ??
            (hrvMap?['stressScore'] as num?)?.toDouble();

        final sleepVal = sleepMap != null
            ? '${(sleepMap['avg'] as num?)?.toStringAsFixed(1) ?? '--'}h'
            : '--';

        final steps = (stepsMap?['sum'] as num?)?.toInt();
        final stepsVal = steps != null
            ? (steps >= 1000
                  ? '${(steps / 1000).toStringAsFixed(1)}k'
                  : steps.toString())
            : '--';

        if (moodMap != null && _currentMood == 'Good') {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted)
              setState(
                () => _currentMood = moodMap['label'] as String? ?? 'Good',
              );
          });
        }
        final moodVal = moodMap != null
            ? (moodMap['label'] as String? ?? '--')
            : '--';

        final wellnessVal = wellnessMap != null
            ? '${(wellnessMap['avg'] as num?)?.round() ?? '--'}'
            : '--';

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _latestScanStream,
          builder: (context, scanSnap) {
            final latestScanBpm = _latestBpmFrom(scanSnap.data?.docs ?? []);
            final hrVal = latestScanBpm == null ? '--' : '$latestScanBpm bpm';

            return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _goalsStreamCached,
              builder: (context, goalSnap) {
                final goalDocs = goalSnap.data?.docs ?? [];
                final goalData = goalDocs.isNotEmpty
                    ? goalDocs.first.data()
                    : null;
                final goalTitle =
                    goalData?['title'] as String? ?? 'No active goal';
                final rawPercent =
                    (goalData?['progress']?['completionPercent'] as num?)
                        ?.toDouble() ??
                    0;
                final goalProgress = (rawPercent / 100).clamp(0.0, 1.0);

                return _buildScaffold(
                  stressScore: stressScore,
                  stressLoading: loading,
                  sleepVal: sleepVal,
                  sleepLoading: loading,
                  stepsVal: stepsVal,
                  stepsLoading: loading,
                  hrVal: hrVal,
                  hrLoading:
                      scanSnap.connectionState == ConnectionState.waiting &&
                      !scanSnap.hasData,
                  moodVal: moodVal,
                  moodLoading: loading,
                  wellnessVal: wellnessVal,
                  goalTitle: goalTitle,
                  goalProgress: goalProgress,
                );
              },
            );
          },
        );
      },
    );
  }

  Future<List<gcal.Event>> _loadReachableWindowEvents(
    DateTime todayStart,
  ) async {
    try {
      final events = await CalendarService.getWeekEvents(
        todayStart,
      ).timeout(const Duration(seconds: 15), onTimeout: () => <gcal.Event>[]);
      final signedIn = await CalendarService.isSignedIn();
      if (!signedIn) {
        await NotificationService().cancelCalendarCheckIn();
        return [];
      }

      await _scheduleFinalEventCheckIn(events, todayStart);
      return events;
    } catch (e) {
      debugPrint('Reachable windows calendar load failed: $e');
      return [];
    }
  }

  Future<void> _scheduleFinalEventCheckIn(
    List<gcal.Event> events,
    DateTime todayStart,
  ) async {
    final tomorrow = todayStart.add(const Duration(days: 1));
    final eventEnds =
        events
            .where((event) => event.status != 'cancelled')
            .map((event) => event.end?.dateTime?.toLocal())
            .whereType<DateTime>()
            .where((end) => !end.isBefore(todayStart) && end.isBefore(tomorrow))
            .toList()
          ..sort();

    if (eventEnds.isEmpty) {
      await NotificationService().cancelCalendarCheckIn();
      return;
    }

    await NotificationService().scheduleCalendarCheckIn(eventEnds.last);
  }

  Future<List<gcal.Event>> _getReachableWindowEventsFuture(
    DateTime todayStart,
  ) {
    final normalizedDate = DateTime(
      todayStart.year,
      todayStart.month,
      todayStart.day,
    );

    if (_reachableWindowEventsFuture != null &&
        _reachableWindowEventsDate != null &&
        _reachableWindowEventsDate!.year == normalizedDate.year &&
        _reachableWindowEventsDate!.month == normalizedDate.month &&
        _reachableWindowEventsDate!.day == normalizedDate.day) {
      return _reachableWindowEventsFuture!;
    }

    _reachableWindowEventsDate = normalizedDate;
    _reachableWindowEventsFuture = _loadReachableWindowEvents(normalizedDate);
    return _reachableWindowEventsFuture!;
  }

  Widget _buildScaffold({
    required double? stressScore,
    required bool stressLoading,
    required String sleepVal,
    required bool sleepLoading,
    required String stepsVal,
    required bool stepsLoading,
    required String hrVal,
    required bool hrLoading,
    required String moodVal,
    required bool moodLoading,
    required String wellnessVal,
    required String goalTitle,
    required double goalProgress,
  }) {
    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 24),
              _buildStressCard(stressScore, loading: stressLoading),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _buildMetricTile(
                      'Sleep',
                      sleepVal,
                      Icons.bedtime_rounded,
                      accentPurple,
                      loading: sleepLoading,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _buildMetricTile(
                      'Steps',
                      stepsVal,
                      Icons.directions_walk_rounded,
                      greenColor,
                      loading: stepsLoading,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _buildMetricTile(
                      'Heart Rate',
                      hrVal,
                      Icons.favorite_rounded,
                      const Color(0xFFFF3B30),
                      showConnectHint: false,
                      loading: hrLoading,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _buildMetricTile(
                      'Mood',
                      moodVal,
                      Icons.mood_rounded,
                      const Color(0xFFF97316),
                      loading: moodLoading,
                      emptyAction: _showMoodCheck,
                      emptyActionLabel: 'Check in →',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              _buildSectionTitle('QUICK ACTIONS'),
              const SizedBox(height: 12),
              _buildQuickActions(),
              const SizedBox(height: 28),
              _buildSectionTitle("TODAY'S INSIGHTS"),
              const SizedBox(height: 12),
              _buildScheduleInsightCard(),
              if (sleepVal != '--')
                _buildInsightCard(
                  icon: Icons.nightlight_round,
                  iconColor: accentPurple,
                  iconBg: const Color(0x1F7B6EF6),
                  title: _getSleepInsightTitle(sleepVal),
                  subtitle: _getSleepInsightSubtitle(sleepVal, hrVal),
                ),
              if (sleepVal != '--') const SizedBox(height: 10),
              if (hrVal != '--')
                _buildInsightCard(
                  icon: Icons.favorite_rounded,
                  iconColor: const Color(0xFFFF3B30),
                  iconBg: const Color(0x1FFF3B30),
                  title: _getHRVInsightTitle(hrVal),
                  subtitle: _getHRVInsightSubtitle(hrVal),
                ),
              if (sleepVal == '--' && hrVal == '--')
                _buildInsightCard(
                  icon: Icons.info_outline_rounded,
                  iconColor: textGrey,
                  iconBg: const Color(0x1F8E8E93),
                  title: 'No insights yet',
                  subtitle:
                      'Connect Apple Health or complete a scan to see your daily insights.',
                ),
              const SizedBox(height: 28),
              _buildSectionTitle('TODAY\'S REACHABLE WINDOWS'),
              const SizedBox(height: 12),
              _buildReachableWindows(),
              const SizedBox(height: 28),
              _buildSectionTitle('TODAY\'S SCHEDULE'),
              const SizedBox(height: 12),
              _buildCalendarCard(),
              const SizedBox(height: 160),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_getGreeting()},',
              style: const TextStyle(
                color: textGrey,
                fontSize: 15,
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  _getFirstName(),
                  style: const TextStyle(
                    color: textDark,
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(width: 6),
                const Text('👋', style: TextStyle(fontSize: 26)),
              ],
            ),
          ],
        ),
        GestureDetector(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
          child: Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: cardWhite,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 12,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            child: const Icon(Icons.person, color: accentPurple, size: 22),
          ),
        ),
      ],
    );
  }

  Widget _buildStressCard(double? stressScore, {bool loading = false}) {
    final statusColor = stressScore == null
        ? const Color(0xFF8E8E93)
        : _getStressColor(stressScore);
    final stressLabel = stressScore == null
        ? 'No data yet'
        : _getStressLabel(stressScore);
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: accentPurple,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: accentPurple.withOpacity(0.4),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Stack(
          children: [
            // Decorative circle top-right
            Positioned(
              top: -30,
              right: -30,
              child: Container(
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.08),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Positioned(
              top: 10,
              right: 10,
              child: Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.06),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            // Content
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Current Stress Level',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.75),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      loading
                          ? Container(
                              width: 80,
                              height: 56,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                            )
                          : TweenAnimationBuilder<double>(
                              tween: Tween(begin: 0, end: stressScore ?? 0),
                              duration: const Duration(milliseconds: 1200),
                              curve: Curves.easeOutCubic,
                              builder: (_, value, __) => Text(
                                stressScore == null
                                    ? '--'
                                    : value.toInt().toString(),
                                style: TextStyle(
                                  fontSize: stressScore == null ? 30 : 56,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                  height: 1.0,
                                  letterSpacing: -2,
                                ),
                              ),
                            ),
                      const Padding(
                        padding: EdgeInsets.only(left: 4),
                        child: Text(
                          '/100',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                            color: Colors.white60,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        stressLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: (stressScore ?? 0) / 100),
                      duration: const Duration(milliseconds: 1400),
                      curve: Curves.easeOutCubic,
                      builder: (_, value, __) => LinearProgressIndicator(
                        value: value,
                        minHeight: 6,
                        backgroundColor: Colors.white.withOpacity(0.2),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricTile(
    String label,
    String value,
    IconData icon,
    Color color, {
    bool showConnectHint = true,
    bool loading = false,
    VoidCallback? emptyAction,
    String emptyActionLabel = 'Connect Health →',
  }) {
    final bool isEmpty = value == '--';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      decoration: BoxDecoration(
        color: cardWhite,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0x0F000000),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(
            icon,
            color: isEmpty ? const Color(0xFFC7C7CC) : color,
            size: 20,
          ),
          const SizedBox(height: 6),
          loading
              ? Container(
                  width: 36,
                  height: 14,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE5E5EA),
                    borderRadius: BorderRadius.circular(4),
                  ),
                )
              : Text(
                  value,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: isEmpty ? const Color(0xFFC7C7CC) : textDark,
                  ),
                ),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 10, color: textGrey)),
          if (isEmpty && showConnectHint) ...[
            const SizedBox(height: 4),
            GestureDetector(
              onTap:
                  emptyAction ??
                  () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
              child: Text(
                emptyActionLabel,
                style: const TextStyle(fontSize: 10, color: textGrey),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: textGrey,
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.0,
      ),
    );
  }

  Widget _buildQuickActions() {
    return Row(
      children: [
        Expanded(
          child: _buildActionCard(
            icon: Icons.flash_on_rounded,
            iconColor: accentPurple,
            iconBg: Color(0x1F7B6EF6),
            title: 'Quick Scan',
            subtitle: '15-sec stress check',
            onTap: () => widget.onScanTap?.call(),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildActionCard(
            icon: Icons.edit_note_rounded,
            iconColor: greenColor,
            iconBg: Color(0x1F34C759),
            title: 'Check In',
            subtitle: 'Daily wellness log',
            onTap: _showMoodCheck,
          ),
        ),
      ],
    );
  }

  Widget _buildActionCard({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return _PressableActionCard(
      icon: icon,
      iconColor: iconColor,
      iconBg: iconBg,
      title: title,
      subtitle: subtitle,
      onTap: onTap,
    );
  }

  Widget _buildInsightCard({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String title,
    required String subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: cardWhite,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Color(0x0D000000),
            blurRadius: 15,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: textDark,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: textGrey,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScheduleInsightCard() {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);

    return FutureBuilder<_ScheduleInsight?>(
      future: _getScheduleInsightFuture(todayStart),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _buildInsightCard(
              icon: Icons.calendar_today_rounded,
              iconColor: const Color(0xFF007AFF),
              iconBg: const Color(0x1F007AFF),
              title: 'Reviewing your schedule',
              subtitle:
                  'Checking today’s calendar load for useful timing insights.',
            ),
          );
        }

        final insight = snapshot.data;
        if (insight == null) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _buildInsightCard(
            icon: insight.icon,
            iconColor: insight.color,
            iconBg: insight.color.withValues(alpha: 0.12),
            title: insight.title,
            subtitle: insight.subtitle,
          ),
        );
      },
    );
  }

  Future<_ScheduleInsight?> _getScheduleInsightFuture(DateTime todayStart) {
    if (_scheduleInsightFuture != null &&
        _scheduleInsightDate != null &&
        _scheduleInsightDate!.year == todayStart.year &&
        _scheduleInsightDate!.month == todayStart.month &&
        _scheduleInsightDate!.day == todayStart.day) {
      return _scheduleInsightFuture!;
    }

    _scheduleInsightDate = todayStart;
    _scheduleInsightFuture = _loadScheduleInsight(todayStart);
    return _scheduleInsightFuture!;
  }

  Future<_ScheduleInsight?> _loadScheduleInsight(DateTime todayStart) async {
    final todayEnd = todayStart.add(const Duration(days: 1));
    final events = <_ScheduleEvent>[];

    bool googleSignedIn = false;
    bool outlookSignedIn = false;

    try {
      googleSignedIn = await CalendarService.isSignedIn().timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
    } catch (_) {
      googleSignedIn = false;
    }

    try {
      outlookSignedIn = await OutlookCalendarService.isSignedIn().timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
    } catch (_) {
      outlookSignedIn = false;
    }

    if (!googleSignedIn && !outlookSignedIn) return null;

    if (googleSignedIn) {
      try {
        final googleEvents = await _getReachableWindowEventsFuture(todayStart);
        events.addAll(
          googleEvents.where((event) => event.status != 'cancelled').map((
            event,
          ) {
            final start = event.start?.dateTime?.toLocal();
            final end = event.end?.dateTime?.toLocal();
            if (start == null || end == null) return null;
            return _ScheduleEvent(
              title: event.summary?.trim().isNotEmpty == true
                  ? event.summary!.trim()
                  : 'Calendar event',
              start: start,
              end: end,
            );
          }).whereType<_ScheduleEvent>(),
        );
      } catch (e) {
        debugPrint('Schedule insight Google load failed: $e');
      }
    }

    if (outlookSignedIn) {
      try {
        final outlookEvents =
            await OutlookCalendarService.getWeekEvents(todayStart).timeout(
              const Duration(seconds: 8),
              onTimeout: () => <OutlookEvent>[],
            );
        events.addAll(
          outlookEvents.map((event) {
            return _ScheduleEvent(
              title: event.subject.trim().isNotEmpty
                  ? event.subject.trim()
                  : 'Calendar event',
              start: event.start.toLocal(),
              end: event.end.toLocal(),
            );
          }),
        );
      } catch (e) {
        debugPrint('Schedule insight Outlook load failed: $e');
      }
    }

    final todayEvents = events.where((event) {
      return event.start.isBefore(todayEnd) && event.end.isAfter(todayStart);
    }).toList()..sort((a, b) => a.start.compareTo(b.start));

    return _buildScheduleInsight(todayEvents, todayStart);
  }

  _ScheduleInsight _buildScheduleInsight(
    List<_ScheduleEvent> events,
    DateTime todayStart,
  ) {
    if (events.isEmpty) {
      return const _ScheduleInsight(
        icon: Icons.event_available_rounded,
        color: greenColor,
        title: 'Light schedule today',
        subtitle:
            'No calendar events found today. This is a good window for focus, recovery, or goal progress.',
      );
    }

    final workStart = DateTime(
      todayStart.year,
      todayStart.month,
      todayStart.day,
      9,
    );
    final workEnd = DateTime(
      todayStart.year,
      todayStart.month,
      todayStart.day,
      17,
    );

    DateTime clampStart(DateTime value) =>
        value.isBefore(workStart) ? workStart : value;
    DateTime clampEnd(DateTime value) =>
        value.isAfter(workEnd) ? workEnd : value;

    int scheduledMinutes = 0;
    int afternoonEvents = 0;
    _ScheduleEvent? longestEvent;

    for (final event in events) {
      final clippedStart = clampStart(event.start);
      final clippedEnd = clampEnd(event.end);
      if (clippedEnd.isAfter(clippedStart)) {
        scheduledMinutes += clippedEnd.difference(clippedStart).inMinutes;
      }
      if (event.start.hour >= 12) afternoonEvents++;
      if (longestEvent == null || event.duration > longestEvent.duration) {
        longestEvent = event;
      }
    }

    var tightTransitions = 0;
    for (var i = 1; i < events.length; i++) {
      final gap = events[i].start.difference(events[i - 1].end).inMinutes;
      if (gap >= 0 && gap <= 15) tightTransitions++;
    }

    final scheduledLabel = _durationLabel(Duration(minutes: scheduledMinutes));
    final eventWord = events.length == 1 ? 'event' : 'events';

    if (tightTransitions >= 2) {
      return _ScheduleInsight(
        icon: Icons.event_busy_rounded,
        color: orangeColor,
        title: 'Back-to-back schedule block',
        subtitle:
            'You have ${events.length} $eventWord with tight transitions. Protect a short reset before the busiest block.',
      );
    }

    if (scheduledMinutes >= 240 || events.length >= 5) {
      return _ScheduleInsight(
        icon: Icons.calendar_month_rounded,
        color: orangeColor,
        title: 'Heavy day ahead',
        subtitle:
            '$scheduledLabel is scheduled between 9 AM and 5 PM. Keep one recovery window open if you can.',
      );
    }

    if (afternoonEvents >= 3) {
      return _ScheduleInsight(
        icon: Icons.wb_sunny_rounded,
        color: const Color(0xFFFF9500),
        title: 'Busy afternoon ahead',
        subtitle:
            'Most of today’s calendar load is later in the day. Use the morning for focused or important work.',
      );
    }

    final longest = longestEvent;
    if (longest != null && longest.duration.inMinutes >= 90) {
      return _ScheduleInsight(
        icon: Icons.timelapse_rounded,
        color: const Color(0xFF007AFF),
        title: 'Long calendar block today',
        subtitle:
            '${longest.title} runs ${_durationLabel(longest.duration)}. Plan a quick decompression break afterward.',
      );
    }

    return _ScheduleInsight(
      icon: Icons.event_note_rounded,
      color: const Color(0xFF007AFF),
      title: 'Balanced schedule today',
      subtitle:
          'You have ${events.length} $eventWord today. Your calendar load looks manageable if you keep small buffers between tasks.',
    );
  }

  String _durationLabel(Duration duration) {
    final minutes = duration.inMinutes;
    if (minutes >= 60) {
      final hours = minutes ~/ 60;
      final remainder = minutes % 60;
      return remainder == 0 ? '${hours}h' : '${hours}h ${remainder}m';
    }
    return '${minutes}m';
  }

  Widget _buildReachableWindows() {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);

    return FutureBuilder<List<gcal.Event>>(
      future: _getReachableWindowEventsFuture(todayStart),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: cardWhite,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFFE5E5EA)),
            ),
            child: const Row(
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: accentPurple,
                  ),
                ),
                SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'Analyzing your calendar for cognitive load windows…',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: textDark,
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        final events =
            (snapshot.data ?? const <gcal.Event>[]).where((event) {
              final start = event.start?.dateTime?.toLocal();
              return start != null &&
                  start.year == now.year &&
                  start.month == now.month &&
                  start.day == now.day;
            }).toList()..sort((a, b) {
              final aStart = a.start?.dateTime?.toLocal() ?? todayStart;
              final bStart = b.start?.dateTime?.toLocal() ?? todayStart;
              return aStart.compareTo(bStart);
            });

        final workStart = DateTime(now.year, now.month, now.day, 9);
        final workEnd = DateTime(now.year, now.month, now.day, 17);

        DateTime clampStart(DateTime value) =>
            value.isBefore(workStart) ? workStart : value;
        DateTime clampEnd(DateTime value) =>
            value.isAfter(workEnd) ? workEnd : value;

        String formatTime(DateTime value) {
          final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
          final minute = value.minute.toString().padLeft(2, '0');
          final suffix = value.hour >= 12 ? 'PM' : 'AM';
          return '$hour:$minute $suffix';
        }

        String formatRange(DateTime start, DateTime end) =>
            '${formatTime(start)} - ${formatTime(end)}';

        String durationLabel(Duration duration) {
          final minutes = duration.inMinutes;
          if (minutes >= 60) {
            final hours = minutes ~/ 60;
            final remainder = minutes % 60;
            return remainder == 0 ? '${hours}h' : '${hours}h ${remainder}m';
          }
          return '${minutes}m';
        }

        final highLoadWindows =
            events
                .map((event) {
                  final start = event.start?.dateTime?.toLocal();
                  final end = event.end?.dateTime?.toLocal();
                  if (start == null || end == null) return null;

                  final clippedStart = clampStart(start);
                  final clippedEnd = clampEnd(end);
                  if (!clippedEnd.isAfter(clippedStart)) return null;

                  return {
                    'time': formatRange(clippedStart, clippedEnd),
                    'label': event.summary?.trim().isNotEmpty == true
                        ? event.summary!.trim()
                        : 'Calendar event',
                    'duration': clippedEnd.difference(clippedStart),
                    'event': event,
                  };
                })
                .whereType<Map<String, dynamic>>()
                .toList()
              ..sort(
                (a, b) => (b['duration'] as Duration).compareTo(
                  a['duration'] as Duration,
                ),
              );

        final lowLoadWindows = <Map<String, dynamic>>[];
        var cursor = workStart;

        for (final event in events) {
          final start = event.start?.dateTime?.toLocal();
          final end = event.end?.dateTime?.toLocal();
          if (start == null || end == null) continue;

          final clippedStart = clampStart(start);
          final clippedEnd = clampEnd(end);

          if (clippedStart.isAfter(cursor)) {
            final gap = clippedStart.difference(cursor);
            if (gap.inMinutes >= 30) {
              lowLoadWindows.add({
                'time': formatRange(cursor, clippedStart),
                'label': '${durationLabel(gap)} open',
                'duration': gap,
                'start': cursor,
                'end': clippedStart,
              });
            }
          }

          if (clippedEnd.isAfter(cursor)) {
            cursor = clippedEnd;
          }
        }

        if (cursor.isBefore(workEnd)) {
          final gap = workEnd.difference(cursor);
          if (gap.inMinutes >= 30) {
            lowLoadWindows.add({
              'time': formatRange(cursor, workEnd),
              'label': '${durationLabel(gap)} open',
              'duration': gap,
              'start': cursor,
              'end': workEnd,
            });
          }
        }

        highLoadWindows.sort(
          (a, b) =>
              (b['duration'] as Duration).compareTo(a['duration'] as Duration),
        );
        lowLoadWindows.sort(
          (a, b) =>
              (b['duration'] as Duration).compareTo(a['duration'] as Duration),
        );

        return Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: cardWhite,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFFE5E5EA)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0A000000),
                blurRadius: 10,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCognitiveLoadSection(
                title: 'Here are your times of high cognitive load',
                icon: Icons.psychology_alt_rounded,
                color: orangeColor,
                emptyText: 'No busy calendar blocks found today.',
                windows: highLoadWindows.take(2).toList(),
              ),
              const SizedBox(height: 18),
              _buildCognitiveLoadSection(
                title: 'Here are your times with the lowest cognitive load',
                icon: Icons.self_improvement_rounded,
                color: greenColor,
                emptyText: 'No open 30+ minute windows found today.',
                windows: lowLoadWindows.take(2).toList(),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCognitiveLoadSection({
    required String title,
    required IconData icon,
    required Color color,
    required String emptyText,
    required List<Map<String, dynamic>> windows,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: textDark,
                  height: 1.25,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (windows.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF7F7FA),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              emptyText,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: textGrey,
              ),
            ),
          )
        else
          ...windows.map((window) {
            final event = window['event'] as gcal.Event?;
            final openStart = window['start'] as DateTime?;
            final openEnd = window['end'] as DateTime?;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: const Color(0xFFF7F7FA),
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: event == null
                      ? openStart == null || openEnd == null
                            ? null
                            : () => _calendarKey.currentState?.showCreateEvent(
                                openStart,
                                openEnd,
                              )
                      : () =>
                            _calendarKey.currentState?.showEventDetails(event),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                window['time'] as String,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: textDark,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                window['label'] as String,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: textGrey,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (event != null ||
                            (openStart != null && openEnd != null))
                          Icon(
                            Icons.chevron_right_rounded,
                            color: color,
                            size: 20,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
      ],
    );
  }

  String _getSleepInsightTitle(String sleepVal) {
    final hours = double.tryParse(sleepVal.replaceAll('h', '')) ?? 0;
    if (hours >= 8) return 'Excellent sleep last night';
    if (hours >= 7) return 'Good sleep last night';
    if (hours >= 6) return 'Moderate sleep last night';
    return 'Low sleep last night';
  }

  String _getSleepInsightSubtitle(String sleepVal, String hrVal) {
    return '$sleepVal of sleep recorded';
  }

  String _getHRVInsightTitle(String hrVal) {
    final bpm = int.tryParse(hrVal.replaceAll(' bpm', '')) ?? 0;
    if (bpm < 60) return 'Resting heart rate looks calm';
    if (bpm < 80) return 'Heart rate in normal range';
    if (bpm < 100) return 'Heart rate slightly elevated';
    return 'Heart rate elevated today';
  }

  String _getHRVInsightSubtitle(String hrVal) {
    final bpm = int.tryParse(hrVal.replaceAll(' bpm', '')) ?? 0;
    if (bpm < 60)
      return 'Your heart rate of $hrVal suggests good recovery today.';
    if (bpm < 80) return 'Your heart rate of $hrVal is within a healthy range.';
    if (bpm < 100)
      return 'Your heart rate of $hrVal is a bit higher than usual. Consider a rest day.';
    return 'Your heart rate of $hrVal is elevated. Try some breathing exercises.';
  }

  Widget _buildCalendarCard() {
    return _WeeklyCalendar(key: _calendarKey);
  }

  String _formatCalendarDate(DateTime dt) {
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${days[dt.weekday - 1]}, ${months[dt.month - 1]} ${dt.day}';
  }

  String _formatHour(int hour) {
    if (hour == 12) return '12 PM';
    if (hour > 12) return '${hour - 12} PM';
    return '$hour AM';
  }

  List<Map<String, dynamic>> _getTodayEvents(DateTime now) {
    // Seed events based on day of week so they feel consistent
    final day = now.weekday;
    final events = <Map<String, dynamic>>[];

    // Monday
    if (day == 1) {
      events.addAll([
        {
          'hour': 9,
          'title': 'Team Standup',
          'subtitle': '15 min · Google Meet',
          'color': accentPurple,
          'icon': Icons.groups_rounded,
        },
        {
          'hour': 11,
          'title': 'Product Review',
          'subtitle': '1 hr · Conference Room A',
          'color': const Color(0xFF007AFF),
          'icon': Icons.slideshow_rounded,
        },
        {
          'hour': 13,
          'title': 'Lunch with Sarah',
          'subtitle': 'The Kitchen, Floor 2',
          'color': greenColor,
          'icon': Icons.restaurant_rounded,
        },
        {
          'hour': 15,
          'title': 'Sprint Planning',
          'subtitle': '2 hrs · Zoom',
          'color': const Color(0xFFFF9500),
          'icon': Icons.task_rounded,
        },
      ]);
    }
    // Tuesday
    else if (day == 2) {
      events.addAll([
        {
          'hour': 9,
          'title': '1:1 with Manager',
          'subtitle': '30 min · Office',
          'color': accentPurple,
          'icon': Icons.person_rounded,
        },
        {
          'hour': 10,
          'title': 'Design Review',
          'subtitle': '1 hr · Figma call',
          'color': const Color(0xFFFF3B30),
          'icon': Icons.design_services_rounded,
        },
        {
          'hour': 14,
          'title': 'Client Call — Acme',
          'subtitle': '45 min · Zoom',
          'color': const Color(0xFF007AFF),
          'icon': Icons.business_rounded,
        },
        {
          'hour': 16,
          'title': 'Focus Time',
          'subtitle': 'Blocked — deep work',
          'color': greenColor,
          'icon': Icons.do_not_disturb_on_rounded,
        },
      ]);
    }
    // Wednesday
    else if (day == 3) {
      events.addAll([
        {
          'hour': 9,
          'title': 'All Hands Meeting',
          'subtitle': '1 hr · Main Hall',
          'color': const Color(0xFFFF9500),
          'icon': Icons.groups_rounded,
        },
        {
          'hour': 11,
          'title': '🎂 Alex\'s Birthday',
          'subtitle': 'Team celebration at 3PM',
          'color': const Color(0xFFFF3B30),
          'icon': Icons.cake_rounded,
        },
        {
          'hour': 13,
          'title': 'Lunch & Learn',
          'subtitle': 'AI in Healthcare — Cafeteria',
          'color': accentPurple,
          'icon': Icons.school_rounded,
        },
        {
          'hour': 15,
          'title': 'Code Review',
          'subtitle': '1 hr · PR #142',
          'color': greenColor,
          'icon': Icons.code_rounded,
        },
      ]);
    }
    // Thursday
    else if (day == 4) {
      events.addAll([
        {
          'hour': 9,
          'title': 'Team Standup',
          'subtitle': '15 min · Google Meet',
          'color': accentPurple,
          'icon': Icons.groups_rounded,
        },
        {
          'hour': 10,
          'title': 'Investor Update',
          'subtitle': '1 hr · Board Room',
          'color': const Color(0xFF007AFF),
          'icon': Icons.trending_up_rounded,
        },
        {
          'hour': 12,
          'title': 'Working Lunch',
          'subtitle': 'Q3 roadmap discussion',
          'color': greenColor,
          'icon': Icons.restaurant_rounded,
        },
        {
          'hour': 14,
          'title': 'User Research',
          'subtitle': '2 hrs · User interviews',
          'color': const Color(0xFFFF9500),
          'icon': Icons.people_rounded,
        },
        {
          'hour': 16,
          'title': 'Retrospective',
          'subtitle': '1 hr · Zoom',
          'color': const Color(0xFFFF3B30),
          'icon': Icons.refresh_rounded,
        },
      ]);
    }
    // Friday
    else if (day == 5) {
      events.addAll([
        {
          'hour': 9,
          'title': 'Team Standup',
          'subtitle': '15 min · Google Meet',
          'color': accentPurple,
          'icon': Icons.groups_rounded,
        },
        {
          'hour': 11,
          'title': 'Demo Day',
          'subtitle': '2 hrs · All teams',
          'color': const Color(0xFFFF9500),
          'icon': Icons.slideshow_rounded,
        },
        {
          'hour': 14,
          'title': 'Friday Wind Down',
          'subtitle': 'Optional — team social',
          'color': greenColor,
          'icon': Icons.celebration_rounded,
        },
      ]);
    }
    // Weekend
    else {
      events.addAll([
        {
          'hour': 10,
          'title': 'Morning Run',
          'subtitle': '5km · Riverside Trail',
          'color': greenColor,
          'icon': Icons.directions_run_rounded,
        },
        {
          'hour': 12,
          'title': 'Brunch with Family',
          'subtitle': 'Home',
          'color': const Color(0xFFFF9500),
          'icon': Icons.home_rounded,
        },
        {
          'hour': 15,
          'title': 'Personal Project',
          'subtitle': 'Focus time',
          'color': accentPurple,
          'icon': Icons.lightbulb_rounded,
        },
      ]);
    }

    return events;
  }

  void _showMoodCheck() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(40),
              topRight: Radius.circular(40),
            ),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: accentPurple.withOpacity(0.25),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: accentPurple.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.mood_rounded,
                    color: accentPurple,
                    size: 28,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  "How are you feeling?",
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF2D3142),
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  "Don't think too much, just tap.",
                  style: TextStyle(color: Color(0xFF8E8E93), fontSize: 14),
                ),
                const SizedBox(height: 32),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _moodOption(
                        'Great',
                        '🤩',
                        const Color(0xFFFFEDD5),
                        const Color(0xFFF97316),
                      ),
                      _moodOption(
                        'Good',
                        '😊',
                        const Color(0xFFDCFCE7),
                        const Color(0xFF22C55E),
                      ),
                      _moodOption(
                        'Okay',
                        '😐',
                        const Color(0xFFF3F4F6),
                        const Color(0xFF6B7280),
                      ),
                      _moodOption(
                        'Down',
                        '😔',
                        const Color(0xFFEDE9FE),
                        accentPurple,
                      ),
                      _moodOption(
                        'Awful',
                        '😫',
                        const Color(0xFFFEE2E2),
                        const Color(0xFFEF4444),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    'Your mood shapes your daily insights',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: accentPurple.withOpacity(0.7),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 28),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _moodOption(
    String label,
    String emoji,
    Color bgColor,
    Color accentColor,
  ) {
    bool isSelected = _currentMood == label;
    return GestureDetector(
      onTap: () async {
        setState(() => _currentMood = label);
        Navigator.pop(context);
        try {
          await MetricsService.saveMoodCheckIn(label);
        } catch (e) {
          debugPrint('Mood save failed: $e');
        }
      },
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: isSelected ? accentColor : bgColor,
              shape: BoxShape.circle,
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: accentColor.withOpacity(0.4),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : [],
            ),
            child: Center(
              child: Text(emoji, style: const TextStyle(fontSize: 28)),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            label,
            style: TextStyle(
              color: isSelected
                  ? const Color(0xFF2D3142)
                  : const Color(0xFF9CA3AF),
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScheduleEvent {
  const _ScheduleEvent({
    required this.title,
    required this.start,
    required this.end,
  });

  final String title;
  final DateTime start;
  final DateTime end;

  Duration get duration => end.difference(start);
}

class _ScheduleInsight {
  const _ScheduleInsight({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
}

class _WeeklyCalendar extends StatefulWidget {
  const _WeeklyCalendar({super.key});
  @override
  State<_WeeklyCalendar> createState() => _WeeklyCalendarState();
}

class _WeeklyCalendarState extends State<_WeeklyCalendar> {
  int _weekOffset = 0;
  final ScrollController _scrollController = ScrollController();
  List<gcal.Event> _googleEvents = [];
  List<OutlookEvent> _outlookEvents = [];
  bool _isGoogleConnected = false;
  bool _isOutlookConnected = false;
  bool _isLoading = false;
  DateTime? _lastGoogleCalendarAttempt;
  DateTime? _lastGoogleCalendarFailure;
  int? _lastGoogleCalendarWeekOffset;
  bool get _hasConnectedCalendar => _isGoogleConnected || _isOutlookConnected;

  static const double _cellH = 52;
  static const double _timeColW = 52;
  static const Color _accentPurple = Color(0xFF7B6EF6);
  static const Color _textDark = Color(0xFF1C1C1E);
  static const Color _textGrey = Color(0xFF8E8E93);
  static const Color _border = Color(0xFFE5E5EA);

  static const _days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  static const _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  static const _hours = [
    0,
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    15,
    16,
    17,
    18,
    19,
    20,
    21,
    22,
    23,
  ];

  @override
  void initState() {
    super.initState();
    CalendarService.connectionNotifier.addListener(
      _handleGoogleCalendarConnectionChange,
    );
    _loadExistingGoogleCalendar();
    _loadExistingOutlookCalendar();
  }

  void _scrollToFirstTodayEvent() {
    if (_weekOffset != 0) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;

      final now = DateTime.now();
      final starts =
          <DateTime>[
              ..._googleEvents
                  .map((event) => event.start?.dateTime?.toLocal())
                  .whereType<DateTime>(),
              ..._outlookEvents.map((event) => event.start.toLocal()),
            ].where((start) {
              return start.year == now.year &&
                  start.month == now.month &&
                  start.day == now.day;
            }).toList()
            ..sort();

      final firstStart = starts.isEmpty ? now : starts.first;
      final eventHour = firstStart.hour + (firstStart.minute / 60);
      final scrollTo = (eventHour * _cellH) - _cellH;
      _scrollController.animateTo(
        scrollTo.clamp(0.0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _loadExistingGoogleCalendar({bool force = false}) async {
    if (_isLoading) return;

    final now = DateTime.now();

    if (!force &&
        _lastGoogleCalendarAttempt != null &&
        _lastGoogleCalendarWeekOffset == _weekOffset &&
        now.difference(_lastGoogleCalendarAttempt!) <
            const Duration(seconds: 30)) {
      debugPrint('Google Calendar load skipped: cooldown active');
      return;
    }

    if (!force &&
        _lastGoogleCalendarFailure != null &&
        now.difference(_lastGoogleCalendarFailure!) <
            const Duration(minutes: 2)) {
      debugPrint(
        'Google Calendar load skipped: recent failure cooldown active',
      );
      return;
    }

    _lastGoogleCalendarAttempt = now;
    _lastGoogleCalendarWeekOffset = _weekOffset;

    setState(() => _isLoading = true);
    try {
      final signedIn = await CalendarService.isSignedIn().timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
      if (!signedIn) {
        if (!mounted) return;
        setState(() {
          _isGoogleConnected = false;
          _isLoading = false;
        });
        return;
      }

      final dates = _getWeekDates();
      final weekStart = dates.first;
      final events = await CalendarService.getWeekEvents(
        weekStart,
      ).timeout(const Duration(seconds: 8), onTimeout: () => <gcal.Event>[]);

      if (!mounted) return;
      setState(() {
        _googleEvents = events;
        _isGoogleConnected = CalendarService.connectionNotifier.value;
        _isLoading = false;
      });
      _scrollToFirstTodayEvent();
    } catch (e) {
      debugPrint('Calendar silent load error: $e');
      _lastGoogleCalendarFailure = DateTime.now();
      if (!mounted) return;
      setState(() {
        _isGoogleConnected = false;
        _isLoading = false;
      });
    }
  }

  Future<void> _loadExistingOutlookCalendar() async {
    try {
      final signedIn = await OutlookCalendarService.isSignedIn().timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );

      if (!signedIn) {
        if (!mounted) return;
        setState(() {
          _outlookEvents = [];
          _isOutlookConnected = false;
        });
        return;
      }

      final dates = _getWeekDates();
      final weekStart = dates.first;
      final events = await OutlookCalendarService.getWeekEvents(
        weekStart,
      ).timeout(const Duration(seconds: 8), onTimeout: () => <OutlookEvent>[]);

      if (!mounted) return;
      setState(() {
        _outlookEvents = events;
        _isOutlookConnected = true;
      });
      _scrollToFirstTodayEvent();
    } catch (e) {
      debugPrint('Existing Outlook calendar load failed: $e');
      if (!mounted) return;
      setState(() {
        _outlookEvents = [];
        _isOutlookConnected = false;
      });
    }
  }

  @override
  void dispose() {
    CalendarService.connectionNotifier.removeListener(
      _handleGoogleCalendarConnectionChange,
    );
    _scrollController.dispose();
    super.dispose();
  }

  void _handleGoogleCalendarConnectionChange() {
    if (!mounted) return;
    if (CalendarService.connectionNotifier.value) {
      _lastGoogleCalendarAttempt = null;
      _lastGoogleCalendarFailure = null;
      _lastGoogleCalendarWeekOffset = null;
      if (!_isLoading) {
        _loadExistingGoogleCalendar(force: true);
      }
      return;
    }
    setState(() {
      _googleEvents = [];
      _isGoogleConnected = false;
      _isLoading = false;
      _lastGoogleCalendarAttempt = null;
      _lastGoogleCalendarFailure = null;
      _lastGoogleCalendarWeekOffset = null;
    });
  }

  Future<void> _connectGoogle() async {
    setState(() => _isLoading = true);
    try {
      final dates = _getWeekDates();
      final weekStart = dates.first;
      _lastGoogleCalendarAttempt = null;
      _lastGoogleCalendarFailure = null;
      _lastGoogleCalendarWeekOffset = null;

      final events = await CalendarService.connectAndGetWeekEvents(weekStart);
      if (!mounted) return;
      setState(() {
        _googleEvents = events;
        _isGoogleConnected = true;
      });
      _scrollToFirstTodayEvent();
    } catch (e) {
      debugPrint('Calendar error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _connectOutlook() async {
    setState(() => _isLoading = true);
    try {
      final dates = _getWeekDates();
      final weekStart = dates.first;
      final events = await OutlookCalendarService.connectAndGetWeekEvents(
        weekStart,
      );
      if (!mounted) return;
      setState(() {
        _outlookEvents = events;
        _isOutlookConnected = true;
      });
      _scrollToFirstTodayEvent();
    } catch (e) {
      debugPrint('Outlook calendar connect error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<DateTime> _getWeekDates() {
    final now = DateTime.now();
    final monday = now
        .subtract(Duration(days: now.weekday - 1))
        .add(Duration(days: _weekOffset * 7));
    return List.generate(
      7,
      (i) => DateTime(monday.year, monday.month, monday.day + i),
    );
  }

  String _fmt12(int h) {
    if (h == 0) return '12 AM';
    if (h == 12) return '12 PM';
    if (h > 12) return '${h - 12} PM';
    return '$h AM';
  }

  String _monthLabel(List<DateTime> dates) {
    final start = dates.first;
    final end = dates.last;
    if (start.month == end.month) {
      return '${_months[start.month - 1]} ${start.year}';
    }
    return '${_months[start.month - 1]} – ${_months[end.month - 1]} ${start.year}';
  }

  String _formatEventDateTime(DateTime? dateTime) {
    if (dateTime == null) return 'Unknown time';
    final local = dateTime.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final suffix = local.hour >= 12 ? 'PM' : 'AM';
    return '${_days[local.weekday % 7]}, ${_months[local.month - 1]} ${local.day} at $hour:$minute $suffix';
  }

  String _formatEventTimeRange(gcal.Event event) {
    final start = event.start?.dateTime?.toLocal();
    final end = event.end?.dateTime?.toLocal();
    if (start == null) return 'Unknown time';

    final startHour = start.hour % 12 == 0 ? 12 : start.hour % 12;
    final startMinute = start.minute.toString().padLeft(2, '0');
    final startSuffix = start.hour >= 12 ? 'PM' : 'AM';

    if (end == null) {
      return '${_formatEventDateTime(start)}';
    }

    final endHour = end.hour % 12 == 0 ? 12 : end.hour % 12;
    final endMinute = end.minute.toString().padLeft(2, '0');
    final endSuffix = end.hour >= 12 ? 'PM' : 'AM';

    return '${_days[start.weekday % 7]}, ${_months[start.month - 1]} ${start.day}, '
        '$startHour:$startMinute $startSuffix – $endHour:$endMinute $endSuffix';
  }

  DateTime _withTime(DateTime date, TimeOfDay time) =>
      DateTime(date.year, date.month, date.day, time.hour, time.minute);

  String _eventRecurrence(gcal.Event event) {
    final rule = event.recurrence?.join(' ').toUpperCase() ?? '';
    if (rule.contains('FREQ=DAILY')) return 'daily';
    if (rule.contains('FREQ=MONTHLY')) return 'monthly';
    if (rule.contains('FREQ=WEEKLY') || event.recurringEventId != null) {
      return 'weekly';
    }
    return 'none';
  }

  void showCreateEvent(DateTime initialStart, DateTime initialEnd) {
    _createEvent(initialStart, initialEnd: initialEnd);
  }

  Future<void> _createEvent(
    DateTime initialStart, {
    DateTime? initialEnd,
  }) async {
    final draft = await showDialog<_CalendarEventDraft>(
      context: context,
      builder: (_) => _CreateCalendarEventDialog(
        initialStart: initialStart,
        initialEnd: initialEnd,
      ),
    );
    if (!context.mounted || draft == null) return;

    final start = _withTime(draft.date, draft.startTime);
    var end = _withTime(draft.date, draft.endTime);
    if (!end.isAfter(start)) end = end.add(const Duration(days: 1));
    setState(() => _isLoading = true);
    try {
      await CalendarService.createEvent(
        title: draft.title,
        start: start,
        end: end,
        recurrence: draft.recurrence,
      );
      if (!context.mounted) return;
      setState(() => _isLoading = false);
      await _loadExistingGoogleCalendar(force: true);
      if (!context.mounted) return;
      _showCalendarMessage('Event created.');
    } catch (e) {
      _showCalendarMessage('Could not create event: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _editEvent(gcal.Event event) async {
    final originalStart = event.start?.dateTime?.toLocal();
    final originalEnd = event.end?.dateTime?.toLocal();
    if (originalStart == null || originalEnd == null) {
      _showCalendarMessage('All-day events cannot be edited here yet.');
      return;
    }

    var date = DateTime(
      originalStart.year,
      originalStart.month,
      originalStart.day,
    );
    var startTime = TimeOfDay.fromDateTime(originalStart);
    var endTime = TimeOfDay.fromDateTime(originalEnd);
    var recurrence = _eventRecurrence(event);

    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          title: const Text('Edit event'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.calendar_today_rounded),
                title: const Text('Date'),
                subtitle: Text(
                  '${_months[date.month - 1]} ${date.day}, ${date.year}',
                ),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: date,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) setDialogState(() => date = picked);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule_rounded),
                title: const Text('Start time'),
                trailing: Text(startTime.format(context)),
                onTap: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: startTime,
                  );
                  if (picked != null) setDialogState(() => startTime = picked);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule_outlined),
                title: const Text('End time'),
                trailing: Text(endTime.format(context)),
                onTap: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: endTime,
                  );
                  if (picked != null) setDialogState(() => endTime = picked);
                },
              ),
              DropdownButtonFormField<String>(
                initialValue: recurrence,
                decoration: const InputDecoration(
                  labelText: 'Repeats',
                  prefixIcon: Icon(Icons.repeat_rounded),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'none',
                    child: Text('Does not repeat'),
                  ),
                  DropdownMenuItem(value: 'daily', child: Text('Daily')),
                  DropdownMenuItem(value: 'weekly', child: Text('Weekly')),
                  DropdownMenuItem(value: 'monthly', child: Text('Monthly')),
                ],
                onChanged: (value) {
                  if (value != null) setDialogState(() => recurrence = value);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (shouldSave != true || !mounted) return;

    final start = _withTime(date, startTime);
    var end = _withTime(date, endTime);
    if (!end.isAfter(start)) end = end.add(const Duration(days: 1));
    setState(() => _isLoading = true);
    try {
      await CalendarService.updateEventTimeAndRecurrence(
        event,
        start: start,
        end: end,
        recurrence: recurrence,
      );
      if (mounted) setState(() => _isLoading = false);
      await _loadExistingGoogleCalendar(force: true);
      _showCalendarMessage('Event updated.');
    } catch (e) {
      _showCalendarMessage('Could not update event: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _removeEvent(gcal.Event event) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove event?'),
        content: Text(
          'This will remove “${event.summary ?? 'Untitled event'}” from Google Calendar.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _isLoading = true);
    try {
      await CalendarService.deleteEvent(event);
      if (mounted) setState(() => _isLoading = false);
      await _loadExistingGoogleCalendar(force: true);
      _showCalendarMessage('Event removed.');
    } catch (e) {
      _showCalendarMessage('Could not remove event: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showCalendarMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openMaps(String location) async {
    final googleWebUri = Uri.https('www.google.com', '/maps/search/', {
      'api': '1',
      'query': location,
    });

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      final googleAppUri = Uri.parse(
        'comgooglemaps://?q=${Uri.encodeQueryComponent(location)}',
      );
      if (await canLaunchUrl(googleAppUri)) {
        await launchUrl(googleAppUri, mode: LaunchMode.externalApplication);
        return;
      }

      final appleMapsUri = Uri.https('maps.apple.com', '/', {'q': location});
      if (await launchUrl(
        appleMapsUri,
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } else if (await launchUrl(
      googleWebUri,
      mode: LaunchMode.externalApplication,
    )) {
      return;
    }

    _showCalendarMessage('Could not open a maps app.');
  }

  void showEventDetails(gcal.Event event) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        final title = event.summary ?? 'Untitled event';
        final location = event.location;
        final description = event.description;
        final attendees = event.attendees ?? const <gcal.EventAttendee>[];

        return Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            boxShadow: const [
              BoxShadow(
                color: Color(0x26000000),
                blurRadius: 24,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE5E5EA),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F0FE),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(
                          Icons.event_rounded,
                          color: Color(0xFF1A73E8),
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                color: _textDark,
                                height: 1.2,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _formatEventTimeRange(event),
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: _textGrey,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (location != null && location.trim().isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _EventDetailRow(
                      icon: Icons.place_rounded,
                      label: 'Location',
                      value: location,
                      onTap: () => _openMaps(location),
                    ),
                  ],
                  if (description != null && description.trim().isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _EventDetailRow(
                      icon: Icons.notes_rounded,
                      label: 'Description',
                      value: description,
                      maxValueHeight: 140,
                    ),
                  ],
                  if (attendees.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _EventDetailRow(
                      icon: Icons.people_rounded,
                      label: 'Attendees',
                      value: attendees
                          .map(
                            (attendee) =>
                                attendee.displayName ??
                                attendee.email ??
                                'Guest',
                          )
                          .take(6)
                          .join(', '),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(context);
                            _removeEvent(event);
                          },
                          icon: const Icon(Icons.delete_outline_rounded),
                          label: const Text('Remove'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            Navigator.pop(context);
                            _editEvent(event);
                          },
                          icon: const Icon(Icons.edit_rounded),
                          label: const Text('Edit'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _accentPurple,
                            foregroundColor: Colors.white,
                            elevation: 0,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final dates = _getWeekDates();
    final now = DateTime.now();

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: const Color(0x0F000000),
            blurRadius: 15,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: _border, width: 0.5)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.calendar_today_rounded,
                        size: 16,
                        color: _accentPurple,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _monthLabel(dates),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _textDark,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(width: 8),
                        if (!_isGoogleConnected)
                          GestureDetector(
                            onTap: _isLoading ? null : _connectGoogle,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1a73e8),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: _isLoading
                                  ? const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text(
                                      'Connect Google',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                            ),
                          ),
                        if (!_isOutlookConnected) ...[
                          const SizedBox(width: 4),
                          GestureDetector(
                            onTap: _isLoading ? null : _connectOutlook,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0078D4),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: _isLoading
                                  ? const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text(
                                      'Connect Outlook',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                        const SizedBox(width: 4),
                        _navBtn(Icons.chevron_left_rounded, () {
                          setState(() => _weekOffset--);
                          if (_isGoogleConnected) _loadExistingGoogleCalendar();
                          if (_isOutlookConnected)
                            _loadExistingOutlookCalendar();
                        }),
                        const SizedBox(width: 4),
                        GestureDetector(
                          onTap: () => setState(() => _weekOffset = 0),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(color: _border),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              'Today',
                              style: TextStyle(fontSize: 12, color: _textDark),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        _navBtn(Icons.chevron_right_rounded, () {
                          setState(() => _weekOffset++);
                          if (_isGoogleConnected) _loadExistingGoogleCalendar();
                          if (_isOutlookConnected)
                            _loadExistingOutlookCalendar();
                        }),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Day headers
            Row(
              children: [
                SizedBox(width: _timeColW),
                ...dates.map((d) {
                  final isToday =
                      _weekOffset == 0 &&
                      d.day == now.day &&
                      d.month == now.month &&
                      d.year == now.year;
                  return Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: const BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: _border, width: 0.5),
                          right: BorderSide(color: _border, width: 0.5),
                        ),
                      ),
                      child: Column(
                        children: [
                          Text(
                            _days[d.weekday % 7],
                            style: const TextStyle(
                              fontSize: 10,
                              color: _textGrey,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: isToday
                                  ? const Color(0xFF1a73e8)
                                  : Colors.transparent,
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Text(
                                '${d.day}',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                  color: isToday ? Colors.white : _textDark,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),

            // Body
            if (!_hasConnectedCalendar)
              Container(
                height: 220,
                alignment: Alignment.center,
                child: SingleChildScrollView(
                  physics: const NeverScrollableScrollPhysics(),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.calendar_month_rounded,
                        size: 48,
                        color: Color(0xFFE5E5EA),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'No calendar connected',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: _textDark,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Connect Google or Outlook above\nto see your events here.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: _textGrey,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 20),
                      GestureDetector(
                        onTap: _isLoading ? null : _connectGoogle,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1a73e8),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: _isLoading
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.calendar_month_rounded,
                                      size: 14,
                                      color: Colors.white,
                                    ),
                                    SizedBox(width: 6),
                                    Text(
                                      'Connect Google Calendar',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      GestureDetector(
                        onTap: _isLoading ? null : _connectOutlook,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0078D4),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: _isLoading
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.calendar_month_rounded,
                                      size: 14,
                                      color: Colors.white,
                                    ),
                                    SizedBox(width: 6),
                                    Text(
                                      'Connect Outlook Calendar',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              SizedBox(
                height: 400,
                child: SingleChildScrollView(
                  controller: _scrollController,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Time column
                      SizedBox(
                        width: _timeColW,
                        child: Column(
                          children: _hours
                              .map(
                                (h) => SizedBox(
                                  height: _cellH,
                                  child: Align(
                                    alignment: Alignment.topRight,
                                    child: Padding(
                                      padding: const EdgeInsets.only(
                                        right: 8,
                                        top: 4,
                                      ),
                                      child: Text(
                                        _fmt12(h),
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: _textGrey,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ),

                      // Day columns
                      ...dates.map((d) {
                        final dow = d.weekday % 7;
                        final isToday =
                            _weekOffset == 0 &&
                            d.day == now.day &&
                            d.month == now.month &&
                            d.year == now.year;
                        const dayEvents = <_CalEvent>[];
                        final googleDayEvents = _isGoogleConnected
                            ? _googleEvents.where((e) {
                                final start = e.start?.dateTime?.toLocal();
                                return start != null &&
                                    start.day == d.day &&
                                    start.month == d.month;
                              }).toList()
                            : <gcal.Event>[];
                        final outlookDayEvents = _isOutlookConnected
                            ? _outlookEvents.where((e) {
                                final start = e.start.toLocal();
                                return start.day == d.day &&
                                    start.month == d.month &&
                                    start.year == d.year;
                              }).toList()
                            : <OutlookEvent>[];

                        return Expanded(
                          child: Container(
                            decoration: const BoxDecoration(
                              border: Border(
                                right: BorderSide(color: _border, width: 0.5),
                              ),
                            ),
                            child: Stack(
                              children: [
                                // Hour cells
                                Column(
                                  children: _hours
                                      .map(
                                        (h) => InkWell(
                                          onTap: _isGoogleConnected
                                              ? () => _createEvent(
                                                  DateTime(
                                                    d.year,
                                                    d.month,
                                                    d.day,
                                                    h,
                                                  ),
                                                )
                                              : null,
                                          child: Container(
                                            height: _cellH,
                                            decoration: const BoxDecoration(
                                              border: Border(
                                                bottom: BorderSide(
                                                  color: _border,
                                                  width: 0.5,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      )
                                      .toList(),
                                ),

                                // Google Calendar events
                                ...googleDayEvents.map((ev) {
                                  final start = ev.start?.dateTime?.toLocal();
                                  final end = ev.end?.dateTime?.toLocal();
                                  if (start == null)
                                    return const SizedBox.shrink();
                                  final startH =
                                      start.hour + start.minute / 60.0;
                                  final endH = end != null
                                      ? end.hour + end.minute / 60.0
                                      : startH + 1;
                                  final top = startH * _cellH;
                                  final height = ((endH - startH) * _cellH - 2)
                                      .clamp(18.0, double.infinity);
                                  return Positioned(
                                    top: top,
                                    left: 2,
                                    right: 2,
                                    height: height,
                                    child: Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(4),
                                        onTap: () => showEventDetails(ev),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 5,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFe8f0fe),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                            border: const Border(
                                              left: BorderSide(
                                                color: Color(0xFF1a73e8),
                                                width: 3,
                                              ),
                                            ),
                                          ),
                                          child: Text(
                                            ev.summary ?? 'Event',
                                            style: const TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFF1557b0),
                                            ),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                }),
                                // Outlook Calendar events
                                ...outlookDayEvents.map((ev) {
                                  final start = ev.start.toLocal();
                                  final end = ev.end.toLocal();
                                  final startH =
                                      start.hour + start.minute / 60.0;
                                  final endH = end.hour + end.minute / 60.0;
                                  final top = startH * _cellH;
                                  final height = ((endH - startH) * _cellH - 2)
                                      .clamp(18.0, double.infinity);
                                  return Positioned(
                                    top: top,
                                    left: 4,
                                    right: 0,
                                    height: height,
                                    child: Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(4),
                                        onTap: () {},
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 5,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFE6F2FB),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                            border: const Border(
                                              left: BorderSide(
                                                color: Color(0xFF0078D4),
                                                width: 3,
                                              ),
                                            ),
                                          ),
                                          child: Text(
                                            ev.subject,
                                            style: const TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFF005A9E),
                                            ),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                }),

                                // Now line
                                if (isToday)
                                  Positioned(
                                    top: (now.hour + now.minute / 60) * _cellH,
                                    left: 0,
                                    right: 0,
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 8,
                                          height: 8,
                                          decoration: const BoxDecoration(
                                            color: Color(0xFFea4335),
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        Expanded(
                                          child: Container(
                                            height: 2,
                                            color: const Color(0xFFea4335),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _navBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          border: Border.all(color: _border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 15, color: _textDark),
      ),
    );
  }
}

class _CalendarEventDraft {
  const _CalendarEventDraft({
    required this.title,
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.recurrence,
  });

  final String title;
  final DateTime date;
  final TimeOfDay startTime;
  final TimeOfDay endTime;
  final String recurrence;
}

class _CreateCalendarEventDialog extends StatefulWidget {
  const _CreateCalendarEventDialog({
    required this.initialStart,
    this.initialEnd,
  });

  final DateTime initialStart;
  final DateTime? initialEnd;

  @override
  State<_CreateCalendarEventDialog> createState() =>
      _CreateCalendarEventDialogState();
}

class _CreateCalendarEventDialogState
    extends State<_CreateCalendarEventDialog> {
  late final TextEditingController _titleController;
  late DateTime _date;
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;
  String _recurrence = 'none';
  String? _titleError;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _date = DateUtils.dateOnly(widget.initialStart);
    _startTime = TimeOfDay.fromDateTime(widget.initialStart);
    _endTime = TimeOfDay.fromDateTime(
      widget.initialEnd ?? widget.initialStart.add(const Duration(hours: 1)),
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (!context.mounted || picked == null) return;
    setState(() => _date = picked);
  }

  Future<void> _pickStartTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _startTime,
    );
    if (!context.mounted || picked == null) return;
    setState(() => _startTime = picked);
  }

  Future<void> _pickEndTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _endTime,
    );
    if (!context.mounted || picked == null) return;
    setState(() => _endTime = picked);
  }

  void _submit() {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _titleError = 'Enter an event title');
      return;
    }
    Navigator.pop(
      context,
      _CalendarEventDraft(
        title: title,
        date: _date,
        startTime: _startTime,
        endTime: _endTime,
        recurrence: _recurrence,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      title: const Text('Create event'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleController,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Event title',
                prefixIcon: const Icon(Icons.event_rounded),
                errorText: _titleError,
              ),
              onChanged: (_) {
                if (_titleError != null) setState(() => _titleError = null);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.calendar_today_rounded),
              title: const Text('Date'),
              subtitle: Text(
                MaterialLocalizations.of(context).formatFullDate(_date),
              ),
              onTap: _pickDate,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule_rounded),
              title: const Text('Start time'),
              trailing: Text(_startTime.format(context)),
              onTap: _pickStartTime,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule_outlined),
              title: const Text('End time'),
              trailing: Text(_endTime.format(context)),
              onTap: _pickEndTime,
            ),
            DropdownButtonFormField<String>(
              initialValue: _recurrence,
              decoration: const InputDecoration(
                labelText: 'Repeats',
                prefixIcon: Icon(Icons.repeat_rounded),
              ),
              items: const [
                DropdownMenuItem(value: 'none', child: Text('Does not repeat')),
                DropdownMenuItem(value: 'daily', child: Text('Daily')),
                DropdownMenuItem(value: 'weekly', child: Text('Weekly')),
                DropdownMenuItem(value: 'monthly', child: Text('Monthly')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _recurrence = value);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}

class _CalEvent {
  final int dow;
  final int h;
  final int m;
  final double dur;
  final String title;
  final String sub;
  final Color color;
  final Color bg;
  const _CalEvent({
    required this.dow,
    required this.h,
    required this.m,
    required this.dur,
    required this.title,
    required this.sub,
    required this.color,
    required this.bg,
  });
}

class _EventDetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final double? maxValueHeight;
  final VoidCallback? onTap;

  const _EventDetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.maxValueHeight,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: onTap == null ? 0 : 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: const Color(0xFF8E8E93)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF8E8E93),
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: maxValueHeight ?? double.infinity,
                      ),
                      child: SingleChildScrollView(
                        physics: maxValueHeight == null
                            ? const NeverScrollableScrollPhysics()
                            : const BouncingScrollPhysics(),
                        child: Text(
                          value,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF1C1C1E),
                            height: 1.35,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 8),
                const Icon(
                  Icons.open_in_new_rounded,
                  size: 16,
                  color: Color(0xFF1A73E8),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PressableActionCard extends StatefulWidget {
  final IconData icon;
  final Color iconColor;
  final Color iconBg;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _PressableActionCard({
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  State<_PressableActionCard> createState() => _PressableActionCardState();
}

class _PressableActionCardState extends State<_PressableActionCard> {
  static const _minimumPressedDuration = Duration(milliseconds: 140);

  bool _isPressed = false;
  DateTime? _pressedAt;
  Timer? _releaseTimer;

  void _setPressed(bool value) {
    if (_isPressed == value) return;
    setState(() => _isPressed = value);
  }

  void _handleTapDown(TapDownDetails details) {
    _releaseTimer?.cancel();
    _pressedAt = DateTime.now();
    _setPressed(true);
  }

  void _handleTapUp(TapUpDetails details) {
    final pressedAt = _pressedAt;
    final elapsed = pressedAt == null
        ? Duration.zero
        : DateTime.now().difference(pressedAt);
    final remaining = _minimumPressedDuration - elapsed;

    if (remaining <= Duration.zero) {
      _setPressed(false);
      return;
    }

    _releaseTimer = Timer(remaining, () {
      if (mounted) {
        _setPressed(false);
      }
    });
  }

  void _handleTapCancel() {
    _releaseTimer?.cancel();
    _setPressed(false);
  }

  @override
  void dispose() {
    _releaseTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _handleTapDown,
        onTapUp: _handleTapUp,
        onTapCancel: _handleTapCancel,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _isPressed ? 0.98 : 1,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _isPressed
                  ? const Color(0xFFE5E5EA)
                  : const Color(0xFFFFFFFF),
              borderRadius: BorderRadius.circular(20),
              boxShadow: _isPressed
                  ? const []
                  : const [
                      BoxShadow(
                        color: Color(0x0F000000),
                        blurRadius: 15,
                        offset: Offset(0, 4),
                      ),
                    ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: widget.iconBg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(widget.icon, color: widget.iconColor, size: 22),
                ),
                const SizedBox(height: 14),
                Text(
                  widget.title,
                  style: const TextStyle(
                    color: Color(0xFF1C1C1E),
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  widget.subtitle,
                  style: const TextStyle(
                    color: Color(0xFF8E8E93),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
