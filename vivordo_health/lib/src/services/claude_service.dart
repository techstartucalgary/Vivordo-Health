import 'dart:async';
import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'ai_service.dart';
import 'gemini_service.dart';

export 'ai_service.dart'
    show kMaxInputTokens, kMaxOutputTokensChat, kMaxOutputTokensSpike;

// =============================================================================
// ClaudeService
//
// Implements AIService by proxying every LLM call through the `pandaClaude`
// Firebase HTTPS Callable Cloud Function.  The function holds the Anthropic
// API key in Secret Manager — the key NEVER leaves the server (VIV-309).
//
// Cloud Function contract:
//   Request : { "system": String, "user": String }
//   Response: { "text": String }   (raw JSON from Claude)
//
// All data-processing logic (Firestore fetch, compact payload, JSON parsing)
// delegates to GeminiService static helpers to avoid duplication.
// =============================================================================

class ClaudeService implements AIService {
  static final _fn = FirebaseFunctions.instance.httpsCallable('pandaClaude');

  // Appended to GeminiService.spikeSystemPrompt for Claude calls.
  // Together they must exceed 1,024 tokens so Anthropic caches the prefix.
  static const _spikeJsonSuffix = '''

OUTPUT FORMAT
Return ONLY a valid JSON object. No markdown fences, no backticks, no prose outside
the braces. Any text outside the JSON will break the parser.

Required top-level keys:
  "summary": {
    "data_window_start": "ISO-8601 string — start of the analysis window",
    "data_window_end":   "ISO-8601 string — end of the analysis window",
    "overall_notes":     "≤140 chars — one sentence describing the week at a glance"
  },
  "spikes": [ /* zero or more spike objects — see schema below */ ]

Spike object schema:
  "spike_id":  "spk_N" (N = 1-based index),
  "day":       "human day label — copy DATA spike.day verbatim, e.g. \"Wed, Jun 17\"",
  "start":     "YYYY-MM-DD — the day the spike occurred (DATE ONLY, no time)",
  "end":       "YYYY-MM-DD — same day (DATE ONLY, no time)",
  "signals": {
    "heart_rate": { "baseline": number, "peak": number },
    "hrv":        { "baseline": number, "min": number },
    "steps":      { "peak_window": number }
  },
  "context":   { "nearby_events": [], "confidence": 0.0–1.0 },
  "hypotheses": [
    { "label": string, "reason": "≤80 chars", "confidence": 0.0–1.0 }
  ],
  "questions": [
    {
      "question_id":   "q_N",
      "prompt":        "≤90 chars — what were you doing / feeling?",
      "type":          "multiple_choice",
      "options":       ["Chip A 😊", "Chip B 😕", "Something else 🙋"],
      "depth_prompts": ["follow-up 1", "follow-up 2"]
    }
  ],
  "ml_labels_to_collect": ["label_key_1", "label_key_2"]

RULES
• Max 3 questions per spike. Prefer multiple-choice with 4-5 options plus
  "Something else 🙋". Never ask open-ended questions on the predefined path.
• Vary phrasing across calls — never reuse the same question wording verbatim.
• Generate 2-3 depth_prompts per question for the "tell me more" flow.
• Keep question prompts ≤ 90 chars, overall_notes ≤ 140 chars.
• Do NOT diagnose. Use "may be related to" language. Never say "stress" alone
  — say "work-related stress" or "social pressure" etc.
• Do NOT invent symptoms, events, journal entries, goals, or any context not
  present in DATA. If a field is absent, omit it from your hypotheses.
• DAILY DATA ONLY: metrics are daily aggregates — you do NOT know the time of
  day a spike happened. Reference the DAY (copy spike.day) and NEVER state or
  invent a clock time ("2pm", "noon", "this morning", "afternoon", "evening").
• If no spikes are detected, return "spikes": [] with a reassuring overall_notes.

HYPOTHESIS LABEL TAXONOMY
Use exactly these label strings in hypotheses[].label:
  work_stress      — deadline, meeting, performance pressure, task overload
  social_conflict  — argument, disagreement, difficult conversation, social pressure
  exercise         — intentional workout, sport, physical training (HR spike is expected)
  illness          — feeling unwell, fever, physical discomfort
  anxiety          — general worry, rumination, panic, anticipatory stress
  commute          — travel, transport delays, driving in traffic
  family           — family conflict, caregiving pressure, domestic tension
  financial        — money worries, bills, job security
  environmental    — noise, heat, crowding, sensory overload
  unknown          — no clear trigger identifiable from available data

ML LABELS TO COLLECT PER SPIKE
"ml_labels_to_collect" must be a subset of these keys:
  stressor_type    — which hypothesis label applies (required for every spike)
  stress_intensity — low | medium | high | very_high
  aware_at_time    — was the user aware of stress as it happened? yes | no | retrospective
  coping_used      — did the user try a coping strategy? yes | no | not_yet
  trigger_recurs   — is this a recurring trigger? yes | no | unsure

QUESTION PHRASING GUIDE
• Use conversational language: "What was going on for you on [DAY]?" not
  "What was your primary activity during the spike window?"
• Reference the DAY using spike.day (e.g. "on Wed, Jun 17") — NEVER a clock time.
• Name the signal: "your heart rate reached [PEAK] bpm that day" grounds it in data
• Chip option order: most likely hypothesis first, then alternatives, then
  "Something else 🙋" always last
• depth_prompts should be open-ended: "What made that feel particularly hard?"
  not leading: "Was it the deadline that caused it?"

EXAMPLE OUTPUT (reference only — vary wording each call)
{
  "summary": {
    "data_window_start": "2026-06-09",
    "data_window_end": "2026-06-16",
    "overall_notes": "One notable spike on Tuesday — heart rate reached 115 bpm."
  },
  "spikes": [{
    "spike_id": "spk_1",
    "day": "Tue, Jun 16",
    "start": "2026-06-16",
    "end": "2026-06-16",
    "signals": {
      "heart_rate": {"baseline": 62.0, "peak": 115.0},
      "hrv": {"baseline": 52.0, "min": 38.0},
      "steps": {"peak_window": 847.0}
    },
    "context": {"nearby_events": [], "confidence": 0.72},
    "hypotheses": [
      {"label": "work_stress",
       "reason": "Low steps that day — may be related to desk-bound deadline pressure",
       "confidence": 0.74}
    ],
    "questions": [{
      "question_id": "q_1",
      "prompt": "What was going on for you on Tue, Jun 16 when your HR hit 115 bpm?",
      "type": "multiple_choice",
      "options": ["Work / study 📚", "Exercise 🏃", "Social situation 👥", "Commute 🚗", "Something else 🙋"],
      "depth_prompts": [
        "What made that day feel particularly stressful?",
        "How long did that pressure last?"
      ]
    }],
    "ml_labels_to_collect": ["stressor_type", "stress_intensity", "aware_at_time"]
  }]
}''';

  // Dialogue system prompt — must stay above 1,024 tokens (Anthropic cache min)
  // so the cache fires on turn 2+ of every session.
  static const _dialogueSystem =
      'You are Robot, a warm, empathetic wellness companion in the Vivordo app.\n'
      'Your role is to help users understand their stress patterns through structured\n'
      'but caring conversations grounded in their real Apple Health data.\n'
      '\n'
      'RESPONSE FORMAT\n'
      'Return ONLY a valid JSON object — no markdown fences, no backticks, no prose\n'
      'outside the JSON. Any text outside the braces will break the parser.\n'
      '\n'
      'Required schema:\n'
      '{\n'
      '  "intent": string,\n'
      '  "message": string,\n'
      '  "depth_follow_up": string,\n'
      '  "injected_question": {\n'
      '    "question_id": string,\n'
      '    "prompt": string,\n'
      '    "options": [string]\n'
      '  },\n'
      '  "filled_slots": {\n'
      '    "stressor": string,\n'
      '    "emotion": string,\n'
      '    "intensity": string,\n'
      '    "physical_symptom": string,\n'
      '    "activity": string,\n'
      '    "location": string,\n'
      '    "time_context": string,\n'
      '    "coping_strategy": string,\n'
      '    "sleep_quality": string,\n'
      '    "social_context": string,\n'
      '    "other": string\n'
      '  },\n'
      '  "rec_hint": string,\n'
      '  "calendar_action": {"operation": string, "title": string, '
      '"target_title": string, "start": string, "end": string, "recurrence": string}\n'
      '}\n'
      '\n'
      'INTENT VALUES — choose exactly one:\n'
      '"answer_label"        — User answered a predefined question. Acknowledge\n'
      '                        warmly, reflect what you heard, and note a pattern\n'
      '                        if one is evident. Do NOT ask the next predefined\n'
      '                        question — the app sequences these automatically.\n'
      '"want_deeper_answer"  — User seems to want to explore further. Set\n'
      '                        depth_follow_up to one open-ended probe.\n'
      '"digress"             — User brought up a new topic not on the predefined\n'
      '                        path. Engage genuinely for up to 3 turns.\n'
      '"digression_complete" — Digression is wrapping up. Return gently to the\n'
      '                        main predefined path.\n'
      '"new_stressor"        — A fresh stressor emerges mid-conversation. Set\n'
      '                        injected_question with 3-5 chip options plus\n'
      '                        "Something else 🙋".\n'
      '"recommend"           — Offer a concrete coping strategy. Set rec_hint to\n'
      '                        comma-separated keywords (e.g. "breathing, anxiety").\n'
      '                        Write one warm intro sentence only — the app renders\n'
      '                        the recommendation cards.\n'
      '"chitchat"            — General chat not requiring structured slot capture.\n'
      '"skip"                — User explicitly declines to engage on a topic.\n'
      '"calendar_action"     — User asks to create, update, or delete a Google Calendar event.\n'
      '                        Fill calendar_action; use local ISO-8601 start/end. title is the\n'
      '                        new title and target_title identifies an existing event. Never\n'
      '                        guess missing title/date/time; ask a chitchat clarification.\n'
      '\n'
      'TONE PRINCIPLES\n'
      '• Warm peer, never clinical. Say "may be related to" — never diagnose.\n'
      '• Concrete over vague: "Try 4-7-8 breathing for 2 minutes before your next\n'
      '  meeting" beats "Try to relax".\n'
      '• 2-4 sentences per message. Longer feels overwhelming.\n'
      '• Digression depth ≥ 3 turns: begin warmly steering back to the main path.\n'
      '• Never ask the next predefined question — the app handles sequencing.\n'
      '• Never ask more than one question per turn.\n'
      '• Reference the Apple Health data (heart rate, HRV, steps) when relevant —\n'
      '  it makes insights feel grounded rather than generic.\n'
      '• Availability/planning asks ("when am I free / mentally available"): when a\n'
      '  SCHEDULE block is provided, use it to find open windows, then weigh them\n'
      '  against the stress/energy patterns in APPLE HEALTH CONTEXT to recommend\n'
      '  the best time(s). Name a specific day + time range. If no SCHEDULE block is\n'
      '  present, tell them their calendar isn\'t connected. Keep intent "chitchat".\n'
      '• MEMORY: you DO have access to past sessions. When a "PAST INSIGHTS" block\n'
      '  is present it holds the user\'s recurring stressors, emotions, coping, and\n'
      '  recent session recaps — use it to personalise and show continuity. NEVER\n'
      '  say you lack access to past insights or saved data when that block exists.\n'
      '\n'
      'SLOT EXTRACTION RULES\n'
      'Extract values from what the user says in THIS turn only. Use "" for any\n'
      'slot not mentioned. Do not carry forward values — the app merges slots\n'
      'across turns.\n'
      '"intensity" must be exactly "low", "medium", or "high". Infer:\n'
      '  "a bit stressed" / "slightly" → "low"\n'
      '  "pretty overwhelmed" / "quite anxious" → "medium"\n'
      '  "completely panicked" / "can\'t cope" → "high"\n'
      '"stressor" should be a short noun phrase (e.g. "work deadline", "argument\n'
      '  with partner", "exam pressure") — not a sentence.\n'
      '"coping_strategy" should capture what the user did or tried, even if it\n'
      '  was unhelpful (e.g. "avoidance", "distraction", "exercise").\n'
      '\n'
      'ANTI-PATTERNS — never do these:\n'
      '• Do NOT say "I understand that must be hard" without following up with\n'
      '  something concrete or a specific reflection.\n'
      '• Do NOT ask two questions in one message turn.\n'
      '• Do NOT invent context, journal entries, events, or stressors not stated\n'
      '  by the user or present in Apple Health data.\n'
      '• Do NOT use words like "diagnose", "disorder", "condition", "therapy".\n'
      '• Do NOT use the 💜 emoji or ANY heart emoji (❤️🩷💜💙 etc.) anywhere.\n'
      '• Do NOT produce prose outside the JSON object.\n'
      '\n'
      'REC_HINT VOCABULARY — use these keywords for the rec engine:\n'
      'breathing          box-breathing, 4-7-8 technique, slow exhale\n'
      'grounding          5-4-3-2-1 senses, body scan, cold water on wrists\n'
      'movement           walk, light stretch, stair climb, desk mobility\n'
      'sleep              wind-down routine, screen-off 30min, sleep hygiene\n'
      'social             reach out, short call, share feelings, connect\n'
      'reframe            cognitive reframe, silver lining, perspective shift\n'
      'boundary           say no, limit scope, communicate capacity\n'
      'schedule           time-block, prioritise, single-task, Pomodoro\n'
      'nutrition          hydration, light snack, caffeine timing\n'
      'nature             outdoor break, sunlight, fresh air\n'
      'journaling         brain dump, gratitude list, worry log\n'
      'music              calming playlist, focus music, nature sounds\n'
      '\n'
      'EXAMPLE OUTPUTS (vary wording — these are reference patterns only)\n'
      '\n'
      'intent: answer_label — user chose "Work / study 📚"\n'
      '{"intent":"answer_label","message":"Work stress mid-afternoon — that '
      'lines right up with your 2pm heart rate spike. Deadline pressure is one '
      'of the most common triggers we see in health data like yours. '
      'You\'re definitely not alone in this pattern.","depth_follow_up":"",'
      '"injected_question":null,"filled_slots":{"stressor":"work deadline",'
      '"emotion":"","intensity":"","physical_symptom":"","activity":"work_focus",'
      '"location":"","time_context":"afternoon","coping_strategy":"",'
      '"sleep_quality":"","social_context":"","other":""},"rec_hint":""}\n'
      '\n'
      'intent: want_deeper_answer — user said "yeah it was pretty stressful"\n'
      '{"intent":"want_deeper_answer","message":"That kind of pressure builds '
      'fast, especially when it\'s hard to switch off. What part of it felt '
      'most draining — the workload itself, or how long it lasted?",'
      '"depth_follow_up":"What part felt most draining — the workload, or '
      'how long it lasted?","injected_question":null,"filled_slots":{"stressor":"",'
      '"emotion":"stressed","intensity":"medium","physical_symptom":"",'
      '"activity":"","location":"","time_context":"","coping_strategy":"",'
      '"sleep_quality":"","social_context":"","other":""},"rec_hint":""}\n'
      '\n'
      'intent: recommend — user described feeling anxious and overwhelmed\n'
      '{"intent":"recommend","message":"Given what you\'ve described, a quick '
      '4-7-8 breathing reset before high-stakes tasks can genuinely bring that '
      'heart rate down — your data shows it responds well to short pauses.",'
      '"depth_follow_up":"","injected_question":null,"filled_slots":{"stressor":"",'
      '"emotion":"anxious","intensity":"high","physical_symptom":"elevated heart rate",'
      '"activity":"","location":"","time_context":"","coping_strategy":"",'
      '"sleep_quality":"","social_context":"","other":""},'
      '"rec_hint":"breathing, anxiety"}\n'
      '\n'
      'intent: digress — user brought up sleep problems mid-session\n'
      '{"intent":"digress","message":"Sleep is so tightly linked to how your '
      'heart rate recovers overnight — it\'s worth talking about. '
      'What\'s been getting in the way of a good night recently?",'
      '"depth_follow_up":"","injected_question":null,"filled_slots":{"stressor":"",'
      '"emotion":"","intensity":"","physical_symptom":"","activity":"",'
      '"location":"","time_context":"","coping_strategy":"","sleep_quality":"poor",'
      '"social_context":"","other":""},"rec_hint":""}';

  static String _buildAppleHealthContext(
    List<Map<String, dynamic>> spikeContext,
  ) {
    final trimmed = GeminiService.trimSpikeContext(spikeContext);
    return 'APPLE HEALTH CONTEXT\n${jsonEncode(trimmed)}';
  }

  static Map<String, dynamic> _cacheBlock(String text) => {
    'type': 'text',
    'text': text,
    'cache_control': {'type': 'ephemeral'},
  };

  // ---------------------------------------------------------------------------
  // analyzePandaSession
  // ---------------------------------------------------------------------------

  @override
  Future<PandaSessionData> analyzePandaSession({
    String? extraUserContext,
    String? userName,
    String? userId,
  }) async {
    if (userId == null || userId.isEmpty) {
      return GeminiService.emptyStateSession(userName ?? 'there');
    }

    final payload = await GeminiService.fetchRealUserPayload(userId);
    if (payload == null) {
      return GeminiService.emptyStateSession(userName ?? 'there');
    }

    final compact = GeminiService.buildCompactPayload(payload, topK: 1);

    // Nothing to analyze (no spike candidates — e.g. every detected spike day
    // was already surfaced once). Skip the LLM round trip entirely: it would
    // just return `spikes: []` after several seconds. Opens the chat instantly.
    if ((compact['spike_candidates'] as List? ?? const []).isEmpty) {
      if (kDebugMode) {
        debugPrint('[Claude][spike] no spike candidates — skipping LLM call');
      }
      return GeminiService.noSpikesSession(payload, overrideName: userName);
    }

    return _runSpikeAnalysis(
      userId: userId,
      payload: payload,
      compact: compact,
      userName: userName,
      extraUserContext: extraUserContext,
    );
  }

  @override
  Future<PandaSessionBootstrap> startSession({
    String? extraUserContext,
    String? userName,
    String? userId,
  }) async {
    if (userId == null || userId.isEmpty) {
      return PandaSessionBootstrap(
        session: GeminiService.emptyStateSession(userName ?? 'there'),
      );
    }

    final payload = await GeminiService.fetchRealUserPayload(userId);
    if (payload == null) {
      return PandaSessionBootstrap(
        session: GeminiService.emptyStateSession(userName ?? 'there'),
      );
    }

    final compact = GeminiService.buildCompactPayload(payload, topK: 1);

    // Nothing to analyze → no LLM call at all; the chat is already final.
    if ((compact['spike_candidates'] as List? ?? const []).isEmpty) {
      if (kDebugMode) {
        debugPrint('[Claude][spike] no spike candidates — skipping LLM call');
      }
      return PandaSessionBootstrap(
        session: GeminiService.noSpikesSession(payload, overrideName: userName),
      );
    }

    // Opener NOW; the labeling questions stream in behind it.
    return PandaSessionBootstrap(
      session: GeminiService.bootstrapSession(
        payload,
        overrideName: userName,
        hasSpikes: true,
      ),
      spikeAnalysis: _runSpikeAnalysis(
        userId: userId,
        payload: payload,
        compact: compact,
        userName: userName,
        extraUserContext: extraUserContext,
      ),
    );
  }

  /// The spike-analysis LLM round trip — shared by analyzePandaSession (await)
  /// and startSession (background).
  Future<PandaSessionData> _runSpikeAnalysis({
    required String userId,
    required Map<String, dynamic> payload,
    required Map<String, dynamic> compact,
    String? userName,
    String? extraUserContext,
  }) async {
    compact['user_context'] = extraUserContext?.trim() ?? '';
    compact['_variability_seed'] =
        DateTime.now().millisecondsSinceEpoch % 100000;

    final userPrompt = GeminiService.buildSpikeUserPrompt(compact);
    final systemPrompt = '${GeminiService.spikeSystemPrompt}$_spikeJsonSuffix';

    final result = await _fn.call<dynamic>({
      'system': [_cacheBlock(systemPrompt)],
      'user': [
        {'type': 'text', 'text': userPrompt},
      ],
      'maxTokens': kMaxOutputTokensSpike,
    });

    final raw = (result.data as Map?)?['text']?.toString() ?? '';
    final usage = (result.data as Map?)?['usage'] as Map?;
    if (kDebugMode) {
      debugPrint('[Claude][spike] response length: ${raw.length} chars');
      debugPrint(
        '[Claude][spike] usage — input: ${usage?['input_tokens'] ?? 0}, '
        'output: ${usage?['output_tokens'] ?? 0}, '
        'cache_create: ${usage?['cache_creation_input_tokens'] ?? 0}, '
        'cache_read: ${usage?['cache_read_input_tokens'] ?? 0}',
      );
    }

    final session = GeminiService.parsePandaSession(
      raw,
      payload,
      overrideName: userName,
    );
    // Record the surfaced spike's day so Panda doesn't re-ask about it.
    if (AppFlags.dedupeAnalyzedSpikes && session.rawSpikes.isNotEmpty) {
      unawaited(
        GeminiService.markSpikeDaysAnalyzed(
          userId,
          GeminiService.spikeDaysFromCompact(compact),
        ),
      );
    }
    return session;
  }

  // ---------------------------------------------------------------------------
  // processTurn
  // ---------------------------------------------------------------------------

  @override
  Future<PandaTurnReply> processTurn({
    required String userMessage,
    required List<Map<String, String>> conversationHistory,
    required List<Map<String, dynamic>> spikeContext,
    required bool isOnPredefinedPath,
    required bool isInDigression,
    required int digressionTurnCount,
    String? pendingQuestionId,
    String? pendingQuestionPrompt,
    String? digressionTopic,
    Map<String, String>? accumulatedSlots,
    String? scheduleContext,
    String? insightsContext,
    String? dashboardContext,
  }) async {
    // Trim the conversation to fit rather than REFUSING the turn. The old guard
    // returned a canned "we've covered a lot of ground — let's wrap up" reply,
    // which ended the chat before the user was finished. Panda now always
    // answers, so the conversation reaches its own natural conclusion.
    final fitted = GeminiService.fitConversation(
      conversationHistory,
      userMessage,
    );
    final cappedHistory = fitted.history;
    final effectiveMessage = fitted.message;

    // Build health context once — reused in the cached system block.
    final healthCtx = _buildAppleHealthContext(spikeContext);
    // Schedule digest is stable for the session → goes in a cached system block.
    final scheduleCtx = (scheduleContext != null && scheduleContext.isNotEmpty)
        ? 'SCHEDULE (next 7 days, local time):\n$scheduleContext'
        : null;

    // embedSpikeContext/embedPersona/embedTaskInstructions: false — all three
    // are already in the cached system blocks (_dialogueSystem + healthCtx),
    // so omitting them from the user prompt saves ~110–130 uncached tokens/turn.
    final userPrompt = GeminiService.buildDialoguePrompt(
      userMessage: effectiveMessage,
      conversationHistory: cappedHistory,
      spikeContext: spikeContext,
      isOnPredefinedPath: isOnPredefinedPath,
      isInDigression: isInDigression,
      digressionTurnCount: digressionTurnCount,
      pendingQuestionId: pendingQuestionId,
      pendingQuestionPrompt: pendingQuestionPrompt,
      digressionTopic: digressionTopic,
      accumulatedSlots: accumulatedSlots,
      // Insights can change mid-session (a just-saved finding), so they are NOT
      // cached — embed them in the uncached user prompt so they're always fresh.
      insightsContext: insightsContext,
      dashboardContext: dashboardContext,
      embedSpikeContext: false,
      embedPersona: false,
      embedTaskInstructions: false,
      embedScheduleContext: false,
      embedInsightsContext: true,
    );

    // Stable cached blocks per session:
    //  1. dialogueSystem  — JSON schema + persona instructions (never changes)
    //  2. healthCtx       — spike data (stable for the session lifetime)
    //  3. scheduleCtx     — calendar digest (stable for the session lifetime)
    // accumulatedSlots are NOT cached because they change every turn and would
    // invalidate the cache.  They are already included in userPrompt via
    // buildDialoguePrompt ("SLOTS SO FAR: ...").
    final cachedSystem = [
      _cacheBlock(_dialogueSystem),
      _cacheBlock(healthCtx),
      if (scheduleCtx != null) _cacheBlock(scheduleCtx),
    ];

    final result = await _fn.call<dynamic>({
      'system': cachedSystem,
      'user': [
        {'type': 'text', 'text': userPrompt},
      ],
      'maxTokens': kMaxOutputTokensChat,
    });

    final raw = (result.data as Map?)?['text']?.toString() ?? '';
    final usage = (result.data as Map?)?['usage'] as Map?;
    if (kDebugMode) {
      debugPrint('[Claude][dialogue] response length: ${raw.length} chars');
      debugPrint(
        '[Claude][dialogue] usage — input: ${usage?['input_tokens'] ?? 0}, '
        'output: ${usage?['output_tokens'] ?? 0}, '
        'cache_create: ${usage?['cache_creation_input_tokens'] ?? 0}, '
        'cache_read: ${usage?['cache_read_input_tokens'] ?? 0}',
      );
    }

    return GeminiService.parseTurnReply(raw);
  }

  // ---------------------------------------------------------------------------
  // summarizeSession
  //
  // Generates the brief end-of-session continuity note via the pandaClaude
  // proxy. Reuses GeminiService.summarySystemPrompt + buildSummaryPrompt so
  // both backends produce the same shape. Returns '' on any failure so the
  // caller falls back to the deterministic summary.
  // ---------------------------------------------------------------------------

  @override
  Future<String> summarizeSession({
    required List<Map<String, String>> conversation,
    required Map<String, String> slots,
    required Map<String, String> labeledAnswers,
  }) async {
    try {
      final userPrompt = GeminiService.buildSummaryPrompt(
        conversation: conversation,
        slots: slots,
        labeledAnswers: labeledAnswers,
      );

      final estimated = GeminiService.estimateTokens(
        GeminiService.summarySystemPrompt + userPrompt,
      );
      if (estimated > kMaxInputTokens) return '';

      final result = await _fn.call<dynamic>({
        'system': [
          {'type': 'text', 'text': GeminiService.summarySystemPrompt},
        ],
        'user': [
          {'type': 'text', 'text': userPrompt},
        ],
        'maxTokens': kMaxOutputTokensSummary,
      });

      final raw = (result.data as Map?)?['text']?.toString() ?? '';
      if (kDebugMode) {
        final usage = (result.data as Map?)?['usage'] as Map?;
        debugPrint(
          '[Claude][summary] length: ${raw.length} chars, '
          'input: ${usage?['input_tokens'] ?? 0}, '
          'output: ${usage?['output_tokens'] ?? 0}',
        );
      }
      return raw.trim();
    } catch (e) {
      if (kDebugMode) debugPrint('[Claude][summary] failed: $e');
      return '';
    }
  }
}
