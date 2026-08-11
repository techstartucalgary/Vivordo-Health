import 'package:flutter/material.dart';
import 'home_screen.dart';
import 'scan_screen.dart';
import 'dashboard_screen.dart';
import 'panda_screen.dart';

class MainNavigationScreen extends StatefulWidget {
  final int initialIndex;
  const MainNavigationScreen({super.key, this.initialIndex = 0});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  late int _selectedIndex;
  final Color primaryPurple = const Color(0xFF7B6EF6);

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialIndex;
  }

  @override
  Widget build(BuildContext context) {
    // Build only the active page to avoid eagerly initialising the camera
    // (ScanScreen) when the user hasn't navigated to it yet.
    Widget activePage;
    switch (_selectedIndex) {
      case 0:
        activePage = HomeScreen(onScanTap: () => setState(() => _selectedIndex = 1));
        break;
      case 1:
        activePage = const ScanScreen();
        break;
      case 2:
        activePage = DashboardScreen(onScanTap: () => setState(() => _selectedIndex = 1));
        break;
      case 3:
        activePage = const PandaScreen();
        break;
      default:
        activePage = HomeScreen(onScanTap: () => setState(() => _selectedIndex = 1));
    }

    return Scaffold(
      body: Stack(
        children: [
          activePage,
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
      onTap: () => setState(() => _selectedIndex = index),
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
