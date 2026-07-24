

import 'package:flutter/material.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    this.onFinished,
  });

  /// Called when the user taps Skip or Get Started.
  ///
  /// Wire this up from the parent screen to mark onboarding as seen and route
  /// the user to the main app.
  final Future<void> Function()? onFinished;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool _isFinishing = false;

  final List<_OnboardingPageData> _pages = const [
    _OnboardingPageData(
      icon: Icons.favorite_rounded,
      title: 'Welcome to Vivordo',
      description:
          'Vivordo helps you track your health signals, scans, and wellness patterns in one simple place.',
    ),
    _OnboardingPageData(
      icon: Icons.camera_alt_rounded,
      title: 'Complete health scans',
      description:
          'Use guided scans to collect readings like heart rate and other wellness metrics over time.',
    ),
    _OnboardingPageData(
      icon: Icons.insights_rounded,
      title: 'Understand your trends',
      description:
          'Your dashboard shows recent results and long-term patterns so you can see and understand what is changing.',
    ),
    _OnboardingPageData(
      icon: Icons.edit_note_rounded,
      title: 'Personal AI Assistant',
      description:
          'Ask questions about your health data and receive personalized wellness insights.',
    ),
    _OnboardingPageData(
      icon: Icons.lock_rounded,
      title: 'You stay in control',
      description:
          'Manage permissions and connected services from your profile whenever you need to.',
    ),
  ];

  bool get _isLastPage => _currentPage == _pages.length - 1;

  Future<void> _finishOnboarding() async {
    if (_isFinishing) return;

    setState(() {
      _isFinishing = true;
    });

    try {
      await widget.onFinished?.call();
    } finally {
      if (mounted) {
        setState(() {
          _isFinishing = false;
        });
      }
    }
  }

  void _goToNextPage() {
    if (_isLastPage) {
      _finishOnboarding();
      return;
    }

    _pageController.nextPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _isFinishing ? null : _finishOnboarding,
                  child: const Text('Skip'),
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: _pages.length,
                  onPageChanged: (index) {
                    setState(() {
                      _currentPage = index;
                    });
                  },
                  itemBuilder: (context, index) {
                    final page = _pages[index];
                    return _OnboardingPage(
                      data: page,
                      color: colorScheme.primary,
                    );
                  },
                ),
              ),
              _PageDots(
                count: _pages.length,
                currentIndex: _currentPage,
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton(
                  onPressed: _isFinishing ? null : _goToNextPage,
                  child: _isFinishing
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        )
                      : Text(_isLastPage ? 'Get Started' : 'Next'),
                ),
              ),
              const SizedBox(height: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnboardingPage extends StatelessWidget {
  const _OnboardingPage({
    required this.data,
    required this.color,
  });

  final _OnboardingPageData data;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 132,
          height: 132,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(
            data.icon,
            size: 64,
            color: color,
          ),
        ),
        const SizedBox(height: 44),
        Text(
          data.title,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          data.description,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(
            height: 1.45,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _PageDots extends StatelessWidget {
  const _PageDots({
    required this.count,
    required this.currentIndex,
  });

  final int count;
  final int currentIndex;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (index) {
        final isActive = index == currentIndex;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          width: isActive ? 24 : 8,
          height: 8,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: isActive
                ? colorScheme.primary
                : colorScheme.outlineVariant,
          ),
        );
      }),
    );
  }
}

class _OnboardingPageData {
  const _OnboardingPageData({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;
}