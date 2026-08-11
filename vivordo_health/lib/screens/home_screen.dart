import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'profile_screen.dart';
import 'package:vivordo_health/src/services/metrics_service.dart';
import 'panda_screen.dart';
import 'package:vivordo_health/src/services/calendar_service.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;

class HomeScreen extends StatefulWidget {
  final VoidCallback? onScanTap;
  const HomeScreen({super.key, this.onScanTap});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _currentMood = 'Good';
  // _messageCopied removed — smart message card replaced with calendar

  // Cached streams — created once in initState to avoid duplicate Firestore listeners
  late Stream<double?> _stressStream;
  late Stream<DocumentSnapshot<Map<String, dynamic>>> _sleepStream;
  late Stream<DocumentSnapshot<Map<String, dynamic>>> _stepsStream;
  late Stream<DocumentSnapshot<Map<String, dynamic>>> _hrStream;
  late Stream<DocumentSnapshot<Map<String, dynamic>>> _moodStream;
  late Stream<DocumentSnapshot<Map<String, dynamic>>> _wellnessStream;
  late Stream<QuerySnapshot<Map<String, dynamic>>> _goalsStreamCached;

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
    _stressStream = _stressScoreStream();
    final today = _todayPeriod();
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid;
    _sleepStream = uid != null
        ? FirebaseFirestore.instance.collection('metrics_daily').doc('${uid}_sleep_$today').snapshots()
        : const Stream.empty();
    _stepsStream = uid != null
        ? FirebaseFirestore.instance.collection('metrics_daily').doc('${uid}_steps_$today').snapshots()
        : const Stream.empty();
    // NOTE: HR tile reads from metrics_daily/{uid}_heart_rate_today.
    // Scan results are saved to heart_rate_scans collection (not metrics_daily),
    // so a completed scan does NOT update this tile yet.
    // This will be fixed in VH-SCAN-3 when scan results are written to metrics_daily.
    _hrStream = uid != null
        ? FirebaseFirestore.instance.collection('metrics_daily').doc('${uid}_heart_rate_$today').snapshots()
        : const Stream.empty();
    _moodStream = uid != null
        ? FirebaseFirestore.instance.collection('metrics_daily').doc('${uid}_mood_$today').snapshots()
        : const Stream.empty();
    _wellnessStream = uid != null
        ? FirebaseFirestore.instance.collection('metrics_daily').doc('${uid}_wellness_$today').snapshots()
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

  Stream<DocumentSnapshot<Map<String, dynamic>>> _todayMetric(String metricType) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const Stream.empty();
    final docId = '${user.uid}_${metricType}_${_todayPeriod()}';
    return FirebaseFirestore.instance.collection('metrics_daily').doc(docId).snapshots();
  }

  /// Reads stress score: prefers HRV-derived stress from HealthKit ('hrv' doc),
  /// falls back to manual 'stress' doc from seed data.
  Stream<double?> _stressScoreStream() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return Stream.value(null);
    final today = _todayPeriod();
    final uid = user.uid;

    // Try HRV doc first — if it has stressScore field, use it
    final hrvDoc = FirebaseFirestore.instance
        .collection('metrics_daily')
        .doc('${uid}_hrv_$today')
        .snapshots()
        .map((snap) => (snap.data()?['stressScore'] as num?)?.toDouble());

    // Combine: return HRV-based stress if available, else manual stress
    return hrvDoc.asyncMap((hrv) async {
      if (hrv != null) return hrv;
      final stressSnap = await FirebaseFirestore.instance
          .collection('metrics_daily')
          .doc('${uid}_stress_$today')
          .get();
      return (stressSnap.data()?['avg'] as num?)?.toDouble();
    });
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

  void _openPanda() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const PandaScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return _buildScaffold(stressScore: null, stressLoading: false, sleepVal: '--', sleepLoading: false, stepsVal: '--', stepsLoading: false, hrVal: '--', hrLoading: false, moodVal: '--', moodLoading: false, wellnessVal: '--', goalTitle: 'No goal set', goalProgress: 0);
    }

    return StreamBuilder<double?>(
      stream: _stressStream,
      builder: (context, stressSnap) {
        final bool stressLoading = !stressSnap.hasData && stressSnap.connectionState == ConnectionState.waiting;
        final double? stressScore = stressSnap.data;

        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _sleepStream,
          builder: (context, sleepSnap) {
            final sleepData = sleepSnap.data?.data();
            final sleepVal = sleepData != null
                ? '${(sleepData['avg'] as num?)?.toStringAsFixed(1) ?? '--'}h'
                : '--';
            final bool sleepLoading = !sleepSnap.hasData && sleepSnap.connectionState == ConnectionState.waiting;
            
            return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: _stepsStream,
              builder: (context, stepsSnap) {
                final stepsData = stepsSnap.data?.data();
                final steps = (stepsData?['sum'] as num?)?.toInt();
                final stepsVal = steps != null
                    ? (steps >= 1000 ? '${(steps / 1000).toStringAsFixed(1)}k' : steps.toString())
                    : '--';
                final bool stepsLoading = !stepsSnap.hasData && stepsSnap.connectionState == ConnectionState.waiting;

                return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: _hrStream,
                  builder: (context, hrSnap) {
                    final hrData = hrSnap.data?.data();
                    final hrVal = hrData != null
                        ? '${(hrData['avg'] as num?)?.round() ?? '--'} bpm'
                        : '--';
                    final bool hrLoading = !hrSnap.hasData && hrSnap.connectionState == ConnectionState.waiting;

                    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                      stream: _moodStream,
                      builder: (context, moodSnap) {
                        final moodData = moodSnap.data?.data();
                        if (moodData != null && _currentMood == '--') {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) setState(() => _currentMood = moodData['label'] as String? ?? '--');
                          });
                        }
                        final moodVal = moodData != null
                            ? (moodData['label'] as String? ?? '--')
                            : '--';
                        final bool moodLoading = !moodSnap.hasData && moodSnap.connectionState == ConnectionState.waiting;

                        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                          stream: _wellnessStream,
                          builder: (context, wellnessSnap) {
                            final wellnessData = wellnessSnap.data?.data();
                            final wellnessVal = wellnessData != null
                                ? '${(wellnessData['avg'] as num?)?.round() ?? '--'}'
                                : '--';

                        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                          stream: _goalsStreamCached,
                          builder: (context, goalSnap) {
                            final goalDocs = goalSnap.data?.docs ?? [];
                            final goalData = goalDocs.isNotEmpty ? goalDocs.first.data() : null;
                            final goalTitle = goalData?['title'] as String? ?? 'No active goal';
                            final rawPercent = (goalData?['progress']?['completionPercent'] as num?)?.toDouble() ?? 0;
                            final goalProgress = (rawPercent / 100).clamp(0.0, 1.0);

                            return _buildScaffold(
                              stressScore: stressScore,
                              stressLoading: stressLoading,
                              sleepVal: sleepVal,
                              sleepLoading: sleepLoading,
                              stepsVal: stepsVal,
                              stepsLoading: stepsLoading,
                              hrVal: hrVal,
                              hrLoading: hrLoading,
                              moodVal: moodVal,
                              moodLoading: moodLoading,
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
                  },
                );
              },
            );
          },
        );
      },
    );
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
                  Expanded(child: _buildMetricTile('Sleep', sleepVal, Icons.bedtime_rounded, accentPurple, loading: sleepLoading)),
                  const SizedBox(width: 10),
                  Expanded(child: _buildMetricTile('Steps', stepsVal, Icons.directions_walk_rounded, greenColor, loading: stepsLoading)),
                  const SizedBox(width: 10),
                  Expanded(child: _buildMetricTile('Heart Rate', hrVal, Icons.favorite_rounded, const Color(0xFFFF3B30), showConnectHint: false, loading: hrLoading)),
                  const SizedBox(width: 10),
                  Expanded(child: _buildMetricTile('Mood', moodVal, Icons.mood_rounded, const Color(0xFFF97316), loading: moodLoading)),
                ],
              ),
              const SizedBox(height: 28),
              _buildSectionTitle('QUICK ACTIONS'),
              const SizedBox(height: 12),
              _buildQuickActions(),
              const SizedBox(height: 28),
              _buildSectionTitle("TODAY'S INSIGHTS"),
              const SizedBox(height: 12),
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
                  subtitle: 'Connect Apple Health or complete a scan to see your daily insights.',
                ),
              const SizedBox(height: 28),
              _buildSectionTitle('REACHABLE WINDOWS'),
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
    final statusColor = stressScore == null ? const Color(0xFF8E8E93) : _getStressColor(stressScore);
    final stressLabel = stressScore == null ? 'No data yet' : _getStressLabel(stressScore);
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
                                stressScore == null ? '--' : value.toInt().toString(),
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
                        valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
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
  
  Widget _buildMetricTile(String label, String value, IconData icon, Color color, {bool showConnectHint = true, bool loading = false}) {
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
          Icon(icon, color: isEmpty ? const Color(0xFFC7C7CC) : color, size: 20),
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
          Text(
            label,
            style: const TextStyle(fontSize: 10, color: textGrey),
          ),
          if (isEmpty && showConnectHint) ...[
            const SizedBox(height: 4),
            GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ),
              child: const Text(
                'Connect Health →',
                style: TextStyle(fontSize: 10, color: textGrey),
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
            subtitle: '60-sec stress check',
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: cardWhite,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
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
                color: iconBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: iconColor, size: 22),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              style: const TextStyle(
                color: textDark,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              style: const TextStyle(
                color: textGrey,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
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

  Widget _buildReachableWindows() {
    final windows = [
      {'time': '12:30 - 1:00 PM', 'label': 'Low stress', 'color': greenColor},
      {'time': '6:00 - 7:30 PM', 'label': 'Post-workout calm', 'color': accentPurple},
      {'time': '9:30 - 10:30 PM', 'label': 'Moderate - winding down', 'color': orangeColor},
    ];

    return Column(
      children: windows.map((w) {
        final color = w['color'] as Color;
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            color: cardWhite,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Color(0x0A000000),
                blurRadius: 10,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  w['time'] as String,
                  style: const TextStyle(
                    color: textDark,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  w['label'] as String,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
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
    if (bpm < 60) return 'Your heart rate of $hrVal suggests good recovery today.';
    if (bpm < 80) return 'Your heart rate of $hrVal is within a healthy range.';
    if (bpm < 100) return 'Your heart rate of $hrVal is a bit higher than usual. Consider a rest day.';
    return 'Your heart rate of $hrVal is elevated. Try some breathing exercises.';
  }
  

Widget _buildCalendarCard() {
    return const _WeeklyCalendar();
  }

  String _formatCalendarDate(DateTime dt) {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
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
        {'hour': 9,  'title': 'Team Standup',        'subtitle': '15 min · Google Meet',     'color': accentPurple,              'icon': Icons.groups_rounded},
        {'hour': 11, 'title': 'Product Review',       'subtitle': '1 hr · Conference Room A', 'color': const Color(0xFF007AFF),   'icon': Icons.slideshow_rounded},
        {'hour': 13, 'title': 'Lunch with Sarah',     'subtitle': 'The Kitchen, Floor 2',     'color': greenColor,                'icon': Icons.restaurant_rounded},
        {'hour': 15, 'title': 'Sprint Planning',      'subtitle': '2 hrs · Zoom',             'color': const Color(0xFFFF9500),   'icon': Icons.task_rounded},
      ]);
    }
    // Tuesday
    else if (day == 2) {
      events.addAll([
        {'hour': 9,  'title': '1:1 with Manager',     'subtitle': '30 min · Office',          'color': accentPurple,              'icon': Icons.person_rounded},
        {'hour': 10, 'title': 'Design Review',         'subtitle': '1 hr · Figma call',        'color': const Color(0xFFFF3B30),   'icon': Icons.design_services_rounded},
        {'hour': 14, 'title': 'Client Call — Acme',   'subtitle': '45 min · Zoom',            'color': const Color(0xFF007AFF),   'icon': Icons.business_rounded},
        {'hour': 16, 'title': 'Focus Time',            'subtitle': 'Blocked — deep work',      'color': greenColor,                'icon': Icons.do_not_disturb_on_rounded},
      ]);
    }
    // Wednesday
    else if (day == 3) {
      events.addAll([
        {'hour': 9,  'title': 'All Hands Meeting',    'subtitle': '1 hr · Main Hall',         'color': const Color(0xFFFF9500),   'icon': Icons.groups_rounded},
        {'hour': 11, 'title': '🎂 Alex\'s Birthday',  'subtitle': 'Team celebration at 3PM',  'color': const Color(0xFFFF3B30),   'icon': Icons.cake_rounded},
        {'hour': 13, 'title': 'Lunch & Learn',        'subtitle': 'AI in Healthcare — Cafeteria', 'color': accentPurple,          'icon': Icons.school_rounded},
        {'hour': 15, 'title': 'Code Review',          'subtitle': '1 hr · PR #142',           'color': greenColor,                'icon': Icons.code_rounded},
      ]);
    }
    // Thursday
    else if (day == 4) {
      events.addAll([
        {'hour': 9,  'title': 'Team Standup',         'subtitle': '15 min · Google Meet',     'color': accentPurple,              'icon': Icons.groups_rounded},
        {'hour': 10, 'title': 'Investor Update',      'subtitle': '1 hr · Board Room',        'color': const Color(0xFF007AFF),   'icon': Icons.trending_up_rounded},
        {'hour': 12, 'title': 'Working Lunch',        'subtitle': 'Q3 roadmap discussion',    'color': greenColor,                'icon': Icons.restaurant_rounded},
        {'hour': 14, 'title': 'User Research',        'subtitle': '2 hrs · User interviews',  'color': const Color(0xFFFF9500),   'icon': Icons.people_rounded},
        {'hour': 16, 'title': 'Retrospective',        'subtitle': '1 hr · Zoom',              'color': const Color(0xFFFF3B30),   'icon': Icons.refresh_rounded},
      ]);
    }
    // Friday
    else if (day == 5) {
      events.addAll([
        {'hour': 9,  'title': 'Team Standup',         'subtitle': '15 min · Google Meet',     'color': accentPurple,              'icon': Icons.groups_rounded},
        {'hour': 11, 'title': 'Demo Day',             'subtitle': '2 hrs · All teams',        'color': const Color(0xFFFF9500),   'icon': Icons.slideshow_rounded},
        {'hour': 14, 'title': 'Friday Wind Down',     'subtitle': 'Optional — team social',   'color': greenColor,                'icon': Icons.celebration_rounded},
      ]);
    }
    // Weekend
    else {
      events.addAll([
        {'hour': 10, 'title': 'Morning Run',          'subtitle': '5km · Riverside Trail',    'color': greenColor,                'icon': Icons.directions_run_rounded},
        {'hour': 12, 'title': 'Brunch with Family',   'subtitle': 'Home',                     'color': const Color(0xFFFF9500),   'icon': Icons.home_rounded},
        {'hour': 15, 'title': 'Personal Project',     'subtitle': 'Focus time',               'color': accentPurple,              'icon': Icons.lightbulb_rounded},
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
                child: const Icon(Icons.mood_rounded, color: accentPurple, size: 28),
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
                    _moodOption('Great', '🤩', const Color(0xFFFFEDD5), const Color(0xFFF97316)),
                    _moodOption('Good', '😊', const Color(0xFFDCFCE7), const Color(0xFF22C55E)),
                    _moodOption('Okay', '😐', const Color(0xFFF3F4F6), const Color(0xFF6B7280)),
                    _moodOption('Down', '😔', const Color(0xFFEDE9FE), accentPurple),
                    _moodOption('Awful', '😫', const Color(0xFFFEE2E2), const Color(0xFFEF4444)),
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
      String label, String emoji, Color bgColor, Color accentColor) {
    bool isSelected = _currentMood == label;
    return GestureDetector(
      onTap: () async {
        setState(() => _currentMood = label);
        Navigator.pop(context);
        try { await MetricsService.saveMoodCheckIn(label); } catch (e) { debugPrint('Mood save failed: $e'); }
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
                          offset: const Offset(0, 4))
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
              color: isSelected ? const Color(0xFF2D3142) : const Color(0xFF9CA3AF),
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _WeeklyCalendar extends StatefulWidget {
  const _WeeklyCalendar();
  @override
  State<_WeeklyCalendar> createState() => _WeeklyCalendarState();
}

class _WeeklyCalendarState extends State<_WeeklyCalendar> {
  int _weekOffset = 0;
  final ScrollController _scrollController = ScrollController();
  List<gcal.Event> _googleEvents = [];
  bool _isConnected = false;
  bool _isLoading = false;

  static const double _cellH = 52;
  static const double _timeColW = 52;
  static const Color _accentPurple = Color(0xFF7B6EF6);
  static const Color _textDark = Color(0xFF1C1C1E);
  static const Color _textGrey = Color(0xFF8E8E93);
  static const Color _border = Color(0xFFE5E5EA);

  static const _days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  static const _months = [
    'January','February','March','April','May','June',
    'July','August','September','October','November','December'
  ];
  static const _hours = [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23];

  

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final now = DateTime.now();
      final scrollTo = (now.hour * _cellH) - _cellH;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(
          scrollTo.clamp(0, _scrollController.position.maxScrollExtent),
        );
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _connectGoogle() async {
    setState(() => _isLoading = true);
    try {
      final dates = _getWeekDates();
      final events = await CalendarService.getWeekEvents(dates.first);
      setState(() {
        _googleEvents = events;
        _isConnected = true;
      });
    } catch (e) {
      debugPrint('Calendar error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  List<DateTime> _getWeekDates() {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1))
        .add(Duration(days: _weekOffset * 7));
    return List.generate(7, (i) =>
        DateTime(monday.year, monday.month, monday.day + i));
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

  void _showEventDetails(gcal.Event event) {
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
                    ),
                  ],
                  if (description != null && description.trim().isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _EventDetailRow(
                      icon: Icons.notes_rounded,
                      label: 'Description',
                      value: description,
                    ),
                  ],
                  if (attendees.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _EventDetailRow(
                      icon: Icons.people_rounded,
                      label: 'Attendees',
                      value: attendees
                          .map((attendee) => attendee.displayName ?? attendee.email ?? 'Guest')
                          .take(6)
                          .join(', '),
                    ),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _accentPurple,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: const Text(
                        'Done',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
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
              child: Row(
                children: [
                  const Icon(Icons.calendar_today_rounded, size: 16, color: _accentPurple),
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
                  const SizedBox(width: 8),
                  if (!_isConnected)
                    GestureDetector(
                      onTap: _isLoading ? null : _connectGoogle,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
                  const SizedBox(width: 4),
                  _navBtn(Icons.chevron_left_rounded, () {
                    setState(() => _weekOffset--);
                    if (_isConnected) _connectGoogle();
                  }),
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: () => setState(() => _weekOffset = 0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
                    if (_isConnected) _connectGoogle();
                  }),
                ],
              ),
            ),

            // Day headers
            Row(
              children: [
                SizedBox(width: _timeColW),
                ...dates.map((d) {
                  final isToday = _weekOffset == 0 &&
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
            if (!_isConnected)
              Container(
                height: 220,
                alignment: Alignment.center,
                child: SingleChildScrollView(
                  physics: const NeverScrollableScrollPhysics(),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.calendar_month_rounded, size: 48, color: Color(0xFFE5E5EA)),
                      const SizedBox(height: 16),
                      const Text(
                        'No calendar connected',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _textDark),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Tap "Connect Google Calendar" above\nto see your events here.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: _textGrey, height: 1.5),
                      ),
                      const SizedBox(height: 20),
                      GestureDetector(
                        onTap: _isLoading ? null : _connectGoogle,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1a73e8),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: _isLoading
                              ? const SizedBox(
                                  width: 14, height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.calendar_month_rounded, size: 14, color: Colors.white),
                                    SizedBox(width: 6),
                                    Text(
                                      'Connect Google Calendar',
                                      style: TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600),
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
                        children: _hours.map((h) => SizedBox(
                          height: _cellH,
                          child: Align(
                            alignment: Alignment.topRight,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 8, top: 4),
                              child: Text(
                                _fmt12(h),
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: _textGrey,
                                ),
                              ),
                            ),
                          ),
                        )).toList(),
                      ),
                    ),

                    // Day columns
                    ...dates.map((d) {
                      final dow = d.weekday % 7;
                      final isToday = _weekOffset == 0 &&
                          d.day == now.day &&
                          d.month == now.month &&
                          d.year == now.year;
                      const dayEvents = <_CalEvent>[];
                      final googleDayEvents = _isConnected
                          ? _googleEvents.where((e) {
                              final start = e.start?.dateTime?.toLocal();
                              return start != null &&
                                  start.day == d.day &&
                                  start.month == d.month;
                            }).toList()
                          : <gcal.Event>[];

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
                                children: _hours.map((h) => Container(
                                  height: _cellH,
                                  decoration: const BoxDecoration(
                                    border: Border(
                                      bottom: BorderSide(color: _border, width: 0.5),
                                    ),
                                  ),
                                )).toList(),
                              ),

              

                              // Google Calendar events
                              ...googleDayEvents.map((ev) {
                                final start = ev.start?.dateTime?.toLocal();
                                final end = ev.end?.dateTime?.toLocal();
                                if (start == null) return const SizedBox.shrink();
                                final startH = start.hour + start.minute / 60.0;
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
                                      onTap: () => _showEventDetails(ev),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 5, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFe8f0fe),
                                          borderRadius: BorderRadius.circular(4),
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

  const _EventDetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
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
              Text(
                value,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF1C1C1E),
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}