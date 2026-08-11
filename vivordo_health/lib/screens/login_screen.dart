import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:vivordo_health/src/services/auth_service.dart';
import 'main_navigation.dart';
import 'signup_screen.dart';
import 'welcome_beta_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const Color accentPurple = Color(0xFF7B6EF6);
  static const Color textDark = Color(0xFF1C1C1E);
  static const Color textGrey = Color(0xFF8E8E93);

  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final email = _emailCtrl.text.trim();
    final pass = _passCtrl.text;
    if (email.isEmpty || pass.isEmpty) return;
    setState(() => _isLoading = true);
    final success = await AuthService.emailLogin(
      emailAddress: email,
      password: pass,
      context: context,
    );
    if (!mounted) return;
    setState(() => _isLoading = false);
    if (success) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const MainNavigationScreen()),
      );
    }
  }

  void _showResetPasswordSheet() {
    final resetEmailCtrl = TextEditingController(text: _emailCtrl.text.trim());
    bool sending = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 28,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 32,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Reset Password',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: textDark),
              ),
              const SizedBox(height: 6),
              const Text(
                "Enter your email and we'll send you a link to reset your password.",
                style: TextStyle(fontSize: 14, color: textGrey, height: 1.5),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: resetEmailCtrl,
                keyboardType: TextInputType.emailAddress,
                autofocus: true,
                decoration: _inputDecoration(
                  hintText: 'you@example.com',
                  icon: Icons.mail_outline_rounded,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: sending
                      ? null
                      : () async {
                          if (resetEmailCtrl.text.trim().isEmpty) return;
                          setSheetState(() => sending = true);
                          final ok = await AuthService.sendPasswordReset(
                            emailAddress: resetEmailCtrl.text,
                            context: ctx,
                          );
                          if (!ctx.mounted) return;
                          Navigator.pop(ctx);
                          if (ok) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Reset link sent to ${resetEmailCtrl.text.trim()}',
                                ),
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            );
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accentPurple,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  child: sending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Text(
                          'Send Reset Link',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          // ── Purple decorative orbs ──────────────────────────────────────
          Positioned(
            top: -80,
            right: -80,
            child: _Orb(size: 260, color: accentPurple.withOpacity(0.12)),
          ),
          Positioned(
            top: 60,
            right: -30,
            child: _Orb(size: 120, color: accentPurple.withOpacity(0.08)),
          ),
          Positioned(
            bottom: -100,
            left: -80,
            child: _Orb(size: 300, color: accentPurple.withOpacity(0.10)),
          ),
          Positioned(
            bottom: 160,
            left: -30,
            child: _Orb(size: 100, color: accentPurple.withOpacity(0.07)),
          ),

          // ── Content ─────────────────────────────────────────────────────
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Logo + wordmark
                    Center(
                      child: Column(
                        children: [
                          Image.asset(
                            'assets/finalLogo.png',
                            width: 75,
                            height: 75,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Vivordo',
                            style: TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                              color: textDark,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'See your stress. Find your balance.',
                            style: TextStyle(fontSize: 14, color: textGrey),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 48),

                    // ── Form ────────────────────────────────────────────────
                    const Text(
                      'Welcome back',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: textDark,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Sign in to your account',
                      style: TextStyle(fontSize: 14, color: textGrey),
                    ),
                    const SizedBox(height: 28),

                    // Email
                    _FieldLabel('Email'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      style: const TextStyle(fontSize: 15, color: textDark),
                      decoration: _inputDecoration(
                        hintText: 'you@example.com',
                        icon: Icons.mail_outline_rounded,
                      ),
                    ),
                    const SizedBox(height: 18),

                    // Password
                    _FieldLabel('Password'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _passCtrl,
                      obscureText: _obscurePassword,
                      style: const TextStyle(fontSize: 15, color: textDark),
                      onSubmitted: (_) => _login(),
                      decoration: _inputDecoration(
                        hintText: '••••••••',
                        icon: Icons.lock_outline_rounded,
                      ).copyWith(
                        suffixIcon: GestureDetector(
                          onTap: () => setState(() => _obscurePassword = !_obscurePassword),
                          child: Icon(
                            _obscurePassword
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            color: textGrey,
                            size: 20,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 10),

                    // Forgot password
                    Align(
                      alignment: Alignment.centerRight,
                      child: GestureDetector(
                        onTap: _showResetPasswordSheet,
                        child: const Text(
                          'Forgot password?',
                          style: TextStyle(
                            color: accentPurple,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 28),

                    // Sign in button
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _login,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: accentPurple,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 0,
                        ),
                        child: _isLoading
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2.5,
                                ),
                              )
                            : const Text(
                                'Sign In',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                              ),
                      ),
                    ),

                    const SizedBox(height: 32),

                    // Divider
                    Row(
                      children: [
                        Expanded(child: Divider(color: Colors.grey.shade200)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Text(
                            'New here?',
                            style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                          ),
                        ),
                        Expanded(child: Divider(color: Colors.grey.shade200)),
                      ],
                    ),

                    const SizedBox(height: 24),

                    // Create account
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: OutlinedButton(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const WelcomeBetaScreen()),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: accentPurple,
                          side: BorderSide(color: accentPurple.withOpacity(0.4)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: const Text(
                          'Create Account',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),

                    const SizedBox(height: 32),

                    // Privacy note
                    Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.lock_outline_rounded, size: 13, color: Colors.grey.shade400),
                          const SizedBox(width: 5),
                          Text(
                            'All data is encrypted and securely stored.',
                            style: TextStyle(color: Colors.grey.shade400, fontSize: 11),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration({
    required String hintText,
    required IconData icon,
  }) {
    return InputDecoration(
      hintText: hintText,
      hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
      prefixIcon: Icon(icon, color: Colors.grey.shade400, size: 20),
      filled: true,
      fillColor: const Color(0xFFF7F7FB),
      contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.grey.shade100),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: accentPurple, width: 1.5),
      ),
    );
  }
}

// ── Helper widgets ────────────────────────────────────────────────────────────

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Color(0xFF1C1C1E),
      ),
    );
  }
}

class _Orb extends StatelessWidget {
  final double size;
  final Color color;
  const _Orb({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
