import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:vivordo_health/src/services/user_service.dart';
import 'package:vivordo_health/src/services/health_service.dart';
import 'package:vivordo_health/src/models/user_model.dart';
import 'login_screen.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:vivordo_health/src/services/metrics_service.dart';



class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});


  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}


class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  bool _pushNotifications = true;
  bool _autoSyncData = true;

  bool _isEmailVerificationSignOut = false;

  // Loading states for HealthKit actions
  bool _isConnectingAll = false;           // "Connect Apple Health" button
  String? _togglingMetric;                 // key of metric currently being toggled

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
        ? FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .snapshots()
        : const Stream.empty();


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
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }


  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only check when the user returns to the app — this handles the case
    // where they tap the verification link while the app is already open
    if (state == AppLifecycleState.resumed) {
      _checkEmailSync();
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
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Edit $field'),
          content: field == "Password"
              ? TextField(
                  controller: controller,
                  obscureText: true,
                  decoration:
                      const InputDecoration(labelText: 'New Password'),
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
                    await UserService.updatePassword(controller.text);
                  }


                  if (mounted) {
                    Navigator.pop(context);


                    final message = field == "Email"
                        ? 'Verification email sent to ${controller.text}. Tap the link to confirm your new email.'
                        : '$field updated successfully!';


                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(message)),
                    );
                  }
                } on FirebaseAuthException catch (e) {
                  String errorMessage = 'Error: ${e.message}';
                  if (e.code == 'requires-recent-login') {
                    errorMessage =
                        'For security, please log out and log back in to change your $field.';
                  }
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(errorMessage)),
                    );
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
        final rawData     = snapshot.data!.data() as Map<String, dynamic>;
        final userData    = UserModel.fromMap(rawData, snapshot.data!.id);
        final pendingEmail = rawData['pendingEmail'] as String?;

        // Read consent from the same doc — avoids opening extra listeners.
        final consentRaw   = rawData['healthKitConsent'] as Map? ?? {};
        final consent      = consentRaw.map((k, v) => MapEntry(k.toString(), v == true));
        final anyConsented = consent.values.any((v) => v);


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
                          child: const Icon(Icons.arrow_back_ios_new_rounded, size: 16, color: Color(0xFF1C1C1E)),
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
                              style: const TextStyle(fontSize: 13, color: Color(0xFF8E8E93)),
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
                          border: Border.all(color: const Color(0xFF7B6EF6).withOpacity(0.25), width: 2),
                        ),
                        child: userData.photoUrl != null && userData.photoUrl!.startsWith('http')
                            ? ClipOval(child: Image.network(userData.photoUrl!, fit: BoxFit.cover))
                            : const Icon(Icons.person_outline_rounded, size: 26, color: Color(0xFF7B6EF6)),
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
                          const Icon(Icons.mail_outline, color: Colors.amber, size: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Verify your new email: $pendingEmail\nCheck your inbox and tap the link.',
                              style: const TextStyle(fontSize: 13, color: Colors.black87, height: 1.4),
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
                        onTap: () => _showEditDialog(context, 'Name', userData.displayName ?? ''),
                      ),
                      _buildDivider(),
                      _buildInfoRow(
                        Icons.mail_outline_rounded,
                        'Email',
                        userData.email ?? 'Set your email',
                        onTap: () => _showEditDialog(context, 'Email', userData.email ?? ''),
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

                  // ── Connected Devices ──────────────────────────────────────
                  _buildSectionLabel('Connected Devices'),
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
                                color: anyConsented ? Colors.pinkAccent : const Color(0xFF8E8E93),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Apple Health',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF1C1C1E),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    anyConsented ? 'Connected — syncing data' : 'Not connected',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: anyConsented ? const Color(0xFF34C759) : const Color(0xFF8E8E93),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: anyConsented
                                    ? const Color(0xFFE9FAF0)
                                    : const Color(0xFFF2F2F7),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                anyConsented ? 'Active' : 'Off',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: anyConsented ? const Color(0xFF34C759) : const Color(0xFF8E8E93),
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
                                      await HealthService().enableAll();
                                    } catch (e) {
                                      if (mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('Could not connect: $e')),
                                        );
                                      }
                                    } finally {
                                      if (mounted) setState(() => _isConnectingAll = false);
                                    }
                                  },
                            icon: _isConnectingAll
                                ? const SizedBox(
                                    width: 16, height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : const Icon(Icons.health_and_safety_outlined, size: 18),
                            label: Text(_isConnectingAll ? 'Connecting…' : 'Connect Apple Health'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF7B6EF6),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Grants read-only access to all health metrics',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 11, color: Color(0xFF8E8E93)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 24),

                  // ── Health Data Permissions ────────────────────────────────
                  _buildSectionLabel('Health Data Permissions'),
                  _buildCard(
                    children: kHealthMetrics.map((metric) {
                      final enabled    = consent[metric.key] == true;
                      final isToggling = _togglingMetric == metric.key;
                      return Column(
                        children: [
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: enabled,
                            activeColor: const Color(0xFF7B6EF6),
                            onChanged: isToggling
                                ? null
                                : (val) async {
                                    setState(() => _togglingMetric = metric.key);
                                    try {
                                      if (val) {
                                        await HealthService().enableMetric(metric.key);
                                      } else {
                                        await HealthService().disableMetric(metric.key);
                                      }
                                    } catch (e) {
                                      if (mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('Error: $e')),
                                        );
                                      }
                                    } finally {
                                      if (mounted) setState(() => _togglingMetric = null);
                                    }
                                  },
                            title: Text(
                              metric.label,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                                color: isToggling ? const Color(0xFF8E8E93) : const Color(0xFF1C1C1E),
                              ),
                            ),
                            subtitle: Text(
                              isToggling
                                  ? (enabled ? 'Removing access…' : 'Requesting access…')
                                  : metric.description,
                              style: TextStyle(
                                fontSize: 12,
                                color: isToggling ? const Color(0xFF7B6EF6) : const Color(0xFF8E8E93),
                              ),
                            ),
                            secondary: isToggling
                                ? const SizedBox(
                                    width: 20, height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF7B6EF6)),
                                  )
                                : Icon(
                                    _metricIcon(metric.key),
                                    color: enabled ? const Color(0xFF7B6EF6) : const Color(0xFF8E8E93),
                                    size: 20,
                                  ),
                          ),
                          if (metric != kHealthMetrics.last)
                            const Divider(height: 1, indent: 44, endIndent: 0),
                        ],
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 24),

                  // ── App Settings ───────────────────────────────────────────
                  _buildSectionLabel('App Settings'),
                  _buildCard(
                    children: [
                      _buildToggleRow(
                        Icons.notifications_none_rounded,
                        'Push Notifications',
                        'Daily reminders & insights',
                        _pushNotifications,
                        (val) => setState(() => _pushNotifications = val),
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
// ── Developer Tools ────────────────────────────────────────
                  _buildSectionLabel('Developer Tools'),
                  _buildCard(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: () async {
                              try {
                                await MetricsService.seedDemoData();
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Demo data loaded successfully!'),
                                      backgroundColor: Colors.green,
                                    ),
                                  );
                                }
                              } catch (e) {
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Failed: $e'),
                                      backgroundColor: Colors.red,
                                    ),
                                  );
                                }
                              }
                            },
                            icon: const Icon(Icons.data_object_rounded, size: 18),
                            label: const Text('Load Demo Data'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF7B6EF6),
                              foregroundColor: Colors.white,
                              elevation: 0,
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
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // ── Log Out ────────────────────────────────────────────────
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton.icon(
                      onPressed: () async => FirebaseAuth.instance.signOut(),
                      icon: const Icon(Icons.logout_rounded, size: 18, color: Color(0xFFFF3B30)),
                      label: const Text('Log Out'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFFE5E5),
                        foregroundColor: const Color(0xFFFF3B30),
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
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

  Widget _buildDivider() =>
      const Divider(height: 1, color: Color(0xFFF2F2F7));

  Widget _buildInfoRow(IconData icon, String label, String value, {VoidCallback? onTap}) {
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
                  Text(label,
                      style: const TextStyle(fontSize: 11, color: Color(0xFF8E8E93), fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(value,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF1C1C1E))),
                ],
              ),
            ),
            if (onTap != null)
              const Icon(Icons.chevron_right_rounded, size: 20, color: Color(0xFFC7C7CC)),
          ],
        ),
      ),
    );
  }

  Widget _buildToggleRow(IconData icon, String title, String subtitle, bool value, ValueChanged<bool> onChanged) {
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
                Text(title,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF1C1C1E))),
                Text(subtitle,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF8E8E93))),
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
      case 'steps':              return Icons.directions_walk_rounded;
      case 'active_calories':    return Icons.local_fire_department_rounded;
      case 'exercise_time':      return Icons.fitness_center_rounded;
      case 'distance':           return Icons.straighten_rounded;
      case 'flights_climbed':    return Icons.stairs_rounded;
      // Heart
      case 'heart_rate':         return Icons.favorite_rounded;
      case 'resting_heart_rate': return Icons.favorite_border_rounded;
      case 'hrv':                return Icons.show_chart_rounded;
      // Breathing / Vitals
      case 'blood_oxygen':       return Icons.air_rounded;
      case 'respiratory_rate':   return Icons.wind_power_rounded;
      // Sleep
      case 'sleep':              return Icons.bedtime_rounded;
      // Body
      case 'weight':             return Icons.monitor_weight_rounded;
      case 'body_fat':           return Icons.percent_rounded;
      // Mind
      case 'mindfulness':        return Icons.self_improvement_rounded;
      // Fitness
      case 'vo2max':             return Icons.speed_rounded;
      default:                   return Icons.monitor_heart_outlined;
    }
  }
}