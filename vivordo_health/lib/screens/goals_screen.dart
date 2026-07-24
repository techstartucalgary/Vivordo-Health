import 'dart:async';
import 'package:flutter/material.dart';

enum ScanState { idle, scanning, complete }

class GoalsScreen extends StatefulWidget {
  const GoalsScreen({super.key});

  @override
  State<GoalsScreen> createState() => _GoalsScreenState();
}

class _GoalsScreenState extends State<GoalsScreen>
    with TickerProviderStateMixin {
  ScanState _scanState = ScanState.idle;
  double _progress = 0;
  Timer? _timer;

  late AnimationController _pulseController;
  late AnimationController _spinController;
  late Animation<double> _pulseAnimation;

  static const Color accentPurple = Color(0xFF7B6EF6);
  static const Color bgColor = Color(0xFFF2F2F7);
  static const Color cardWhite = Colors.white;
  static const Color textDark = Color(0xFF1C1C1E);
  static const Color textGrey = Color(0xFF8E8E93);
  static const Color greenColor = Color(0xFF34C759);
  static const Color redColor = Color(0xFFFF3B30);

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }


  @override
  void dispose() {
    _pulseController.dispose();
    _spinController.dispose();
    _timer?.cancel();
    super.dispose();
  }

  void _startScan() {
    setState(() {
      _scanState = ScanState.scanning;
      _progress = 0;
    });
    _spinController.repeat();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      setState(() {
        _progress += 1.7;
        if (_progress >= 100) {
          _progress = 100;
          timer.cancel();
          _spinController.stop();
          _scanState = ScanState.complete;
        }
      });
    });
  }

  void _reset() {
    setState(() {
      _scanState = ScanState.idle;
      _progress = 0;
    });
    _pulseController.repeat(reverse: true);
  }

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
                'Stress Scan',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: textDark,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '60-second physiological assessment',
                style: TextStyle(fontSize: 14, color: textGrey),
              ),
              const SizedBox(height: 32),
              if (_scanState == ScanState.idle) _buildIdleState(),
              if (_scanState == ScanState.scanning) _buildScanningState(),
              if (_scanState == ScanState.complete) _buildCompleteState(),
              const SizedBox(height: 120),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIdleState() {
    return Column(
      children: [
        const SizedBox(height: 32),
        Center(
          child: SizedBox(
            width: 160,
            height: 160,
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (_, __) => Transform.scale(
                    scale: _pulseAnimation.value,
                    child: Container(
                      width: 160,
                      height: 160,
                      decoration: BoxDecoration(
                        color: accentPurple.withOpacity(0.08),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
                Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    color: accentPurple.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.fingerprint,
                    size: 70,
                    color: accentPurple,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 32),
        const Text(
          'Place your finger on the camera',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: textDark,
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Cover the rear camera lens gently with your fingertip. Stay still for 60 seconds.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: textGrey, height: 1.5),
        ),
        const SizedBox(height: 36),
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton(
            onPressed: _startScan,
            style: ElevatedButton.styleFrom(
              backgroundColor: accentPurple,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              elevation: 0,
            ),
            child: const Text(
              'Start Scan',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildScanningState() {
    return Column(
      children: [
        const SizedBox(height: 32),
        Center(
          child: SizedBox(
            width: 160,
            height: 160,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    color: accentPurple.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                ),
                RotationTransition(
                  turns: _spinController,
                  child: SizedBox(
                    width: 150,
                    height: 150,
                    child: CircularProgressIndicator(
                      strokeWidth: 4,
                      backgroundColor: accentPurple.withOpacity(0.2),
                      valueColor:
                          const AlwaysStoppedAnimation<Color>(accentPurple),
                    ),
                  ),
                ),
                AnimatedBuilder(
                  animation: _pulseController,
                  builder: (_, __) => Opacity(
                    opacity: 0.6 + 0.4 * _pulseController.value,
                    child: const Icon(
                      Icons.show_chart_rounded,
                      size: 52,
                      color: accentPurple,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 32),
        const Text(
          'Scanning...',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: textDark,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Keep your finger still on the camera',
          style: TextStyle(fontSize: 14, color: textGrey),
        ),
        const SizedBox(height: 24),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: LinearProgressIndicator(
            value: _progress / 100,
            minHeight: 12,
            backgroundColor: accentPurple.withOpacity(0.15),
            valueColor: const AlwaysStoppedAnimation<Color>(accentPurple),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${_progress.clamp(0, 100).round()}% complete',
          style: const TextStyle(fontSize: 12, color: textGrey),
        ),
      ],
    );
  }

  Widget _buildCompleteState() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding:
              const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
          decoration: BoxDecoration(
            color: accentPurple,
            borderRadius: BorderRadius.circular(24),
          ),
          child: const Column(
            children: [
              Text(
                'Your Stress Score',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              SizedBox(height: 8),
              Text(
                '38',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 60,
                  fontWeight: FontWeight.bold,
                  height: 1.0,
                ),
              ),
              SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _GreenDot(),
                  SizedBox(width: 6),
                  Text(
                    'Low Stress',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _buildMetricCard(
                  Icons.favorite_rounded, 'Heart Rate', '68 bpm', redColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildMetricCard(
                  Icons.show_chart_rounded, 'HRV', '52 ms', greenColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildMetricCard(
                  Icons.psychology_outlined, 'Strain', 'Low', accentPurple),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: accentPurple.withOpacity(0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: accentPurple.withOpacity(0.2)),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AI Insight',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: textDark,
                ),
              ),
              SizedBox(height: 6),
              Text(
                'Your nervous system is well-recovered. This is a great time for focused work or meaningful conversations.',
                style: TextStyle(fontSize: 13, color: textGrey, height: 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: OutlinedButton(
            onPressed: _reset,
            style: OutlinedButton.styleFrom(
              foregroundColor: textDark,
              side: const BorderSide(color: Color(0xFFE5E5EA)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            child: const Text(
              'Scan Again',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMetricCard(
      IconData icon, String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: cardWhite,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E5EA)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: textDark,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 10, color: textGrey),
          ),
        ],
      ),
    );
  }
}

class _GreenDot extends StatelessWidget {
  const _GreenDot();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: const BoxDecoration(
        color: Color(0xFF34C759),
        shape: BoxShape.circle,
      ),
    );
  }
}
