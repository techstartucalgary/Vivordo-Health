import 'package:flutter/material.dart';
import 'signup_screen.dart';

class WelcomeBetaScreen extends StatefulWidget {
  const WelcomeBetaScreen({super.key});

  @override
  State<WelcomeBetaScreen> createState() => _WelcomeBetaScreenState();
}

class _WelcomeBetaScreenState extends State<WelcomeBetaScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeIn;
  late Animation<Offset> _slideUp;

  static const accentPurple = Color(0xFF7B6EF6);
  static const textDark     = Color(0xFF1C1C1E);
  static const textGrey     = Color(0xFF8E8E93);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _fadeIn  = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slideUp = Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero)
        .animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeIn,
          child: SlideTransition(
            position: _slideUp,
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 64),

                  // ── Badge ──────────────────────────────────────────────────
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: accentPurple.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: accentPurple.withOpacity(0.25)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.science_rounded, size: 13, color: accentPurple),
                        SizedBox(width: 6),
                        Text(
                          'BETA TESTER',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: accentPurple,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),

                  // ── Hero emoji + title ─────────────────────────────────────
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      color: accentPurple.withOpacity(0.08),
                      shape: BoxShape.circle,
                    ),
                    child: const Center(
                      child: Text('🎉', style: TextStyle(fontSize: 48)),
                    ),
                  ),
                  const SizedBox(height: 24),

                  const Text(
                    'Welcome to Vivordo!',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: textDark,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'You\'re one of our first users 🌟\nHelp us shape the future of health tech.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 15, color: textGrey, height: 1.6),
                  ),

                  const SizedBox(height: 36),

                  // ── What to expect card ────────────────────────────────────
                  _infoCard(
                    icon: Icons.favorite_rounded,
                    iconColor: const Color(0xFFFF6B6B),
                    title: 'What is Vivordo?',
                    body:
                        'Vivordo is your personal health companion. It tracks stress, heart rate, sleep, activity, and mood — and gives you AI-powered insights to help you live better.',
                  ),
                  const SizedBox(height: 14),

                  // ── Beta card ──────────────────────────────────────────────
                  _infoCard(
                    icon: Icons.bug_report_rounded,
                    iconColor: const Color(0xFFFF9500),
                    title: 'You\'re a beta tester 🧪',
                    body:
                        'This is an early version of Vivordo. Features may be incomplete and things might break — that\'s totally okay! Your feedback helps us fix and improve everything.',
                  ),
                  const SizedBox(height: 14),

                  // ── Report issues card ─────────────────────────────────────
                  _infoCard(
                    icon: Icons.chat_bubble_outline_rounded,
                    iconColor: accentPurple,
                    title: 'Spotted a bug? Tell us!',
                    body:
                        'If anything looks off, crashes, or doesn\'t work as expected, please let us know. You can reach us at support@vivordo.com or through the Profile page.',
                  ),
                  const SizedBox(height: 32),

                  // ── Tips row ───────────────────────────────────────────────
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: accentPurple.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: accentPurple.withOpacity(0.15)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '✨  Tips to get started',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: accentPurple,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _tipRow('👆', 'Tap Scan to measure your heart rate'),
                        _tipRow('📊', 'Check Metrics for your health trends'),
                        _tipRow('🔗', 'Connect Apple Health in Profile for richer data'),
                        _tipRow('🤖', 'Chat with the AI for personalised insights'),
                      ],
                    ),
                  ),

                  const SizedBox(height: 36),

                  // ── CTA button ─────────────────────────────────────────────
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(context).pushReplacement(
                          MaterialPageRoute(builder: (_) => const SignupScreen()),
                        ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: accentPurple,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      child: const Text("Let's go  →"),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Thank you for being part of the journey 💜',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: textGrey),
                  ),
                  const SizedBox(height: 48),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _infoCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String body,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE5E5EA)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 20, color: iconColor),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: textDark,
                    )),
                const SizedBox(height: 5),
                Text(body,
                    style: const TextStyle(
                      fontSize: 13,
                      color: textGrey,
                      height: 1.5,
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tipRow(String emoji, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 15)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 13, color: textGrey, height: 1.4)),
          ),
        ],
      ),
    );
  }
}
