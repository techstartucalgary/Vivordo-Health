import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import '../src/services/gemini_service.dart';

class StressSpikeTestPage extends StatefulWidget {
  const StressSpikeTestPage({super.key});

  @override
  State<StressSpikeTestPage> createState() => _StressSpikeTestPageState();
}

// ---- Chat auto-scroll ----
final Map<String, ScrollController> _chatScrollBySpikeId = {};

ScrollController _getChatScroll(String spikeId) {
  return _chatScrollBySpikeId.putIfAbsent(spikeId, () => ScrollController());
}

void _scrollChatToBottom(String spikeId, {bool animated = true}) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final controller = _chatScrollBySpikeId[spikeId];
    if (controller == null) return;
    if (!controller.hasClients) return;

    final target = controller.position.maxScrollExtent;
    if (animated) {
      controller.animateTo(
        target,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    } else {
      controller.jumpTo(target);
    }
  });
}

// ---- Chat auto-scroll ----
final Map<String, ScrollController> _chatScrollBySpikeId = {};

ScrollController _getChatScroll(String spikeId) {
  return _chatScrollBySpikeId.putIfAbsent(spikeId, () => ScrollController());
}

void _scrollChatToBottom(String spikeId, {bool animated = true}) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final controller = _chatScrollBySpikeId[spikeId];
    if (controller == null) return;
    if (!controller.hasClients) return;

    final target = controller.position.maxScrollExtent;
    if (animated) {
      controller.animateTo(
        target,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    } else {
      controller.jumpTo(target);
    }
  });
}

class _StressSpikeTestPageState extends State<StressSpikeTestPage> {
  final _contextController = TextEditingController();
  final _service = GeminiService();

  bool _loading = false;

  Stopwatch? _stopwatch;
  Timer? _timer;
  Duration _elapsed = Duration.zero;

  String? _jsonOutput;
  String? _error;

  // ---- Demo user banner ----
  Map<String, dynamic>? _demoUserMap;

  // ---- Demo user banner ----
  Map<String, dynamic>? _demoUserMap;

  // ---- History ----
  final List<_RunRecord> _history = [];
  static const int _maxHistory = 10;

  // ---- Chatbot state (per run) ----
  Map<String, dynamic>? _lastDecoded; // full parsed JSON result
  final Map<String, _SpikeChatSession> _sessionsBySpikeId = {};
  String? _activeSpikeId; // which spike is currently open in chatbot UI
  final TextEditingController _otherController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _refreshDemoUserBanner();
  }

  void _refreshDemoUserBanner() {
    final demo = _service.peekDemoUser();
    setState(() => _demoUserMap = demo.toMap());
  }

  void _switchUser() {
    _service.pickNewDemoUser();
    _refreshDemoUserBanner();

    for (final c in _chatScrollBySpikeId.values) {
      c.dispose();
    }
    _chatScrollBySpikeId.clear();

    setState(() {
      _lastDecoded = null;
      _sessionsBySpikeId.clear();
      _activeSpikeId = null;
      _jsonOutput = null;
      _error = null;
    });
  }


  // ---- Chatbot state (per run) ----
  Map<String, dynamic>? _lastDecoded; // full parsed JSON result
  final Map<String, _SpikeChatSession> _sessionsBySpikeId = {};
  String? _activeSpikeId; // which spike is currently open in chatbot UI
  final TextEditingController _otherController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _refreshDemoUserBanner();
  }

  void _refreshDemoUserBanner() {
    final demo = _service.peekDemoUser();
    setState(() => _demoUserMap = demo.toMap());
  }

  void _switchUser() {
    _service.pickNewDemoUser();
    _refreshDemoUserBanner();

    for (final c in _chatScrollBySpikeId.values) {
      c.dispose();
    }
    _chatScrollBySpikeId.clear();

    setState(() {
      _lastDecoded = null;
      _sessionsBySpikeId.clear();
      _activeSpikeId = null;
      _jsonOutput = null;
      _error = null;
    });
  }


  // ---- Timer helpers ----
  void _startTimer() {
    _stopwatch = Stopwatch()..start();
    _elapsed = Duration.zero;

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      setState(() => _elapsed = _stopwatch?.elapsed ?? Duration.zero);
      setState(() => _elapsed = _stopwatch?.elapsed ?? Duration.zero);
    });
  }

  void _stopTimer() {
    _stopwatch?.stop();
    _timer?.cancel();
    _timer = null;

    if (!mounted) return;
    setState(() => _elapsed = _stopwatch?.elapsed ?? _elapsed);
    setState(() => _elapsed = _stopwatch?.elapsed ?? _elapsed);
  }

  String _formatDuration(Duration d) {
    final seconds = (d.inMilliseconds / 1000.0).toStringAsFixed(2);
    return "$seconds s";
  }

  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hour12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final min = local.minute.toString().padLeft(2, '0');
    final ampm = local.hour >= 12 ? 'PM' : 'AM';
    return "$y-$m-$d  $hour12:$min $ampm";
  }

  // ---- Main action ----
  Future<void> _runTest() async {
    final startedAt = DateTime.now();
    int? spikeCount;
    bool success = false;
    String? historyError;

    setState(() {
      _loading = true;
      _lastDecoded = null;

      _sessionsBySpikeId.clear();
      _activeSpikeId = null;

      for (final c in _chatScrollBySpikeId.values) {
        c.dispose();
      }
      _chatScrollBySpikeId.clear();

      _lastDecoded = null;

      _sessionsBySpikeId.clear();
      _activeSpikeId = null;

      for (final c in _chatScrollBySpikeId.values) {
        c.dispose();
      }
      _chatScrollBySpikeId.clear();

      _jsonOutput = null;
      _error = null;
    });



    _startTimer();

    try {
      final rawSample = _service.getSampleData();
      final compact = _service.buildCompactPayloadForTest(rawSample, topK: 3);
      final rawSample = _service.getSampleData();
      final compact = _service.buildCompactPayloadForTest(rawSample, topK: 3);

      final raw = await _service
          .analyzeStressSpikes(
            data: compact,
            data: compact,
            extraUserContext: _contextController.text,
          )
          .timeout(const Duration(seconds: 90));
          .timeout(const Duration(seconds: 90));

      final decoded = _tryDecodeJson(raw);

      if (decoded == null) {
        historyError = "Could not parse JSON.";
        historyError = "Could not parse JSON.";
        setState(() {
          _error = "Could not parse JSON. Try again.";
          _error = "Could not parse JSON. Try again.";
          _jsonOutput = raw;
        });
      } else {
        final prettyJson = const JsonEncoder.withIndent('  ').convert(decoded);

        final spikes = decoded["spikes"];
        if (spikes is List) spikeCount = spikes.length;

        _initChatSessionsFromDecoded(decoded);

        _initChatSessionsFromDecoded(decoded);

        success = true;

        setState(() {
          _lastDecoded = decoded;
          _lastDecoded = decoded;
          _jsonOutput = prettyJson;
        });
      }
    } on TimeoutException {
      historyError = "Request timed out after 90 seconds.";
      setState(() => _error = "Request timed out after 90 seconds.");
      historyError = "Request timed out after 90 seconds.";
      setState(() => _error = "Request timed out after 90 seconds.");
    } catch (e) {
      historyError = e.toString();
      historyError = e.toString();
      setState(() => _error = e.toString());
    } finally {
      _stopTimer();
      final duration = _elapsed;

      // Push history record (include conversation logs snapshot if available)
      // Push history record (include conversation logs snapshot if available)
      _addHistory(
        _RunRecord(
          startedAt: startedAt,
          duration: duration,
          spikeCount: spikeCount,
          success: success,
          error: historyError,
          contextSnippet: _contextController.text.trim().isEmpty
              ? null
              : _contextController.text.trim(),
          spikeConversations: _sessionsBySpikeId.values
              .map((s) => s.toLog())
              .toList(),
          spikeConversations: _sessionsBySpikeId.values
              .map((s) => s.toLog())
              .toList(),
        ),
      );

      if (mounted) setState(() => _loading = false);
    }
  }

  void _addHistory(_RunRecord record) {
    if (!mounted) return;
    setState(() {
      _history.insert(0, record);
      if (_history.length > _maxHistory) {
        _history.removeRange(_maxHistory, _history.length);
      }
    });
  }

  void _clearHistory() {
    setState(() => _history.clear());
    setState(() => _history.clear());
  }

  // ---- JSON parsing helpers ----
  Map<String, dynamic>? _tryDecodeJson(String text) {
    try {
      var cleaned = text.trim();

      cleaned = cleaned
          .replaceAll(RegExp(r'^```[a-zA-Z]*\s*'), '')
          .replaceAll(RegExp(r'\s*```$'), '')
          .trim();

      final start = cleaned.indexOf('{');
      final end = cleaned.lastIndexOf('}');
      if (start == -1 || end == -1 || end <= start) return null;

      cleaned = cleaned.substring(start, end + 1);
      cleaned = cleaned.replaceAll('\u2028', '').replaceAll('\u2029', '');
      cleaned = cleaned
          .replaceAll(RegExp(r'^```[a-zA-Z]*\s*'), '')
          .replaceAll(RegExp(r'\s*```$'), '')
          .trim();

      final start = cleaned.indexOf('{');
      final end = cleaned.lastIndexOf('}');
      if (start == -1 || end == -1 || end <= start) return null;

      cleaned = cleaned.substring(start, end + 1);
      cleaned = cleaned.replaceAll('\u2028', '').replaceAll('\u2029', '');

      final obj = jsonDecode(cleaned);
      if (obj is Map<String, dynamic>) return obj;
      return null;
    } catch (_) {
    } catch (_) {
      return null;
    }
  }

  // ---- Chatbot session init ----
  void _initChatSessionsFromDecoded(Map<String, dynamic> decoded) {
  // ---- Chatbot session init ----
  void _initChatSessionsFromDecoded(Map<String, dynamic> decoded) {
    final spikes = decoded["spikes"];
    if (spikes is! List) return;
    if (spikes is! List) return;

    _sessionsBySpikeId.clear();
    _sessionsBySpikeId.clear();

    for (final s in spikes) {
      if (s is! Map) continue;
    for (final s in spikes) {
      if (s is! Map) continue;

      final spikeId = s["spike_id"]?.toString() ?? "unknown_spike";
      _getChatScroll(spikeId);
      final startIso = s["start"]?.toString();
      final endIso = s["end"]?.toString();

      final spikeId = s["spike_id"]?.toString() ?? "unknown_spike";
      _getChatScroll(spikeId);
      final startIso = s["start"]?.toString();
      final endIso = s["end"]?.toString();

      final timePhrase = _formatTimeRange(startIso, endIso);

      // Build a short assistant opener with optional hypothesis/event hints
      String hint = "";
      final hypotheses = s["hypotheses"];
      if (hypotheses is List && hypotheses.isNotEmpty && hypotheses.first is Map) {
        final h0 = hypotheses.first as Map;
        final reason = h0["reason"]?.toString();
        if (reason != null && reason.trim().isNotEmpty) {
          hint = " It may be related to ${reason.trim()}.";
      // Build a short assistant opener with optional hypothesis/event hints
      String hint = "";
      final hypotheses = s["hypotheses"];
      if (hypotheses is List && hypotheses.isNotEmpty && hypotheses.first is Map) {
        final h0 = hypotheses.first as Map;
        final reason = h0["reason"]?.toString();
        if (reason != null && reason.trim().isNotEmpty) {
          hint = " It may be related to ${reason.trim()}.";
        }
      }

      final opener =
          "I noticed a spike around $timePhrase.$hint Let’s label what was happening so this data becomes more accurate.";

      // Questions script from model
      final questions = <_SpikeQuestion>[];
      final qs = s["questions"];
      if (qs is List) {
        for (final q in qs) {
          if (q is! Map) continue;
          final qid = q["question_id"]?.toString() ?? "q_${questions.length + 1}";
          final prompt = q["prompt"]?.toString() ?? "";
          final type = q["type"]?.toString() ?? "single_choice";

          final opts = <String>[];
          final optionsAny = q["options"];
          if (optionsAny is List) {
            for (final o in optionsAny) {
              final t = o.toString().trim();
              if (t.isNotEmpty) opts.add(t);
            }
          }

          questions.add(_SpikeQuestion(
            questionId: qid,
            prompt: prompt,
            type: type,
            options: opts,
          ));
      final opener =
          "I noticed a spike around $timePhrase.$hint Let’s label what was happening so this data becomes more accurate.";

      // Questions script from model
      final questions = <_SpikeQuestion>[];
      final qs = s["questions"];
      if (qs is List) {
        for (final q in qs) {
          if (q is! Map) continue;
          final qid = q["question_id"]?.toString() ?? "q_${questions.length + 1}";
          final prompt = q["prompt"]?.toString() ?? "";
          final type = q["type"]?.toString() ?? "single_choice";

          final opts = <String>[];
          final optionsAny = q["options"];
          if (optionsAny is List) {
            for (final o in optionsAny) {
              final t = o.toString().trim();
              if (t.isNotEmpty) opts.add(t);
            }
          }

          questions.add(_SpikeQuestion(
            questionId: qid,
            prompt: prompt,
            type: type,
            options: opts,
          ));
        }
      }

      // If model forgot questions, add one safe fallback
      if (questions.isEmpty) {
        questions.add(
          _SpikeQuestion(
            questionId: "q_fallback",
            prompt: "What best describes what was happening around that time?",
            type: "single_choice",
            options: const ["Exercise", "Work/School", "Social", "Commute", "Other"],
          ),
        );
      }

      final session = _SpikeChatSession(
        spikeId: spikeId,
        opener: opener,
        questions: questions,
      );

      // Start transcript
      session.turns.add(_ChatTurn.assistant(opener));

      // Ask first question
      session.turns.add(_ChatTurn.assistant(session.currentQuestion.prompt));

      _sessionsBySpikeId[spikeId] = session;
    }

    // Select first spike by default
    final firstId = _sessionsBySpikeId.keys.isNotEmpty
        ? _sessionsBySpikeId.keys.first
        : null;

    _activeSpikeId = firstId;
    if (_activeSpikeId != null) {
      _getChatScroll(_activeSpikeId!);
      _scrollChatToBottom(_activeSpikeId!, animated: false);
    }

  }

  // ---- Chat actions ----
  void _selectSpike(String spikeId) {
    setState(() => _activeSpikeId = spikeId);
    _getChatScroll(spikeId);
    _scrollChatToBottom(spikeId, animated: false);
  }


  void _answerWithOption(String spikeId, String option) {
    final session = _sessionsBySpikeId[spikeId];
    if (session == null || session.isComplete) return;

    setState(() {
      session.turns.add(_ChatTurn.user(option));
      session.captureAnswer(option);

      if (session.isComplete) {
        session.turns.add(_ChatTurn.assistant(
          "Got it — thanks. You can switch spikes above, or save this conversation.",
        ));
      } else {
        session.turns.add(_ChatTurn.assistant(session.currentQuestion.prompt));
      }
    });

    _scrollChatToBottom(spikeId);
  }


  void _answerWithOtherText(String spikeId) {
    final text = _otherController.text.trim();
    if (text.isEmpty) return;

    _otherController.clear();
    _answerWithOption(spikeId, text);
  }

  // Placeholder: backend save hook
  Future<void> _saveConversationToBackend(_SpikeChatSession session) async {
    // TODO: Replace with Firestore / backend write.
    // Example future shape:
    // await FirebaseFirestore.instance.collection("stress_labels").add(session.toBackendMap());

    // For now, just show a snackbar confirming where you’ll plug it in.
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Saved placeholder: hook Firestore here later.")),
    );
  }

  // ---- Time formatting ----
  // ---- Time formatting ----
  String _formatTimeRange(String? startIso, String? endIso) {
    try {
      if (startIso == null) return "an unknown time";

      final start = DateTime.parse(startIso).toLocal();
      final startStr = _formatTime(start);
      final start = DateTime.parse(startIso).toLocal();
      final startStr = _formatTime(start);

      if (endIso == null) return startStr;
      if (endIso == null) return startStr;

      final end = DateTime.parse(endIso).toLocal();
      final endStr = _formatTime(end);
      final end = DateTime.parse(endIso).toLocal();
      final endStr = _formatTime(end);

      return "$startStr–$endStr";
    } catch (_) {
      return "an unknown time";
    }
  }
      return "$startStr–$endStr";
    } catch (_) {
      return "an unknown time";
    }
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return "$hour:$minute $period";
  }
  String _formatTime(DateTime dt) {
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return "$hour:$minute $period";
  }

  @override
  void dispose() {
    _timer?.cancel();
    _stopwatch?.stop();

    for (final c in _chatScrollBySpikeId.values) {
      c.dispose();
    }
    _chatScrollBySpikeId.clear();


    for (final c in _chatScrollBySpikeId.values) {
      c.dispose();
    }
    _chatScrollBySpikeId.clear();

    _contextController.dispose();
    _otherController.dispose();
    _otherController.dispose();
    super.dispose();
  }



  @override
  Widget build(BuildContext context) {
    final demo = _demoUserMap;

    final userLine = demo == null
        ? "Current Demo User: —"
        : "Current Demo User: ${demo["userId"]} • ${demo["stressCategory"]} • Stress ${demo["dailyStressLevel"]}";

    final demo = _demoUserMap;

    final userLine = demo == null
        ? "Current Demo User: —"
        : "Current Demo User: ${demo["userId"]} • ${demo["stressCategory"]} • Stress ${demo["dailyStressLevel"]}";

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Stress Spike Test'),
          bottom: const TabBar(
            tabs: [
              Tab(text: "Test"),
              Tab(text: "History"),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildTestTab(userLine),
            _buildHistoryTab(),
            _buildTestTab(userLine),
            _buildHistoryTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildTestTab(String userLine) {
    final session = (_activeSpikeId == null) ? null : _sessionsBySpikeId[_activeSpikeId!];
  Widget _buildTestTab(String userLine) {
    final session = (_activeSpikeId == null) ? null : _sessionsBySpikeId[_activeSpikeId!];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(userLine, style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                TextButton(
                  onPressed: _loading ? null : _switchUser,
                  child: const Text("Switch User"),
                ),
              ],
            ),
            const SizedBox(height: 10),

            Row(
              children: [
                Expanded(
                  child: Text(userLine, style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                TextButton(
                  onPressed: _loading ? null : _switchUser,
                  child: const Text("Switch User"),
                ),
              ],
            ),
            const SizedBox(height: 10),

            TextField(
              controller: _contextController,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: 'Optional context (for better questions)',
                hintText: 'e.g., had a quiz at 9am, drank extra coffee...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 12),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loading ? null : _runTest,
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : const Text('Run Gemini on Sample Data'),
              ),
            ),

            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  _loading ? "LLM Execution Time: " : "Last LLM Time: ",
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  _formatDuration(_elapsed),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: _loading ? Colors.deepPurple : Colors.black87,
                  ),
                ),
                if (_loading) ...[
                  const SizedBox(width: 10),
                  const Text("(running...)", style: TextStyle(color: Colors.deepPurple)),
                  const Text("(running...)", style: TextStyle(color: Colors.deepPurple)),
                ],
              ],
            ),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loading ? null : _runTest,
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : const Text('Run Gemini on Sample Data'),
              ),
            ),

            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  _loading ? "LLM Execution Time: " : "Last LLM Time: ",
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  _formatDuration(_elapsed),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: _loading ? Colors.deepPurple : Colors.black87,
                  ),
                ),
                if (_loading) ...[
                  const SizedBox(width: 10),
                  const Text("(running...)", style: TextStyle(color: Colors.deepPurple)),
                ],
              ],
            ),

            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],

            const SizedBox(height: 12),
            const SizedBox(height: 12),

            Expanded(
              child: Column(
                children: [
                _Panel(
                  title: "Friendly Output (Chatbot)",
                  child: _buildChatbot(session),
                  scroll: false, // IMPORTANT
                ),

                _Panel(
                  title: "JSON Output",
                  child: SelectableText(
                    _jsonOutput ?? "JSON output will appear here.",
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  ),
                  scroll: true, // JSON needs scroll
                ),

                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatbot(_SpikeChatSession? session) {
    if (_lastDecoded == null) {
      return const Text("Run the test to start a labeling conversation.");
    }

    if (_sessionsBySpikeId.isEmpty) {
      return const Text("No spike sessions available.");
    }

    final spikeIds = _sessionsBySpikeId.keys.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Spike selector (chips)
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: spikeIds.map((id) {
            final selected = id == _activeSpikeId;
            return ChoiceChip(
              label: Text(id),
              selected: selected,
              onSelected: (_) => _selectSpike(id),
            );
          }).toList(),
        ),
        const SizedBox(height: 10),
        if (session == null) const Text("Select a spike above."),
        if (session != null) ...[
          Expanded(
            child: ListView.builder(
              controller: _getChatScroll(session.spikeId),
              itemCount: session.turns.length,
              itemBuilder: (context, index) {
                final t = session.turns[index];
                final isUser = t.role == _ChatRole.user;

                return Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    constraints: const BoxConstraints(maxWidth: 520),
                    decoration: BoxDecoration(
                      color: isUser ? Colors.deepPurple.withOpacity(0.12) : Colors.black12,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.black12),
                    ),
                    child: Text(t.text),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 10),

          if (!session.isComplete) ...[
            // Option buttons for current question
            _buildOptionButtons(session),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _otherController,
                    decoration: InputDecoration(
                      hintText: "Other (type your own answer)",
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _answerWithOtherText(session.spikeId),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () => _answerWithOtherText(session.spikeId),
                  child: const Text("Send"),
                )
              ],
            ),
          ] else ...[
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: () => _saveConversationToBackend(session),
                  icon: const Icon(Icons.save),
                  label: const Text("Save conversation (placeholder)"),
                ),
                const SizedBox(width: 10),
                Text(
                  "Captured: ${session.answers.length} answers",
                  style: const TextStyle(color: Colors.black54),
                )
              ],
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildOptionButtons(_SpikeChatSession session) {
    final q = session.currentQuestion;

    // If no options, we rely on "Other" input
    if (q.options.isEmpty) {
      return const Text("No preset options for this question. Use the text box below.");
    }

    // Render as tappable chips/buttons
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: q.options.map((opt) {
        return OutlinedButton(
          onPressed: () => _answerWithOption(session.spikeId, opt),
          child: Text(opt),
        );
      }).toList(),
    );
  }

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
                    "Recent Runs (latest first)",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
                TextButton(
                  onPressed: _history.isEmpty ? null : _clearHistory,
                  child: const Text("Clear"),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _history.isEmpty
                  ? const Center(
                      child: Text(
                        "No history yet.\nRun the test to see entries here.",
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.separated(
                      itemCount: _history.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final r = _history[index];

                        final statusText = r.success ? "Success" : "Failed";
                        final statusColor =
                            r.success ? Colors.green : Colors.red;

                        final spikesText = r.spikeCount == null
                            ? "Spikes: —"
                            : "Spikes: ${r.spikeCount}";

                        return Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.black12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      _formatDateTime(r.startedAt),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: statusColor.withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(
                                          color: statusColor.withOpacity(0.4)),
                                    ),
                                    child: Text(
                                      statusText,
                                      style: TextStyle(
                                        color: statusColor,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Text(
                                    "Time: ${_formatDuration(r.duration)}",
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Text(spikesText),
                                ],
                              ),
                              if (r.contextSnippet != null &&
                                  r.contextSnippet!.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(
                                  "Context: ${r.contextSnippet}",
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.black54),
                                ),
                              ],
                              if (!r.success && r.error != null) ...[
                                const SizedBox(height: 6),
                                Text(
                                  "Error: ${r.error}",
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.red),
                                ),
                              ],

                              // ---- Conversation Logs (from chatbot) ----
                              if (r.spikeConversations.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                const Text(
                                  "Conversations (logged)",
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 6),
                                ...r.spikeConversations.map((c) {
                                  return ExpansionTile(
                                    tilePadding: EdgeInsets.zero,
                                    title: Text("Spike: ${c.spikeId} • Answers: ${c.answers.length}"),
                                    children: [
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withOpacity(0.03),
                                          borderRadius: BorderRadius.circular(10),
                                          border: Border.all(color: Colors.black12),
                                        ),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            const Text(
                                              "Transcript",
                                              style: TextStyle(fontWeight: FontWeight.w600),
                                            ),
                                            const SizedBox(height: 6),
                                            ...c.turns.map((t) {
                                              final prefix = t.role == _ChatRole.user ? "You: " : "Vivordo Assistant: ";
                                              return Padding(
                                                padding: const EdgeInsets.symmetric(vertical: 2),
                                                child: Text("$prefix${t.text}"),
                                              );
                                            }).toList(),
                                            const SizedBox(height: 10),
                                            const Text(
                                              "Captured Answers",
                                              style: TextStyle(fontWeight: FontWeight.w600),
                                            ),
                                            const SizedBox(height: 6),
                                            ...c.answers.entries.map((e) {
                                              return Text("${e.key}: ${e.value}");
                                            }).toList(),
                                            const SizedBox(height: 10),
                                            Text(
                                              "Backend hook: call save with this spikeId + answers map.",
                                              style: TextStyle(color: Colors.black.withOpacity(0.55)),
                                            )
                                          ],
                                        ),
                                      ),
                                    ],
                                  );
                                }).toList(),
                              ],

                              // ---- Conversation Logs (from chatbot) ----
                              if (r.spikeConversations.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                const Text(
                                  "Conversations (logged)",
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 6),
                                ...r.spikeConversations.map((c) {
                                  return ExpansionTile(
                                    tilePadding: EdgeInsets.zero,
                                    title: Text("Spike: ${c.spikeId} • Answers: ${c.answers.length}"),
                                    children: [
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withOpacity(0.03),
                                          borderRadius: BorderRadius.circular(10),
                                          border: Border.all(color: Colors.black12),
                                        ),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            const Text(
                                              "Transcript",
                                              style: TextStyle(fontWeight: FontWeight.w600),
                                            ),
                                            const SizedBox(height: 6),
                                            ...c.turns.map((t) {
                                              final prefix = t.role == _ChatRole.user ? "You: " : "Vivordo Assistant: ";
                                              return Padding(
                                                padding: const EdgeInsets.symmetric(vertical: 2),
                                                child: Text("$prefix${t.text}"),
                                              );
                                            }).toList(),
                                            const SizedBox(height: 10),
                                            const Text(
                                              "Captured Answers",
                                              style: TextStyle(fontWeight: FontWeight.w600),
                                            ),
                                            const SizedBox(height: 6),
                                            ...c.answers.entries.map((e) {
                                              return Text("${e.key}: ${e.value}");
                                            }).toList(),
                                            const SizedBox(height: 10),
                                            Text(
                                              "Backend hook: call save with this spikeId + answers map.",
                                              style: TextStyle(color: Colors.black.withOpacity(0.55)),
                                            )
                                          ],
                                        ),
                                      ),
                                    ],
                                  );
                                }).toList(),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.child,
    this.scroll = false,
  });
  const _Panel({
    required this.title,
    required this.child,
    this.scroll = false,
  });

  final String title;
  final Widget child;

  // when true, Panel will wrap child in a scroll view (good for long text like JSON)
  final bool scroll;

  // when true, Panel will wrap child in a scroll view (good for long text like JSON)
  final bool scroll;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.black12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Expanded(
              child: scroll ? SingleChildScrollView(child: child) : child,
              child: scroll ? SingleChildScrollView(child: child) : child,
            ),
          ],
        ),
      ),
    );
  }
}


// ---------------------
// Chatbot data models
// ---------------------

enum _ChatRole { user, assistant }

class _ChatTurn {
  _ChatTurn({required this.role, required this.text, DateTime? at})
      : timestamp = at ?? DateTime.now();

  final _ChatRole role;
  final String text;
  final DateTime timestamp;

  factory _ChatTurn.user(String text) => _ChatTurn(role: _ChatRole.user, text: text);
  factory _ChatTurn.assistant(String text) =>
      _ChatTurn(role: _ChatRole.assistant, text: text);
}

class _SpikeQuestion {
  const _SpikeQuestion({
    required this.questionId,
    required this.prompt,
    required this.type,
    required this.options,
  });

  final String questionId;
  final String prompt;
  final String type;
  final List<String> options;
}

class _SpikeChatSession {
  _SpikeChatSession({
    required this.spikeId,
    required this.opener,
    required this.questions,
  });

  final String spikeId;
  final String opener;
  final List<_SpikeQuestion> questions;

  final List<_ChatTurn> turns = [];
  final Map<String, String> answers = {}; // question_id -> answer

  int _questionIndex = 0;

  bool get isComplete => _questionIndex >= questions.length;

  _SpikeQuestion get currentQuestion =>
      questions[_questionIndex.clamp(0, questions.length - 1)];

  void captureAnswer(String answerText) {
    if (isComplete) return;

    final qid = currentQuestion.questionId;
    answers[qid] = answerText;

    _questionIndex++;
  }

  _SpikeConversationLog toLog() {
    return _SpikeConversationLog(
      spikeId: spikeId,
      turns: List<_ChatTurn>.from(turns),
      answers: Map<String, String>.from(answers),
    );
  }

  // Optional: shape you can later send to backend
  Map<String, dynamic> toBackendMap() {
    return {
      "spike_id": spikeId,
      "answers": answers,
      "turns": turns
          .map((t) => {
                "role": t.role == _ChatRole.user ? "user" : "assistant",
                "text": t.text,
                "timestamp": t.timestamp.toIso8601String(),
              })
          .toList(),
      "created_at": DateTime.now().toIso8601String(),
    };
  }
}

// What gets logged into History
class _SpikeConversationLog {
  _SpikeConversationLog({
    required this.spikeId,
    required this.turns,
    required this.answers,
  });

  final String spikeId;
  final List<_ChatTurn> turns;
  final Map<String, String> answers;
}


// ---------------------
// Chatbot data models
// ---------------------

enum _ChatRole { user, assistant }

class _ChatTurn {
  _ChatTurn({required this.role, required this.text, DateTime? at})
      : timestamp = at ?? DateTime.now();

  final _ChatRole role;
  final String text;
  final DateTime timestamp;

  factory _ChatTurn.user(String text) => _ChatTurn(role: _ChatRole.user, text: text);
  factory _ChatTurn.assistant(String text) =>
      _ChatTurn(role: _ChatRole.assistant, text: text);
}

class _SpikeQuestion {
  const _SpikeQuestion({
    required this.questionId,
    required this.prompt,
    required this.type,
    required this.options,
  });

  final String questionId;
  final String prompt;
  final String type;
  final List<String> options;
}

class _SpikeChatSession {
  _SpikeChatSession({
    required this.spikeId,
    required this.opener,
    required this.questions,
  });

  final String spikeId;
  final String opener;
  final List<_SpikeQuestion> questions;

  final List<_ChatTurn> turns = [];
  final Map<String, String> answers = {}; // question_id -> answer

  int _questionIndex = 0;

  bool get isComplete => _questionIndex >= questions.length;

  _SpikeQuestion get currentQuestion =>
      questions[_questionIndex.clamp(0, questions.length - 1)];

  void captureAnswer(String answerText) {
    if (isComplete) return;

    final qid = currentQuestion.questionId;
    answers[qid] = answerText;

    _questionIndex++;
  }

  _SpikeConversationLog toLog() {
    return _SpikeConversationLog(
      spikeId: spikeId,
      turns: List<_ChatTurn>.from(turns),
      answers: Map<String, String>.from(answers),
    );
  }

  // Optional: shape you can later send to backend
  Map<String, dynamic> toBackendMap() {
    return {
      "spike_id": spikeId,
      "answers": answers,
      "turns": turns
          .map((t) => {
                "role": t.role == _ChatRole.user ? "user" : "assistant",
                "text": t.text,
                "timestamp": t.timestamp.toIso8601String(),
              })
          .toList(),
      "created_at": DateTime.now().toIso8601String(),
    };
  }
}

// What gets logged into History
class _SpikeConversationLog {
  _SpikeConversationLog({
    required this.spikeId,
    required this.turns,
    required this.answers,
  });

  final String spikeId;
  final List<_ChatTurn> turns;
  final Map<String, String> answers;
}

class _RunRecord {
  _RunRecord({
    required this.startedAt,
    required this.duration,
    required this.success,
    this.spikeCount,
    this.error,
    this.contextSnippet,
    this.spikeConversations = const [],
    this.spikeConversations = const [],
  });

  final DateTime startedAt;
  final Duration duration;
  final bool success;
  final int? spikeCount;
  final String? error;
  final String? contextSnippet;

  // New: logs captured from chatbot
  final List<_SpikeConversationLog> spikeConversations;

  // New: logs captured from chatbot
  final List<_SpikeConversationLog> spikeConversations;
}
