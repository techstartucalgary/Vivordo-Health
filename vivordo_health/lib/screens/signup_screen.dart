import 'package:flutter/material.dart';
import 'package:vivordo_health/src/services/auth_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:vivordo_health/src/services/user_service.dart';
import 'welcome_beta_screen.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final PageController _pageController = PageController();
  final _formKey = GlobalKey<FormState>();

  int _currentPage = 0;
  final int _totalQuestions = 9;
  bool _isLoading = false; // prevents double-tap triggering emailSignup twice

  static const accentPurple = Color(0xFF7B6EF6);
  static const bgColor      = Color(0xFFF2F2F7);
  static const textDark     = Color(0xFF1C1C1E);
  static const textGrey     = Color(0xFF8E8E93);

  // Centralized data map for future database integration
  final Map<String, dynamic> _userData = {'responses': <String, dynamic>{}};

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passController = TextEditingController();
  final TextEditingController _confirmPassController = TextEditingController();

  // For show/hide password
  bool _showPassword = false;
  bool _showConfirmPassword = false;


  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passController.dispose();
    _confirmPassController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  bool _isCurrentQuestionAnswered() {
    if (_currentPage == 0) return true; // Handled by Form validation
    if (_currentPage > _totalQuestions) return true; // Thank you slide

    String key = "q$_currentPage";
    return _userData['responses'].containsKey(key) &&
        _userData['responses'][key] != null;
  }

  Future<void> _nextPage() async {
    //TODO: Consider case where user signs up but exists before questionare is completed
    if (_currentPage == 0) {
      if (_formKey.currentState!.validate()) {
        if (_passController.text != _confirmPassController.text) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Passwords do not match"),
              backgroundColor: Colors.redAccent,
            ),
          );
          return;
        }
        // Guard against double-tap: if already loading, do nothing.
        // Without this, tapping the button twice calls createUserWithEmailAndPassword
        // twice with the same email — the second call returns email-already-in-use
        // even though the email is brand new.
        if (_isLoading) return;
        setState(() => _isLoading = true);
        final success = await AuthService.emailSignup(
          emailAddress: _emailController.text,
          password: _passController.text,
          displayName: _nameController.text,
          context: context,
        );
        if (mounted) setState(() => _isLoading = false);
        if (success && mounted) {
          _pageController.nextPage(
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeInOutCubicEmphasized,
          );
          return;
        }
      }
    } else {
      if (_currentPage == _totalQuestions) {
        _submitQuestionnaire().then((_) {
          if (mounted) {
            _pageController.nextPage(
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeInOutCubicEmphasized,
            );
          }
        });
      } else {
        _pageController.nextPage(
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOutCubicEmphasized, // Smoother animation
        );
      }
    }
  }

  Future<void> _submitQuestionnaire() async {
    setState(() => _isLoading = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await UserService.submitQuestionnaire(
          user: user,
          userdata: _userData,
        );
      }
    } catch (e) {
      debugPrint("Error submitting questionnaire: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Failed to submit assessment: $e"),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    double progress = _currentPage == 0 
        ? 0.5 
        : (_currentPage > _totalQuestions ? 1.0 : _currentPage / _totalQuestions);

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Column(
          children: [
          // ── Top bar ──────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _currentPage > 0
                      ? () => _pageController.previousPage(
                            duration: const Duration(milliseconds: 350),
                            curve: Curves.easeInOut,
                          )
                      : () => Navigator.pop(context),
                  child: Container(
                    width: 38, height: 38,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE5E5EA)),
                    ),
                    child: const Icon(Icons.arrow_back_ios_new_rounded, size: 15, color: textDark),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _currentPage == 0 ? 'Create Account' : 'Stress Assessment',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: textDark),
                      ),
                      Text(
                        _currentPage == 0
                            ? 'Set up your profile'
                            : _currentPage > _totalQuestions
                                ? 'All done!'
                                : 'Question $_currentPage of $_totalQuestions',
                        style: const TextStyle(fontSize: 12, color: textGrey),
                      ),
                    ],
                  ),
                ),
                // Step badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: accentPurple.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _currentPage == 0 ? 'Step 1' : '${(progress * 100).toInt()}%',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: accentPurple),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // ── Progress bar ─────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: const Color(0xFFE5E5EA),
                valueColor: const AlwaysStoppedAnimation<Color>(accentPurple),
                minHeight: 4,
              ),
            ),
          ),
          const SizedBox(height: 8),

          Expanded(
            child: PageView(
              controller: _pageController,
              onPageChanged: (page) => setState(() => _currentPage = page),
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _buildAccountSetup(), // Page 0
                // ── 9 corporate-professional stress questions ─────────────
                _buildMultipleChoiceQuestion(
                  q: 'q1',
                  emoji: '🏢',
                  title: 'How would you describe your work setup?',
                  options: ['Full-time office', 'Fully remote', 'Hybrid', 'Frequent travel', 'Varies a lot'],
                ),
                _buildSliderQuestion(
                  q: 'q2',
                  emoji: '🧠',
                  title: 'By end of day, how mentally drained do you feel?',
                  lowLabel: 'Barely drained', highLabel: 'Completely exhausted',
                ),
                _buildMultipleChoiceQuestion(
                  q: 'q3',
                  emoji: '⏰',
                  title: 'How many hours do you typically work per day?',
                  options: ['Under 7h', '7–9h', '9–11h', '11h+', 'It varies wildly'],
                ),
                _buildSliderQuestion(
                  q: 'q4',
                  emoji: '📵',
                  title: 'How well can you disconnect from work after hours?',
                  lowLabel: 'Always checking in', highLabel: 'Fully switched off',
                ),
                _buildMultipleChoiceQuestion(
                  q: 'q5',
                  emoji: '🍽️',
                  title: 'How often do you skip meals or eat at your desk?',
                  options: ['Never', 'Rarely', 'Sometimes', 'Often', 'Almost every day'],
                ),
                _buildSliderQuestion(
                  q: 'q6',
                  emoji: '📬',
                  title: 'How pressured do you feel to respond to messages outside work hours?',
                  lowLabel: 'Not at all', highLabel: 'Constant pressure',
                ),
                _buildMultipleChoiceQuestion(
                  q: 'q7',
                  emoji: '😴',
                  title: 'On a typical work night, how much sleep do you get?',
                  options: ['Under 5h', '5–6h', '6–7h', '7–8h', '8h+'],
                ),
                _buildSliderQuestion(
                  q: 'q8',
                  emoji: '💓',
                  title: 'How often do deadlines or meetings cause you anxiety?',
                  lowLabel: 'Very rarely', highLabel: 'Nearly every day',
                ),
                _buildMultipleChoiceQuestion(
                  q: 'q9',
                  emoji: '📋',
                  title: 'How would you describe your current workload?',
                  options: ['Very manageable', 'Manageable', 'Heavy', 'Very heavy', 'Overwhelming'],
                ),
                _buildThankYouSlide(),
              ],
            ),
          ),

          // ── Action button ───────────────────────────────────────────────
          if (_currentPage <= _totalQuestions)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: (_isCurrentQuestionAnswered() && !_isLoading) ? _nextPage : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accentPurple,
                    disabledBackgroundColor: const Color(0xFFD1CEFF),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          height: 20, width: 20,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : Text(
                          _currentPage == 0 ? 'Create Account' : 'Next →',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Widgets ──────────────────────────────────────────────────────

  Widget _buildAccountSetup() {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Your details',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: textDark, letterSpacing: -0.3)),
            const SizedBox(height: 4),
            const Text('Takes less than a minute', style: TextStyle(fontSize: 13, color: textGrey)),
            const SizedBox(height: 24),
            _buildField('Full Name', _nameController, Icons.person_outline_rounded, 'First Last'),
            _buildField('Work Email', _emailController, Icons.mail_outline_rounded, 'you@company.com', keyboardType: TextInputType.emailAddress),
            _buildField('Password', _passController, Icons.lock_outline_rounded, 'Min 6 characters', isPass: true),
            _buildField('Confirm Password', _confirmPassController, Icons.lock_outline_rounded, 'Repeat password', isPass: true, isConfirm: true),
            const SizedBox(height: 4),
            // Security notice
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: accentPurple.withOpacity(0.06),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: accentPurple.withOpacity(0.18)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.shield_outlined, size: 16, color: accentPurple),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Your data is encrypted and never shared with third parties.',
                      style: TextStyle(fontSize: 12, color: textGrey, height: 1.4),
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

  Widget _buildField(
    String label,
    TextEditingController ctrl,
    IconData icon,
    String hint, {
    bool isPass = false,
    bool isConfirm = false,
    TextInputType keyboardType = TextInputType.text,
  }) {
    final isVisible = isConfirm ? _showConfirmPassword : _showPassword;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                  color: textGrey, letterSpacing: 0.3)),
          const SizedBox(height: 6),
          TextFormField(
            controller: ctrl,
            obscureText: isPass && !isVisible,
            keyboardType: keyboardType,
            style: const TextStyle(fontSize: 15, color: textDark),
            decoration: InputDecoration(
              prefixIcon: Icon(icon, color: const Color(0xFFC7C7CC), size: 18),
              hintText: hint,
              hintStyle: const TextStyle(color: Color(0xFFC7C7CC), fontSize: 14),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFFE5E5EA)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFFE5E5EA)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: accentPurple, width: 1.5),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFFFF3B30)),
              ),
              suffixIcon: isPass
                  ? IconButton(
                      icon: Icon(
                        isVisible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                        color: const Color(0xFFC7C7CC), size: 18,
                      ),
                      onPressed: () => setState(() {
                        if (isConfirm) {
                          _showConfirmPassword = !_showConfirmPassword;
                        } else {
                          _showPassword = !_showPassword;
                        }
                      }),
                    )
                  : null,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Required';
              if (label == 'Work Email' &&
                  !RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(v)) {
                return 'Invalid email';
              }
              if (isPass && v.length < 6) return 'Min 6 characters';
              return null;
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSliderQuestion({
    required String q,
    required String emoji,
    required String title,
    required String lowLabel,
    required String highLabel,
  }) {
    final double? val = _userData['responses'][q];
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // emoji badge
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: accentPurple.withOpacity(0.08),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(emoji, style: const TextStyle(fontSize: 30)),
          ),
          const SizedBox(height: 20),
          Text(title,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold,
                  color: textDark, height: 1.35, letterSpacing: -0.3)),
          const SizedBox(height: 8),
          const Text('Slide to answer', style: TextStyle(fontSize: 13, color: textGrey)),
          const SizedBox(height: 40),
          // Current value bubble
          Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 72, height: 72,
              decoration: BoxDecoration(
                color: val == null ? const Color(0xFFE5E5EA) : accentPurple,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  val == null ? '?' : val.toInt().toString(),
                  style: TextStyle(
                    fontSize: 26, fontWeight: FontWeight.bold,
                    color: val == null ? textGrey : Colors.white,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: accentPurple,
              inactiveTrackColor: const Color(0xFFE5E5EA),
              thumbColor: accentPurple,
              overlayColor: accentPurple.withOpacity(0.12),
              trackHeight: 6,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12),
            ),
            child: Slider(
              value: val ?? 5.0,
              min: 1, max: 10, divisions: 9,
              onChanged: (v) => setState(() => _userData['responses'][q] = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(lowLabel, style: const TextStyle(fontSize: 11, color: textGrey)),
                Text(highLabel, style: const TextStyle(fontSize: 11, color: textGrey)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMultipleChoiceQuestion({
    required String q,
    required String emoji,
    required String title,
    required List<String> options,
  }) {
    final selected = _userData['responses'][q];
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: accentPurple.withOpacity(0.08),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(emoji, style: const TextStyle(fontSize: 30)),
          ),
          const SizedBox(height: 20),
          Text(title,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold,
                  color: textDark, height: 1.35, letterSpacing: -0.3)),
          const SizedBox(height: 8),
          const Text('Choose one', style: TextStyle(fontSize: 13, color: textGrey)),
          const SizedBox(height: 24),
          ...options.map((opt) {
            final isSelected = selected == opt;
            return GestureDetector(
              onTap: () => setState(() => _userData['responses'][q] = opt),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                decoration: BoxDecoration(
                  color: isSelected ? accentPurple : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isSelected ? accentPurple : const Color(0xFFE5E5EA),
                    width: isSelected ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        opt,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: isSelected ? Colors.white : textDark,
                        ),
                      ),
                    ),
                    if (isSelected)
                      const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildThankYouSlide() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(
          Icons.check_circle_outline,
          size: 80,
          color: Color(0xFF7C69EF),
        ),
        const SizedBox(height: 20),
        const Text(
          "Thank You!",
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: Color(0xFF2D3142),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          "Your profile is all set up.\nLet's get started on your health journey.",
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16, color: Colors.grey, height: 1.5),
        ),
        const SizedBox(height: 40),
        ElevatedButton(
          onPressed: () {
            Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF7C69EF),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          child: const Text("Go to Dashboard", style: TextStyle(fontSize: 16)),
        ),
      ],
    );
  }
}