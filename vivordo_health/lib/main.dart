import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:vivordo_health/firebase_options.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:vivordo_health/screens/main_navigation.dart';
import 'package:vivordo_health/src/services/notification_service.dart';
import 'package:vivordo_health/src/services/health_service.dart';
import 'screens/login_screen.dart';
import 'screens/signup_screen.dart';
import 'screens/home_screen.dart';
import 'package:firebase_app_check/firebase_app_check.dart';


// Global navigator key for notification navigation
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await FirebaseAppCheck.instance.activate(
  appleProvider: AppleProvider.debug,
  //providerApple: const AppleProvider(), // for simulator/debug
     );
  

  // Initialize notification service
  await NotificationService().initialize();

  runApp(
    // Only one provider: the auth state stream.
    // UserModel data is loaded per-screen (profile) or via HealthService
    // (consent). A second StreamProvider<UserModel?> reading User? at creation
    // time always got null (initialData) and created a broken/wasted Firestore
    // listener — removed to reduce concurrent listener count.
    StreamProvider<User?>(
      create: (_) => FirebaseAuth.instance.authStateChanges(),
      initialData: null,
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Vivordo Health',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primaryColor: const Color(0xFF857DEA),
        scaffoldBackgroundColor: const Color(0xFFFBFaff),
        colorScheme: ColorScheme.fromSwatch().copyWith(
          primary: const Color(0xFF857DEA),
          secondary: const Color(0xFF857DEA),
        ),
        useMaterial3: true,
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const AuthGate(),
        '/signup': (context) => const SignupScreen(),
        '/home': (context) => const HomeScreen(),
      },
    );
  }
}

/// AuthGate watches the auth state and routes accordingly.
/// On login it triggers a full 30-day HealthKit sync.
/// While logged in it syncs today's data every 3 minutes.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  String? _lastSyncedUid;
  Timer? _syncTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Sync HealthKit data every 3 minutes while the app is open.
    _syncTimer = Timer.periodic(const Duration(minutes: 3), (_) {
      if (FirebaseAuth.instance.currentUser != null) {
        HealthService().syncToday();
      }
    });
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Sync today's data whenever the app comes back to the foreground.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (FirebaseAuth.instance.currentUser != null) {
        HealthService().syncToday();
      }
    }
  }

  /// Full 30-day sync triggered once per login session.
  void _triggerFullSync(String uid) {
    if (_lastSyncedUid == uid) return;
    _lastSyncedUid = uid;
    HealthService().syncToFirestore(daysBack: 30);
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<User?>();

    if (user == null) {
      _lastSyncedUid = null;
      // Clear the cached consent broadcast so the next login gets a fresh stream
      HealthService().clearConsentCache();
      return const LoginScreen();
    }

    _triggerFullSync(user.uid);
    return const MainNavigationScreen();
  }
}
