import 'dart:async';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
// ignore: avoid_web_libraries_in_flutter
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import '../src/services/gemini_service.dart';
import '../src/services/recommendation_engine.dart';
import '../src/services/insight_service.dart';
import '../src/models/insights.dart';
import '../src/services/panda_recommendations.dart';

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
    color: Color(0xFFFF8C69),
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
    color: Color(0xFF0ABFBC),
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
    color: Color(0xFF4CAF50),
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

  final GeminiService _svc = GeminiService();
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

  // ── Category pill state ────────────────────────────────────────────────────
  // Pills appear only after ALL spike questions are answered.
  // They stay visible throughout free chat.
  // _categoryPillsDismissed is no longer used for dismissal by the user;
  // pills are permanent once shown (but done card hides when a category is tapped).
  bool _categoryPillsVisible = false;

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
    super.initState()
    ;
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

    _loadSession();
  }

  // ── Subscribe to Firestore insights stream ─────────────────────────────────

  void _subscribeToInsights(String userId) {
    _historyStream?.cancel();
    _historyStream = _insightSvc
        .streamPandaInsights(userId, limit: 50)
        .listen((insights) {
      if (mounted) {
        setState(() => _firestoreInsights = insights);
      }
    }, onError: (Object e) {
      // ignore: avoid_print
      print('[PandaScreen] streamPandaInsights error: $e');
    });
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
      _currentInsightId = null;
      _sessionComplete = false;
      // Pills and done card reset on new session
      _categoryPillsVisible = false;
      _doneCardVisible = false;
      _session = null;
    });

    try {
      final session = await _svc
          .analyzePandaSession(
            userName: _currentFirstName.isNotEmpty ? _currentFirstName : null,
          )
          .timeout(const Duration(seconds: 90));

      if (!mounted) return;
      setState(() {
        _session = session;
        _questionQueue.addAll(session.questions);
        _loading = false;
      });

      // 1. Warm opener
      await _pandaSay(session.openerMessage);

      // 2. First spike question fires immediately (no waiting for engagement)
      if (_questionQueue.isNotEmpty) {
        await _pandaSay(_questionQueue.first.prompt);
      } else {
        // No questions at all — treat as complete immediately
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
        _error = 'Took too long. Tap retry to try again.';
      });
      _saveLocalHistory(startedAt, success: false, error: 'Timed out after 90s.');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Something went wrong: $e';
      });
      _saveLocalHistory(startedAt, success: false, error: e.toString());
    }
  }

  // ===========================================================================
  // Local history (conversation graph / answer display only)
  // ===========================================================================

  void _saveLocalHistory(DateTime startedAt,
      {required bool success, String? error}) {
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
          answers: {
            ..._spikeAnswers,
            ..._categoryInsights,
          },
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

  Future<void> _pandaSay(String text,
      {int typingMs = 1100,
      _TurnKind kind = _TurnKind.normal,
      List<PandaRec> recs = const [],
      List<String> categoryOptions = const [],
      Color? categoryColor,
      String? categoryLabel}) async {
    if (!mounted) return;
    setState(() => _pandaTyping = true);
    _scrollBottom();
    await Future.delayed(Duration(milliseconds: typingMs));
    if (!mounted) return;
    setState(() {
      _pandaTyping = false;
      _turns.add(_Turn.assistant(text,
          kind: kind,
          recs: recs,
          categoryOptions: categoryOptions,
          categoryColor: categoryColor,
          categoryLabel: categoryLabel));
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
    // Hide the session complete card once the user starts exploring categories
    if (_doneCardVisible) {
      setState(() => _doneCardVisible = false);
    }
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
        .map((t) => {
              'role': t.role == _Role.user ? 'user' : 'assistant',
              'text': t.text,
            })
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
          )
          .timeout(const Duration(seconds: 35));

      if (!mounted) return;

      if (reply.filledSlots != null) {
        setState(() => _sessionSlots.addAll(
            Map.fromEntries(reply.filledSlots!.entries
                .where((e) => e.value.trim().isNotEmpty))));
      }

      final insightKey = 'category::$categoryLabel::$prompt';
      setState(() {
        _categoryInsights[insightKey] = reply.message;
        _pandaTyping = false;
      });

      // Handle recommend intent — surface rec cards alongside the message
      if (reply.intent == PandaIntent.recommend) {
        final recs = RecommendationEngine.recommend(
          sessionSlots: Map<String, String>.from(_sessionSlots),
          llmHint: reply.recHint,
          excludeIds: Set<String>.from(_shownRecIds),
        );
        setState(() => _shownRecIds.addAll(recs.map((r) => r.id)));
        await _pandaSay(reply.message, typingMs: 0,
            kind: _TurnKind.recommend, recs: recs);
      } else {
        setState(() => _turns.add(_Turn.assistant(reply.message)));
        _scrollBottom();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _pandaTyping = false);
      await _pandaSay(
          "I ran into a hiccup — try tapping that again.",
          typingMs: 0);
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
      _turns.add(_Turn.user(option));
      _spikeAnswers[q.questionId] = option;
      _graphNodes.add(_ConvNode(
        questionId: q.questionId,
        questionText: q.prompt,
        answer: option,
        isBranch: _injectedIds.contains(q.questionId),
        parentNodeId:
            _injectedIds.contains(q.questionId) ? _interruptedNodeId : null,
      ));
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
        .map((t) => {
              'role': t.role == _Role.user ? 'user' : 'assistant',
              'text': t.text,
            })
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
            isOnPredefinedPath: _state == _DialogueState.onPath ||
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
          )
          .timeout(const Duration(seconds: 35));

      if (!mounted) return;

      if (reply.filledSlots != null) {
        setState(() => _sessionSlots.addAll(
            Map.fromEntries(reply.filledSlots!.entries
                .where((e) => e.value.trim().isNotEmpty))));
      }

      setState(() => _pandaTyping = false);

      switch (reply.intent) {
        case PandaIntent.answerLabel:
          if (currentQ != null) {
            setState(() {
              _spikeAnswers[currentQ.questionId] = text;
              _graphNodes.add(_ConvNode(
                questionId: currentQ.questionId,
                questionText: currentQ.prompt,
                answer: text,
                isBranch: _injectedIds.contains(currentQ.questionId),
                parentNodeId: _injectedIds.contains(currentQ.questionId)
                    ? _interruptedNodeId
                    : null,
              ));
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
            _digressionStack.add(_DigressionFrame(
              pendingQuestionId: currentQ?.questionId ?? '',
              pendingQuestionPrompt: currentQ?.prompt ?? '',
              topic: text,
            ));
          });
          await _pandaSay(reply.message, typingMs: 0, kind: _TurnKind.digression);

        case PandaIntent.digressionComplete:
          final frame = _digressionStack.isNotEmpty
              ? _digressionStack.removeLast()
              : null;
          setState(() {
            _state = frame == null || _qIdx >= _questionQueue.length
                ? _DialogueState.free
                : _DialogueState.onPath;
          });
          await _pandaSay(reply.message, typingMs: 0, kind: _TurnKind.digression);
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
          await _pandaSay(reply.message, typingMs: 0,
              kind: _TurnKind.recommend, recs: recs);

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
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _pandaTyping = false);
      await _pandaSay(
          "I hit a small issue. Try sending that again.",
          typingMs: 0);
    }
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
          'Thanks so much for sharing all of that! 💜  '
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

  Future<void> _persistCompletedSession() async {
    final resolvedUserId = _currentUserId.isNotEmpty
        ? _currentUserId
        : _svc.getActiveDemoUser().userId;
    final labeledAnswers = {..._spikeAnswers, ..._categoryInsights};
    try {
      final insight = await _insightSvc.saveSessionInsight(
        userId: resolvedUserId,
        sessionDate: _sessionStart ?? DateTime.now(),
        sessionSlots: Map<String, String>.from(_sessionSlots),
        labeledAnswers: labeledAnswers,
      );
      if (mounted) setState(() => _currentInsightId = insight.id);
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
      _DialogueState.inDepth      => ('going deeper…', _purple),
      _ when _loading             => ('analysing…', Colors.orange),
      _ when _pandaTyping         => ('typing…', Colors.orange),
      _DialogueState.free         => ('free chat', _purple),
      _                           => ('online', Colors.green),
    };

    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0.5,
      automaticallyImplyLeading: false,
      title: Column(children: [
        const Text('Panda',
            style: TextStyle(
                color: _ink, fontSize: 17, fontWeight: FontWeight.bold)),
        Text(statusText, style: TextStyle(color: statusColor, fontSize: 12)),
      ]),
      centerTitle: true,
      bottom: TabBar(
        controller: _tabCtrl,
        tabs: const [Tab(text: 'Chat'), Tab(text: 'History')],
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
    return Column(children: [
      _buildPathStrip(),
      Expanded(child: _buildChatArea()),
      _buildInputArea(),
      SizedBox(height: MediaQuery.of(context).padding.bottom + 100),
    ]);
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
      child: Row(children: [
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
        Text(stripLabel,
            style: TextStyle(
                fontSize: 11,
                color: stripColor,
                fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Widget _buildChatArea() {
    if (_loading && _turns.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _avatar(),
          const SizedBox(height: 20),
          const TypingIndicator(),
          const SizedBox(height: 14),
          const Text('Panda is analysing your data…',
              style: TextStyle(color: Colors.black45, fontSize: 14)),
        ]),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.wifi_off_rounded, size: 48, color: Colors.black26),
            const SizedBox(height: 16),
            Text(_error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _loadSession,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _purple,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
              ),
            ),
          ]),
        ),
      );
    }

    final showChips = !_pandaTyping &&
        !_sessionComplete &&
        _state != _DialogueState.inDigression &&
        _currentQ != null &&
        _currentQ!.options.isNotEmpty;

    final showDepthHint = !_pandaTyping &&
        _state == _DialogueState.inDepth &&
        _currentQ != null;

    // Category pills: only visible after ALL spike questions are answered.
    final showCategoryPills = _categoryPillsVisible &&
        !_pandaTyping &&
        !_loading &&
        _turns.isNotEmpty;

    // Done card: shown after completion, hidden after first category tap.
    final showDone = _doneCardVisible && _sessionComplete;

    return SafeArea(
      bottom: false,
      child: ListView.builder(
        controller: _scrollCtrl,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        itemCount: _turns.length +
            (_pandaTyping ? 1 : 0) +
            (showCategoryPills ? 1 : 0) +
            (showChips ? 1 : 0) +
            (showDepthHint ? 1 : 0) +
            (showDone ? 1 : 0),
        itemBuilder: (context, i) {
          if (i < _turns.length) {
            final t = _turns[i];
            return t.role == _Role.user
                ? _userBubble(t.text)
                : _assistantBubble(t.text,
                    kind: t.kind,
                    recs: t.recs,
                    categoryOptions: t.categoryOptions,
                    categoryColor: t.categoryColor,
                    categoryLabel: t.categoryLabel);
          }
          int off = _turns.length;
          if (_pandaTyping && i == off) return _typingBubble();
          if (_pandaTyping) off++;
          if (showCategoryPills && i == off) return _categoryPillsWidget();
          if (showCategoryPills) off++;
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

  Widget _assistantBubble(String text, {
    _TurnKind kind = _TurnKind.normal,
    List<PandaRec> recs = const [],
    List<String> categoryOptions = const [],
    Color? categoryColor,
    String? categoryLabel,
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
        badge = _kindBadge(Icons.auto_awesome_rounded, 'for you',
            const Color(0xFFFF8C69));
      case _TurnKind.categoryMenu:
        bg = Colors.white;
        border = (categoryColor ?? _purple).withOpacity(0.15);
        badge = null;
      case _TurnKind.normal:
        bg = Colors.white;
        border = Colors.transparent;
        badge = null;
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
              _avatar(),
              const SizedBox(width: 10),
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
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
                          offset: const Offset(0, 2))
                    ],
                  ),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (badge != null) ...[
                          badge,
                          const SizedBox(height: 6)
                        ],
                        Text(text,
                            style: const TextStyle(
                                color: Colors.black87,
                                fontSize: 15,
                                height: 1.45)),
                      ]),
                ),
              ),
              const SizedBox(width: 40),
            ]),
          ),
          // Category option chips below a categoryMenu bubble
          if (categoryOptions.isNotEmpty && categoryLabel != null)
            Padding(
              padding:
                  const EdgeInsets.only(left: 50, right: 8, bottom: 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: categoryOptions
                    .map((opt) => GestureDetector(
                          onTap: () =>
                              _categoryOptionTap(opt, categoryLabel),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 9),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: (categoryColor ?? _purple)
                                    .withOpacity(0.35),
                                width: 1.2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: (categoryColor ?? _purple)
                                      .withOpacity(0.06),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Text(opt,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: (categoryColor ?? _purple)
                                      .withOpacity(0.85),
                                )),
                          ),
                        ))
                    .toList(),
              ),
            ),
          // Rec cards
          if (recs.isNotEmpty)
            Padding(
              padding:
                  const EdgeInsets.only(left: 50, right: 8, bottom: 8),
              child: Column(
                  children: recs.map((rec) => _RecCard(rec: rec)).toList()),
            ),
        ],
      ),
    );
  }

  Widget _kindBadge(IconData icon, String label, Color color) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 11, color: color.withOpacity(0.7)),
      const SizedBox(width: 4),
      Text(label,
          style: TextStyle(
              fontSize: 10,
              color: color.withOpacity(0.7),
              fontWeight: FontWeight.w600)),
    ]);
  }

  Widget _userBubble(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        const SizedBox(width: 40),
        Flexible(
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
            child: Text(text,
                style: const TextStyle(
                    color: _ink, fontSize: 15, height: 1.45)),
          ),
        ),
      ]),
    );
  }

  Widget _typingBubble() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
        _avatar(),
        const SizedBox(width: 10),
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
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
                  offset: const Offset(0, 2))
            ],
          ),
          child: const TypingIndicator(),
        ),
      ]),
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
              'Explore with Panda',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.black38,
                  letterSpacing: 0.3),
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
                        horizontal: 16, vertical: 9),
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
            .map((opt) => GestureDetector(
                  onTap: () => _chipTap(opt),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: _purple.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(20),
                      border:
                          Border.all(color: _purple.withOpacity(0.25)),
                    ),
                    child: Text(opt,
                        style: const TextStyle(
                            color: _purple,
                            fontWeight: FontWeight.w600,
                            fontSize: 14)),
                  ),
                ))
            .toList(),
      ),
    );
  }

  Widget _depthHintRow() {
    return Padding(
      padding: const EdgeInsets.only(left: 58, bottom: 12),
      child: Row(children: [
        Icon(Icons.layers_rounded,
            size: 13, color: _purple.withOpacity(0.5)),
        const SizedBox(width: 6),
        Text(
          'Keep sharing or type "done" to move on',
          style: TextStyle(
              fontSize: 12,
              color: _purple.withOpacity(0.55),
              fontStyle: FontStyle.italic),
        ),
      ]),
    );
  }

  /// The "Session complete" card — shown after all spike Qs are answered,
  /// hidden (via _doneCardVisible = false) when any category pill is tapped.
  Widget _doneCard() {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      child: Center(
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: _purple.withOpacity(0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _purple.withOpacity(0.15)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('✅  Session complete',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: _purple,
                    fontSize: 14)),
            const SizedBox(height: 4),
            Text(
                '${_spikeAnswers.length} answer${_spikeAnswers.length == 1 ? '' : 's'} captured'
                '${_sessionSlots.isNotEmpty ? ' · ${_sessionSlots.length} insights extracted' : ''}',
                style: const TextStyle(
                    color: Colors.black45, fontSize: 13)),
            const SizedBox(height: 4),
            const Text('Tap a category above to explore, or start a new session.',
                style:
                    TextStyle(color: Colors.black38, fontSize: 12)),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: _loadSession,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('New session'),
              style:
                  TextButton.styleFrom(foregroundColor: _purple),
            ),
          ]),
        ),
      ),
    );
  }

  // ── Input area ─────────────────────────────────────────────────────────────

  Widget _buildInputArea() {
    final bool disabled = _loading || _pandaTyping;

    String hint;
    if (_sessionComplete) {
      hint = 'Ask Panda anything 💜';
    } else if (disabled) {
      hint = 'Panda is thinking…';
    } else if (_state == _DialogueState.inDigression) {
      hint = 'Keep going — Panda is all ears…';
    } else if (_state == _DialogueState.inDepth) {
      hint = 'Tell me more, or type "done" to move on…';
    } else {
      hint = 'Answer or ask Panda anything…';
    }

    return Container(
      padding: EdgeInsets.fromLTRB(16, 10, 16, MediaQuery.of(context).padding.bottom + 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border:
            Border(top: BorderSide(color: Colors.black12, width: 0.5)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (!_sessionComplete &&
            _state == _DialogueState.onPath &&
            _currentQ != null &&
            _currentQ!.options.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Tap an option above or type your own answer',
              style: TextStyle(
                  color: Colors.grey.shade400, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _inputCtrl,
              enabled: !disabled,
              textInputAction: TextInputAction.send,
              maxLines: null,
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(
                    color: Colors.grey.shade400, fontSize: 14),
                filled: true,
                fillColor:
                    disabled ? Colors.grey.shade100 : _bg,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide:
                        BorderSide(color: Colors.grey.shade300)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide:
                        BorderSide(color: Colors.grey.shade300)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: const BorderSide(
                        color: _purple, width: 1.5)),
                disabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide:
                        BorderSide(color: Colors.grey.shade200)),
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
              child: Icon(Icons.send_rounded,
                  color: disabled
                      ? Colors.grey.shade400
                      : Colors.white,
                  size: 20),
            ),
          ),
        ]),
      ]),
    );
  }

  // ===========================================================================
  // History tab — streams from Firestore insights collection
  // ===========================================================================

  Widget _buildHistoryTab() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Row(children: [
            const Expanded(
                child: Text('Past Sessions',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: _ink))),
          ]),
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
                              color: Colors.black45, height: 1.5)),
                    ]))
                : ListView.separated(
                    itemCount: _firestoreInsights.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: 10),
                    itemBuilder: (_, i) =>
                        _insightCard(_firestoreInsights[i]),
                  ),
          ),
        ]),
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

  Widget _insightCard(Insights insight) {
    final sessionDt = insight.sessionDate?.toDate() ??
        insight.createdAt.toDate();

    String fmtDt(DateTime dt) {
      final l = dt.toLocal();
      final h12 = l.hour % 12 == 0 ? 12 : l.hour % 12;
      final min = l.minute.toString().padLeft(2, '0');
      final ap = l.hour >= 12 ? 'PM' : 'AM';
      return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}  $h12:$min $ap';
    }

    final slots = insight.pandaSlots;
    final labeledAnswers = insight.pandaLabeledAnswers ?? {};
    final corrections = insight.pandaCorrections ?? [];
    final hasSlots = slots != null && !slots.isEmpty;
    final hasAnswers = labeledAnswers.isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black.withOpacity(0.07)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 8,
              offset: const Offset(0, 2))
        ],
      ),
      child: Theme(
        data: Theme.of(context)
            .copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          childrenPadding: const EdgeInsets.only(
              left: 16, right: 16, bottom: 16),
          title: Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(fmtDt(sessionDt),
                        style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            color: _ink)),
                    const SizedBox(height: 3),
                    Row(children: [
                      Text(
                          '${labeledAnswers.length} answers captured',
                          style: const TextStyle(
                              fontSize: 12,
                              color: Colors.black45)),
                      if (hasSlots) ...[
                        const SizedBox(width: 8),
                        _badge(
                            '${slots.toMap().length} insights',
                            _purple),
                      ],
                      if (corrections.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        _badge('${corrections.length} edits', _teal),
                      ],
                    ]),
                  ]),
            ),
            // Status pill
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.10),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                    color: Colors.green.withOpacity(0.3)),
              ),
              child: const Text('Complete',
                  style: TextStyle(
                      color: Colors.green,
                      fontSize: 11,
                      fontWeight: FontWeight.w700)),
            ),
          ]),
          children: [
            // Overall notes
            if (insight.body != null && insight.body!.isNotEmpty) ...[
              _noteBox(insight.body!),
              const SizedBox(height: 12),
            ],

            // Q→A pairs — spike labeled answers only
            // (category insights are excluded; they are conversation, not spike labels)
            if (hasAnswers) ...[
              Row(children: [
                const Expanded(
                  child: Text('Your Answers',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: _ink)),
                ),
                Text('tap ✏️ to correct',
                    style: TextStyle(
                        fontSize: 10,
                        color: Colors.black38,
                        fontStyle: FontStyle.italic)),
              ]),
              const SizedBox(height: 8),
              ...labeledAnswers.entries
                  // Only show spike answers (skip category:: keys)
                  .where((e) => !e.key.startsWith('category::'))
                  .map((e) {
                // Find the latest answer (account for corrections)
                final correctedEntry = corrections
                    .where((c) => c.questionId == e.key)
                    .lastOrNull;
                final displayAnswer =
                    correctedEntry?.newAnswer ?? e.value;
                final wasEdited = correctedEntry != null;

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: Colors.black.withOpacity(0.08)),
                    ),
                    child: Row(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10),
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Text(e.key,
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.black45,
                                        height: 1.35)),
                                const SizedBox(height: 3),
                                Row(children: [
                                  Expanded(
                                    child: Text(
                                        displayAnswer,
                                        style: const TextStyle(
                                            fontSize: 13,
                                            color: _ink,
                                            fontWeight:
                                                FontWeight.w500)),
                                  ),
                                  if (wasEdited)
                                    Padding(
                                      padding: const EdgeInsets
                                          .only(left: 4),
                                      child: Icon(
                                          Icons.edit_rounded,
                                          size: 11,
                                          color: _teal
                                              .withOpacity(0.6)),
                                    ),
                                ]),
                              ],
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: () => _editFirestoreAnswer(
                              insight: insight,
                              questionId: e.key,
                              currentAnswer: displayAnswer),
                          borderRadius: const BorderRadius.only(
                              topRight: Radius.circular(10),
                              bottomRight: Radius.circular(10)),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            child: const Text('✏️',
                                style: TextStyle(fontSize: 16)),
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
              const Text('Extracted Insights',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: _ink)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: slots.toMap().entries
                    .map((e) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: _teal.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: _teal.withOpacity(0.2)),
                          ),
                          child: Text('${e.key}: ${e.value}',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: _teal.withOpacity(0.9))),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 8),
            ],

            // Corrections audit trail
            if (corrections.isNotEmpty) ...[
              const SizedBox(height: 4),
              const Text('Edit History',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: _ink)),
              const SizedBox(height: 6),
              ...corrections.map((c) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Icon(Icons.edit_rounded,
                          size: 12,
                          color: _teal.withOpacity(0.5)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${c.questionId}: "${c.oldAnswer}" → "${c.newAnswer}"',
                          style: const TextStyle(
                              fontSize: 11,
                              color: Colors.black45,
                              height: 1.3),
                        ),
                      ),
                    ]),
                  )),
            ],
          ],
        ),
      ),
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
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: const Row(children: [
          Text('✏️  ', style: TextStyle(fontSize: 20)),
          Expanded(
              child: Text('Edit Answer',
                  style: TextStyle(
                      fontSize: 17, fontWeight: FontWeight.bold))),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(questionId,
                style: const TextStyle(
                    fontSize: 13,
                    color: Colors.black54,
                    height: 1.4,
                    fontStyle: FontStyle.italic)),
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
                  borderSide:
                      BorderSide(color: _purple.withOpacity(0.3)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: _purple, width: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
                '⚡ Correcting your answer helps Panda learn your stress patterns more accurately.',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.black38,
                    height: 1.4)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel',
                  style: TextStyle(color: Colors.black45))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _purple,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
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

    final resolvedUserId = _currentUserId.isNotEmpty
        ? _currentUserId
        : _svc.getActiveDemoUser().userId;

    try {
      await _insightSvc.correctAnswer(
        userId: resolvedUserId,
        insightId: insight.id!,
        questionId: questionId,
        oldAnswer: currentAnswer,
        newAnswer: newAnswer,
      );
      // The Firestore stream will push the updated insight automatically.
    } catch (e) {
      // ignore: avoid_print
      print('[PandaScreen] correctAnswer failed: $e');
    }
  }

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10,
              color: color,
              fontWeight: FontWeight.w600)),
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
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.psychology_outlined,
            size: 16, color: _purple),
        const SizedBox(width: 8),
        Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontSize: 13, color: _purple, height: 1.4))),
      ]),
    );
  }

  void _showSafetyDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24)),
        title: const Row(children: [
          Icon(Icons.shield_outlined, color: Colors.blueAccent),
          SizedBox(width: 10),
          Text('Privacy & Safety',
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold)),
        ]),
        content: const Text(
            'All health insights and conversations are encrypted and private.',
            style: TextStyle(fontSize: 15, height: 1.4)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Got it',
                  style: TextStyle(
                      color: _purple,
                      fontWeight: FontWeight.bold))),
        ],
      ),
    );
  }

  Widget _RecCard({required PandaRec rec}) {
    final Color catColor = _recCategoryColor(rec.category);
    return GestureDetector(
      onTap:
          rec.deepLink != null ? () => _launchUrl(rec.deepLink!) : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: catColor.withOpacity(0.25), width: 1.3),
          boxShadow: [
            BoxShadow(
                color: catColor.withOpacity(0.07),
                blurRadius: 8,
                offset: const Offset(0, 2))
          ],
        ),
        child: Row(children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: catColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
                child: Text(rec.emoji,
                    style: const TextStyle(fontSize: 18))),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(rec.title,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: catColor)),
                  const SizedBox(height: 2),
                  Text(rec.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11.5,
                          color: Colors.black54,
                          height: 1.35)),
                ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (rec.durationLabel != null)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: catColor.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(rec.durationLabel!,
                    style: TextStyle(
                        fontSize: 10,
                        color: catColor,
                        fontWeight: FontWeight.w600)),
              ),
            if (rec.deepLink != null) ...[
              const SizedBox(height: 4),
              Icon(Icons.open_in_new_rounded,
                  size: 14, color: catColor.withOpacity(0.5)),
            ],
          ]),
        ]),
      ),
    );
  }

  Color _recCategoryColor(RecCategory cat) {
    switch (cat) {
      case RecCategory.music:     return const Color(0xFF1DB954);
      case RecCategory.breathing: return const Color(0xFF5B8DEF);
      case RecCategory.movement:  return const Color(0xFFFF6B6B);
      case RecCategory.sleep:     return const Color(0xFF9B72CF);
      case RecCategory.focus:     return const Color(0xFFFFAA00);
      case RecCategory.social:    return const Color(0xFF0ABFBC);
      case RecCategory.nutrition: return const Color(0xFF4CAF50);
      case RecCategory.journal:   return const Color(0xFFFF8C69);
    }
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Widget _avatar() => Container(
        width: 40,
        height: 40,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          image: DecorationImage(
              image: AssetImage('assets/panda_icon.png'),
              fit: BoxFit.contain),
        ),
      );
}

// =============================================================================
// Data models
// =============================================================================

enum _Role { user, assistant }
enum _TurnKind { normal, digression, depth, recommend, categoryMenu }

class _Turn {
  _Turn({
    required this.role,
    required this.text,
    this.kind = _TurnKind.normal,
    this.recs = const [],
    this.categoryOptions = const [],
    this.categoryColor,
    this.categoryLabel,
  });
  final _Role role;
  final String text;
  final _TurnKind kind;
  final List<PandaRec> recs;
  final List<String> categoryOptions;
  final Color? categoryColor;
  /// Which category set this menu belongs to — needed to route option taps.
  final String? categoryLabel;

  factory _Turn.user(String t) => _Turn(role: _Role.user, text: t);
  factory _Turn.assistant(String t, {
    _TurnKind kind = _TurnKind.normal,
    List<PandaRec> recs = const [],
    List<String> categoryOptions = const [],
    Color? categoryColor,
    String? categoryLabel,
  }) =>
      _Turn(
          role: _Role.assistant,
          text: t,
          kind: kind,
          recs: recs,
          categoryOptions: categoryOptions,
          categoryColor: categoryColor,
          categoryLabel: categoryLabel);
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
            duration: const Duration(milliseconds: 600))
          ..repeat(reverse: true));
    _anims = _ctrls
        .map((c) => Tween<double>(begin: 0.25, end: 1.0).animate(
            CurvedAnimation(parent: c, curve: Curves.easeInOut)))
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
                color: Colors.grey.shade400, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}

