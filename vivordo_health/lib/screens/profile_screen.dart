import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:vivordo_health/src/services/calendar_service.dart';
import 'package:vivordo_health/src/services/outlook_calendar_service.dart';
import 'package:vivordo_health/src/services/user_service.dart';
import 'package:vivordo_health/src/services/health_service.dart';
import 'package:vivordo_health/src/services/fitbit_service.dart';
import 'package:vivordo_health/src/services/notification_service.dart';
import 'package:vivordo_health/src/services/analytics_service.dart';
import 'package:vivordo_health/src/models/user_model.dart';
import 'login_screen.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  bool _autoSyncData = true;

  bool _isEmailVerificationSignOut = false;

  // Loading states for HealthKit actions
  bool _isConnectingAll = false; // "Connect Apple Health" button
  String? _togglingMetric; // key of metric currently being toggled
  bool _isGoogleCalendarConnected = false;
  bool _isUpdatingGoogleCalendar = false;
  bool _isOutlookCalendarConnected = false;
  bool _isUpdatingOutlookCalendar = false;
  bool _isUpdatingFitbit = false;
  bool _isUpdatingScanReminder = false;
  bool _isUpdatingCheckInReminder = false;

  // Bug report
  final TextEditingController _bugReportController = TextEditingController();
  bool _isSubmittingBugReport = false;

  StreamSubscription<User?>? _authSubscription;

  // Cached Firestore stream — MUST be created once in initState and reused.
  // If we create it inside build() a new stream object is made on every
  // rebuild, StreamBuilder detects the change, resets to 'waiting', and the
  // screen spins forever.
  late Stream<DocumentSnapshot<Map<String, dynamic>>> _userDocStream;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    final uid = FirebaseAuth.instance.currentUser?.uid;
    _userDocStream = uid != null
        ? FirebaseFirestore.instance.collection('users').doc(uid).snapshots()
        : const Stream.empty();

    CalendarService.connectionNotifier.addListener(
      _handleGoogleCalendarConnectionChange,
    );
    _refreshGoogleCalendarConnection();
    _refreshOutlookCalendarConnection();

    // Skip the first emission — it just reflects current login state, not a change
    bool isFirstEmission = true;
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (isFirstEmission) {
        isFirstEmission = false;
        return;
      }
      if (user == null && mounted) {
        final message = _isEmailVerificationSignOut
            ? 'Email verified! Please log in again with your new email.'
            : 'You have been signed out.';

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 4),
          ),
        );
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const LoginScreen()),
          (route) => false,
        );
      }
    });

    // NOTE: We do NOT call _checkEmailSync() here anymore.
    // Cleanup of pendingEmail now happens in AuthService.emailLogin,
    // so by the time the user reaches this screen it is already clean.
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _bugReportController.dispose();
    CalendarService.connectionNotifier.removeListener(
      _handleGoogleCalendarConnectionChange,
    );
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _submitBugReport() async {
    final message = _bugReportController.text.trim();
    if (message.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please describe the bug before sending.'),
        ),
      );
      return;
    }

    setState(() => _isSubmittingBugReport = true);
    try {
      await UserService.submitBugReport(message);
      if (mounted) {
        _bugReportController.clear();
        FocusScope.of(context).unfocus();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Thanks! Your bug report has been sent.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not send report: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSubmittingBugReport = false);
    }
  }

  void _handleGoogleCalendarConnectionChange() {
    if (!mounted) return;
    setState(() {
      _isGoogleCalendarConnected = CalendarService.connectionNotifier.value;
    });
  }

  Future<void> _refreshGoogleCalendarConnection() async {
    final hasAccess = await CalendarService.hasCalendarAccess();
    if (mounted) setState(() => _isGoogleCalendarConnected = hasAccess);
  }

  Future<void> _updateGoogleCalendarConnection() async {
    setState(() => _isUpdatingGoogleCalendar = true);
    try {
      if (_isGoogleCalendarConnected) {
        await CalendarService.signOut();
      } else {
        final today = DateTime.now();
        final weekStart = today.subtract(Duration(days: today.weekday - 1));
        await CalendarService.connectAndGetWeekEvents(
          DateTime(weekStart.year, weekStart.month, weekStart.day),
        );
      }

      final isConnected = CalendarService.connectionNotifier.value;
      if (mounted) {
        setState(() => _isGoogleCalendarConnected = isConnected);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isConnected
                  ? 'Google Calendar has been signed in.'
                  : 'Google Calendar has been logged out.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update Google Calendar: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isUpdatingGoogleCalendar = false);
    }
  }

  Future<void> _refreshOutlookCalendarConnection() async {
    final isConnected = await OutlookCalendarService.isSignedIn();
    if (mounted) {
      setState(() => _isOutlookCalendarConnected = isConnected);
    }
  }

  Future<void> _updateOutlookCalendarConnection() async {
    setState(() => _isUpdatingOutlookCalendar = true);
    try {
      if (_isOutlookCalendarConnected) {
        await OutlookCalendarService.signOut();
      } else {
        final today = DateTime.now();
        final weekStart = today.subtract(Duration(days: today.weekday - 1));
        await OutlookCalendarService.connectAndGetWeekEvents(
          DateTime(weekStart.year, weekStart.month, weekStart.day),
        );
      }

      final isConnected = await OutlookCalendarService.isSignedIn();
      if (mounted) {
        setState(() => _isOutlookCalendarConnected = isConnected);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isConnected
                  ? 'Outlook Calendar has been signed in.'
                  : 'Outlook Calendar has been logged out.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update Outlook Calendar: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isUpdatingOutlookCalendar = false);
    }
  }

  Future<void> _updateFitbitConnection(bool isConnected) async {
    if (_isUpdatingFitbit) return;
    setState(() => _isUpdatingFitbit = true);
    try {
      if (isConnected) {
        await FitbitService.instance.disconnect();
      } else {
        await FitbitService.instance.connect();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isConnected
                  ? 'Fitbit has been disconnected.'
                  : 'Fitbit connected and the last 30 days were synced.',
            ),
          ),
        );
      }
    } on FitbitAccountNotLinkedException catch (error) {
      if (mounted) await _showGoogleHealthSetupDialog(error.setupUrl);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Fitbit could not be updated. Please try again shortly.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isUpdatingFitbit = false);
    }
  }

  Future<void> _showGoogleHealthSetupDialog(Uri setupUrl) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Finish Google Health setup'),
        content: const Text(
          'This Google account is not linked to Google Health yet. Complete '
          'the setup using the same account that owns your Fitbit data, then '
          'return to Vivordo and sync again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              final opened = await launchUrl(
                setupUrl,
                mode: LaunchMode.externalApplication,
              );
              if (!opened && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Could not open Google Health setup.'),
                  ),
                );
              }
            },
            child: const Text('Open setup'),
          ),
        ],
      ),
    );
  }

  Future<void> _updateReminderPreference({
    required String field,
    required bool enabled,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final isScanReminder = field == 'scanReminderEnabled';
    if (isScanReminder ? _isUpdatingScanReminder : _isUpdatingCheckInReminder) {
      return;
    }

    setState(() {
      if (isScanReminder) {
        _isUpdatingScanReminder = true;
      } else {
        _isUpdatingCheckInReminder = true;
      }
    });

    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'preferences.$field': enabled,
      });
      if (isScanReminder) {
        await NotificationService().setDailyScanRemindersEnabled(enabled);
      } else {
        await NotificationService().setCalendarCheckInReminderEnabled(enabled);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update reminder settings.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          if (isScanReminder) {
            _isUpdatingScanReminder = false;
          } else {
            _isUpdatingCheckInReminder = false;
          }
        });
      }
    }
  }

  String _formatReminderTime(int minutes) {
    final hour24 = minutes ~/ 60;
    final minute = minutes % 60;
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    final suffix = hour24 >= 12 ? 'PM' : 'AM';
    return '$hour12:${minute.toString().padLeft(2, '0')} $suffix';
  }

  Future<void> _chooseScanReminderTime({
    required List<int> reminderTimes,
    int? index,
  }) async {
    final isAdding = index == null;
    final currentMinutes = isAdding
        ? (reminderTimes.last + 4 * 60) % (24 * 60)
        : reminderTimes[index!];
    final selected = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: currentMinutes ~/ 60,
        minute: currentMinutes % 60,
      ),
    );
    if (selected == null || !mounted) return;

    final selectedMinutes = selected.hour * 60 + selected.minute;
    final updatedTimes = [...reminderTimes];
    final existingTime = index == null ? null : reminderTimes[index];
    if (updatedTimes.contains(selectedMinutes) &&
        existingTime != selectedMinutes) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That reminder time already exists.')),
      );
      return;
    }
    if (isAdding) {
      updatedTimes.add(selectedMinutes);
    } else {
      updatedTimes[index!] = selectedMinutes;
    }
    updatedTimes.sort();
    await _saveScanReminderTimes(updatedTimes);
  }

  Future<void> _removeScanReminderTime(
    List<int> reminderTimes,
    int index,
  ) async {
    if (reminderTimes.length <= 1) return;
    final updatedTimes = [...reminderTimes]..removeAt(index);
    await _saveScanReminderTimes(updatedTimes);
  }

  Future<void> _saveScanReminderTimes(List<int> reminderTimes) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'preferences.scanReminderTimes': reminderTimes,
        'preferences.scanReminderMorningMinutes': FieldValue.delete(),
        'preferences.scanReminderEveningMinutes': FieldValue.delete(),
      });
      await NotificationService().setDailyScanReminderTimes(reminderTimes);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update reminder time.')),
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only check when the user returns to the app — this handles the case
    // where they tap the verification link while the app is already open
    if (state == AppLifecycleState.resumed) {
      _checkEmailSync();
      _refreshOutlookCalendarConnection();
    }
  }

  Future<void> _checkEmailSync() async {
    final didLogout = await UserService.syncEmailWithAuth();
    if (didLogout) {
      _isEmailVerificationSignOut = true;
    }
    // Navigation handled by authStateChanges listener
  }

  void _showEditDialog(
    BuildContext context,
    String field,
    String currentValue,
  ) {
    final TextEditingController controller = TextEditingController(
      text: currentValue,
    );
    // Only used when field == "Password" — Firebase always requires proof of
    // the current password (via reauthentication) before it will accept a
    // new one, so we collect it up front instead of dead-ending on a
    // requires-recent-login error after the fact.
    final TextEditingController currentPasswordController =
        TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Edit $field'),
          content: field == "Password"
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: currentPasswordController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Current Password',
                      ),
                    ),
                    TextField(
                      controller: controller,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'New Password',
                      ),
                    ),
                  ],
                )
              : TextField(
                  controller: controller,
                  decoration: InputDecoration(labelText: field),
                ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                try {
                  if (field == "Name") {
                    await UserService.updateDisplayName(controller.text);
                  } else if (field == "Email") {
                    await UserService.updateEmail(controller.text);
                  } else if (field == "Password") {
                    if (controller.text.length < 6) {
                      throw FirebaseAuthException(
                        code: 'weak-password',
                        message: 'Password should be at least 6 characters',
                      );
                    }
                    await UserService.reauthenticate(
                      currentPasswordController.text,
                    );
                    await UserService.updatePassword(controller.text);
                  }

                  if (mounted) {
                    Navigator.pop(context);

                    final message = field == "Email"
                        ? 'Verification email sent to ${controller.text}. Tap the link to confirm your new email.'
                        : '$field updated successfully!';

                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(message)));
                  }
                } on FirebaseAuthException catch (e) {
                  String errorMessage = 'Error: ${e.message}';
                  if (e.code == 'requires-recent-login') {
                    errorMessage =
                        'For security, please log out and log back in to change your $field.';
                  } else if (e.code == 'wrong-password' ||
                      e.code == 'invalid-credential') {
                    errorMessage = 'Current password is incorrect.';
                  } else if (e.code == 'weak-password') {
                    errorMessage = e.message ?? 'Password is too weak.';
                  }
                  if (mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(errorMessage)));
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error: ${e.toString()}')),
                    );
                  }
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Build is driven entirely by _userDocStream which was cached in initState.
    // We do NOT call context.watch<User?>() here — that triggers extra rebuilds
    // and can cause a spinner loop because the Provider's initialData is null.
    // Sign-out is handled by the _authSubscription listener in initState.
    return StreamBuilder<DocumentSnapshot>(
      stream: _userDocStream,
      builder: (context, snapshot) {
        // Still loading first snapshot
        if (!snapshot.hasData &&
            snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(color: Color(0xFF7C69EF)),
            ),
          );
        }

        // Firestore error — show message with back button so user isn't stuck
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, color: Colors.grey, size: 40),
                  const SizedBox(height: 12),
                  const Text('Could not load profile'),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Go back'),
                  ),
                ],
              ),
            ),
          );
        }

        // Doc missing — auto-create it and wait for the stream to update
        final authUser = FirebaseAuth.instance.currentUser;
        if (!snapshot.hasData || !snapshot.data!.exists) {
          if (authUser != null) UserService.createUser(authUser);
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(color: Color(0xFF7C69EF)),
            ),
          );
        }

        // Extract everything from the ONE snapshot — no extra Firestore listeners.
        final rawData = snapshot.data!.data() as Map<String, dynamic>;
        final userData = UserModel.fromMap(rawData, snapshot.data!.id);
        final pendingEmail = rawData['pendingEmail'] as String?;
        final preferences = rawData['preferences'] as Map? ?? {};
        final scanReminderEnabled = preferences['scanReminderEnabled'] != false;
        final checkInReminderEnabled =
            preferences['checkInReminderEnabled'] != false;
        final savedReminderTimes =
            (preferences['scanReminderTimes'] as List?)
                ?.whereType<num>()
                .map((value) => value.toInt().clamp(0, 1439).toInt())
                .toSet()
                .toList() ??
            [];
        final scanReminderTimes = savedReminderTimes.isNotEmpty
            ? savedReminderTimes
            : <int>[
                ((preferences['scanReminderMorningMinutes'] as num?)?.toInt() ??
                        9 * 60)
                    .clamp(0, 1439)
                    .toInt(),
                ((preferences['scanReminderEveningMinutes'] as num?)?.toInt() ??
                        17 * 60)
                    .clamp(0, 1439)
                    .toInt(),
              ];
        scanReminderTimes.sort();

        // Read consent from the same doc — avoids opening extra listeners.
        final consentRaw = rawData['healthKitConsent'] as Map? ?? {};
        final consent = consentRaw.map(
          (k, v) => MapEntry(k.toString(), v == true),
        );
        final anyConsented = consent.values.any((v) => v);
        final selectedMetricCount = kHealthMetrics
            .where((metric) => consent[metric.key] == true)
            .length;
        final fitbitConnected = rawData['fitbitConnected'] == true;

        return Scaffold(
          backgroundColor: const Color(0xFFF2F2F7),
          body: SafeArea(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Top bar ────────────────────────────────────────────────
                  const SizedBox(height: 48),
                  Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFE5E5EA)),
                          ),
                          child: const Icon(
                            Icons.arrow_back_ios_new_rounded,
                            size: 16,
                            color: Color(0xFF1C1C1E),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Profile',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1C1C1E),
                                letterSpacing: -0.5,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              userData.email ?? '',
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFF8E8E93),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Avatar
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: const Color(0xFF7B6EF6).withOpacity(0.12),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0xFF7B6EF6).withOpacity(0.25),
                            width: 2,
                          ),
                        ),
                        child:
                            userData.photoUrl != null &&
                                userData.photoUrl!.startsWith('http')
                            ? ClipOval(
                                child: Image.network(
                                  userData.photoUrl!,
                                  fit: BoxFit.cover,
                                ),
                              )
                            : const Icon(
                                Icons.person_outline_rounded,
                                size: 26,
                                color: Color(0xFF7B6EF6),
                              ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // ── Pending Email Banner ───────────────────────────────────
                  if (pendingEmail != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF8E1),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.amber.shade300),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.mail_outline,
                            color: Colors.amber,
                            size: 18,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Verify your new email: $pendingEmail\nCheck your inbox and tap the link.',
                              style: const TextStyle(
                                fontSize: 13,
                                color: Colors.black87,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // ── Account Information ────────────────────────────────────
                  _buildSectionLabel('Account'),
                  _buildCard(
                    children: [
                      _buildInfoRow(
                        Icons.person_outline_rounded,
                        'Name',
                        userData.displayName ?? 'Set your name',
                        onTap: () => _showEditDialog(
                          context,
                          'Name',
                          userData.displayName ?? '',
                        ),
                      ),
                      _buildDivider(),
                      _buildInfoRow(
                        Icons.mail_outline_rounded,
                        'Email',
                        userData.email ?? 'Set your email',
                        onTap: () => _showEditDialog(
                          context,
                          'Email',
                          userData.email ?? '',
                        ),
                      ),
                      _buildDivider(),
                      _buildInfoRow(
                        Icons.lock_outline_rounded,
                        'Password',
                        '••••••••',
                        onTap: () => _showEditDialog(context, 'Password', ''),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // ── Apple Health ───────────────────────────────────────────
                  _buildSectionLabel('Apple Health'),
                  _buildCard(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: anyConsented
                                    ? const Color(0xFFFFE4EC)
                                    : const Color(0xFFF2F2F7),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                Icons.favorite_rounded,
                                size: 18,
                                color: anyConsented
                                    ? Colors.pinkAccent
                                    : const Color(0xFF8E8E93),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Health data sync',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF1C1C1E),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    anyConsented
                                        ? '$selectedMetricCount of ${kHealthMetrics.length} metrics selected'
                                        : 'No metrics selected',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: anyConsented
                                          ? const Color(0xFF34C759)
                                          : const Color(0xFF8E8E93),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: anyConsented
                                    ? const Color(0xFFE9FAF0)
                                    : const Color(0xFFF2F2F7),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                anyConsented ? 'On' : 'Off',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: anyConsented
                                      ? const Color(0xFF34C759)
                                      : const Color(0xFF8E8E93),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (!anyConsented) ...[
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _isConnectingAll
                                ? null
                                : () async {
                                    setState(() => _isConnectingAll = true);
                                    try {
                                      final granted = await HealthService()
                                          .enableAll();
                                      if (mounted && !granted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Apple Health permissions were not granted.',
                                            ),
                                          ),
                                        );
                                      }
                                    } catch (e) {
                                      if (mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              'Could not connect: $e',
                                            ),
                                          ),
                                        );
                                      }
                                    } finally {
                                      if (mounted)
                                        setState(
                                          () => _isConnectingAll = false,
                                        );
                                    }
                                  },
                            icon: _isConnectingAll
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(
                                    Icons.health_and_safety_outlined,
                                    size: 18,
                                  ),
                            label: Text(
                              _isConnectingAll
                                  ? 'Requesting access…'
                                  : 'Select all health metrics',
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF7B6EF6),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Apple controls access. Vivordo only reads the metrics you approve.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFF8E8E93),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 24),

                  // ── Fitbit ────────────────────────────────────────────────
                  _buildSectionLabel('Connected Wearables'),
                  _buildCard(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF00B0B9,
                                ).withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                Icons.watch_rounded,
                                size: 18,
                                color: Color(0xFF00B0B9),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Fitbit',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF1C1C1E),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    fitbitConnected
                                        ? 'Connected — health data sync enabled'
                                        : 'Connect your Fitbit account',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: fitbitConnected
                                          ? const Color(0xFF34C759)
                                          : const Color(0xFF8E8E93),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            TextButton.icon(
                              onPressed: _isUpdatingFitbit
                                  ? null
                                  : () => _updateFitbitConnection(
                                      fitbitConnected,
                                    ),
                              icon: _isUpdatingFitbit
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Color(0xFF00B0B9),
                                      ),
                                    )
                                  : Icon(
                                      fitbitConnected
                                          ? Icons.link_off_rounded
                                          : Icons.link_rounded,
                                      size: 16,
                                    ),
                              label: Text(
                                _isUpdatingFitbit
                                    ? (fitbitConnected
                                          ? 'Disconnecting…'
                                          : 'Connecting…')
                                    : (fitbitConnected
                                          ? 'Disconnect'
                                          : 'Connect'),
                              ),
                              style: TextButton.styleFrom(
                                foregroundColor: fitbitConnected
                                    ? const Color(0xFFFF3B30)
                                    : const Color(0xFF00B0B9),
                                textStyle: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (fitbitConnected) ...[
                        _buildDivider(),
                        SizedBox(
                          width: double.infinity,
                          child: TextButton.icon(
                            onPressed: _isUpdatingFitbit
                                ? null
                                : () async {
                                    setState(() => _isUpdatingFitbit = true);
                                    try {
                                      await FitbitService.instance.sync(
                                        daysBack: 30,
                                      );
                                      if (mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Fitbit data is up to date.',
                                            ),
                                          ),
                                        );
                                      }
                                    } on FitbitAccountNotLinkedException catch (
                                      error
                                    ) {
                                      if (mounted) {
                                        await _showGoogleHealthSetupDialog(
                                          error.setupUrl,
                                        );
                                      }
                                    } catch (_) {
                                      if (mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Fitbit could not be synced. '
                                              'Please try again shortly.',
                                            ),
                                          ),
                                        );
                                      }
                                    } finally {
                                      if (mounted) {
                                        setState(
                                          () => _isUpdatingFitbit = false,
                                        );
                                      }
                                    }
                                  },
                            icon: const Icon(Icons.sync_rounded, size: 17),
                            label: const Text('Sync last 30 days'),
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF00B0B9),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 24),

                  // ── Connected Calendars ───────────────────────────────────
                  _buildSectionLabel('Connected Calendars'),
                  _buildCard(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF7B6EF6,
                                ).withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                Icons.calendar_month_rounded,
                                size: 18,
                                color: Color(0xFF7B6EF6),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Google Calendar',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF1C1C1E),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _isGoogleCalendarConnected
                                        ? 'Connected — calendar access enabled'
                                        : 'Not connected',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: _isGoogleCalendarConnected
                                          ? const Color(0xFF34C759)
                                          : const Color(0xFF8E8E93),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            TextButton.icon(
                              onPressed: _isUpdatingGoogleCalendar
                                  ? null
                                  : _updateGoogleCalendarConnection,
                              icon: _isUpdatingGoogleCalendar
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Color(0xFF7B6EF6),
                                      ),
                                    )
                                  : Icon(
                                      _isGoogleCalendarConnected
                                          ? Icons.logout_rounded
                                          : Icons.login_rounded,
                                      size: 16,
                                    ),
                              label: Text(
                                _isUpdatingGoogleCalendar
                                    ? (_isGoogleCalendarConnected
                                          ? 'Logging out…'
                                          : 'Signing in…')
                                    : (_isGoogleCalendarConnected
                                          ? 'Log Out'
                                          : 'Sign In'),
                              ),
                              style: TextButton.styleFrom(
                                foregroundColor: _isGoogleCalendarConnected
                                    ? const Color(0xFFFF3B30)
                                    : const Color(0xFF7B6EF6),
                                textStyle: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      _buildDivider(),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF0078D4,
                                ).withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                Icons.calendar_month_rounded,
                                size: 18,
                                color: Color(0xFF0078D4),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Outlook Calendar',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF1C1C1E),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _isOutlookCalendarConnected
                                        ? 'Connected - calendar access enabled'
                                        : 'Not connected',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: _isOutlookCalendarConnected
                                          ? const Color(0xFF34C759)
                                          : const Color(0xFF8E8E93),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            TextButton.icon(
                              onPressed: _isUpdatingOutlookCalendar
                                  ? null
                                  : _updateOutlookCalendarConnection,
                              icon: _isUpdatingOutlookCalendar
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Color(0xFF0078D4),
                                      ),
                                    )
                                  : Icon(
                                      _isOutlookCalendarConnected
                                          ? Icons.logout_rounded
                                          : Icons.login_rounded,
                                      size: 16,
                                    ),
                              label: Text(
                                _isUpdatingOutlookCalendar
                                    ? (_isOutlookCalendarConnected
                                          ? 'Logging out...'
                                          : 'Signing in...')
                                    : (_isOutlookCalendarConnected
                                          ? 'Log Out'
                                          : 'Sign In'),
                              ),
                              style: TextButton.styleFrom(
                                foregroundColor: _isOutlookCalendarConnected
                                    ? const Color(0xFFFF3B30)
                                    : const Color(0xFF0078D4),
                                textStyle: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // ── Health Data Sync ───────────────────────────────────────
                  _buildSectionLabel('Health Data Sync'),
                  _buildCard(
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text(
                          'Choose which Apple Health metrics Vivordo syncs. Turning a metric off removes its saved data from Vivordo but does not change Apple Health permissions.',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: Color(0xFF636366),
                          ),
                        ),
                      ),
                      ...kHealthMetrics.map((metric) {
                        final enabled = consent[metric.key] == true;
                        final isToggling = _togglingMetric == metric.key;
                        return Column(
                          children: [
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              value: enabled,
                              thumbColor: WidgetStateProperty.resolveWith(
                                (states) =>
                                    states.contains(WidgetState.selected)
                                    ? Colors.white
                                    : const Color(0xFFFFFFFF),
                              ),
                              trackColor: WidgetStateProperty.resolveWith(
                                (states) =>
                                    states.contains(WidgetState.selected)
                                    ? const Color(0xFF7B6EF6)
                                    : const Color(0xFFD1D1D6),
                              ),
                              trackOutlineColor: const WidgetStatePropertyAll(
                                Colors.transparent,
                              ),
                              onChanged: (val) async {
                                if (isToggling) return;
                                setState(() => _togglingMetric = metric.key);
                                try {
                                  if (val) {
                                    final granted = await HealthService()
                                        .enableMetric(metric.key);
                                    if (!granted && mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            '${metric.label} was not enabled. Review Vivordo permissions in Apple Health.',
                                          ),
                                        ),
                                      );
                                    }
                                  } else {
                                    await HealthService().disableMetric(
                                      metric.key,
                                    );
                                  }
                                } catch (e) {
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Error: $e')),
                                    );
                                  }
                                } finally {
                                  if (mounted)
                                    setState(() => _togglingMetric = null);
                                }
                              },
                              title: Text(
                                metric.label,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                  color: isToggling
                                      ? const Color(0xFF8E8E93)
                                      : const Color(0xFF1C1C1E),
                                ),
                              ),
                              subtitle: Text(
                                isToggling
                                    ? (enabled
                                          ? 'Removing saved Vivordo data…'
                                          : 'Requesting Apple Health access…')
                                    : metric.description,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isToggling
                                      ? const Color(0xFF7B6EF6)
                                      : const Color(0xFF8E8E93),
                                ),
                              ),
                              secondary: isToggling
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Color(0xFF7B6EF6),
                                      ),
                                    )
                                  : Icon(
                                      _metricIcon(metric.key),
                                      color: enabled
                                          ? const Color(0xFF7B6EF6)
                                          : const Color(0xFF8E8E93),
                                      size: 20,
                                    ),
                            ),
                            if (metric != kHealthMetrics.last)
                              const Divider(
                                height: 1,
                                indent: 44,
                                endIndent: 0,
                              ),
                          ],
                        );
                      }),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // ── App Settings ───────────────────────────────────────────
                  _buildSectionLabel('App Settings'),
                  _buildCard(
                    children: [
                      _buildToggleRow(
                        Icons.monitor_heart_outlined,
                        'Scan Reminders',
                        '${scanReminderTimes.length} reminder${scanReminderTimes.length == 1 ? '' : 's'} each day',
                        scanReminderEnabled,
                        (val) => _updateReminderPreference(
                          field: 'scanReminderEnabled',
                          enabled: val,
                        ),
                      ),
                      if (scanReminderEnabled) ...[
                        for (
                          var index = 0;
                          index < scanReminderTimes.length;
                          index++
                        ) ...[
                          _buildDivider(),
                          _buildReminderTimeRow(
                            index: index,
                            minutes: scanReminderTimes[index],
                            canRemove: scanReminderTimes.length > 1,
                            onEdit: () => _chooseScanReminderTime(
                              reminderTimes: scanReminderTimes,
                              index: index,
                            ),
                            onRemove: () => _removeScanReminderTime(
                              scanReminderTimes,
                              index,
                            ),
                          ),
                        ],
                        if (scanReminderTimes.length < 10) ...[
                          _buildDivider(),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: () => _chooseScanReminderTime(
                                reminderTimes: scanReminderTimes,
                              ),
                              icon: const Icon(Icons.add_alarm_rounded),
                              label: const Text('Add reminder'),
                            ),
                          ),
                        ],
                      ],
                      _buildDivider(),
                      _buildToggleRow(
                        Icons.chat_bubble_outline_rounded,
                        'Daily Check-in Reminder',
                        'After your final calendar event',
                        checkInReminderEnabled,
                        (val) => _updateReminderPreference(
                          field: 'checkInReminderEnabled',
                          enabled: val,
                        ),
                      ),
                      _buildDivider(),
                      _buildToggleRow(
                        Icons.sync_rounded,
                        'Auto Sync Health Data',
                        'Syncs every 3 minutes in background',
                        _autoSyncData,
                        (val) => setState(() => _autoSyncData = val),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // ── Report a Bug ───────────────────────────────────────────
                  _buildSectionLabel('Report a Bug'),
                  _buildCard(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(7),
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xFF7B6EF6,
                                    ).withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(
                                    Icons.bug_report_outlined,
                                    size: 16,
                                    color: Color(0xFF7B6EF6),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                const Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Found a problem?',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF1C1C1E),
                                        ),
                                      ),
                                      Text(
                                        'Tell us what went wrong and we’ll look into it',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF8E8E93),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            TextField(
                              controller: _bugReportController,
                              minLines: 3,
                              maxLines: 6,
                              textCapitalization: TextCapitalization.sentences,
                              style: const TextStyle(
                                fontSize: 14,
                                color: Color(0xFF1C1C1E),
                              ),
                              decoration: InputDecoration(
                                hintText: 'Describe the bug…',
                                hintStyle: const TextStyle(
                                  fontSize: 14,
                                  color: Color(0xFF8E8E93),
                                ),
                                filled: true,
                                fillColor: const Color(0xFFF2F2F7),
                                contentPadding: const EdgeInsets.all(14),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: BorderSide.none,
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: BorderSide.none,
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: const BorderSide(
                                    color: Color(0xFF7B6EF6),
                                    width: 1.5,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: _isSubmittingBugReport
                                    ? null
                                    : _submitBugReport,
                                icon: _isSubmittingBugReport
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Icon(Icons.send_rounded, size: 18),
                                label: Text(
                                  _isSubmittingBugReport
                                      ? 'Sending…'
                                      : 'Send Report',
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF7B6EF6),
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  textStyle: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // ── Log Out ────────────────────────────────────────────────
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        // Log while still authenticated — Firestore rules
                        // reject writes once signOut() clears the session.
                        await AnalyticsService().logLogout();
                        await FirebaseAuth.instance.signOut();
                      },
                      icon: const Icon(
                        Icons.logout_rounded,
                        size: 18,
                        color: Color(0xFFFF3B30),
                      ),
                      label: const Text('Log Out'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFFE5E5),
                        foregroundColor: const Color(0xFFFF3B30),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 120),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Helper Widgets ─────────────────────────────────────────────────────────

  Widget _buildSectionLabel(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: Color(0xFF8E8E93),
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget _buildCard({required List<Widget> children}) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFE5E5EA)),
        ),
        child: Column(children: children),
      ),
    );
  }

  Widget _buildDivider() => const Divider(height: 1, color: Color(0xFFF2F2F7));

  Widget _buildInfoRow(
    IconData icon,
    String label,
    String value, {
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(
          children: [
            Icon(icon, size: 18, color: const Color(0xFF7B6EF6)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF8E8E93),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1C1C1E),
                    ),
                  ),
                ],
              ),
            ),
            if (onTap != null)
              const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: Color(0xFFC7C7CC),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildReminderTimeRow({
    required int index,
    required int minutes,
    required bool canRemove,
    required VoidCallback onEdit,
    required VoidCallback onRemove,
  }) {
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: onEdit,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Row(
                children: [
                  const Icon(
                    Icons.alarm_rounded,
                    size: 18,
                    color: Color(0xFF7B6EF6),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Reminder ${index + 1}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF8E8E93),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _formatReminderTime(minutes),
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1C1C1E),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: Color(0xFFC7C7CC),
                  ),
                ],
              ),
            ),
          ),
        ),
        IconButton(
          onPressed: canRemove ? onRemove : null,
          tooltip: canRemove
              ? 'Remove reminder'
              : 'At least one reminder is required',
          icon: const Icon(Icons.delete_outline_rounded),
          color: const Color(0xFFFF3B30),
          disabledColor: const Color(0xFFC7C7CC),
        ),
      ],
    );
  }

  Widget _buildToggleRow(
    IconData icon,
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: const Color(0xFF7B6EF6).withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: const Color(0xFF7B6EF6)),
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
                    color: Color(0xFF1C1C1E),
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF8E8E93),
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: const Color(0xFF7B6EF6),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }

  IconData _metricIcon(String key) {
    switch (key) {
      // Activity
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
      // Heart
      case 'heart_rate':
        return Icons.favorite_rounded;
      case 'resting_heart_rate':
        return Icons.favorite_border_rounded;
      case 'hrv':
        return Icons.show_chart_rounded;
      // Breathing / Vitals
      case 'blood_oxygen':
        return Icons.air_rounded;
      case 'respiratory_rate':
        return Icons.wind_power_rounded;
      // Sleep
      case 'sleep':
        return Icons.bedtime_rounded;
      // Body
      case 'weight':
        return Icons.monitor_weight_rounded;
      case 'body_fat':
        return Icons.percent_rounded;
      // Mind
      case 'mindfulness':
        return Icons.self_improvement_rounded;
      // Fitness
      case 'vo2max':
        return Icons.speed_rounded;
      default:
        return Icons.monitor_heart_outlined;
    }
  }
}
