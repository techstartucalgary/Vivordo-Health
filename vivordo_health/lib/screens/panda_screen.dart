import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
// ignore: avoid_web_libraries_in_flutter
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;
import '../src/services/ai_service.dart';
import '../src/services/ai_service_factory.dart';
import '../src/services/gemini_service.dart' show GeminiService;
import '../src/services/recommendation_engine.dart';
import '../src/services/insight_service.dart';
import '../src/models/insights.dart';
import '../src/services/panda_recommendations.dart';
import '../src/services/calendar_service.dart';
import 'package:flutter_svg/flutter_svg.dart';

// Robot mascot inlined as a string so it renders via SvgPicture.string —
// bypasses the asset bundle + web service-worker cache that was serving a
// blank/stale asset on Flutter Web. Gradient ("3D") version; SVG <filter>
// elements were removed (flutter_svg can't render them — they were what
// blanked it before). viewBox is cropped tight to the robot so it fills.
const String _kRobotSvg =
    r'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="288 35 648 900" fill="none">
<defs>
<radialGradient id="shellHead" cx="0" cy="0" r="1" gradientUnits="userSpaceOnUse" gradientTransform="translate(580 182) rotate(70) scale(410 300)">
<stop offset="0" stop-color="#FBFAFF"/><stop offset=".20" stop-color="#DCD8FF"/><stop offset=".52" stop-color="#7B6EF6"/><stop offset="1" stop-color="#4636BE"/>
</radialGradient>
<radialGradient id="shellBody" cx="0" cy="0" r="1" gradientUnits="userSpaceOnUse" gradientTransform="translate(545 505) rotate(67) scale(310 280)">
<stop offset="0" stop-color="#F6F3FF"/><stop offset=".22" stop-color="#BCB3FF"/><stop offset=".58" stop-color="#7B6EF6"/><stop offset="1" stop-color="#4B3BC9"/>
</radialGradient>
<linearGradient id="edgeShade" x1="363" y1="178" x2="850" y2="462" gradientUnits="userSpaceOnUse">
<stop stop-color="#FFFFFF" stop-opacity=".70"/><stop offset=".45" stop-color="#FFFFFF" stop-opacity=".12"/><stop offset="1" stop-color="#2A216F" stop-opacity=".36"/>
</linearGradient>
<linearGradient id="glass" x1="455" y1="214" x2="810" y2="426" gradientUnits="userSpaceOnUse">
<stop stop-color="#151A32"/><stop offset=".55" stop-color="#030611"/><stop offset="1" stop-color="#121423"/>
</linearGradient>
<linearGradient id="glassShine" x1="655" y1="214" x2="815" y2="370" gradientUnits="userSpaceOnUse">
<stop stop-color="#FFFFFF" stop-opacity=".35"/><stop offset=".42" stop-color="#FFFFFF" stop-opacity=".10"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
</linearGradient>
<linearGradient id="purpleLight" x1="0" y1="0" x2="1" y2="1">
<stop stop-color="#FFFFFF"/><stop offset=".28" stop-color="#D9CFFF"/><stop offset=".63" stop-color="#A178FF"/><stop offset="1" stop-color="#7B6EF6"/>
</linearGradient>
<radialGradient id="hoverGlow" cx="0" cy="0" r="1" gradientUnits="userSpaceOnUse" gradientTransform="translate(612 817) scale(280 82)">
<stop stop-color="#B8ADFF" stop-opacity=".62"/><stop offset=".48" stop-color="#7B6EF6" stop-opacity=".22"/><stop offset="1" stop-color="#7B6EF6" stop-opacity="0"/>
</radialGradient>
<radialGradient id="armGrad" cx="0" cy="0" r="1" gradientUnits="userSpaceOnUse" gradientTransform="translate(360 540) rotate(55) scale(120 88)">
<stop stop-color="#FFFFFF"/><stop offset=".25" stop-color="#CBC5FF"/><stop offset=".68" stop-color="#7B6EF6"/><stop offset="1" stop-color="#4D3DCC"/>
</radialGradient>
<radialGradient id="earGrad" cx="0" cy="0" r="1" gradientUnits="userSpaceOnUse" gradientTransform="translate(370 260) rotate(82) scale(112 82)">
<stop stop-color="#FFFFFF"/><stop offset=".30" stop-color="#C9C1FF"/><stop offset=".72" stop-color="#7B6EF6"/><stop offset="1" stop-color="#4535BB"/>
</radialGradient>
</defs>
<ellipse cx="610" cy="842" rx="300" ry="82" fill="url(#hoverGlow)"/>
<ellipse cx="610" cy="812" rx="155" ry="29" stroke="#EEEAFE" stroke-width="8" opacity=".75"/>
<ellipse cx="610" cy="812" rx="108" ry="18" stroke="#A79EFF" stroke-width="4" opacity=".55"/>
<g opacity=".95">
<path d="M618 158V78" stroke="#8F82FF" stroke-width="8" stroke-linecap="round"/>
<path d="M430 270l-23-80" stroke="#8F82FF" stroke-width="8" stroke-linecap="round"/>
<path d="M812 275l28-76" stroke="#8F82FF" stroke-width="8" stroke-linecap="round"/>
<circle cx="618" cy="66" r="21" fill="url(#purpleLight)"/><circle cx="401" cy="176" r="18" fill="url(#purpleLight)"/><circle cx="845" cy="185" r="18" fill="url(#purpleLight)"/>
</g>
<ellipse cx="374" cy="318" rx="57" ry="92" fill="url(#earGrad)"/>
<ellipse cx="371" cy="318" rx="34" ry="59" fill="#111326"/>
<ellipse cx="371" cy="318" rx="25" ry="47" stroke="url(#purpleLight)" stroke-width="9"/>
<ellipse cx="351" cy="258" rx="15" ry="20" fill="#FFFFFF" opacity=".44"/>
<ellipse cx="866" cy="322" rx="45" ry="86" fill="url(#earGrad)" opacity=".88"/>
<ellipse cx="870" cy="322" rx="25" ry="53" fill="#111326" opacity=".72"/>
<ellipse cx="870" cy="322" rx="17" ry="43" stroke="url(#purpleLight)" stroke-width="7" opacity=".84"/>
<path d="M410 188C437 145 486 124 612 124c143 0 234 25 261 80 17 35 17 153-3 192-25 49-82 62-250 59-164-3-220-21-240-74-23-60-13-146 30-193Z" fill="url(#shellHead)"/>
<path d="M412 190C464 139 604 123 744 142c68 10 109 32 128 65-65-43-170-51-293-43-86 6-144 15-167 26Z" fill="#FFFFFF" opacity=".32"/>
<path d="M386 362c38 90 237 102 420 77-31 22-88 29-186 27-164-3-220-21-240-74-5-13-8-23-9-34 5 2 10 3 15 4Z" fill="#33258F" opacity=".20"/>
<path d="M414 185c67-54 260-70 380-27" stroke="url(#edgeShade)" stroke-width="18" stroke-linecap="round" opacity=".5"/>
<path d="M455 238C474 207 516 198 617 200c112 2 178 13 200 46 15 23 16 104 1 132-22 41-71 47-201 45-126-3-169-15-185-52-16-39-8-104 23-133Z" fill="url(#glass)"/>
<path d="M455 238C474 207 516 198 617 200c112 2 178 13 200 46 15 23 16 104 1 132-22 41-71 47-201 45-126-3-169-15-185-52-16-39-8-104 23-133Z" stroke="#FFFFFF" stroke-opacity=".58" stroke-width="8"/>
<path d="M692 218c58 5 102 18 124 48 15 21 17 64 6 98-14-43-50-72-110-92 22-17 21-37-20-54Z" fill="url(#glassShine)"/>
<circle cx="558" cy="316" r="38" fill="#2B1457"/>
<circle cx="558" cy="316" r="27" stroke="url(#purpleLight)" stroke-width="13"/>
<circle cx="720" cy="318" r="38" fill="#2B1457"/>
<circle cx="720" cy="318" r="27" stroke="url(#purpleLight)" stroke-width="13"/>
<rect x="615" y="363" width="57" height="17" rx="9" fill="url(#purpleLight)"/>
<path d="M420 502C454 450 514 434 624 444c111 10 180 41 196 92 18 59-5 156-45 199-31 34-81 49-169 47-94-2-150-20-181-61-38-52-38-167-5-219Z" fill="url(#shellBody)"/>
<path d="M425 498c58-40 230-48 329 11-61-25-246-27-329-11Z" fill="#FFFFFF" opacity=".28"/>
<path d="M435 714c66 45 250 51 340 14-34 36-84 54-169 52-90-2-143-20-171-66Z" fill="#312286" opacity=".25"/>
<path d="M424 504c22-36 66-54 139-59" stroke="#FFFFFF" stroke-width="11" stroke-linecap="round" opacity=".27"/>
<path d="M381 505c44 0 62 41 42 91-19 47-61 83-101 75-39-8-48-54-19-102 20-34 48-64 78-64Z" fill="url(#armGrad)"/>
<path d="M351 530c27-10 46-4 52 16-26 9-55 49-74 88-18-17-5-79 22-104Z" fill="#FFFFFF" opacity=".34"/>
<path d="M826 505c39 4 77 41 93 90 14 43-7 75-45 70-38-5-73-38-91-80-20-45 3-83 43-80Z" fill="url(#armGrad)" opacity=".95"/>
<path d="M856 525c30 15 48 47 52 79-24-32-58-50-91-55 5-19 19-31 39-24Z" fill="#FFFFFF" opacity=".31"/>
<ellipse cx="444" cy="525" rx="26" ry="43" fill="#151337" opacity=".54"/>
<ellipse cx="801" cy="528" rx="24" ry="43" fill="#151337" opacity=".50"/>
<rect x="497" y="530" width="251" height="155" rx="42" fill="url(#glass)"/>
<rect x="497" y="530" width="251" height="155" rx="42" stroke="#FFFFFF" stroke-width="8" stroke-opacity=".62"/>
<rect x="515" y="548" width="215" height="119" rx="30" stroke="#A79EFF" stroke-width="4" opacity=".50"/>
<path d="M650 540c42 3 70 13 83 32-19-9-56-15-101-15 9-5 15-10 18-17Z" fill="#FFFFFF" opacity=".18"/>
<g stroke="url(#purpleLight)" stroke-width="6" stroke-linecap="round" stroke-linejoin="round">
<path d="M575 601c-18-24 5-50 31-35 11-25 48-21 54 4 27-5 47 17 35 42 20 16 6 50-22 48-12 23-47 24-61 3-23 14-54-7-44-33-18-4-24-19-18-29 5-9 14-12 25 0Z"/>
<path d="M604 566c-12 24 10 31 31 29M653 572c-12 17-4 34 17 37M587 621c27-15 56-9 87 22M618 604c-7 22 2 40 26 56"/>
</g>
<g fill="#EDE8FF">
<circle cx="545" cy="604" r="4"/><circle cx="699" cy="589" r="4"/><circle cx="562" cy="642" r="4"/><circle cx="682" cy="650" r="4"/>
<circle cx="573" cy="707" r="8"/><circle cx="621" cy="707" r="8"/><circle cx="672" cy="707" r="8"/>
</g>
<path d="M500 766c56 24 159 25 216 2-11 29-49 46-105 47-57 0-97-17-111-49Z" fill="#33278D" opacity=".62"/>
<path d="M490 760c74 26 166 27 241 2" stroke="#DCD6FF" stroke-width="5" opacity=".66"/>
<path d="M735 151c65 12 99 32 115 67" stroke="#FFFFFF" stroke-width="13" stroke-linecap="round" opacity=".48"/>
<path d="M805 520c33 16 56 43 68 80" stroke="#FFFFFF" stroke-width="12" stroke-linecap="round" opacity=".42"/>
<path d="M448 562c-17 50-11 113 17 147" stroke="#FFFFFF" stroke-width="10" stroke-linecap="round" opacity=".23"/>
</svg>''';
// =============================================================================
// DIALOGUE FLOW
// =============================================================================
//
// 1. Warm opener (data-aware greeting, no spike interrogation)
// 2. First spike labeling question fires immediately
// 3. After ALL spike questions are answered → category pills appear + session
//    complete card appears
// 4. Tapping a category pill hides the session complete card; pills stay visible
// 5. Category responses are enriched with all slots collected so far
// 6. Session completes when all spike questions answered; free chat continues
//
// STATE MACHINE:
//   onPath       →  Asking predefined spike labeling questions
//   inDepth      →  Going deeper on current question
//   inDigression →  User left the path (advice/support)
//   free         →  Path complete, open conversation
//
// =============================================================================

enum _DialogueState { onPath, inDepth, inDigression, free }

// =============================================================================
// CONTEXTUAL PROMPT SETS — shown after ALL spike questions are answered
// =============================================================================

class _PromptSet {
  const _PromptSet({
    required this.label,
    required this.icon,
    required this.color,
    required this.categoryMessage,
    required this.prompts,
  });
  final String label;
  final IconData icon;
  final Color color;
  final String categoryMessage;
  final List<String> prompts;
}

const List<_PromptSet> _kPromptSets = [
  _PromptSet(
    label: 'My Day',
    icon: Icons.wb_sunny_outlined,
    color: Color(0xFF7B6EF6),
    categoryMessage:
        "Here's what I can help you with for today — pick what feels most useful 👇",
    prompts: [
      "What should I do based on my stress today?",
      "What does my stress mean today?",
      "How should I plan my day?",
      "Am I at risk of burnout?",
      "Help me plan or message people today",
    ],
  ),
  _PromptSet(
    label: 'My Patterns',
    icon: Icons.insights_rounded,
    color: Color(0xFF7B6EF6),
    categoryMessage:
        "I can dig into your stress patterns — what would you like to understand? 👇",
    prompts: [
      "What patterns are you seeing in my stress?",
      "When am I most mentally drained?",
      "What's actually causing my stress?",
      "When am I free vs actually available?",
    ],
  ),
  _PromptSet(
    label: 'My Energy',
    icon: Icons.bolt_rounded,
    color: Color(0xFF7B6EF6),
    categoryMessage:
        "Let's look at what's shaping your energy and recovery — choose a question 👇",
    prompts: [
      "What does my typical day look like?",
      "What drains me the most?",
      "How do I act when I'm overwhelmed?",
      "What helps me recover fastest?",
      "Who should I prioritize staying available for?",
    ],
  ),
  _PromptSet(
    label: 'Plans & People',
    icon: Icons.people_outline_rounded,
    color: Color(0xFF7B6EF6),
    categoryMessage:
        "I can help you navigate plans and people based on how you're doing — what do you need? 👇",
    prompts: [
      "Set expectations for this week",
      "Suggest a better time to connect",
      "How should I handle plans today?",
      "What's the best way to reach out right now?",
    ],
  ),
];

// =============================================================================
// PandaScreen
// =============================================================================

class PandaScreen extends StatefulWidget {
  const PandaScreen({super.key});

  @override
  State<PandaScreen> createState() => _PandaScreenState();
}

class _PandaScreenState extends State<PandaScreen>
    with SingleTickerProviderStateMixin {
  static const Color _purple = Color(0xFF7B6EF6);
  static const Color _teal = Color(0xFF0ABFBC);
  static const Color _ink = Color(0xFF2D3142);
  static const Color _bg = Color(0xFFF2F2F7);

  late AIService _svc;
  final InsightService _insightSvc = InsightService();

  // ── Session ────────────────────────────────────────────────────────────────
  PandaSessionData? _session;
  bool _loading = true;
  String? _error;
  DateTime? _sessionStart;

  // ── Question queue ─────────────────────────────────────────────────────────
  final List<PandaQuestion> _questionQueue = [];
  int _qIdx = 0;
  int _depthTurns = 0;
  static const int _maxDepth = 5;

  // ── Dialogue state ─────────────────────────────────────────────────────────
  _DialogueState _state = _DialogueState.onPath;
  final List<_DigressionFrame> _digressionStack = [];

  // ── Graph ──────────────────────────────────────────────────────────────────
  final List<_ConvNode> _graphNodes = [];
  final Set<String> _injectedIds = {};
  String? _interruptedNodeId;

  // ── Slot accumulation ──────────────────────────────────────────────────────
  final Map<String, String> _sessionSlots = {};

  // ── Answers (spike Q→A) ────────────────────────────────────────────────────
  final Map<String, String> _spikeAnswers = {};

  // ── Category insights (category label+prompt → Panda response) ────────────
  final Map<String, String> _categoryInsights = {};

  // ── Recommendation tracking ────────────────────────────────────────────────
  final Set<String> _shownRecIds = {};

  // Stressors already saved as a standalone chat insight this session — prevents
  // saving a duplicate insight when the same stressor recurs across turns.
  final Set<String> _savedChatStressors = {};

  // Insight summaries generated THIS session (chat findings + completion recap),
  // surfaced to the dialogue LLM immediately so a just-saved insight is usable
  // on the very next turn (the session-init insightsContext only has the past).
  final List<String> _sessionInsightNotes = [];

  /// True while the spike-analysis LLM call is still running in the background
  /// (the chat is already open and usable — progressive loading).
  bool _analyzingSpikes = false;

  /// Google Calendar schedule digest, fetched in the BACKGROUND after the chat
  /// opens (it's too slow for the init critical path). Fed into dialogue turns
  /// once it arrives; null until then / when Calendar isn't connected.
  String? _scheduleContext;

  // ── Category pill state ────────────────────────────────────────────────────
  // Pills appear only after ALL spike questions are answered.
  // They stay visible throughout free chat.
  // _categoryPillsDismissed is no longer used for dismissal by the user;
  // pills are permanent once shown (but done card hides when a category is tapped).
  bool _categoryPillsVisible = false;
  // Which pill's sub-options are currently expanded. Null = none.
  String? _activeCategoryLabel;

  // ── Done card visibility ───────────────────────────────────────────────────
  // The "Session complete" card is shown after all spike Qs are answered
  // and hidden once the user taps any category pill.
  bool _doneCardVisible = false;

  // ── Insight ────────────────────────────────────────────────────────────────
  String? _currentInsightId;

  // ── Auth ───────────────────────────────────────────────────────────────────
  String _currentUserId = '';
  String _currentFirstName = '';

  // ── Chat ───────────────────────────────────────────────────────────────────
  final List<_Turn> _turns = [];
  bool _sessionComplete = false;
  bool _pandaTyping = false;

  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  // ── History (Firestore stream) ─────────────────────────────────────────────
  // The history tab now streams directly from the insights collection.
  // _firestoreInsights holds the latest snapshot; _historyStream is the
  // subscription kept alive for the lifetime of this screen.
  List<Insights> _firestoreInsights = [];
  StreamSubscription<List<Insights>>? _historyStream;

  // ── In-memory history (kept for graph / conversation display only) ─────────
  final List<_HistoryRecord> _localHistory = [];
  static const int _maxLocalHistory = 20;

  late final TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      _currentUserId = user.uid;
      if (user.displayName != null && user.displayName!.isNotEmpty) {
        _currentFirstName = user.displayName!.split(' ').first;
      } else if (user.email != null && user.email!.isNotEmpty) {
        _currentFirstName = user.email!.split('@').first;
      } else {
        _currentFirstName = 'there';
      }
    }

    PandaRecommendations.load();

    // Start listening to Firestore insights once we have a userId
    if (_currentUserId.isNotEmpty) {
      _subscribeToInsights(_currentUserId);
    }

    _initAIService();
  }

  // Resolves the active AIService backend (via Remote Config feature flag)
  // and then starts the session.  The loading indicator is already visible
  // (_loading = true by default), so there is no UI gap.
  Future<void> _initAIService() async {
    _svc = await AIServiceFactory.get();
    if (mounted) _loadSession();
  }

  // ── Subscribe to Firestore insights stream ─────────────────────────────────

  void _subscribeToInsights(String userId) {
    _historyStream?.cancel();
    _historyStream = _insightSvc
        .streamPandaInsights(userId, limit: 50)
        .listen(
          (insights) {
            if (mounted) {
              setState(() => _firestoreInsights = insights);
            }
          },
          onError: (Object e) {
            // ignore: avoid_print
            print('[PandaScreen] streamPandaInsights error: $e');
          },
        );
  }

  @override
  void dispose() {
    _historyStream?.cancel();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _tabCtrl.dispose();
    super.dispose();
  }

  // ===========================================================================
  // Session init
  // ===========================================================================

  /// Background calendar load — kicked off after the chat has already opened so
  /// it never delays session init. Once it lands, subsequent dialogue turns get
  /// the schedule and Panda can answer availability/planning questions.
  Future<void> _loadScheduleContext() async {
    final ctx = await GeminiService.fetchScheduleContext();
    if (!mounted || ctx == null || ctx.isEmpty) return;
    setState(() => _scheduleContext = ctx);
  }

  Future<void> _loadSession() async {
    final startedAt = DateTime.now();
    _sessionStart = startedAt;

    setState(() {
      _loading = true;
      _error = null;
      _turns.clear();
      _spikeAnswers.clear();
      _categoryInsights.clear();
      _questionQueue.clear();
      _qIdx = 0;
      _depthTurns = 0;
      _state = _DialogueState.onPath;
      _digressionStack.clear();
      _graphNodes.clear();
      _injectedIds.clear();
      _interruptedNodeId = null;
      _sessionSlots.clear();
      _shownRecIds.clear();
      _savedChatStressors.clear();
      _sessionInsightNotes.clear();
      _analyzingSpikes = false;
      _scheduleContext = null;
      _currentInsightId = null;
      _sessionComplete = false;
      // Pills and done card reset on new session
      _categoryPillsVisible = false;
      _activeCategoryLabel = null;
      _doneCardVisible = false;
      _session = null;
    });

    try {
      // PHASE 1 — fast bootstrap: Firestore only (no calendar, no LLM). The
      // chat opens immediately with the opener instead of waiting on the model.
      final boot = await _svc
          .startSession(
            userName: _currentFirstName.isNotEmpty ? _currentFirstName : null,
            userId: _currentUserId.isNotEmpty ? _currentUserId : null,
          )
          .timeout(const Duration(seconds: 30));

      if (!mounted) return;
      setState(() {
        _session = boot.session;
        _loading = false;
        _analyzingSpikes = boot.spikeAnalysis != null;
      });

      // Calendar is slow — load it in the background and feed it into later
      // dialogue turns once it lands.
      unawaited(_loadScheduleContext());

      // 1. Warm opener — shown right away.
      await _pandaSay(boot.session.openerMessage);

      // Nothing to analyze → the session is already final.
      if (boot.spikeAnalysis == null) {
        if (!mounted) return;
        setState(() {
          _sessionComplete = true;
          _state = _DialogueState.free;
          _categoryPillsVisible = true;
          _doneCardVisible = true;
        });
        _saveLocalHistory(startedAt, success: true);
        return;
      }

      // PHASE 2 — the labeling questions arrive behind the opener.
      final full = await boot.spikeAnalysis!.timeout(
        const Duration(seconds: 90),
      );
      if (!mounted) return;
      setState(() {
        _session = full;
        _questionQueue
          ..clear()
          ..addAll(full.questions);
        _analyzingSpikes = false;
      });

      if (_questionQueue.isNotEmpty) {
        await _pandaSay(_questionQueue.first.prompt);
      } else {
        setState(() {
          _sessionComplete = true;
          _state = _DialogueState.free;
          _categoryPillsVisible = true;
          _doneCardVisible = true;
        });
        _saveLocalHistory(startedAt, success: true);
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _analyzingSpikes = false;
        _error = 'Took too long. Tap retry to try again.';
      });
      _saveLocalHistory(
        startedAt,
        success: false,
        error: 'Timed out after 90s.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _analyzingSpikes = false;
        _loading = false;
        _error = 'Something went wrong: $e';
      });
      _saveLocalHistory(startedAt, success: false, error: e.toString());
    }
  }

  // ===========================================================================
  // Local history (conversation graph / answer display only)
  // ===========================================================================

  void _saveLocalHistory(
    DateTime startedAt, {
    required bool success,
    String? error,
  }) {
    if (!mounted) return;
    setState(() {
      _localHistory.insert(
        0,
        _HistoryRecord(
          startedAt: startedAt,
          endedAt: DateTime.now(),
          success: success,
          error: error,
          turns: List<_Turn>.from(_turns),
          answers: {..._spikeAnswers, ..._categoryInsights},
          overallNotes: _session?.overallNotes ?? '',
          graphNodes: List<_ConvNode>.from(_graphNodes),
          sessionSlots: Map<String, String>.from(_sessionSlots),
        ),
      );
      if (_localHistory.length > _maxLocalHistory) {
        _localHistory.removeRange(_maxLocalHistory, _localHistory.length);
      }
    });
  }

  // ===========================================================================
  // Panda says
  // ===========================================================================

  Future<void> _pandaSay(
    String text, {
    int typingMs = 1100,
    _TurnKind kind = _TurnKind.normal,
    List<PandaRec> recs = const [],
    List<String> categoryOptions = const [],
    Color? categoryColor,
    String? categoryLabel,
    PandaCalendarAction? calendarAction,
  }) async {
    if (!mounted) return;
    setState(() => _pandaTyping = true);
    _scrollBottom();
    await Future.delayed(Duration(milliseconds: typingMs));
    if (!mounted) return;
    setState(() {
      _pandaTyping = false;
      _turns.add(
        _Turn.assistant(
          text,
          kind: kind,
          recs: recs,
          categoryOptions: categoryOptions,
          categoryColor: categoryColor,
          categoryLabel: categoryLabel,
          calendarAction: calendarAction,
        ),
      );
    });
    _scrollBottom();
  }

  void _scrollBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    });
  }

  PandaQuestion? get _currentQ =>
      _qIdx < _questionQueue.length ? _questionQueue[_qIdx] : null;

  // ===========================================================================
  // Category pill tap — Panda sends category message with option chips
  // The done card is hidden once a category is explored.
  // ===========================================================================

  Future<void> _categoryTap(_PromptSet set) async {
    if (_pandaTyping) return;
    setState(() {
      _pandaTyping = true;
      _doneCardVisible = false;
      _activeCategoryLabel = set.label; // collapse any previously open pill
    });
    await _pandaSay(
      set.categoryMessage,
      typingMs: 600,
      kind: _TurnKind.categoryMenu,
      categoryOptions: set.prompts,
      categoryColor: set.color,
      categoryLabel: set.label,
    );
  }

  // ===========================================================================
  // Category option chip tap — user picks a prompt, runs through LLM
  // ===========================================================================

  Future<void> _categoryOptionTap(String prompt, String categoryLabel) async {
    if (_pandaTyping) return;

    setState(() => _turns.add(_Turn.user(prompt)));
    _scrollBottom();

    final session = _session;
    if (session == null) return;

    final history = _turns
        .map(
          (t) => {
            'role': t.role == _Role.user ? 'user' : 'assistant',
            'text': t.text,
          },
        )
        .toList();

    setState(() => _pandaTyping = true);
    _scrollBottom();

    try {
      final reply = await _svc
          .processTurn(
            userMessage: prompt,
            conversationHistory: history,
            spikeContext: session.rawSpikes,
            // Category prompts are free conversation — not spike labeling
            isOnPredefinedPath: false,
            isInDigression: false,
            digressionTurnCount: 0,
            pendingQuestionId: null,
            pendingQuestionPrompt: null,
            digressionTopic: null,
            accumulatedSlots: Map<String, String>.from(_sessionSlots),
            scheduleContext: _scheduleContext,
            insightsContext: _currentInsightsContext(),
            dashboardContext: _dashboardContextFor(prompt, session),
          )
          .timeout(const Duration(seconds: 35));

      if (!mounted) return;

      if (reply.filledSlots != null) {
        setState(
          () => _sessionSlots.addAll(
            Map.fromEntries(
              reply.filledSlots!.entries.where(
                (e) => e.value.trim().isNotEmpty,
              ),
            ),
          ),
        );
      }

      // Persist a significant stressor surfaced via this category pill.
      _maybeSaveChatInsight(
        reply: reply,
        userMessage: prompt,
        questionLabel: categoryLabel,
      );

      final insightKey = 'category::$categoryLabel::$prompt';
      setState(() {
        _categoryInsights[insightKey] = reply.message;
        _pandaTyping = false;
        _activeCategoryLabel = null; // collapse options once one is selected
      });

      // Handle recommend intent — surface rec cards alongside the message
      if (reply.intent == PandaIntent.recommend) {
        final recs = RecommendationEngine.recommend(
          sessionSlots: Map<String, String>.from(_sessionSlots),
          llmHint: reply.recHint,
          excludeIds: Set<String>.from(_shownRecIds),
        );
        setState(() => _shownRecIds.addAll(recs.map((r) => r.id)));
        await _pandaSay(
          reply.message,
          typingMs: 0,
          kind: _TurnKind.recommend,
          recs: recs,
        );
      } else {
        setState(() => _turns.add(_Turn.assistant(reply.message)));
        _scrollBottom();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _pandaTyping = false);
      await _pandaSay(
        "I ran into a hiccup — try tapping that again.",
        typingMs: 0,
      );
    }
  }

  // ===========================================================================
  // Chip tap — direct answer to current spike question
  // ===========================================================================

  Future<void> _chipTap(String option) async {
    if (_pandaTyping || _sessionComplete) return;
    final q = _currentQ;
    if (q == null) return;

    setState(() {
      _pandaTyping = true;
      _turns.add(_Turn.user(option));
      _spikeAnswers[q.questionId] = option;
      _graphNodes.add(
        _ConvNode(
          questionId: q.questionId,
          questionText: q.prompt,
          answer: option,
          isBranch: _injectedIds.contains(q.questionId),
          parentNodeId: _injectedIds.contains(q.questionId)
              ? _interruptedNodeId
              : null,
        ),
      );
      _qIdx++;
      _depthTurns = 0;
      _state = _DialogueState.onPath;
      // NOTE: category pills are NOT shown here — they appear only after
      // all spike questions are complete (handled in _advanceOrComplete).
    });
    _scrollBottom();
    await _advanceOrComplete();
  }

  // ===========================================================================
  // Free-text submit
  // ===========================================================================

  Future<void> _submit() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _pandaTyping) return;
    _inputCtrl.clear();

    setState(() => _turns.add(_Turn.user(text)));
    _scrollBottom();

    final session = _session;
    if (session == null) return;

    final history = _turns
        .map(
          (t) => {
            'role': t.role == _Role.user ? 'user' : 'assistant',
            'text': t.text,
          },
        )
        .toList();

    setState(() => _pandaTyping = true);
    _scrollBottom();

    try {
      final currentQ = _currentQ;

      final reply = await _svc
          .processTurn(
            userMessage: text,
            conversationHistory: history,
            spikeContext: session.rawSpikes,
            isOnPredefinedPath:
                _state == _DialogueState.onPath ||
                _state == _DialogueState.inDepth,
            isInDigression: _state == _DialogueState.inDigression,
            digressionTurnCount: _digressionStack.isNotEmpty
                ? _digressionStack.last.turnCount
                : 0,
            pendingQuestionId: currentQ?.questionId,
            pendingQuestionPrompt: currentQ?.prompt,
            digressionTopic: _digressionStack.isNotEmpty
                ? _digressionStack.last.topic
                : null,
            accumulatedSlots: Map<String, String>.from(_sessionSlots),
            dashboardContext: _dashboardContextFor(text, session),
            scheduleContext: _scheduleContext,
            insightsContext: _currentInsightsContext(),
          )
          .timeout(const Duration(seconds: 35));

      if (!mounted) return;

      if (reply.filledSlots != null) {
        setState(
          () => _sessionSlots.addAll(
            Map.fromEntries(
              reply.filledSlots!.entries.where(
                (e) => e.value.trim().isNotEmpty,
              ),
            ),
          ),
        );
      }

      // Persist a significant stressor surfaced via this free-text question.
      // 'You shared' becomes an editable Q→A entry in the History card.
      _maybeSaveChatInsight(
        reply: reply,
        userMessage: text,
        questionLabel: 'You shared',
      );

      // _pandaTyping stays true here — _pandaSay handles the false transition
      // once the response is rendered. Clearing it early causes chips to flash.
      switch (reply.intent) {
        case PandaIntent.answerLabel:
          if (currentQ != null) {
            setState(() {
              _spikeAnswers[currentQ.questionId] = text;
              _graphNodes.add(
                _ConvNode(
                  questionId: currentQ.questionId,
                  questionText: currentQ.prompt,
                  answer: text,
                  isBranch: _injectedIds.contains(currentQ.questionId),
                  parentNodeId: _injectedIds.contains(currentQ.questionId)
                      ? _interruptedNodeId
                      : null,
                ),
              );
              _qIdx++;
              _depthTurns = 0;
              _state = _DialogueState.onPath;
              // Category pills are NOT shown here — only after all Qs complete.
            });
          }
          await _pandaSay(reply.message, typingMs: 0);
          await _advanceOrComplete();

        case PandaIntent.wantDeeperAnswer:
          setState(() {
            _state = _DialogueState.inDepth;
            _depthTurns++;
          });
          await _pandaSay(
            reply.depthFollowUp?.isNotEmpty == true
                ? reply.depthFollowUp!
                : reply.message,
            typingMs: 0,
            kind: _TurnKind.depth,
          );

        case PandaIntent.digress:
          setState(() {
            _state = _DialogueState.inDigression;
            _digressionStack.add(
              _DigressionFrame(
                pendingQuestionId: currentQ?.questionId ?? '',
                pendingQuestionPrompt: currentQ?.prompt ?? '',
                topic: text,
              ),
            );
          });
          await _pandaSay(
            reply.message,
            typingMs: 0,
            kind: _TurnKind.digression,
          );

        case PandaIntent.digressionComplete:
          final frame = _digressionStack.isNotEmpty
              ? _digressionStack.removeLast()
              : null;
          setState(() {
            _state = frame == null || _qIdx >= _questionQueue.length
                ? _DialogueState.free
                : _DialogueState.onPath;
          });
          await _pandaSay(
            reply.message,
            typingMs: 0,
            kind: _TurnKind.digression,
          );
          if (_state == _DialogueState.onPath && _currentQ != null) {
            await Future.delayed(const Duration(milliseconds: 400));
            await _pandaSay(_currentQ!.prompt);
          }

        case PandaIntent.newStressor:
          if (reply.injectedQuestion != null) {
            setState(() {
              _interruptedNodeId = currentQ?.questionId;
              _injectedIds.add(reply.injectedQuestion!.questionId);
              final at = _qIdx.clamp(0, _questionQueue.length);
              _questionQueue.insert(at, reply.injectedQuestion!);
            });
          }
          await _pandaSay(reply.message, typingMs: 0);
          if (_currentQ != null) await _pandaSay(_currentQ!.prompt);

        case PandaIntent.recommend:
          final recs = RecommendationEngine.recommend(
            sessionSlots: Map<String, String>.from(_sessionSlots),
            llmHint: reply.recHint,
            excludeIds: Set<String>.from(_shownRecIds),
          );
          setState(() => _shownRecIds.addAll(recs.map((r) => r.id)));
          await _pandaSay(
            reply.message,
            typingMs: 0,
            kind: _TurnKind.recommend,
            recs: recs,
          );

        case PandaIntent.skip:
          if (currentQ != null) {
            setState(() {
              _spikeAnswers[currentQ.questionId] = 'skipped';
              _qIdx++;
              _depthTurns = 0;
            });
          }
          await _pandaSay(reply.message, typingMs: 0);
          await _advanceOrComplete();

        case PandaIntent.chitchat:
          if (_state == _DialogueState.inDigression &&
              _digressionStack.isNotEmpty) {
            setState(() => _digressionStack.last.turnCount++);
          }
          await _pandaSay(reply.message, typingMs: 0);

        case PandaIntent.calendarAction:
          if (reply.calendarAction == null) {
            await _pandaSay(
              'I need a little more detail before I can prepare that calendar change.',
              typingMs: 0,
            );
          } else {
            await _pandaSay(
              reply.message,
              typingMs: 0,
              kind: _TurnKind.calendarAction,
              calendarAction: reply.calendarAction,
            );
          }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _pandaTyping = false);
      await _pandaSay(
        "I hit a small issue. Try sending that again.",
        typingMs: 0,
      );
    }
  }

  /// Selects dashboard metrics locally, so ordinary chat turns add zero health
  /// tokens and health questions include only the relevant daily aggregates.
  String? _dashboardContextFor(String message, PandaSessionData session) {
    if (session.dashboardMetrics.isEmpty) return null;
    final text = message.toLowerCase();
    final requested = <String>{};

    bool mentions(Iterable<String> terms) => terms.any(
      (term) => RegExp(
        '(^|[^a-z0-9])${RegExp.escape(term)}([^a-z0-9]|\$)',
      ).hasMatch(text),
    );

    if (mentions(['step', 'steps', 'walk', 'walking'])) requested.add('steps');
    if (mentions(['sleep', 'slept', 'rest', 'tired', 'fatigue'])) {
      requested.add('sleep');
    }
    if (mentions(['hrv', 'variability', 'recovery'])) requested.add('hrv');
    if (mentions(['heart rate', 'pulse', 'bpm'])) {
      requested.addAll(['heart_rate', 'resting_heart_rate']);
    }
    if (mentions(['stress', 'stressed'])) requested.add('stress');
    if (mentions(['wellness', 'wellbeing', 'well-being'])) {
      requested.add('wellness');
    }
    if (mentions(['exercise', 'workout', 'activity', 'active'])) {
      requested.addAll([
        'steps',
        'exercise_time',
        'active_calories',
        'distance',
      ]);
    }
    if (mentions(['weight', 'weigh'])) requested.add('weight');
    if (mentions(['oxygen', 'spo2'])) requested.add('blood_oxygen');
    if (mentions(['respiratory', 'breathing rate'])) {
      requested.add('respiratory_rate');
    }

    final overview = mentions([
      'health',
      'dashboard',
      'metric',
      'metrics',
      'overview',
    ]);
    if (overview && requested.isEmpty) {
      requested.addAll([
        'steps',
        'sleep',
        'resting_heart_rate',
        'hrv',
        'stress',
        'wellness',
      ]);
    }
    if (requested.isEmpty) return null;

    final dates = session.dashboardMetrics.keys.toList()
      ..sort((a, b) => b.compareTo(a));
    final lines = <String>[];
    for (final metric in requested) {
      final values = <String>[];
      for (final date in dates) {
        final raw = session.dashboardMetrics[date]?[metric];
        final value = _dashboardMetricValue(metric, raw);
        if (value != null) values.add('$date=$value');
      }
      if (values.isNotEmpty) lines.add('$metric:${values.join(',')}');
    }
    return lines.isEmpty ? null : lines.join('\n');
  }

  String? _dashboardMetricValue(String metric, dynamic raw) {
    num? value;
    if (raw is num) {
      value = raw;
    } else if (raw is Map) {
      final preferred = metric == 'steps' ? 'sum' : 'avg';
      value = raw[preferred] as num? ??
          raw['avg'] as num? ??
          raw['sum'] as num? ??
          raw['max'] as num?;
    }
    if (value == null) return null;
    return value is int || value == value.roundToDouble()
        ? value.round().toString()
        : value.toStringAsFixed(1);
  }

  // ===========================================================================
  // Advance or complete
  //
  // Category pills and the "Session complete" card only appear here — once
  // every spike question has been answered.
  // ===========================================================================

  Future<void> _advanceOrComplete() async {
    if (_qIdx < _questionQueue.length) {
      // Still more spike questions to ask
      await _pandaSay(_questionQueue[_qIdx].prompt);
    } else {
      // All spike questions answered
      if (!_sessionComplete) {
        await _pandaSay(
          'Thanks so much for sharing all of that!  '
          "I've captured everything. Feel free to explore the categories below or start a new session.",
          typingMs: 900,
        );
        if (!mounted) return;
        setState(() {
          _sessionComplete = true;
          _state = _DialogueState.free;
          // Show category pills and the done card now that all Qs are complete
          _categoryPillsVisible = true;
          _doneCardVisible = true;
        });
        _saveLocalHistory(_sessionStart ?? DateTime.now(), success: true);
        await _persistCompletedSession();
      }
    }
  }

  /// Stable id grouping every insight saved during the current chat session,
  /// so the History tab can render them together (split view).
  String? get _chatSessionId => _sessionStart?.toIso8601String();

  Future<void> _persistCompletedSession() async {
    final resolvedUserId = _currentUserId;
    final labeledAnswers = {..._spikeAnswers, ..._categoryInsights};
    final conversation = _turns
        .map(
          (t) => {
            'role': t.role == _Role.user ? 'user' : 'assistant',
            'text': t.text,
          },
        )
        .toList();
    // Ask the LLM for a comprehensive-but-brief continuity note that captures
    // context/insight (not just a restatement of answers). Falls back to the
    // deterministic summary inside saveSessionInsight when this returns ''.
    String llmSummary = '';
    try {
      llmSummary = await _svc
          .summarizeSession(
            conversation: conversation,
            slots: Map<String, String>.from(_sessionSlots),
            labeledAnswers: labeledAnswers,
          )
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      // Non-fatal — saveSessionInsight will use the deterministic fallback.
    }

    try {
      final insight = await _insightSvc.saveSessionInsight(
        userId: resolvedUserId,
        sessionDate: _sessionStart ?? DateTime.now(),
        sessionSlots: Map<String, String>.from(_sessionSlots),
        labeledAnswers: labeledAnswers,
        conversation: conversation,
        summary: llmSummary.isNotEmpty ? llmSummary : null,
        chatSessionId: _chatSessionId,
      );
      if (mounted) setState(() => _currentInsightId = insight.id);
      // Surface this session's recap to subsequent free-conversation turns.
      if (llmSummary.isNotEmpty && mounted) {
        _sessionInsightNotes.add(llmSummary);
      }
    } catch (e) {
      // ignore: avoid_print
      print('[PandaScreen] saveSessionInsight failed: $e');
    }
  }

  // ===========================================================================
  // Build
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: _buildAppBar(),
      body: TabBarView(
        controller: _tabCtrl,
        children: [_buildChatTab(), _buildHistoryTab()],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final (String statusText, Color statusColor) = switch (_state) {
      _DialogueState.inDigression => ('side chat', _teal),
      _DialogueState.inDepth => ('going deeper…', _purple),
      _ when _loading => ('analysing…', Colors.orange),
      // Chat is already open and usable while the spike analysis finishes.
      _ when _analyzingSpikes => ('reading your data…', Colors.orange),
      _ when _pandaTyping => ('typing…', Colors.orange),
      _DialogueState.free => ('', _purple),
      _ => ('online', Colors.green),
    };

    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0.5,
      automaticallyImplyLeading: false,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _avatar(size: 42),
          const SizedBox(width: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'AI Assistant',
                style: TextStyle(
                  color: _ink,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                statusText,
                style: TextStyle(color: statusColor, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
      centerTitle: true,
      bottom: TabBar(
        controller: _tabCtrl,
        tabs: const [
          Tab(text: 'Chat'),
          Tab(text: 'History'),
        ],
        labelColor: _purple,
        unselectedLabelColor: Colors.grey,
        indicatorColor: _purple,
      ),
      actions: [
        if (!_loading && _error == null)
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.grey),
            tooltip: 'New session',
            onPressed: _loadSession,
          ),
        IconButton(
          icon: const Icon(Icons.info_outline, color: Colors.blueAccent),
          tooltip: 'Data Safety',
          onPressed: _showSafetyDialog,
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildChatTab() {
    return Column(
      children: [
        _buildPathStrip(),
        Expanded(child: _buildChatArea()),
        _buildInputArea(),
        SizedBox(height: MediaQuery.of(context).padding.bottom + 100),
      ],
    );
  }

  Widget _buildPathStrip() {
    if (_loading || _sessionComplete) return const SizedBox.shrink();

    final total = _questionQueue.length;
    final done = _qIdx.clamp(0, total);
    final progress = total > 0 ? done / total : 0.0;

    Color stripColor;
    IconData stripIcon;
    String stripLabel;

    switch (_state) {
      case _DialogueState.inDigression:
        stripColor = _teal;
        stripIcon = Icons.alt_route_rounded;
        stripLabel = 'side chat — path paused';
      case _DialogueState.inDepth:
        stripColor = _purple.withOpacity(0.7);
        stripIcon = Icons.layers_rounded;
        stripLabel = 'going deeper ($done/$total)';
      default:
        stripColor = _purple;
        stripIcon = Icons.linear_scale_rounded;
        stripLabel = total > 0 ? '$done / $total questions' : '';
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      color: stripColor.withOpacity(0.07),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      child: Row(
        children: [
          Icon(stripIcon, size: 13, color: stripColor),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                backgroundColor: Colors.black.withOpacity(0.07),
                valueColor: AlwaysStoppedAnimation<Color>(stripColor),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            stripLabel,
            style: TextStyle(
              fontSize: 11,
              color: stripColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatArea() {
    if (_loading && _turns.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/vivordo_logo.png',
              width: 380,
              height: 300,
              fit: BoxFit.contain,
            ),
            Transform.translate(
              offset: const Offset(0, -40),
              child: const SizedBox(
                width: 200,
                child: LinearProgressIndicator(
                  backgroundColor: Color(0xFFE5E5EA),
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF7B6EF6)),
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Analysing your data…',
              style: TextStyle(color: Colors.black45, fontSize: 14),
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.wifi_off_rounded,
                size: 48,
                color: Colors.black26,
              ),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.black54),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _loadSession,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _purple,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final showChips =
        !_pandaTyping &&
        !_sessionComplete &&
        _state != _DialogueState.inDigression &&
        _currentQ != null &&
        _currentQ!.options.isNotEmpty;

    final showDepthHint =
        !_pandaTyping && _state == _DialogueState.inDepth && _currentQ != null;

    // Category pills: only visible after ALL spike questions are answered.
    final showCategoryPills =
        _categoryPillsVisible &&
        !_pandaTyping &&
        !_loading &&
        _turns.isNotEmpty;

    // Done card: shown after completion, hidden after first category tap.
    final showDone = _doneCardVisible && _sessionComplete;

    // Category pills are pinned above the first bot message so the user sees
    // the available digression topics without scrolling to the bottom.
    final pillsFirst = showCategoryPills ? 1 : 0;

    return SafeArea(
      bottom: false,
      child: ListView.builder(
        controller: _scrollCtrl,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        itemCount:
            pillsFirst +
            _turns.length +
            (_pandaTyping ? 1 : 0) +
            (showChips ? 1 : 0) +
            (showDepthHint ? 1 : 0) +
            (showDone ? 1 : 0),
        itemBuilder: (context, i) {
          // Category pills: index 0 when visible, above all chat turns.
          if (showCategoryPills && i == 0) return _categoryPillsWidget();

          final turnIdx = i - pillsFirst;
          if (turnIdx < _turns.length) {
            final t = _turns[turnIdx];
            final isLastAssistant =
                t.role == _Role.assistant &&
                !_turns
                    .sublist(turnIdx + 1)
                    .any((x) => x.role == _Role.assistant);
            return t.role == _Role.user
                ? _userBubble(t.text)
                : _assistantBubble(
                    t.text,
                    showAvatar: isLastAssistant,
                    kind: t.kind,
                    turn: t,
                    recs: t.recs,
                    categoryOptions: t.categoryOptions,
                    categoryColor: t.categoryColor,
                    categoryLabel: t.categoryLabel,
                    showCategoryOptions:
                        t.categoryLabel == _activeCategoryLabel,
                  );
          }
          int off = pillsFirst + _turns.length;
          if (_pandaTyping && i == off) return _typingBubble();
          if (_pandaTyping) off++;
          if (showChips && i == off) return _chipRow(_currentQ!);
          if (showChips) off++;
          if (showDepthHint && i == off) return _depthHintRow();
          if (showDepthHint) off++;
          if (showDone && i == off) return _doneCard();
          return const SizedBox.shrink();
        },
      ),
    );
  }

  // ===========================================================================
  // Bubbles
  // ===========================================================================

  Widget _assistantBubble(
    String text, {
    bool showAvatar = false,
    _TurnKind kind = _TurnKind.normal,
    _Turn? turn,
    List<PandaRec> recs = const [],
    List<String> categoryOptions = const [],
    Color? categoryColor,
    String? categoryLabel,
    bool showCategoryOptions = false,
  }) {
    Color bg;
    Color border;
    Widget? badge;

    switch (kind) {
      case _TurnKind.digression:
        bg = _teal.withOpacity(0.07);
        border = _teal.withOpacity(0.25);
        badge = _kindBadge(Icons.alt_route_rounded, 'side chat', _teal);
      case _TurnKind.depth:
        bg = _purple.withOpacity(0.05);
        border = _purple.withOpacity(0.18);
        badge = _kindBadge(Icons.layers_rounded, 'deeper', _purple);
      case _TurnKind.recommend:
        bg = Colors.white;
        border = Colors.transparent;
        badge = _kindBadge(
          Icons.auto_awesome_rounded,
          'for you',
          const Color(0xFFFF8C69),
        );
      case _TurnKind.categoryMenu:
        bg = Colors.white;
        border = (categoryColor ?? _purple).withOpacity(0.15);
        badge = null;
      case _TurnKind.normal:
        bg = Colors.white;
        border = Colors.transparent;
        badge = null;
      case _TurnKind.calendarAction:
        bg = const Color(0xFFF4F1FF);
        border = _purple.withOpacity(0.25);
        badge = _kindBadge(Icons.calendar_month_rounded, 'calendar', _purple);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                showAvatar
                    ? Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _avatar(size: 48),
                      )
                    : const SizedBox(width: 10),
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(20),
                        topRight: Radius.circular(20),
                        bottomRight: Radius.circular(20),
                        bottomLeft: Radius.circular(4),
                      ),
                      border: Border.all(color: border, width: 1.2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.04),
                          blurRadius: 5,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (badge != null) ...[
                          badge,
                          const SizedBox(height: 6),
                        ],
                        Text(
                          text,
                          style: const TextStyle(
                            color: Colors.black87,
                            fontSize: 15,
                            height: 1.45,
                          ),
                        ),
                        if (turn?.calendarAction != null) ...[
                          const SizedBox(height: 10),
                          _calendarActionControls(turn!),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 40),
              ],
            ),
          ),
          // Category option chips — only for the active pill (one at a time).
          if (showCategoryOptions &&
              categoryOptions.isNotEmpty &&
              categoryLabel != null)
            Padding(
              padding: const EdgeInsets.only(left: 50, right: 8, bottom: 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: categoryOptions
                    .map(
                      (opt) => GestureDetector(
                        onTap: () => _categoryOptionTap(opt, categoryLabel),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 9,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: (categoryColor ?? _purple).withOpacity(
                                0.35,
                              ),
                              width: 1.2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: (categoryColor ?? _purple).withOpacity(
                                  0.06,
                                ),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Text(
                            opt,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: (categoryColor ?? _purple).withOpacity(
                                0.85,
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          // Rec cards
          if (recs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 50, right: 8, bottom: 8),
              child: Column(
                children: recs.map((rec) => _RecCard(rec: rec)).toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _kindBadge(IconData icon, String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: color.withOpacity(0.7)),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: color.withOpacity(0.7),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _userBubble(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          const SizedBox(width: 40),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: _purple.withOpacity(0.12),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                  bottomLeft: Radius.circular(20),
                  bottomRight: Radius.circular(4),
                ),
                border: Border.all(color: _purple.withOpacity(0.2)),
              ),
              child: Text(
                text,
                style: const TextStyle(color: _ink, fontSize: 15, height: 1.45),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _typingBubble() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _avatar(size: 48),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
                bottomRight: Radius.circular(20),
                bottomLeft: Radius.circular(4),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 5,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const TypingIndicator(),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // Category pills widget — horizontal row, shown after ALL spike Qs answered.
  // No dismiss button: pills are persistent once shown.
  // ===========================================================================

  Widget _categoryPillsWidget() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16, top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Label
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 8),
            child: Text(
              'Explore with AI Assistant',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.black38,
                letterSpacing: 0.3,
              ),
            ),
          ),
          // Pills
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 2),
              itemCount: _kPromptSets.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, idx) {
                final s = _kPromptSets[idx];
                return GestureDetector(
                  onTap: () => _categoryTap(s),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: s.color.withOpacity(0.09),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: s.color.withOpacity(0.35),
                        width: 1.2,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(s.icon, size: 14, color: s.color),
                        const SizedBox(width: 6),
                        Text(
                          s.label,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: s.color.withOpacity(0.9),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _chipRow(PandaQuestion q) {
    return Padding(
      padding: const EdgeInsets.only(left: 58, bottom: 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: q.options
            .map(
              (opt) => GestureDetector(
                onTap: () => _chipTap(opt),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: _purple.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _purple.withOpacity(0.25)),
                  ),
                  child: Text(
                    opt,
                    style: const TextStyle(
                      color: _purple,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _depthHintRow() {
    return Padding(
      padding: const EdgeInsets.only(left: 58, bottom: 12),
      child: Row(
        children: [
          Icon(Icons.layers_rounded, size: 13, color: _purple.withOpacity(0.5)),
          const SizedBox(width: 6),
          Text(
            'Keep sharing or type "done" to move on',
            style: TextStyle(
              fontSize: 12,
              color: _purple.withOpacity(0.55),
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  /// The "Session complete" card — shown after all spike Qs are answered,
  /// hidden (via _doneCardVisible = false) when any category pill is tapped.
  Widget _doneCard() {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: _purple.withOpacity(0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _purple.withOpacity(0.15)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '✅  Session complete',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: _purple,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${_spikeAnswers.length} answer${_spikeAnswers.length == 1 ? '' : 's'} captured'
                '${_sessionSlots.isNotEmpty ? ' · ${_sessionSlots.length} insights extracted' : ''}',
                style: const TextStyle(color: Colors.black45, fontSize: 13),
              ),
              const SizedBox(height: 4),
              const Text(
                'Tap a category above to explore, or start a new session.',
                style: TextStyle(color: Colors.black38, fontSize: 12),
              ),
              const SizedBox(height: 10),
              TextButton.icon(
                onPressed: _loadSession,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('New session'),
                style: TextButton.styleFrom(foregroundColor: _purple),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Input area ─────────────────────────────────────────────────────────────

  Widget _buildInputArea() {
    final bool disabled = _loading || _pandaTyping;

    String hint;
    if (_sessionComplete) {
      hint = 'Ask AI Assistant anything';
    } else if (disabled) {
      hint = 'Panda is thinking…';
    } else if (_state == _DialogueState.inDigression) {
      hint = 'Keep going — Panda is all ears…';
    } else if (_state == _DialogueState.inDepth) {
      hint = 'Tell me more, or type "done" to move on…';
    } else {
      hint = 'Answer or ask AI Assistant anything…';
    }

    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        10,
        16,
        MediaQuery.of(context).padding.bottom + 10,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.black12, width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_sessionComplete &&
              _state == _DialogueState.onPath &&
              _currentQ != null &&
              _currentQ!.options.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Tap an option above or type your own answer',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _inputCtrl,
                  enabled: !disabled,
                  textInputAction: TextInputAction.send,
                  maxLines: null,
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: TextStyle(
                      color: Colors.grey.shade400,
                      fontSize: 14,
                    ),
                    filled: true,
                    fillColor: disabled ? Colors.grey.shade100 : _bg,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: const BorderSide(color: _purple, width: 1.5),
                    ),
                    disabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide(color: Colors.grey.shade200),
                    ),
                  ),
                  onSubmitted: disabled ? null : (_) => _submit(),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: disabled ? null : _submit,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  height: 46,
                  width: 46,
                  decoration: BoxDecoration(
                    color: disabled ? Colors.grey.shade300 : _purple,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.send_rounded,
                    color: disabled ? Colors.grey.shade400 : Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // History tab — streams from Firestore insights collection
  // ===========================================================================

  Widget _buildHistoryTab() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Past Sessions',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: _ink,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _firestoreInsights.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _avatar(),
                          const SizedBox(height: 16),
                          const Text(
                            "No sessions yet.\nComplete a chat and it'll appear here.",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.black45,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    )
                  : Builder(
                      builder: (_) {
                        final groups = _groupedInsights();
                        return ListView.separated(
                          itemCount: groups.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (_, i) => _chatGroupCard(groups[i]),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // Firestore insight card
  //
  // Renders a completed panda session from the insights collection.
  // Mirrors the previous _historyCard layout with Q→A pairs, slots, and
  // edit-answer support wired to InsightService.correctAnswer().
  // ===========================================================================

  /// Groups the flat insight stream into chat sessions (by chatSessionId),
  /// preserving the newest-first order. Insights without a chatSessionId
  /// (older records) each form their own single-item group.
  List<List<Insights>> _groupedInsights() {
    final order = <String>[];
    final map = <String, List<Insights>>{};
    for (final ins in _firestoreInsights) {
      final key = (ins.chatSessionId != null && ins.chatSessionId!.isNotEmpty)
          ? 'chat:${ins.chatSessionId}'
          : 'id:${ins.id ?? identityHashCode(ins)}';
      if (!map.containsKey(key)) {
        map[key] = [];
        order.add(key);
      }
      map[key]!.add(ins);
    }
    return [for (final k in order) map[k]!];
  }

  static String _fmtInsightDt(DateTime dt) {
    final l = dt.toLocal();
    final h12 = l.hour % 12 == 0 ? 12 : l.hour % 12;
    final min = l.minute.toString().padLeft(2, '0');
    final ap = l.hour >= 12 ? 'PM' : 'AM';
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}  $h12:$min $ap';
  }

  // One History card per chat session. When a chat produced multiple distinct
  // insights they render as a split view — one section per insight.
  Widget _chatGroupCard(List<Insights> group) {
    final latest = group.first; // stream is newest-first
    final sessionDt = latest.sessionDate?.toDate() ?? latest.createdAt.toDate();
    final multi = group.length > 1;
    final headerLabel = multi
        ? '${group.length} insights this chat'
        : '${(latest.pandaLabeledAnswers ?? const {}).length} answers captured';

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.black.withOpacity(0.07)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            childrenPadding: const EdgeInsets.only(
              left: 16,
              right: 16,
              bottom: 16,
            ),
            title: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _fmtInsightDt(sessionDt),
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: _ink,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        headerLabel,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.black45,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.green.withOpacity(0.3)),
                  ),
                  child: const Text(
                    'Complete',
                    style: TextStyle(
                      color: Colors.green,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            children: [
              for (int i = 0; i < group.length; i++) ...[
                if (i > 0) ...[
                  const SizedBox(height: 6),
                  Divider(color: Colors.black.withOpacity(0.06), height: 1),
                  const SizedBox(height: 10),
                ],
                _insightSection(group[i], showHeader: multi),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // The content for a single insight — used inside a chat-group split view.
  Widget _insightSection(Insights insight, {required bool showHeader}) {
    final slots = insight.pandaSlots;
    final labeledAnswers = insight.pandaLabeledAnswers ?? {};
    final corrections = insight.pandaCorrections ?? [];
    final hasSlots = slots != null && !slots.isEmpty;
    final hasAnswers = labeledAnswers.entries.any(
      (e) => !e.key.startsWith('category::'),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Per-insight header (only when several insights share the card).
        if (showHeader) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  (insight.title != null && insight.title!.isNotEmpty)
                      ? insight.title!
                      : 'Insight',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: _purple,
                  ),
                ),
              ),
              if (insight.frequency > 1) ...[
                const SizedBox(width: 8),
                _badge('seen ${insight.frequency}×', _teal),
              ],
            ],
          ),
          const SizedBox(height: 8),
        ],
        // Overall notes
        if (insight.body != null && insight.body!.isNotEmpty) ...[
          _noteBox(insight.body!),
          const SizedBox(height: 12),
        ],

        // Q→A pairs — spike labeled answers only
        // (category insights are excluded; they are conversation, not spike labels)
        if (hasAnswers) ...[
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Your Answers',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: _ink,
                  ),
                ),
              ),
              Text(
                'tap ✏️ to correct',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.black38,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...labeledAnswers.entries
              // Only show spike answers (skip category:: keys)
              .where((e) => !e.key.startsWith('category::'))
              .map((e) {
                // Find the latest answer (account for corrections)
                final correctedEntry = corrections
                    .where((c) => c.questionId == e.key)
                    .lastOrNull;
                final displayAnswer = correctedEntry?.newAnswer ?? e.value;
                final wasEdited = correctedEntry != null;

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.black.withOpacity(0.08)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  e.key,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.black45,
                                    height: 1.35,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        displayAnswer,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          color: _ink,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                    if (wasEdited)
                                      Padding(
                                        padding: const EdgeInsets.only(left: 4),
                                        child: Icon(
                                          Icons.edit_rounded,
                                          size: 11,
                                          color: _teal.withOpacity(0.6),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: () => _editFirestoreAnswer(
                            insight: insight,
                            questionId: e.key,
                            currentAnswer: displayAnswer,
                          ),
                          borderRadius: const BorderRadius.only(
                            topRight: Radius.circular(10),
                            bottomRight: Radius.circular(10),
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: const Text(
                              '✏️',
                              style: TextStyle(fontSize: 16),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
          const SizedBox(height: 4),
        ],

        // Extracted wellness slots
        if (hasSlots) ...[
          const Text(
            'Extracted Insights',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: _ink,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: slots
                .toMap()
                .entries
                .map(
                  (e) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: _teal.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _teal.withOpacity(0.2)),
                    ),
                    child: Text(
                      '${e.key}: ${e.value}',
                      style: TextStyle(
                        fontSize: 11,
                        color: _teal.withOpacity(0.9),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 8),
        ],

        // Corrections audit trail
        if (corrections.isNotEmpty) ...[
          const SizedBox(height: 4),
          const Text(
            'Edit History',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: _ink,
            ),
          ),
          const SizedBox(height: 6),
          ...corrections.map(
            (c) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.edit_rounded,
                    size: 12,
                    color: _teal.withOpacity(0.5),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${c.questionId}: "${c.oldAnswer}" → "${c.newAnswer}"',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.black45,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ===========================================================================
  // Edit answer — wired to Firestore via InsightService.correctAnswer()
  // ===========================================================================

  Future<void> _editFirestoreAnswer({
    required Insights insight,
    required String questionId,
    required String currentAnswer,
  }) async {
    if (insight.id == null) return;

    final controller = TextEditingController(text: currentAnswer);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Text('✏️  ', style: TextStyle(fontSize: 20)),
            Expanded(
              child: Text(
                'Edit Answer',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              questionId,
              style: const TextStyle(
                fontSize: 13,
                color: Colors.black54,
                height: 1.4,
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 3,
              minLines: 1,
              decoration: InputDecoration(
                hintText: 'Enter your corrected answer…',
                filled: true,
                fillColor: Colors.grey.shade50,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: _purple.withOpacity(0.3)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: _purple, width: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '⚡ Correcting your answer helps Panda learn your stress patterns more accurately.',
              style: TextStyle(
                fontSize: 11,
                color: Colors.black38,
                height: 1.4,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.black45),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _purple,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    final newAnswer = controller.text.trim();
    if (newAnswer.isEmpty || newAnswer == currentAnswer) return;

    final resolvedUserId = _currentUserId;

    try {
      final updated = await _insightSvc.correctAnswer(
        userId: resolvedUserId,
        insightId: insight.id!,
        questionId: questionId,
        oldAnswer: currentAnswer,
        newAnswer: newAnswer,
      );
      // The Firestore stream will push the updated insight automatically.

      // Regenerate the continuity note so the fed-back summary reflects the
      // corrected answer. No conversation is stored on the insight, so this
      // synthesises from the (updated) slots + labeled answers. Non-fatal.
      unawaited(_regenerateSummary(resolvedUserId, updated));
    } catch (e) {
      // ignore: avoid_print
      print('[PandaScreen] correctAnswer failed: $e');
    }
  }

  /// Re-runs the LLM summary for an edited insight and writes it back.
  Future<void> _regenerateSummary(String userId, Insights updated) async {
    if (updated.id == null) return;
    try {
      final slots = (updated.pandaSlots?.toMap() ?? <String, dynamic>{}).map(
        (k, v) => MapEntry(k, v.toString()),
      );
      final answers = updated.pandaLabeledAnswers ?? const <String, String>{};
      if (slots.isEmpty && answers.isEmpty) return;

      final summary = await _svc
          .summarizeSession(
            conversation: const [],
            slots: slots,
            labeledAnswers: answers,
          )
          .timeout(const Duration(seconds: 20));

      if (summary.isNotEmpty) {
        await _insightSvc.updateSummary(userId, updated.id!, summary);
      }
    } catch (e) {
      // ignore: avoid_print
      print('[PandaScreen] summary regeneration failed: $e');
    }
  }

  // ===========================================================================
  // Chat-discovered stressors → saved as insights
  //
  // When a free-text question or a category-pill answer surfaces a significant
  // stressor (a non-empty `stressor` slot, or intent == new_stressor), persist
  // it as its own insight so it's captured and fed back — even after the
  // predefined session has completed. De-duped by stressor within the session.
  // ===========================================================================

  /// Combines past-session insights (from session init) with summaries captured
  /// earlier in THIS session, so the dialogue LLM always has current context.
  String? _currentInsightsContext() {
    final base = _session?.insightsContext?.trim() ?? '';
    if (base.isEmpty && _sessionInsightNotes.isEmpty) return null;
    final buf = StringBuffer();
    if (_sessionInsightNotes.isNotEmpty) {
      buf.writeln('From earlier in THIS session:');
      for (final n in _sessionInsightNotes) {
        buf.writeln('• $n');
      }
      if (base.isNotEmpty) buf.writeln();
    }
    if (base.isNotEmpty) buf.write(base);
    return buf.toString().trim();
  }

  void _maybeSaveChatInsight({
    required PandaTurnReply reply,
    required String userMessage,
    String? questionLabel,
  }) {
    // Per-turn slots ONLY (this finding) — NOT accumulated _sessionSlots, so a
    // later stressor (e.g. "social") can't inherit/merge into an earlier one
    // (e.g. "work"). Each distinct finding becomes its own insight.
    final slots = Map<String, String>.from(reply.filledSlots ?? const {})
      ..removeWhere((k, v) => v.trim().isEmpty);

    // The model often files a stressor under a more specific slot
    // (social_context / activity / location / other) and leaves `stressor`
    // empty. Promote the best available signal so the finding is still a
    // distinct, titled insight rather than being dropped.
    if ((slots['stressor'] ?? '').isEmpty) {
      final derived =
          slots['social_context'] ??
          slots['activity'] ??
          slots['location'] ??
          slots['other'] ??
          '';
      if (derived.trim().isNotEmpty) slots['stressor'] = derived.trim();
    }
    final stressor = (slots['stressor'] ?? '').trim();

    final significant =
        stressor.isNotEmpty || reply.intent == PandaIntent.newStressor;
    if (kDebugMode) {
      debugPrint(
        '[ChatInsight] intent=${reply.intent} stressor="$stressor" '
        'filledSlots=${reply.filledSlots} significant=$significant',
      );
    }
    if (!significant) return;

    // Within this chat, only block an EXACT repeat of the same stressor phrase.
    // Different scenarios (even in the same category) each get their own
    // insight — cross-chat frequency merging is handled in saveSessionInsight.
    final dedupeKey = Insights.normalizeStressor(stressor);
    if (dedupeKey != null && !_savedChatStressors.add(dedupeKey)) {
      if (kDebugMode) {
        debugPrint('[ChatInsight] skip — "$dedupeKey" already saved this chat');
      }
      return;
    }

    final userId = _currentUserId;
    final conversation = _turns
        .map(
          (t) => {
            'role': t.role == _Role.user ? 'user' : 'assistant',
            'text': t.text,
          },
        )
        .toList();
    final labeled = (questionLabel != null && questionLabel.isNotEmpty)
        ? {questionLabel: userMessage}
        : <String, String>{};

    unawaited(_saveChatInsight(userId, slots, conversation, labeled));
  }

  Future<void> _saveChatInsight(
    String userId,
    Map<String, String> slots,
    List<Map<String, String>> conversation,
    Map<String, String> labeled,
  ) async {
    try {
      String summary = '';
      try {
        summary = await _svc
            .summarizeSession(
              conversation: conversation,
              slots: slots,
              labeledAnswers: labeled,
            )
            .timeout(const Duration(seconds: 20));
      } catch (_) {
        // Non-fatal — saveSessionInsight falls back to a deterministic summary.
      }

      await _insightSvc.saveSessionInsight(
        userId: userId,
        sessionDate: DateTime.now(),
        sessionSlots: slots,
        labeledAnswers: labeled,
        conversation: conversation,
        summary: summary.isNotEmpty ? summary : null,
        chatSessionId: _chatSessionId,
      );

      // Make this finding usable on the next dialogue turn immediately.
      if (summary.isNotEmpty && mounted) _sessionInsightNotes.add(summary);
    } catch (e) {
      // ignore: avoid_print
      print('[PandaScreen] saveChatInsight failed: $e');
    }
  }

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _noteBox(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _purple.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.psychology_outlined, size: 16, color: _purple),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13, color: _purple, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  void _showSafetyDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Row(
          children: [
            Icon(Icons.shield_outlined, color: Colors.blueAccent),
            SizedBox(width: 10),
            Text(
              'Privacy & Safety',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: const Text(
          'All health insights and conversations are encrypted and private.',
          style: TextStyle(fontSize: 15, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Got it',
              style: TextStyle(color: _purple, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _RecCard({required PandaRec rec}) {
    final Color catColor = _recCategoryColor(rec.category);
    return GestureDetector(
      onTap: rec.deepLink != null ? () => _launchUrl(rec.deepLink!) : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: catColor.withOpacity(0.25), width: 1.3),
          boxShadow: [
            BoxShadow(
              color: catColor.withOpacity(0.07),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: catColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: Text(rec.emoji, style: const TextStyle(fontSize: 18)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    rec.title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: catColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    rec.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Colors.black54,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (rec.durationLabel != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: catColor.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      rec.durationLabel!,
                      style: TextStyle(
                        fontSize: 10,
                        color: catColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (rec.deepLink != null) ...[
                  const SizedBox(height: 4),
                  Icon(
                    Icons.open_in_new_rounded,
                    size: 14,
                    color: catColor.withOpacity(0.5),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _recCategoryColor(RecCategory cat) {
    switch (cat) {
      case RecCategory.music:
        return const Color(0xFF1DB954);
      case RecCategory.breathing:
        return const Color(0xFF5B8DEF);
      case RecCategory.movement:
        return const Color(0xFFFF6B6B);
      case RecCategory.sleep:
        return const Color(0xFF9B72CF);
      case RecCategory.focus:
        return const Color(0xFFFFAA00);
      case RecCategory.social:
        return const Color(0xFF0ABFBC);
      case RecCategory.nutrition:
        return const Color(0xFF4CAF50);
      case RecCategory.journal:
        return const Color(0xFFFF8C69);
    }
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Widget _calendarActionControls(_Turn turn) {
    final action = turn.calendarAction!;
    if (turn.calendarStatus == _CalendarActionStatus.running) {
      return const LinearProgressIndicator(minHeight: 3);
    }
    if (turn.calendarStatus == _CalendarActionStatus.done) {
      return const Row(
        children: [
          Icon(Icons.check_circle_rounded, color: Colors.green, size: 18),
          SizedBox(width: 6),
          Text(
            'Calendar updated',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      );
    }
    if (turn.calendarStatus == _CalendarActionStatus.cancelled) {
      return const Text('Cancelled', style: TextStyle(color: Colors.black54));
    }
    if (turn.calendarStatus == _CalendarActionStatus.failed) {
      return Text(
        turn.calendarError ?? 'The calendar change failed.',
        style: const TextStyle(color: Colors.redAccent, fontSize: 13),
      );
    }
    final when = action.start == null
        ? null
        : DateFormat('EEE, MMM d · h:mm a').format(action.start!.toLocal());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _calendarActionSummary(action),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        if (when != null) Text(when, style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 10),
        Row(
          children: [
            FilledButton.icon(
              onPressed: () => _confirmCalendarAction(turn),
              icon: const Icon(Icons.check_rounded, size: 17),
              label: const Text('Confirm'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => setState(
                () => turn.calendarStatus = _CalendarActionStatus.cancelled,
              ),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ],
    );
  }

  String _calendarActionSummary(PandaCalendarAction action) =>
      switch (action.operation) {
        PandaCalendarOperation.create => 'Create “${action.title}”',
        PandaCalendarOperation.update => 'Edit “${action.targetTitle}”',
        PandaCalendarOperation.delete => 'Delete “${action.targetTitle}”',
      };

  Future<void> _confirmCalendarAction(_Turn turn) async {
    setState(() => turn.calendarStatus = _CalendarActionStatus.running);
    try {
      final action = turn.calendarAction!;
      if (action.operation == PandaCalendarOperation.create) {
        await CalendarService.createEvent(
          title: action.title!,
          start: action.start!,
          end: action.end!,
          recurrence: action.recurrence,
        );
      } else {
        final event = await _findCalendarEvent(action);
        if (action.operation == PandaCalendarOperation.delete) {
          await CalendarService.deleteEvent(event);
        } else {
          await CalendarService.updateEvent(
            event,
            title: action.title,
            start: action.start,
            end: action.end,
            recurrence: action.recurrence == 'none' ? null : action.recurrence,
          );
        }
      }
      if (!mounted) return;
      setState(() => turn.calendarStatus = _CalendarActionStatus.done);
      unawaited(_loadScheduleContext());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        turn.calendarStatus = _CalendarActionStatus.failed;
        turn.calendarError = e.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  Future<gcal.Event> _findCalendarEvent(PandaCalendarAction action) async {
    final anchor = action.start?.toLocal();
    final from = anchor == null
        ? DateTime.now().subtract(const Duration(days: 1))
        : DateTime(anchor.year, anchor.month, anchor.day);
    final to = anchor == null
        ? DateTime.now().add(const Duration(days: 60))
        : from.add(const Duration(days: 1));
    final events = await CalendarService.getEventsBetween(from, to);
    String normalize(String value) =>
        value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
    final target = normalize(action.targetTitle ?? '');
    final matches = events
        .where((event) => normalize(event.summary ?? '') == target)
        .toList();
    if (matches.isEmpty) {
      throw StateError(
        'I could not find “${action.targetTitle}” in that date range.',
      );
    }
    if (matches.length > 1) {
      throw StateError(
        'More than one event matches “${action.targetTitle}”. Include its date or time.',
      );
    }
    return matches.single;
  }

  Widget _avatar({double size = 80}) =>
      SvgPicture.string(_kRobotSvg, width: size, height: size);
}

// =============================================================================
// Data models
// =============================================================================

enum _Role { user, assistant }

enum _TurnKind {
  normal,
  digression,
  depth,
  recommend,
  categoryMenu,
  calendarAction,
}

enum _CalendarActionStatus { pending, running, done, cancelled, failed }

class _Turn {
  _Turn({
    required this.role,
    required this.text,
    this.kind = _TurnKind.normal,
    this.recs = const [],
    this.categoryOptions = const [],
    this.categoryColor,
    this.categoryLabel,
    this.calendarAction,
  });
  final _Role role;
  final String text;
  final _TurnKind kind;
  final List<PandaRec> recs;
  final List<String> categoryOptions;
  final Color? categoryColor;

  /// Which category set this menu belongs to — needed to route option taps.
  final String? categoryLabel;
  final PandaCalendarAction? calendarAction;
  _CalendarActionStatus calendarStatus = _CalendarActionStatus.pending;
  String? calendarError;

  factory _Turn.user(String t) => _Turn(role: _Role.user, text: t);
  factory _Turn.assistant(
    String t, {
    _TurnKind kind = _TurnKind.normal,
    List<PandaRec> recs = const [],
    List<String> categoryOptions = const [],
    Color? categoryColor,
    String? categoryLabel,
    PandaCalendarAction? calendarAction,
  }) => _Turn(
    role: _Role.assistant,
    text: t,
    kind: kind,
    recs: recs,
    categoryOptions: categoryOptions,
    categoryColor: categoryColor,
    categoryLabel: categoryLabel,
    calendarAction: calendarAction,
  );
}

class _DigressionFrame {
  _DigressionFrame({
    required this.pendingQuestionId,
    required this.pendingQuestionPrompt,
    required this.topic,
  });
  final String pendingQuestionId;
  final String pendingQuestionPrompt;
  final String topic;
  int turnCount = 0;
}

/// Kept for session graph display only (not persisted to Firestore).
class _HistoryRecord {
  _HistoryRecord({
    required this.startedAt,
    required this.endedAt,
    required this.success,
    required this.turns,
    required this.answers,
    required this.overallNotes,
    required this.graphNodes,
    required this.sessionSlots,
    this.error,
  });
  final DateTime startedAt;
  final DateTime endedAt;
  final bool success;
  final String? error;
  final List<_Turn> turns;
  Map<String, String> answers;
  final String overallNotes;
  final List<_ConvNode> graphNodes;
  final Map<String, String> sessionSlots;
}

class _ConvNode {
  _ConvNode({
    required this.questionId,
    required this.questionText,
    required this.answer,
    required this.isBranch,
    this.parentNodeId,
  });
  final String questionId;
  final String questionText;
  final String answer;
  final bool isBranch;
  final String? parentNodeId;
}

// =============================================================================
// Typing indicator
// =============================================================================

class TypingIndicator extends StatefulWidget {
  const TypingIndicator({super.key});

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with TickerProviderStateMixin {
  late List<AnimationController> _ctrls;
  late List<Animation<double>> _anims;

  @override
  void initState() {
    super.initState();
    _ctrls = List.generate(
      3,
      (_) => AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 600),
      )..repeat(reverse: true),
    );
    _anims = _ctrls
        .map(
          (c) => Tween<double>(
            begin: 0.25,
            end: 1.0,
          ).animate(CurvedAnimation(parent: c, curve: Curves.easeInOut)),
        )
        .toList();
    for (int i = 0; i < 3; i++) {
      Timer(Duration(milliseconds: i * 180), () {
        if (mounted) _ctrls[i].forward();
      });
    }
  }

  @override
  void dispose() {
    for (final c in _ctrls) c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        3,
        (i) => FadeTransition(
          opacity: _anims[i],
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2.5),
            height: 7,
            width: 7,
            decoration: BoxDecoration(
              color: Colors.grey.shade400,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}
