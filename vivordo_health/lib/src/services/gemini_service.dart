import 'dart:convert';
import 'package:firebase_ai/firebase_ai.dart';

import '../demo/demo_user_repository.dart';
import '../demo/demo_user_data.dart';

// =============================================================================
// ARCHITECTURE OVERVIEW
// =============================================================================
//
// This service implements a HYBRID DIALOGUE MANAGER based on 2025 best
// practices from Rasa, Aisera, and the ICM+LLM literature:
//
//   Predefined path  →  Structured labeling questions generated from spike data.
//                       Questions vary each session (seeded prompting + temp).
//                       User can go as deep as they want per question.
//
//   Undefined path   →  Fully open conversation: advice, tips, venting, etc.
//                       Triggered by intent = "digress" | "advice" | "support"
//
//   Dialogue stack   →  When user digreses mid-predefined-path, the path context
//                       is pushed onto a stack. After the digression is resolved
//                       (intent = "digression_complete"), it is popped and the
//                       predefined path resumes seamlessly.
//
//   Slot filling     →  Every turn, the model extracts wellness entities
//                       (stressor, emotion, intensity, activity, coping_strategy,
//                       etc.) and accumulates them in a slot store.
//
//   User data append →  appendEntitiesToUserData() is a placeholder that will
//                       write filled slots to the backend when the pipeline
//                       is ready.
//
// =============================================================================

// ---------------------------------------------------------------------------
// Public data classes
// ---------------------------------------------------------------------------

class PandaSessionData {
  PandaSessionData({
    required this.openerMessage,
    required this.questions,
    required this.overallNotes,
    required this.rawSpikes,
  });

  final String openerMessage;
  final List<PandaQuestion> questions;
  final String overallNotes;

  /// Raw spike JSON kept so the dialogue LLM has health data for context.
  final List<Map<String, dynamic>> rawSpikes;
}

class PandaQuestion {
  PandaQuestion({
    required this.questionId,
    required this.prompt,
    required this.options,
    this.depthPrompts = const [],
  });

  final String questionId;
  final String prompt;
  final List<String> options;

  /// Follow-up prompts to use when user wants to go deeper on this topic.
  /// Populated by the LLM; the app picks the next one when depth > 0.
  final List<String> depthPrompts;
}

// ---------------------------------------------------------------------------
// Intent classification
//
// Based on ICM+LLM hybrid pattern (Aisera / Rasa 2025):
//   answerLabel         → user answered the current structured question
//   wantDeeperAnswer    → user elaborated / wants to go deeper on same topic
//   digress             → user left the path (advice / support / tips / vent)
//   digressionComplete  → user signals they're done with the digression
//   newStressor         → user mentioned a new event — inject a follow-up Q
//   recommend           → user explicitly asked for recommendations (playlists,
//                         exercises, tips, etc.) — triggers rec card rendering
//   chitchat            → casual small-talk
//   skip                → user wants to skip current question
// ---------------------------------------------------------------------------
enum PandaIntent {
  answerLabel,
  wantDeeperAnswer,
  digress,
  digressionComplete,
  newStressor,
  recommend,
  chitchat,
  skip,
}

/// Full structured reply from a single dialogue turn.
class PandaTurnReply {
  PandaTurnReply({
    required this.intent,
    required this.message,
    this.depthFollowUp,
    this.injectedQuestion,
    this.filledSlots,
    this.recHint,
  });

  final PandaIntent intent;

  /// What Panda says (always present, never empty).
  final String message;

  /// When intent == wantDeeperAnswer: a follow-up probing question to ask
  /// the user to keep them engaged at greater depth.
  final String? depthFollowUp;

  /// When intent == newStressor: inject this question into the queue.
  final PandaQuestion? injectedQuestion;

  /// Slot values extracted from this turn (accumulated across session).
  final Map<String, String>? filledSlots;

  /// When intent == recommend: comma-separated keywords hinting which
  /// recommendation categories/topics the user is interested in.
  /// e.g. "music, breathing, sleep" — fed to RecommendationEngine.
  /// The LLM does NOT know the catalog; it only signals intent + keywords.
  final String? recHint;
}

// ---------------------------------------------------------------------------
// Dialogue stack frame — pushed when entering a digression
// ---------------------------------------------------------------------------
class _DialStackFrame {
  _DialStackFrame({
    required this.pendingQuestionId,
    required this.pendingQuestionPrompt,
    required this.digressionTopic,
    required this.turnCount,
  });

  /// The question we were in the middle of when the digression started.
  final String pendingQuestionId;
  final String pendingQuestionPrompt;

  /// What topic triggered the digression (for context in the resume message).
  final String digressionTopic;

  /// How many turns we've been in this digression (for depth limiting).
  int turnCount;
}

// ---------------------------------------------------------------------------
// GeminiService
// ---------------------------------------------------------------------------

class GeminiService {
  GeminiService()
      : _spikeModel = FirebaseAI.googleAI().generativeModel(
          model: 'gemini-3-flash-preview',
          generationConfig: GenerationConfig(
            responseMimeType: 'application/json',
            responseSchema: _spikeSchema,
            candidateCount: 1,
            temperature: 0,
            maxOutputTokens: 1800,
          ),
        ),
        _dialogueModel = FirebaseAI.googleAI().generativeModel(
          model: 'gemini-3-flash-preview',
          generationConfig: GenerationConfig(
            responseMimeType: 'application/json',
            responseSchema: _turnSchema,
            candidateCount: 1,
            // 0.5 gives natural variability without going off-rails
            temperature: 0.5,
            maxOutputTokens: 800,
          ),
        );

  final GenerativeModel _spikeModel;
  final GenerativeModel _dialogueModel;

  final DemoUserRepository _demoRepo = DemoUserRepository();
  DemoUserData? _activeDemoUser;

  DemoUserData getActiveDemoUser() {
    _activeDemoUser ??= _demoRepo.getRandomDemoUser();
    return _activeDemoUser!;
  }

  DemoUserData switchDemoUser() {
    _activeDemoUser = _demoRepo.getRandomDemoUser();
    return _activeDemoUser!;
  }

  DemoUserData peekDemoUser() => getActiveDemoUser();
  DemoUserData pickNewDemoUser() => switchDemoUser();

  Map<String, dynamic> buildCompactPayloadForTest(Map<String, dynamic> raw,
          {int topK = 3}) =>
      _buildCompactPayload(raw, topK: topK);

  // =========================================================================
  // Spike analysis schema
  //
  // The spike model uses temperature=0 and deterministic schema for
  // consistent structured output. VARIABILITY is achieved by:
  //   1. Including a _variability_seed in the payload (timestamp-derived)
  //   2. Instructing the model to rephrase questions differently each time
  //   3. Generating depth_prompts (follow-up probes per question)
  // =========================================================================

  static const String _spikeSystemPrompt = '''
You are Vivordo Stress Labeling Assistant.

GOAL: Given pre-detected spike candidates + events, generate varied labeling
questions to collect ML labels. Also generate depth probes for each question
so the user can explore each topic as deeply as they wish.

RULES:
- Do NOT diagnose or give medical advice. Use "may be related to" language.
- Max 3 questions per spike. Prefer multiple-choice + open option.
- VARY the phrasing each call — never reuse the same wording.
- Generate 2–3 depth_prompts per question (open-ended follow-ups if user wants more).
- Keep question prompts ≤ 90 chars. overall_notes ≤ 140 chars.
- Return ONLY valid JSON. No markdown, no extra text.
''';

  static final Schema _spikeSchema = Schema(
    SchemaType.object,
    properties: {
      "summary": Schema(SchemaType.object, properties: {
        "data_window_start": Schema(SchemaType.string),
        "data_window_end": Schema(SchemaType.string),
        "overall_notes": Schema(SchemaType.string),
      }),
      "spikes": Schema(SchemaType.array,
          items: Schema(SchemaType.object, properties: {
            "spike_id": Schema(SchemaType.string),
            "start": Schema(SchemaType.string),
            "end": Schema(SchemaType.string),
            "signals": Schema(SchemaType.object, properties: {
              "heart_rate": Schema(SchemaType.object, properties: {
                "baseline": Schema(SchemaType.number),
                "peak": Schema(SchemaType.number),
              }),
              "hrv": Schema(SchemaType.object, properties: {
                "baseline": Schema(SchemaType.number),
                "min": Schema(SchemaType.number),
              }),
              "steps": Schema(SchemaType.object, properties: {
                "peak_window": Schema(SchemaType.number),
              }),
            }),
            "context": Schema(SchemaType.object, properties: {
              "nearby_events": Schema(SchemaType.array,
                  items: Schema(SchemaType.object, properties: {
                    "time": Schema(SchemaType.string),
                    "type": Schema(SchemaType.string),
                    "detail": Schema(SchemaType.string),
                  })),
              "confidence": Schema(SchemaType.number),
            }),
            "hypotheses": Schema(SchemaType.array,
                items: Schema(SchemaType.object, properties: {
                  "label": Schema(SchemaType.string),
                  "reason": Schema(SchemaType.string),
                  "confidence": Schema(SchemaType.number),
                })),
            "questions": Schema(SchemaType.array,
                items: Schema(SchemaType.object, properties: {
                  "question_id": Schema(SchemaType.string),
                  "prompt": Schema(SchemaType.string),
                  "type": Schema(SchemaType.string),
                  "options": Schema(SchemaType.array,
                      items: Schema(SchemaType.string)),
                  // NEW: follow-up depth probes for this question
                  "depth_prompts": Schema(SchemaType.array,
                      items: Schema(SchemaType.string)),
                })),
            "ml_labels_to_collect":
                Schema(SchemaType.array, items: Schema(SchemaType.string)),
          })),
    },
  );

  // =========================================================================
  // Dialogue turn schema
  //
  // Based on ICM+LLM best practices:
  //   • intent classification (structured)
  //   • slot filling / entity extraction (for user data enrichment)
  //   • warm natural response (with immediate delivery of advice)
  //   • optional depth follow-up probe
  //   • optional injected question (new stressor)
  // =========================================================================

  static final Schema _turnSchema = Schema(
    SchemaType.object,
    properties: {
      // Intent — one of the PandaIntent values (snake_case string)
      "intent": Schema(SchemaType.string),

      // Panda's response. MUST deliver advice/tips immediately if asked.
      "message": Schema(SchemaType.string),

      // When intent == want_deeper_answer: next open-ended probe to keep user going
      "depth_follow_up": Schema(SchemaType.string),

      // When intent == new_stressor: inject this question
      "injected_question": Schema(SchemaType.object, properties: {
        "question_id": Schema(SchemaType.string),
        "prompt": Schema(SchemaType.string),
        "options": Schema(SchemaType.array, items: Schema(SchemaType.string)),
      }),

      // Slot filling — extract any wellness entities from the user's message.
      // Leave fields empty ("") if not mentioned.
      "filled_slots": Schema(SchemaType.object, properties: {
        "stressor": Schema(SchemaType.string),
        "emotion": Schema(SchemaType.string),
        "intensity": Schema(SchemaType.string),      // low / medium / high
        "physical_symptom": Schema(SchemaType.string),
        "activity": Schema(SchemaType.string),
        "location": Schema(SchemaType.string),
        "time_context": Schema(SchemaType.string),
        "coping_strategy": Schema(SchemaType.string),
        "sleep_quality": Schema(SchemaType.string),
        "social_context": Schema(SchemaType.string),
        "other": Schema(SchemaType.string),
      }),

      // When intent == "recommend": comma-separated keywords describing what
      // the user is looking for. e.g. "music, sleep, breathing, exercise".
      // The app uses this to query RecommendationEngine — LLM never sees catalog.
      "rec_hint": Schema(SchemaType.string),
    },
  );

  // =========================================================================
  // Sample data
  // =========================================================================

  Map<String, dynamic> getSampleData() {
    final demo = getActiveDemoUser();
    final day = DateTime.tryParse(demo.date) ?? DateTime.now();
    final start = DateTime(day.year, day.month, day.day, 18, 0);
    final end = start.add(const Duration(hours: 24));
    final baselineHr = demo.restingHeartRate.toDouble();
    final baselineHrv = demo.hrv.toDouble();
    final samples = <Map<String, dynamic>>[];
    final stressLift = (demo.dailyStressLevel / 25.0);
    final hrvDrop = (demo.dailyStressLevel / 40.0);
    final stepsPerHour = (demo.stepsCount / 24.0);

    for (int i = 0; i < 24; i++) {
      final t = start.add(Duration(hours: i));
      double hr = baselineHr + stressLift;
      double hrv = baselineHrv - hrvDrop;
      double steps = stepsPerHour;
      String activity = "sedentary";
      String tag = "";

      if (i == 14) {
        activity = "light";
        tag = "commute";
        steps += 200;
        hr += 10;
      }
      if (i == 15) {
        activity = "sedentary";
        tag = "work_focus";
        if (demo.stressed) {
          hr += 30;
          hrv -= 18;
        } else {
          hr += 12;
          hrv -= 6;
        }
      }
      if (i == 20) {
        activity = "sedentary";
        tag = "deadline";
        final extra = (demo.stressVariability / 10.0);
        hr += extra;
        hrv -= extra / 2.0;
      }
      if (i == 22 && demo.exerciseSessions > 0) {
        activity = "workout";
        tag = "gym";
        hr += 50;
        hrv -= 22;
        steps += 900;
      }

      hr = hr.clamp(45, 190);
      hrv = hrv.clamp(10, 140);
      steps = steps.clamp(0, 2500);

      samples.add({
        "t": t.toIso8601String(),
        "hr": hr.round(),
        "hrv": hrv.round(),
        "steps": steps.round(),
        "stress_score": demo.dailyStressLevel,
        "activity": activity,
        "tag": tag,
      });
    }

    final events = <Map<String, dynamic>>[
      {
        "time": start
            .add(const Duration(hours: 13, minutes: 40))
            .toIso8601String(),
        "type": "caffeine",
        "detail": demo.stressed ? "coffee (strong)" : "coffee (small)",
      },
      {
        "time": start.add(const Duration(hours: 15)).toIso8601String(),
        "type": "work",
        "detail": "work / class start",
      },
      {
        "time": start.add(const Duration(hours: 20)).toIso8601String(),
        "type": "work",
        "detail": "deadline / high focus",
      },
      if (demo.exerciseSessions > 0)
        {
          "time": start.add(const Duration(hours: 22)).toIso8601String(),
          "type": "activity",
          "detail": "gym workout started",
        },
    ];

    return {
      "demo_user": demo.toMap(),
      "user_profile": {
        "timezone": demo.timezone,
        "age_range": (demo.age < 18) ? "teen" : "adult",
        "resting_hr_typical": demo.restingHeartRate,
        "hrv_rmssd_typical": demo.hrv,
      },
      "data_window": {
        "start": start.toIso8601String(),
        "end": end.toIso8601String(),
      },
      "samples_5min": samples,
      "events": events,
      "sleep_summary": {
        "total_minutes": (demo.sleepDurationHours * 60).round(),
        "sleep_quality": demo.sleepQualityScore,
      },
    };
  }

  // =========================================================================
  // Spike analysis
  // =========================================================================

  Future<String> analyzeStressSpikes({
    required Map<String, dynamic> data,
    String? extraUserContext,
  }) async {
    final Map<String, dynamic> compact = data.containsKey("spike_candidates")
        ? Map<String, dynamic>.from(data)
        : _buildCompactPayload(data, topK: 3);

    compact["user_context"] = extraUserContext?.trim() ?? "";

    // Variability seed: time-based so every call produces fresh question phrasing
    compact["_variability_seed"] =
        DateTime.now().millisecondsSinceEpoch % 100000;

    final userPrompt = '''
Use ONLY the spikes/events/context in DATA. Do NOT invent symptoms or events.

Use DATA.user_context (if non-empty) and DATA.journal:
- Mention briefly in summary.overall_notes
- At least ONE question per spike must reference user_context OR journal

For each question, generate 2–3 depth_prompts (open-ended follow-ups that
encourage the user to elaborate further if they want to go deeper).

Vary the question phrasing — do not reuse wording from previous calls.
(Hint: _variability_seed = ${compact["_variability_seed"]})

Return ONLY valid JSON. No markdown. No backticks.
Include every schema key (use "", 0, [] for unknowns).

DATA: ${jsonEncode(compact)}
''';

    final response = await _spikeModel.generateContent([
      Content.text(_spikeSystemPrompt),
      Content.text(userPrompt),
    ]);
    return response.text ?? '';
  }

  // =========================================================================
  // Panda session init
  // =========================================================================

  Future<PandaSessionData> analyzePandaSession({
    String? extraUserContext,
    // Override the greeting name with the real Firebase user first name.
    // When null, falls back to the demo userId as before.
    String? userName,
  }) async {
    final rawSample = getSampleData();   // REPLACE with real data when pipeline ready
    final compact = _buildCompactPayload(rawSample, topK: 1);
    final raw = await analyzeStressSpikes(
        data: compact, extraUserContext: extraUserContext);
    return _parsePandaSession(raw, rawSample, overrideName: userName);
  }

  // =========================================================================
  // Dialogue turn  —  the core of the hybrid dialogue manager
  //
  // Implements:
  //   • Intent classification (ICM-style structured output)
  //   • Slot filling (entity extraction per turn)
  //   • Depth-adaptive responses (user can go as deep as they want)
  //   • Digression handling with dialogue stack context
  //   • Immediate delivery rule (never promise without delivering)
  // =========================================================================

  Future<PandaTurnReply> processTurn({
    required String userMessage,
    required List<Map<String, String>> conversationHistory,
    required List<Map<String, dynamic>> spikeContext,

    // Path state passed in from PandaScreen
    required bool isOnPredefinedPath,
    required bool isInDigression,
    required int digressionTurnCount,

    // Current pending question (null if session complete or free mode)
    String? pendingQuestionId,
    String? pendingQuestionPrompt,

    // If we are in a digression: what triggered it
    String? digressionTopic,

    // All slots filled so far this session (for context)
    Map<String, String>? accumulatedSlots,
  }) async {
    final historyText = conversationHistory
        .map((t) =>
            "${t['role'] == 'user' ? 'User' : 'Panda'}: ${t['text']}")
        .join('\n');

    // Build path context string for the LLM
    final StringBuffer pathCtx = StringBuffer();
    if (isInDigression) {
      pathCtx.writeln('STATE: IN_DIGRESSION');
      pathCtx.writeln(
          'The user left the predefined path. Digression topic: "${digressionTopic ?? "unknown"}"');
      pathCtx.writeln(
          'Digression depth: $digressionTurnCount turn(s).');
      pathCtx.writeln(
          'If the user seems satisfied / wrapping up, set intent = "digression_complete".');
    } else if (isOnPredefinedPath && pendingQuestionPrompt != null) {
      pathCtx.writeln('STATE: ON_PREDEFINED_PATH');
      pathCtx
          .writeln('Current question (ID: $pendingQuestionId): "$pendingQuestionPrompt"');
    } else {
      pathCtx.writeln('STATE: FREE_CONVERSATION (predefined path complete)');
    }

    final slotsCtx = (accumulatedSlots != null && accumulatedSlots.isNotEmpty)
        ? 'SLOTS FILLED SO FAR: ${jsonEncode(accumulatedSlots)}'
        : 'SLOTS FILLED SO FAR: none yet';

    final prompt = '''
You are Panda 🐼, a warm and emotionally intelligent wellness companion
inside the Vivordo health app.

You run a HYBRID conversation:
  • PREDEFINED PATH: structured labeling Qs (Panda drives)
  • UNDEFINED PATH:  open support, advice, tips (user drives, depth unlimited)
When the user digreses, you handle it fully and the app resumes the path.

$pathCtx

HEALTH SPIKE DATA:
${jsonEncode(spikeContext)}

$slotsCtx

CONVERSATION SO FAR:
$historyText

USER JUST SAID: "$userMessage"

━━━ YOUR TASKS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. CLASSIFY INTENT (pick exactly one):
   "answer_label"         — user answered the current structured question
   "want_deeper_answer"   — user wants to elaborate / go deeper on same topic
   "digress"              — user left the path (advice / tips / support / vent)
   "digression_complete"  — user signals done with digression, ready to continue
   "new_stressor"         — user mentioned a NEW health event not yet covered
   "recommend"            — user explicitly asked for a recommendation: playlist,
                            exercise routine, breathing technique, sleep tip, etc.
   "chitchat"             — casual small-talk unrelated to health
   "skip"                 — user explicitly wants to skip the current question

2. WRITE message (2–4 sentences):
   CRITICAL RULES — violations are serious:
   • NEVER ask the next predefined question — the app does that automatically.
   • If user asks for advice / tips / strategies: DELIVER THEM NOW in this
     message with concrete examples. NEVER say "I can help with that" without
     immediately doing it. E.g. if user asks for breathing tips, give 2–3
     specific techniques right here.
   • If intent == "recommend": write a warm 1-sentence intro like
     "Here are a few things that might help 💜" — the app shows the cards.
   • If user wants to go deeper: ask one open probing follow-up (depth_follow_up).
   • If in a digression and depth ≥ 3: gently and warmly signal you're wrapping
     up so you can continue the check-in. Don't be abrupt.
   • Tone: warm, peer-like, empathetic. NOT clinical.
   • Do NOT diagnose. Use "may be related to" language.

3. DEPTH_FOLLOW_UP (only when intent == "want_deeper_answer"):
   One concise open-ended question to keep the user elaborating.

4. INJECTED_QUESTION (only when intent == "new_stressor"):
   Generate a short targeted question about what the user just mentioned.
   3–5 chip options + always end with "Something else 🙋".

5. REC_HINT (only when intent == "recommend"):
   Comma-separated keywords describing what the user is looking for.
   Examples: "music, sleep", "breathing, anxiety", "exercise, stress relief"
   Keep it short — the app handles matching to actual content.

6. SLOT FILLING — extract ALL wellness entities from the user's message:
   stressor, emotion, intensity (low/medium/high), physical_symptom,
   activity, location, time_context, coping_strategy, sleep_quality,
   social_context, other.
   Leave as "" for anything not mentioned. These are used to enrich user data.

Return ONLY valid JSON. No markdown. No extra text.
''';

    final response =
        await _dialogueModel.generateContent([Content.text(prompt)]);
    return _parseTurnReply(response.text ?? '');
  }

  // =========================================================================
  // User data enrichment  —  PLACEHOLDER
  //
  // Called at end of session with all slots accumulated across the full
  // conversation (both predefined-path answers and undefined-path digressions).
  //
  // TODO: Replace body with real Firestore / backend write when pipeline ready.
  // =========================================================================

  /// Appends all extracted slot values from this session to the user's data.
  ///
  /// [userId]           — the user's unique identifier
  /// [sessionSlots]     — merged slot map for the whole session
  ///                      e.g. {"stressor": "work deadline",
  ///                            "emotion": "anxious",
  ///                            "coping_strategy": "box breathing"}
  /// [labeledAnswers]   — structured Q→A pairs from the predefined path
  /// [sessionDate]      — when the session started
  Future<void> appendEntitiesToUserData({
    required String userId,
    required Map<String, String> sessionSlots,
    required Map<String, String> labeledAnswers,
    required DateTime sessionDate,
  }) async {
    // ── PLACEHOLDER ──────────────────────────────────────────────────────────
    //
    // When the real pipeline is ready, this should:
    //
    //   1. Write sessionSlots to a wellness_entities collection:
    //      await FirebaseFirestore.instance
    //          .collection('users').doc(userId)
    //          .collection('wellness_entities')
    //          .add({
    //            'date': sessionDate.toIso8601String(),
    //            'slots': sessionSlots,
    //            'labeled_answers': labeledAnswers,
    //            'created_at': FieldValue.serverTimestamp(),
    //          });
    //
    //   2. Update aggregated user-level fields (e.g. dominant stressors):
    //      final userRef = FirebaseFirestore.instance
    //          .collection('users').doc(userId);
    //      await userRef.update({
    //        'last_session': sessionDate.toIso8601String(),
    //        'stressor_history': FieldValue.arrayUnion(
    //          [sessionSlots['stressor']].where((s) => s != null && s.isNotEmpty).toList()
    //        ),
    //      });
    //
    //   3. Trigger re-analysis if enough new data has accumulated.
    //
    // ─────────────────────────────────────────────────────────────────────────

    // ignore: avoid_print
    print('[PandaService] PLACEHOLDER — would write to user $userId:');
    // ignore: avoid_print
    print('  Session date : ${sessionDate.toIso8601String()}');
    // ignore: avoid_print
    print('  Slots        : $sessionSlots');
    // ignore: avoid_print
    print('  Labeled Q→A  : $labeledAnswers');
  }

  // =========================================================================
  // Update a single labeled answer  —  PLACEHOLDER
  //
  // Called when the user corrects a response from the History tab.
  // The corrected answer is more valuable than the original because it is
  // deliberate — it should overwrite the training label for that Q/session.
  //
  // TODO: Replace body with real Firestore write when pipeline is ready.
  // =========================================================================

  /// Updates a single labeled Q→A in the user's wellness history.
  ///
  /// [userId]      — the user's unique identifier
  /// [sessionDate] — the start timestamp of the session being corrected
  /// [questionId]  — the ID of the question whose answer changed
  /// [oldAnswer]   — the original answer (kept for audit trail)
  /// [newAnswer]   — the corrected answer the user just entered
  Future<void> updateLabeledAnswer({
    required String userId,
    required DateTime sessionDate,
    required String questionId,
    required String oldAnswer,
    required String newAnswer,
  }) async {
    // ── PLACEHOLDER ──────────────────────────────────────────────────────────
    //
    // When the real pipeline is ready, this should:
    //
    //   1. Find the existing wellness_entities document for this session:
    //      final query = await FirebaseFirestore.instance
    //          .collection('users').doc(userId)
    //          .collection('wellness_entities')
    //          .where('date', isEqualTo: sessionDate.toIso8601String())
    //          .limit(1)
    //          .get();
    //
    //   2. Update the specific answer field in labeled_answers:
    //      if (query.docs.isNotEmpty) {
    //        await query.docs.first.reference.update({
    //          'labeled_answers.$questionId': newAnswer,
    //          'corrections': FieldValue.arrayUnion([{
    //            'question_id': questionId,
    //            'old': oldAnswer,
    //            'new': newAnswer,
    //            'corrected_at': FieldValue.serverTimestamp(),
    //          }]),
    //        });
    //      }
    //
    //   3. Optionally re-derive any aggregated fields that depended on the
    //      old answer (e.g. dominant stressor counts).
    //
    // ─────────────────────────────────────────────────────────────────────────

    // ignore: avoid_print
    print('[PandaService] PLACEHOLDER — updateLabeledAnswer for $userId:');
    // ignore: avoid_print
    print('  Session : ${sessionDate.toIso8601String()}');
    // ignore: avoid_print
    print('  Question: $questionId');
    // ignore: avoid_print
    print('  Old     : "$oldAnswer"');
    // ignore: avoid_print
    print('  New     : "$newAnswer"');
  }

  // =========================================================================
  // Parsing helpers
  // =========================================================================

  PandaTurnReply _parseTurnReply(String raw) {
    try {
      final obj = _extractJson(raw);
      if (obj == null) throw FormatException('no JSON');

      final intentStr = obj['intent']?.toString() ?? 'chitchat';
      final intent = _parseIntent(intentStr);
      final message = obj['message']?.toString().trim().isNotEmpty == true
          ? obj['message'].toString().trim()
          : 'Got it 💜';

      // depth_follow_up
      final depthFollowUp = (intent == PandaIntent.wantDeeperAnswer)
          ? obj['depth_follow_up']?.toString().trim()
          : null;

      // injected_question
      PandaQuestion? injected;
      if (intent == PandaIntent.newStressor) {
        final iqRaw = obj['injected_question'];
        if (iqRaw is Map<String, dynamic>) {
          final qid = iqRaw['question_id']?.toString() ?? '';
          final qp = iqRaw['prompt']?.toString() ?? '';
          final opts = <String>[];
          if (iqRaw['options'] is List) {
            for (final o in iqRaw['options'] as List) {
              final t = o.toString().trim();
              if (t.isNotEmpty) opts.add(t);
            }
          }
          if (qid.isNotEmpty && qp.isNotEmpty && opts.isNotEmpty) {
            injected = PandaQuestion(
                questionId: qid, prompt: qp, options: opts);
          }
        }
      }

      // slot filling
      Map<String, String>? slots;
      if (obj['filled_slots'] is Map<String, dynamic>) {
        final raw = obj['filled_slots'] as Map<String, dynamic>;
        final m = <String, String>{};
        raw.forEach((k, v) {
          final val = v?.toString().trim() ?? '';
          if (val.isNotEmpty) m[k] = val;
        });
        if (m.isNotEmpty) slots = m;
      }

      // rec_hint — only present when intent == recommend
      final recHint = (intent == PandaIntent.recommend)
          ? (obj['rec_hint']?.toString().trim().isNotEmpty == true
              ? obj['rec_hint'].toString().trim()
              : null)
          : null;

      return PandaTurnReply(
        intent: intent,
        message: message,
        depthFollowUp: depthFollowUp,
        injectedQuestion: injected,
        filledSlots: slots,
        recHint: recHint,
      );
    } catch (_) {
      return PandaTurnReply(
          intent: PandaIntent.chitchat, message: 'Got it 💜');
    }
  }

  PandaIntent _parseIntent(String s) {
    switch (s.toLowerCase().trim()) {
      case 'answer_label':
        return PandaIntent.answerLabel;
      case 'want_deeper_answer':
        return PandaIntent.wantDeeperAnswer;
      case 'digress':
        return PandaIntent.digress;
      case 'digression_complete':
        return PandaIntent.digressionComplete;
      case 'new_stressor':
        return PandaIntent.newStressor;
      case 'recommend':
        return PandaIntent.recommend;
      case 'skip':
        return PandaIntent.skip;
      default:
        return PandaIntent.chitchat;
    }
  }

  Map<String, dynamic>? _extractJson(String raw) {
    var cleaned = raw
        .trim()
        .replaceAll(RegExp(r'^```[a-zA-Z]*\s*'), '')
        .replaceAll(RegExp(r'\s*```$'), '')
        .trim();
    final s = cleaned.indexOf('{');
    final e = cleaned.lastIndexOf('}');
    if (s == -1 || e == -1 || e <= s) return null;
    return jsonDecode(cleaned.substring(s, e + 1)) as Map<String, dynamic>?;
  }

  // =========================================================================
  // Parse spike analysis → PandaSessionData
  // =========================================================================

PandaSessionData _parsePandaSession(
  String raw,
  Map<String, dynamic> rawSample, {
  String? overrideName,
}) {
  final demo = rawSample['demo_user'] as Map<String, dynamic>?;

  final userName = overrideName?.isNotEmpty == true
      ? overrideName!
      : (demo?['userId'] as String? ?? 'there')
          .replaceAll(RegExp(r'[_\\-]'), ' ')
          .split(' ')
          .first;

  final obj = _extractJson(raw);

  if (obj == null) {
    return _fallbackSession(userName, 'earlier today', []);
  }

  final overallNotes =
      (obj['summary']?['overall_notes'] as String? ?? '').trim();

  final spikes = obj['spikes'] as List?;
  final rawSpikes =
      spikes?.whereType<Map<String, dynamic>>().toList() ?? [];

  // ── Health signals for opener ─────────────────────────────────────
  final sleepSummary = rawSample['sleep_summary'] as Map?;
  final sleepQuality =
      (sleepSummary?['sleep_quality'] as num?)?.toDouble() ?? 50;

  final sleepHours =
      ((sleepSummary?['total_minutes'] as num?)?.toDouble() ?? 420) / 60;

  final stressLevel =
      (demo?['dailyStressLevel'] as num?)?.toDouble() ?? 50;

  final hrv = (demo?['hrv'] as num?)?.toDouble() ?? 50;

  final journalMood = demo?['journalMood'] as String? ?? '';
  final stressed = demo?['stressed'] as bool? ?? false;

  // ── Build opener ─────────────────────────────────────────────────
  final openerMessage = _buildWarmOpener(
    userName: userName,
    stressLevel: stressLevel,
    hrv: hrv,
    sleepQuality: sleepQuality,
    sleepHours: sleepHours,
    journalMood: journalMood,
    stressed: stressed,
    hasSpikes: spikes != null && spikes.isNotEmpty,
    overallNotes: overallNotes,
  );

  // ── No spikes fallback ────────────────────────────────────────────
  if (spikes == null || spikes.isEmpty) {
    return PandaSessionData(
      openerMessage: openerMessage,
      questions: [],
      overallNotes: overallNotes,
      rawSpikes: rawSpikes,
    );
  }

  // ── First spike only (topK = 1) ───────────────────────────────────
  final spike = spikes.first as Map<String, dynamic>;

  final timePhrase =
      _formatTimeRange(spike['start'] as String?, spike['end'] as String?);

  final questions = <PandaQuestion>[];
  final qs = spike['questions'] as List?;

  if (qs != null) {
    for (final q in qs) {
      if (q is! Map) continue;

      final qid =
          q['question_id']?.toString() ?? 'q_${questions.length + 1}';

      final qp = q['prompt']?.toString() ?? '';
      if (qp.isEmpty) continue;

      final opts = <String>[];

      if (q['options'] is List) {
        for (final o in q['options'] as List) {
          final t = o.toString().trim();
          if (t.isNotEmpty) opts.add(t);
        }
      }

      // Always ensure "Something else"
      if (opts.isNotEmpty &&
          !opts.any((o) => o.toLowerCase().contains('other'))) {
        opts.add('Something else 🙋');
      }

      final depths = <String>[];
      if (q['depth_prompts'] is List) {
        for (final d in q['depth_prompts'] as List) {
          final t = d.toString().trim();
          if (t.isNotEmpty) depths.add(t);
        }
      }

      questions.add(PandaQuestion(
        questionId: qid,
        prompt: qp,
        options: opts,
        depthPrompts: depths,
      ));
    }
  }

  // ── If no valid questions generated ───────────────────────────────
  if (questions.isEmpty) {
    return _fallbackSession(
      userName,
      timePhrase,
      rawSpikes,
      notes: overallNotes,
    );
  }

  // ── Final return ─────────────────────────────────────────────────
  return PandaSessionData(
    openerMessage: openerMessage,
    questions: questions,
    overallNotes: overallNotes,
    rawSpikes: rawSpikes,
  );
}

  // ===========================================================================
  // _buildWarmOpener
  //
  // Generates the first message Panda sends — a warm, personal greeting that
  // references real health signals without interrogating the user about spikes.
  // The tone mirrors the screenshot: validate → summarise state → invite them
  // to share what they want from the conversation.
  // ===========================================================================

  String _buildWarmOpener({
    required String userName,
    required double stressLevel,
    required double hrv,
    required double sleepQuality,
    required double sleepHours,
    required String journalMood,
    required bool stressed,
    required bool hasSpikes,
    required String overallNotes,
  }) {
    // ── Stress descriptor ────────────────────────────────────────────────────
    final String stressDesc;
    final String stressEmoji;
    if (stressLevel < 30) {
      stressDesc = 'low'; stressEmoji = '💚';
    } else if (stressLevel < 55) {
      stressDesc = 'moderate'; stressEmoji = '🌤';
    } else if (stressLevel < 75) {
      stressDesc = 'elevated'; stressEmoji = '🟡';
    } else {
      stressDesc = 'high'; stressEmoji = '🔴';
    }

    // ── HRV descriptor ───────────────────────────────────────────────────────
    final String hrvDesc;
    if (hrv >= 60) {
      hrvDesc = 'strong — your nervous system is well recovered';
    } else if (hrv >= 40) {
      hrvDesc = 'okay — within a typical range for you';
    } else {
      hrvDesc = 'lower than usual — your body might need some recovery time';
    }

    // ── Sleep snippet ────────────────────────────────────────────────────────
    final sleepSnippet = sleepQuality >= 70
        ? 'You got ${sleepHours.toStringAsFixed(1)}h of solid sleep last night. 😴'
        : sleepHours < 6
            ? 'You only got ${sleepHours.toStringAsFixed(1)}h of sleep — that can amplify stress.'
            : 'Your sleep quality was a bit low last night, worth keeping in mind.';

    // ── Mood snippet ─────────────────────────────────────────────────────────
    final moodSnippet = journalMood.isNotEmpty
        ? 'Your journal shows youve been feeling $journalMood. '
        : '';

    // ── Spike nudge (soft, not interrogating) ────────────────────────────────
    final spikeSnippet = hasSpikes
        ? 'I also noticed some stress fluctuations in your data today — '
          'happy to look into those whenever youre ready. '
        : '';

    // ── Capability invite — what can I help with? ────────────────────────────
    const invite =
        'What would you like to explore — your patterns, how to plan today, '
        'or something else on your mind?';

    return 'Hey $userName! $stressEmoji '
        'Based on your data today, your stress is $stressDesc and your HRV is $hrvDesc. '
        '$sleepSnippet '
        '$moodSnippet'
        '$spikeSnippet'
        '$invite';
  }

  PandaSessionData _fallbackSession(
      String userName, String timePhrase, List<Map<String, dynamic>> spikes,
      {String notes = ''}) {
    return PandaSessionData(
      openerMessage:
          'Hey $userName! 🌿 Ive pulled up your health data for today. '
          'What would you like to explore — your stress patterns, how to plan your day, '
          'or something else on your mind? 💜',
      questions: [
        PandaQuestion(
          questionId: 'q_fallback',
          prompt: 'What was happening around $timePhrase?',
          options: const [
            'Work or study 📚',
            'Exercise 🏃',
            'Social situation 👥',
            'Commute 🚗',
            'Something else 🙋',
          ],
          depthPrompts: const [
            'Can you tell me more about what was stressful about that?',
            'How were you feeling physically during that time?',
          ],
        ),
      ],
      overallNotes: notes,
      rawSpikes: spikes,
    );
  }

  // =========================================================================
  // Utility
  // =========================================================================

  String _formatTimeRange(String? startIso, String? endIso) {
    try {
      if (startIso == null) return 'earlier today';
      final start = DateTime.parse(startIso).toLocal();
      final s = _formatTime(start);
      if (endIso == null) return s;
      return '$s–${_formatTime(DateTime.parse(endIso).toLocal())}';
    } catch (_) {
      return 'earlier today';
    }
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }

  Map<String, dynamic> _buildCompactPayload(Map<String, dynamic> raw,
      {int topK = 3}) {
    final profile = raw['user_profile'] ?? {};
    final window = raw['data_window'] ?? {};
    final events = (raw['events'] as List? ?? []).cast<Map>();
    final samples = (raw['samples_5min'] as List? ?? []).cast<Map>();
    final baselineHr = (profile['resting_hr_typical'] ?? 62).toDouble();
    final baselineHrv = (profile['hrv_rmssd_typical'] ?? 52).toDouble();

    var spikeCandidates = _detectSpikes(samples, baselineHr, baselineHrv);
    spikeCandidates.sort((a, b) =>
        _severity(b, baselineHr, baselineHrv)
            .compareTo(_severity(a, baselineHr, baselineHrv)));
    if (spikeCandidates.length > topK) {
      spikeCandidates = spikeCandidates.sublist(0, topK);
    }

    for (final s in spikeCandidates) {
      s['context'] ??= <String, dynamic>{};
      s['context']['nearby_events'] = _eventsNear(
        events: events,
        startIso: s['start'],
        endIso: s['end'],
        minutes: 90,
      );
      s['context']['confidence'] =
          (s['context']['nearby_events'] as List).isEmpty ? 0.55 : 0.75;
    }

    final demoUser = raw['demo_user'] as Map<String, dynamic>?;
    final journal = demoUser == null
        ? {
            'mood': 'unknown',
            'summary': '',
            'keyword': '',
            'stressed': false,
          }
        : {
            'mood': demoUser['journalMood'] ?? 'unknown',
            'summary': demoUser['journalEntrySummary'] ?? '',
            'keyword': demoUser['keyword'] ?? '',
            'stressed': demoUser['stressed'] ?? false,
          };

    return {
      'user_profile': {
        'timezone': profile['timezone'] ?? 'America/Edmonton',
        'age_range': profile['age_range'] ?? 'adult',
        'resting_hr_typical': baselineHr,
        'hrv_rmssd_typical': baselineHrv,
      },
      'data_window': window,
      'journal': journal,
      'user_context': raw['user_context'] ?? '',
      'spike_candidates': spikeCandidates,
    };
  }

  double _severity(
      Map<String, dynamic> s, double baselineHr, double baselineHrv) {
    final hr = (s['signals']?['heart_rate']?['peak'] ?? 0).toDouble();
    final hrvMin =
        (s['signals']?['hrv']?['min'] ?? baselineHrv).toDouble();
    final steps =
        (s['signals']?['steps']?['peak_window'] ?? 0).toDouble();
    return (hr - baselineHr).clamp(0, 100) +
        (baselineHrv - hrvMin).clamp(0, 100) +
        (steps / 200.0).clamp(0, 30);
  }

  List<Map<String, dynamic>> _detectSpikes(
      List<Map> samples, double baselineHr, double baselineHrv) {
    bool isSpike(Map s) {
      final hr = (s['hr'] ?? baselineHr).toDouble();
      final hrv = (s['hrv'] ?? baselineHrv).toDouble();
      final stress = (s['stress_score'] ?? 0).toDouble();
      return hr >= baselineHr + 25 ||
          hrv <= baselineHrv - 18 ||
          stress >= 65;
    }

    final List<Map<String, dynamic>> spikes = [];
    Map<String, dynamic>? cur;
    double peakHr = 0, minHrv = 1e9, peakSteps = 0;

    for (final s in samples) {
      final t = s['t'] as String;
      final hr = (s['hr'] ?? baselineHr).toDouble();
      final hrv = (s['hrv'] ?? baselineHrv).toDouble();
      final steps = (s['steps'] ?? 0).toDouble();

      if (isSpike(s)) {
        cur ??= {
          'spike_id': 'spk_${spikes.length + 1}',
          'start': t,
          'end': t,
          'signals': {
            'heart_rate': {'baseline': baselineHr, 'peak': baselineHr},
            'hrv': {'baseline': baselineHrv, 'min': baselineHrv},
            'steps': {'peak_window': 0},
          },
        };
        cur['end'] = t;
        if (hr > peakHr) peakHr = hr;
        if (hrv < minHrv) minHrv = hrv;
        if (steps > peakSteps) peakSteps = steps;
        cur['signals']['heart_rate']['peak'] = peakHr;
        cur['signals']['hrv']['min'] =
            (minHrv == 1e9) ? baselineHrv : minHrv;
        cur['signals']['steps']['peak_window'] = peakSteps;
      } else {
        if (cur != null) {
          spikes.add(cur);
          cur = null;
          peakHr = 0;
          minHrv = 1e9;
          peakSteps = 0;
        }
      }
    }
    if (cur != null) spikes.add(cur);
    return spikes;
  }

  List<Map<String, dynamic>> _eventsNear({
    required List<Map> events,
    required String startIso,
    required String endIso,
    required int minutes,
  }) {
    final start = DateTime.parse(startIso);
    final end = DateTime.parse(endIso);
    final lo = start.subtract(Duration(minutes: minutes));
    final hi = end.add(Duration(minutes: minutes));
    final nearby = <Map<String, dynamic>>[];
    for (final e in events) {
      final t = DateTime.parse(e['time'] as String);
      if (!t.isBefore(lo) && !t.isAfter(hi)) {
        nearby.add({
          'time': e['time'],
          'type': e['type'] ?? 'unknown',
          'detail': e['detail'] ?? '',
        });
      }
    }
    return nearby;
  }
}