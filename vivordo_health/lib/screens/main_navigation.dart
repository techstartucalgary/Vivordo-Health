import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'home_screen.dart';
import 'scan_screen.dart';
import 'dashboard_screen.dart';
import 'panda_screen.dart';
import '../src/services/analytics_service.dart';
import '../src/services/health_service.dart';

class MainNavigationScreen extends StatefulWidget {
  final int initialIndex;
  const MainNavigationScreen({super.key, this.initialIndex = 0});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen>
    with WidgetsBindingObserver {
  late int _selectedIndex;
  late bool _pandaHasBeenOpened;
  Timer? _healthRefreshTimer;
  final Color primaryPurple = const Color(0xFF7B6EF6);

  /// Analytics screen name per tab index, aligned with the nav bar order.
  static const List<String> _screenNames = ['home', 'scan', 'metrics', 'ai_chat'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selectedIndex = widget.initialIndex;
    _pandaHasBeenOpened = _selectedIndex == 3;
    _logScreenView(_selectedIndex);
    _refreshTodayFromHealth();
    // HealthKit does not push new values into Firestore. Keep the shared data
    // source current for both Home and Dashboard while the app is in use.
    _healthRefreshTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _refreshTodayFromHealth(),
    );
  }

  void _refreshTodayFromHealth() {
    if (FirebaseAuth.instance.currentUser == null) return;
    HealthService().syncToday().catchError((Object error) {
      debugPrint('MainNavigation: Apple Health refresh failed: $error');
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshTodayFromHealth();
  }

  @override
  void dispose() {
    _healthRefreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Switches to [index] and records the screen view. All tab changes route
  /// through here so analytics stay in sync with what's on screen.
  void _selectTab(int index) {
    if (index != _selectedIndex) _logScreenView(index);
    setState(() {
      _selectedIndex = index;
      if (index == 3) _pandaHasBeenOpened = true;
    });
  }

  void _logScreenView(int index) {
    if (index >= 0 && index < _screenNames.length) {
      AnalyticsService().logScreenView(_screenNames[index]);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Build only the active page to avoid eagerly initialising the camera
    // (ScanScreen) when the user hasn't navigated to it yet.
    Widget activePage;
    switch (_selectedIndex) {
      case 0:
        activePage = HomeScreen(onScanTap: () => _selectTab(1));
        break;
      case 1:
        activePage = const ScanScreen();
        break;
      case 2:
        activePage = DashboardScreen(onScanTap: () => _selectTab(1));
        break;
      case 3:
        // Panda is mounted separately below so its active conversation survives
        // switching bottom-navigation tabs.
        activePage = const SizedBox.shrink();
        break;
      default:
        activePage = HomeScreen(onScanTap: () => _selectTab(1));
    }

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: activePage),
          // Keep Panda in the tree after its first visit. Offstage preserves its
          // State (turns, question progress, and session data) while preventing
          // it from painting or receiving input on another tab. Other screens
          // still use the active-page lifecycle, so the camera is not retained.
          if (_pandaHasBeenOpened)
            Positioned.fill(
              child: Offstage(
                offstage: _selectedIndex != 3,
                child: const PandaScreen(),
              ),
            ),
          Positioned(
            bottom: 30,
            left: 24,
            right: 24,
            child: _buildFloatingNavBar(),
          ),
        ],
      ),
    );
  }

  Widget _buildFloatingNavBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 20,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _navItem(Icons.home_rounded, "Home", 0),
          _navItem(Icons.fingerprint, "Scan", 1),
          _navItem(Icons.bar_chart_rounded, "Metrics", 2),
          _navItem(Icons.auto_awesome_rounded, "AI Chat", 3),
        ],
      ),
    );
  }

  Widget _navItem(IconData icon, String label, int index) {
    bool isActive = _selectedIndex == index;
    return GestureDetector(
      onTap: () => _selectTab(index),
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: isActive ? primaryPurple : Colors.grey, size: 26),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: isActive ? primaryPurple : Colors.grey,
              fontSize: 10,
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}
