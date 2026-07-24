import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'login_screen.dart';

/// Shown by AuthGate whenever a signed-in user's email isn't verified yet.
/// Blocks access to the rest of the app — this is what actually prevents
/// account creation with a fake/unreachable address, since Firebase has no
/// way to confirm deliverability except making the user open a real link.
class EmailVerificationScreen extends StatefulWidget {
  // When provided (e.g. mid-signup, before the stress questionnaire), this
  // runs instead of the default "go to AuthGate" redirect — lets a caller
  // resume its own flow rather than always landing in the main app.
  final VoidCallback? onVerified;

  const EmailVerificationScreen({super.key, this.onVerified});

  @override
  State<EmailVerificationScreen> createState() => _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  static const Color accentPurple = Color(0xFF7B6EF6);
  static const Color textDark = Color(0xFF1C1C1E);
  static const Color textGrey = Color(0xFF8E8E93);

  Timer? _pollTimer;
  Timer? _cooldownTimer;
  int _resendCooldown = 0;
  bool _sending = false;
  bool _checking = false;
  // The background poll and the manual "I've verified" tap can both be
  // mid-flight (awaiting reload()) at once. Cancelling _pollTimer only
  // stops *future* ticks, not a check already in progress, so without this
  // guard both can detect emailVerified==true and both fire the verified
  // action — the second call pops again after this screen is already gone,
  // which removes the *next* route (the caller) instead.
  bool _verifiedHandled = false;

  @override
  void initState() {
    super.initState();
    // Check right away too — covers the case where verification already
    // happened (e.g. in another tab) before this screen even appeared,
    // instead of making that case wait for the first 4s tick.
    _checkVerified(silent: true);
    // Poll in the background so verifying via the emailed link (in another
    // tab/app) advances this screen automatically without the user having
    // to come back and tap anything.
    _pollTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _checkVerified(silent: true),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _cooldownTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkVerified({bool silent = false}) async {
    if (_verifiedHandled) return;
    if (!silent) setState(() => _checking = true);
    try {
      await FirebaseAuth.instance.currentUser?.reload();
      if (_verifiedHandled) return; // another in-flight check already won the race
      final user = FirebaseAuth.instance.currentUser;
      if (user != null && user.emailVerified) {
        _verifiedHandled = true;
        _pollTimer?.cancel();
        if (mounted) {
          if (widget.onVerified != null) {
            widget.onVerified!();
          } else {
            Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
          }
        }
        return;
      }
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Not verified yet — check your inbox for the link."),
          ),
        );
      }
    } finally {
      if (!silent && mounted) setState(() => _checking = false);
    }
  }

  Future<void> _resend() async {
    if (_resendCooldown > 0 || _sending) return;
    setState(() => _sending = true);
    try {
      await FirebaseAuth.instance.currentUser?.sendEmailVerification();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Verification email sent.')),
        );
      }
      _startCooldown();
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Failed to resend email.')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _startCooldown() {
    setState(() => _resendCooldown = 60);
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_resendCooldown <= 1) {
        timer.cancel();
        setState(() => _resendCooldown = 0);
      } else {
        setState(() => _resendCooldown--);
      }
    });
  }

  Future<void> _logout() async {
    _pollTimer?.cancel();
    _cooldownTimer?.cancel();
    await FirebaseAuth.instance.signOut();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = FirebaseAuth.instance.currentUser?.email ?? 'your email';
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: accentPurple.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.mark_email_unread_rounded,
                  color: accentPurple,
                  size: 40,
                ),
              ),
              const SizedBox(height: 28),
              const Text(
                'Verify your email',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: textDark,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'We sent a verification link to $email. Open it to activate '
                'your account — this page will continue automatically once '
                "you're verified.",
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: textGrey, height: 1.5),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _checking ? null : () => _checkVerified(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accentPurple,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  child: _checking
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Text(
                          "I've verified",
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                ),
              ),
              const SizedBox(height: 14),
              TextButton(
                onPressed: (_resendCooldown > 0 || _sending) ? null : _resend,
                child: Text(
                  _resendCooldown > 0
                      ? 'Resend available in ${_resendCooldown}s'
                      : 'Resend verification email',
                  style: const TextStyle(color: accentPurple, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _logout,
                child: const Text(
                  'Log out',
                  style: TextStyle(color: textGrey),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
