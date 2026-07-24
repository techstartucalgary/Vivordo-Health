import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/foundation.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;

import 'ai_service.dart';
import 'calendar_service.dart';
import 'insight_service.dart';

export 'ai_service.dart'
    show
        kMaxInputTokens,
        kMaxOutputTokensChat,
        kMaxOutputTokensSpike,
        kMaxOutputTokensSummary;

export 'panda_types.dart';

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
// Static helpers (fetchRealUserPayload, buildCompactPayload, parsePandaSession,
// parseTurnReply, buildSpikeUserPrompt, buildDialoguePrompt, etc.) are public
// so that ClaudeService can reuse the same data-processing logic without
// instantiating Gemini models.
//
// =============================================================================

// ---------------------------------------------------------------------------
// GeminiService
// ---------------------------------------------------------------------------

class GeminiService implements AIService {
  GeminiService()
    : _spikeModel = FirebaseAI.googleAI().generativeModel(
        model: 'gemini-2.5-flash',
        generationConfig: GenerationConfig(
          responseMimeType: 'application/json',
          responseSchema: _spikeSchema,
          candidateCount: 1,
          temperature: 0,
          maxOutputTokens: kMaxOutputTokensSpike,
        ),
      ),
      _dialogueModel = FirebaseAI.googleAI().generativeModel(
        model: 'gemini-2.5-flash',
        generationConfig: GenerationConfig(
          responseMimeType: 'application/json',
          responseSchema: _turnSchema,
          candidateCount: 1,
          temperature: 0.5,
          maxOutputTokens: kMaxOutputTokensChat,
        ),
      ),
      // Plain-text model (no JSON schema) for the end-of-session recap.
      _summaryModel = FirebaseAI.googleAI().generativeModel(
        model: 'gemini-2.5-flash',
        generationConfig: GenerationConfig(
          candidateCount: 1,
          temperature: 0.3,
          maxOutputTokens: kMaxOutputTokensSummary,
        ),
      );

  final GenerativeModel _spikeModel;
  final GenerativeModel _dialogueModel;
  final GenerativeModel _summaryModel;

  // =========================================================================
  // Spike analysis schema
  // =========================================================================

  // System prompt for the end-of-session insight summary (summarizeSession).
  // Shared by GeminiService and ClaudeService so both produce the same shape.
  static const String summarySystemPrompt = '''
You are condensing a completed Vivordo wellness check-in into a CONTINUITY NOTE
for a future session. Write ONE compact paragraph — 2-3 sentences, max 55 words,
third person, plain prose.

Capture, when present: the main stressor and what triggered it; the user's emotion
and intensity; relevant context (time of day, activity, location, social, sleep);
and what coping was tried or actually helped. Add ONE durable insight or recurring
pattern if it is evident from the data.

Do NOT restate the questions or answers verbatim, give advice, greet, or use
emojis. If very little was shared, say so in one short sentence.''';

  static const String spikeSystemPrompt = '''
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
- DAILY DATA ONLY: metrics are daily aggregates. You do NOT know the time of day
  a spike happened. Reference the DAY (use spike.day, e.g. "on Wed, Jun 17") and
  NEVER state or invent a clock time ("2pm", "noon", "this morning", "afternoon").
''';

  static final Schema _spikeSchema = Schema(
    SchemaType.object,
    properties: {
      "summary": Schema(
        SchemaType.object,
        properties: {
          "data_window_start": Schema(SchemaType.string),
          "data_window_end": Schema(SchemaType.string),
          "overall_notes": Schema(SchemaType.string),
        },
      ),
      "spikes": Schema(
        SchemaType.array,
        items: Schema(
          SchemaType.object,
          properties: {
            "spike_id": Schema(SchemaType.string),
            "start": Schema(SchemaType.string),
            "end": Schema(SchemaType.string),
            "signals": Schema(
              SchemaType.object,
              properties: {
                "heart_rate": Schema(
                  SchemaType.object,
                  properties: {
                    "baseline": Schema(SchemaType.number),
                    "peak": Schema(SchemaType.number),
                  },
                ),
                "hrv": Schema(
                  SchemaType.object,
                  properties: {
                    "baseline": Schema(SchemaType.number),
                    "min": Schema(SchemaType.number),
                  },
                ),
                "steps": Schema(
                  SchemaType.object,
                  properties: {"peak_window": Schema(SchemaType.number)},
                ),
              },
            ),
            "context": Schema(
              SchemaType.object,
              properties: {
                "nearby_events": Schema(
                  SchemaType.array,
                  items: Schema(
                    SchemaType.object,
                    properties: {
                      "time": Schema(SchemaType.string),
                      "type": Schema(SchemaType.string),
                      "detail": Schema(SchemaType.string),
                    },
                  ),
                ),
                "confidence": Schema(SchemaType.number),
              },
            ),
            "hypotheses": Schema(
              SchemaType.array,
              items: Schema(
                SchemaType.object,
                properties: {
                  "label": Schema(SchemaType.string),
                  "reason": Schema(SchemaType.string),
                  "confidence": Schema(SchemaType.number),
                },
              ),
            ),
            "questions": Schema(
              SchemaType.array,
              items: Schema(
                SchemaType.object,
                properties: {
                  "question_id": Schema(SchemaType.string),
                  "prompt": Schema(SchemaType.string),
                  "type": Schema(SchemaType.string),
                  "options": Schema(
                    SchemaType.array,
                    items: Schema(SchemaType.string),
                  ),
                  "depth_prompts": Schema(
                    SchemaType.array,
                    items: Schema(SchemaType.string),
                  ),
                },
              ),
            ),
            "ml_labels_to_collect": Schema(
              SchemaType.array,
              items: Schema(SchemaType.string),
            ),
          },
        ),
      ),
    },
  );

  // =========================================================================
  // Dialogue turn schema
  // =========================================================================

  static final Schema _turnSchema = Schema(
    SchemaType.object,
    properties: {
      "intent": Schema(SchemaType.string),
      "message": Schema(SchemaType.string),
      "depth_follow_up": Schema(SchemaType.string),
      "injected_question": Schema(
        SchemaType.object,
        properties: {
          "question_id": Schema(SchemaType.string),
          "prompt": Schema(SchemaType.string),
          "options": Schema(SchemaType.array, items: Schema(SchemaType.string)),
        },
      ),
      "filled_slots": Schema(
        SchemaType.object,
        properties: {
          "stressor": Schema(SchemaType.string),
          "emotion": Schema(SchemaType.string),
          "intensity": Schema(SchemaType.string),
          "physical_symptom": Schema(SchemaType.string),
          "activity": Schema(SchemaType.string),
          "location": Schema(SchemaType.string),
          "time_context": Schema(SchemaType.string),
          "coping_strategy": Schema(SchemaType.string),
          "sleep_quality": Schema(SchemaType.string),
          "social_context": Schema(SchemaType.string),
          "other": Schema(SchemaType.string),
        },
      ),
      "rec_hint": Schema(SchemaType.string),
      "calendar_action": Schema(
        SchemaType.object,
        properties: {
          "operation": Schema(SchemaType.string),
          "title": Schema(SchemaType.string),
          "target_title": Schema(SchemaType.string),
          "start": Schema(SchemaType.string),
          "end": Schema(SchemaType.string),
          "recurrence": Schema(SchemaType.string),
        },
      ),
    },
  );

  // =========================================================================
  // Spike analysis
  // =========================================================================

  Future<String> analyzeStressSpikes({
    required Map<String, dynamic> data,
    String? extraUserContext,
  }) async {
    final Map<String, dynamic> compact = data.containsKey("spike_candidates")
        ? Map<String, dynamic>.from(data)
        : buildCompactPayload(data, topK: 3);

    compact["user_context"] = extraUserContext?.trim() ?? "";
    compact["_variability_seed"] =
        DateTime.now().millisecondsSinceEpoch % 100000;

    final userPrompt = buildSpikeUserPrompt(compact);

    // Token guard — reject before hitting the model if the prompt is too large.
    final estimated = estimateTokens(spikeSystemPrompt + userPrompt);
    if (estimated > kMaxInputTokens) {
      if (kDebugMode) {
        debugPrint(
          '[Gemini][spike] token guard fired: ~$estimated tokens (limit $kMaxInputTokens)',
        );
      }
      return '';
    }

    final response = await _spikeModel.generateContent([
      Content.text(spikeSystemPrompt),
      Content.text(userPrompt),
    ]);
    if (kDebugMode) {
      final usage = response.usageMetadata;
      debugPrint(
        '[Gemini][spike] tokens — in: ${usage?.promptTokenCount}, '
        'out: ${usage?.candidatesTokenCount}',
      );
    }
    return response.text ?? '';
  }

  // =========================================================================
  // Panda session init  (implements AIService)
  // =========================================================================

  @override
  Future<PandaSessionData> analyzePandaSession({
    String? extraUserContext,
    String? userName,
    String? userId,
  }) async {
    if (userId != null && userId.isNotEmpty) {
      // ── Production path: real metrics_daily data ──────────────────────
      final payload = await fetchRealUserPayload(userId);
      if (payload == null) {
        return emptyStateSession(userName ?? 'there');
      }
      final compact = buildCompactPayload(payload, topK: 1);

      // Nothing to analyze — skip the LLM round trip and open the chat instantly
      // instead of waiting on a call that would just return `spikes: []`.
      if ((compact['spike_candidates'] as List? ?? const []).isEmpty) {
        if (kDebugMode) {
          debugPrint('[Gemini][spike] no spike candidates — skipping LLM call');
        }
        return noSpikesSession(payload, overrideName: userName);
      }

      final raw = await analyzeStressSpikes(
        data: compact,
        extraUserContext: extraUserContext,
      );
      final session = parsePandaSession(raw, payload, overrideName: userName);
      // Record the surfaced spike's day so it isn't analyzed again.
      if (AppFlags.dedupeAnalyzedSpikes && session.rawSpikes.isNotEmpty) {
        unawaited(markSpikeDaysAnalyzed(userId, spikeDaysFromCompact(compact)));
      }
      return session;
    }

    // No user id → nothing to analyze; surface the empty state.
    return emptyStateSession(userName ?? 'there');
  }

  @override
  Future<PandaSessionBootstrap> startSession({
    String? extraUserContext,
    String? userName,
    String? userId,
  }) async {
    if (userId == null || userId.isEmpty) {
      return PandaSessionBootstrap(
        session: emptyStateSession(userName ?? 'there'),
      );
    }

    final payload = await fetchRealUserPayload(userId);
    if (payload == null) {
      return PandaSessionBootstrap(
        session: emptyStateSession(userName ?? 'there'),
      );
    }

    final compact = buildCompactPayload(payload, topK: 1);

    // Nothing to analyze → no LLM call at all; the chat is already final.
    if ((compact['spike_candidates'] as List? ?? const []).isEmpty) {
      return PandaSessionBootstrap(
        session: noSpikesSession(payload, overrideName: userName),
      );
    }

    // Opener NOW; the labeling questions stream in behind it.
    final analysis = Future(() async {
      final raw = await analyzeStressSpikes(
        data: compact,
        extraUserContext: extraUserContext,
      );
      final session = parsePandaSession(raw, payload, overrideName: userName);
      if (AppFlags.dedupeAnalyzedSpikes && session.rawSpikes.isNotEmpty) {
        unawaited(markSpikeDaysAnalyzed(userId, spikeDaysFromCompact(compact)));
      }
      return session;
    });

    return PandaSessionBootstrap(
      session: bootstrapSession(
        payload,
        overrideName: userName,
        hasSpikes: true,
      ),
      spikeAnalysis: analysis,
    );
  }

  // =========================================================================
  // Dialogue turn  (implements AIService)
  // =========================================================================

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
    // Trim to fit rather than refuse — Panda always answers, so the chat ends
    // naturally instead of being cut off with a canned "let's wrap up".
    final fitted = fitConversation(conversationHistory, userMessage);

    final prompt = buildDialoguePrompt(
      userMessage: fitted.message,
      conversationHistory: fitted.history,
      spikeContext: spikeContext,
      isOnPredefinedPath: isOnPredefinedPath,
      isInDigression: isInDigression,
      digressionTurnCount: digressionTurnCount,
      pendingQuestionId: pendingQuestionId,
      pendingQuestionPrompt: pendingQuestionPrompt,
      digressionTopic: digressionTopic,
      accumulatedSlots: accumulatedSlots,
      scheduleContext: scheduleContext,
      insightsContext: insightsContext,
      dashboardContext: dashboardContext,
    );

    final response = await _dialogueModel.generateContent([
      Content.text(prompt),
    ]);
    if (kDebugMode) {
      final usage = response.usageMetadata;
      debugPrint(
        '[Gemini][dialogue] tokens — in: ${usage?.promptTokenCount}, '
        'out: ${usage?.candidatesTokenCount}',
      );
    }
    return parseTurnReply(response.text ?? '');
  }

  // =========================================================================
  // Session summary  (implements AIService)
  // =========================================================================

  @override
  Future<String> summarizeSession({
    required List<Map<String, String>> conversation,
    required Map<String, String> slots,
    required Map<String, String> labeledAnswers,
  }) async {
    try {
      final userPrompt = buildSummaryPrompt(
        conversation: conversation,
        slots: slots,
        labeledAnswers: labeledAnswers,
      );
      final estimated = estimateTokens(summarySystemPrompt + userPrompt);
      if (estimated > kMaxInputTokens) return '';

      final response = await _summaryModel.generateContent([
        Content.text(summarySystemPrompt),
        Content.text(userPrompt),
      ]);
      if (kDebugMode) {
        final usage = response.usageMetadata;
        debugPrint(
          '[Gemini][summary] tokens — in: ${usage?.promptTokenCount}, '
          'out: ${usage?.candidatesTokenCount}',
        );
      }
      return (response.text ?? '').trim();
    } catch (e) {
      if (kDebugMode) debugPrint('[Gemini][summary] failed: $e');
      return '';
    }
  }

  // =========================================================================
  // Real user data fetch  (public static — reused by ClaudeService)
  //
  // Queries users/{userId}/metrics_daily/{YYYY-MM-DD} subcollection for the
  // last 7 days.  Each document holds all metrics for that day as top-level
  // fields (heart_rate, mood, sleep, steps, stress, wellness, hrv).
  //
  // Also fetches users/{userId}/preferences and
  // users/{userId}/questionaire_responses for compact user context, plus an
  // aggregate of past Panda sessions from the top-level `insights` collection
  // (recurring stressors/emotions/coping) so the model has cross-session memory.
  //
  // When the user has connected Google Calendar (CalendarService), their events
  // for the analysis window are folded in as `events` — so the spike-correlation
  // engine can tie HR spikes to real meetings — plus a compact `upcoming_events`
  // list for planning context. Degrades silently when not connected.
  //
  // Returns null when the user has no data yet (caller shows empty state).
  // =========================================================================

  static Future<Map<String, dynamic>?> fetchRealUserPayload(
    String userId,
  ) async {
    final db = FirebaseFirestore.instance;
    final now = DateTime.now();
    final userRef = db.collection('users').doc(userId);

    // Each day's metrics live in a single merged doc at
    // users/{userId}/metrics_daily/{YYYY-MM-DD}, keyed by metric type
    // (e.g. 'heart_rate', 'resting_heart_rate', 'hrv', 'steps', 'sleep') — see
    // MetricsService._addMetric, HealthService._writeDataPoints and
    // ScanScreen._saveToFirestore.
    final dateStrings = List.generate(
      7,
      (i) => _fmtDate(now.subtract(Duration(days: i))),
    );

    // Fire all Firestore reads concurrently before any await
    final metricFutures = dateStrings
        .map((d) => userRef.collection('metrics_daily').doc(d).get())
        .toList();
    final prefFuture = userRef.collection('preferences').get();
    final questFuture = userRef.collection('questionaire_responses').get();
    // Recurring patterns from past Panda sessions (top-level `insights`).
    // Degrade gracefully if the query fails (e.g. missing composite index) so a
    // first-time user with no insight history never blocks session init.
    final insightsFuture = InsightService(
      firestore: db,
    ).aggregateSummary(userId).catchError((Object _) => <String, dynamic>{});
    // NOTE: Google Calendar is deliberately NOT fetched here. It needs auth +
    // an enumeration of every calendar + a fetch per calendar, which can take
    // seconds — and it sat on the session-init critical path. It is now loaded
    // in the BACKGROUND via fetchScheduleContext() and fed into later dialogue
    // turns, so the chat opens immediately. (Calendar↔spike correlation was
    // near-useless anyway: the metrics are daily aggregates with no real
    // time-of-day, so no event could ever be aligned to a spike.)

    // User root doc — holds analyzed_spike_days (spike-dedupe ledger).
    final userDocFuture = userRef.get();

    final metricSnaps = await Future.wait(metricFutures);
    final prefSnap = await prefFuture;
    final questSnap = await questFuture;
    final insightsAgg = await insightsFuture;
    final userSnap = await userDocFuture;

    // Days whose spike has already been surfaced once — excluded from detection
    // so Panda doesn't re-ask about the same spike (AppFlags.dedupeAnalyzedSpikes).
    final excludedSpikeDays = AppFlags.dedupeAnalyzedSpikes
        ? Set<String>.from(
            (userSnap.data()?['analyzed_spike_days'] as List?)
                    ?.whereType<String>() ??
                const <String>[],
          )
        : <String>{};

    // Build daily data map: dateStr → {field → value} from the single day doc
    final dailyData = <String, Map<String, dynamic>>{};
    for (int i = 0; i < dateStrings.length; i++) {
      final data = metricSnaps[i].data();
      if (data == null) continue;
      dailyData[dateStrings[i]] = data;
    }

    if (dailyData.isEmpty) return null;

    // HR baseline: 7-day average, preferring resting_heart_rate over heart_rate.
    final hrValues = dailyData.values
        .map(
          (d) =>
              (d['resting_heart_rate']?['avg'] as num?)?.toDouble() ??
              (d['heart_rate']?['avg'] as num?)?.toDouble(),
        )
        .whereType<double>()
        .toList();
    final baselineHr = hrValues.isEmpty
        ? 65.0
        : hrValues.reduce((a, b) => a + b) / hrValues.length;

    final hrvValues = dailyData.values
        .map((d) => (d['hrv']?['avg'] as num?)?.toDouble())
        .whereType<double>()
        .toList();
    final baselineHrv = hrvValues.isEmpty
        ? 52.0
        : hrvValues.reduce((a, b) => a + b) / hrvValues.length;

    final sortedDates = dailyData.keys.toList()..sort((a, b) => b.compareTo(a));
    final latestDate = sortedDates.first;
    final latestData = dailyData[latestDate]!;

    final todaySleepHrs =
        (latestData['sleep']?['avg'] as num?)?.toDouble() ?? 0.0;
    final sleepQuality = todaySleepHrs >= 8
        ? 80.0
        : todaySleepHrs >= 7
        ? 65.0
        : todaySleepHrs >= 6
        ? 45.0
        : todaySleepHrs > 0
        ? 25.0
        : 0.0;

    final samplesChronological = sortedDates.reversed
        .where((dateStr) => !excludedSpikeDays.contains(dateStr))
        .map((dateStr) {
          final d = dailyData[dateStr]!;
          final hrMax =
              (d['heart_rate']?['max'] as num?)?.toDouble() ??
              (d['heart_rate']?['avg'] as num?)?.toDouble() ??
              baselineHr;
          final hrv = (d['hrv']?['avg'] as num?)?.toDouble() ?? baselineHrv;
          final steps = (d['steps']?['sum'] as num?)?.toDouble() ?? 0.0;
          final stress = (d['stress']?['avg'] as num?)?.toInt();
          return <String, dynamic>{
            't': '${dateStr}T12:00:00',
            'hr': hrMax.round(),
            'hrv': hrv.round(),
            'steps': steps.round(),
            'activity': steps > 8000
                ? 'active'
                : steps > 3000
                ? 'light'
                : 'sedentary',
            'stress': ?stress,
            'tag': '',
          };
        })
        .toList();

    final windowStart = DateTime.parse('${sortedDates.last}T00:00:00');
    final windowEnd = DateTime.parse('${latestDate}T23:59:59');

    // Compact user setup from preferences + questionnaire (scalar values only,
    // max 10 fields) — keeps token overhead under ~100 tokens.
    final userSetup = <String, dynamic>{};
    const metaKeys = {'createdAt', 'updatedAt', 'userId', 'id', 'timestamp'};
    for (final doc in [...prefSnap.docs, ...questSnap.docs]) {
      for (final entry in doc.data().entries) {
        if (userSetup.length >= 10) break;
        if (metaKeys.contains(entry.key)) continue;
        final v = entry.value;
        if (v is String || v is num || v is bool) {
          userSetup[entry.key] = v;
        }
      }
    }

    // Compact cross-session memory from the `insights` aggregate (only non-empty
    // signals) — keeps token overhead to ~30–50 tokens.
    final insightsSummary = <String, dynamic>{};
    if ((insightsAgg['session_count'] as int? ?? 0) > 0) {
      for (final key in const ['top_stressors', 'top_emotions', 'top_coping']) {
        final list =
            (insightsAgg[key] as List?)?.whereType<String>().toList() ?? [];
        if (list.isNotEmpty) insightsSummary[key] = list;
      }
      final intensity = insightsAgg['avg_intensity'] as String?;
      if (intensity != null && intensity.isNotEmpty) {
        insightsSummary['typical_intensity'] = intensity;
      }
      final recentSummaries =
          (insightsAgg['recent_summaries'] as List?)
              ?.whereType<String>()
              .toList() ??
          const [];
      if (recentSummaries.isNotEmpty) {
        insightsSummary['recent_sessions'] = recentSummaries;
      }
      final stressorCounts = insightsAgg['stressor_counts'];
      if (stressorCounts is Map && stressorCounts.isNotEmpty) {
        insightsSummary['stressor_counts'] = stressorCounts;
      }
      insightsSummary['past_session_count'] = insightsAgg['session_count'];
    }

    return {
      'user_profile': {
        'timezone': 'UTC',
        'age_range': 'adult',
        'resting_hr_typical': baselineHr,
        'hrv_rmssd_typical': baselineHrv,
        if (userSetup.isNotEmpty) 'user_setup': userSetup,
        if (insightsSummary.isNotEmpty) 'insights_summary': insightsSummary,
      },
      'data_window': {
        'start': windowStart.toIso8601String(),
        'end': windowEnd.toIso8601String(),
      },
      'samples_5min': samplesChronological,
      // Retained in memory for on-demand conversational metric lookups. This is
      // never embedded wholesale in a model prompt.
      'dashboard_metrics': dailyData,
      // Calendar is loaded in the background (fetchScheduleContext) — it is not
      // on the session-init critical path.
      'events': const <Map<String, dynamic>>[],
      if (todaySleepHrs > 0)
        'sleep_summary': {
          'total_hours': todaySleepHrs,
          'sleep_quality': sleepQuality,
        },
      'user_meta': {'userId': userId, 'hrv': baselineHrv},
    };
  }

  /// Graceful empty-state session when the user has no metrics yet.
  static PandaSessionData emptyStateSession(String name) {
    return PandaSessionData(
      openerMessage:
          'Hey $name! 👋 I don\'t have any health data to analyze yet. '
          'Once you start tracking your metrics, I\'ll be able to surface '
          'personalized stress insights here. For now, feel free to chat with '
          'me about anything on your mind.',
      questions: [],
      overallNotes: '',
      rawSpikes: [],
    );
  }

  /// Fetches the Google Calendar schedule digest for the next 7 days.
  ///
  /// Runs OFF the session-init critical path — the calendar needs auth, an
  /// enumeration of every calendar, and a fetch per calendar, which can take
  /// seconds. PandaScreen calls this in the background after the chat has
  /// already opened and feeds the result into subsequent dialogue turns.
  /// Returns null when Calendar isn't connected or nothing is scheduled.
  static Future<String?> fetchScheduleContext() async {
    try {
      final now = DateTime.now();
      final dayStart = DateTime(now.year, now.month, now.day);
      final events = await CalendarService.getEventsBetween(
        dayStart,
        dayStart.add(const Duration(days: 8)),
      ).timeout(const Duration(seconds: 12), onTimeout: () => <gcal.Event>[]);
      final digest = _buildScheduleDigest(events, dayStart);
      return digest.isEmpty ? null : digest;
    } catch (e) {
      if (kDebugMode) debugPrint('[schedule] background fetch failed: $e');
      return null;
    }
  }

  /// Immediate session built from the payload alone — NO LLM call.
  ///
  /// [hasSpikes] false → nothing to analyze (chat is already final).
  /// [hasSpikes] true  → the opener shows now while the labeling questions are
  /// still being generated in the background (progressive loading).
  static PandaSessionData bootstrapSession(
    Map<String, dynamic> payload, {
    String? overrideName,
    required bool hasSpikes,
  }) {
    final meta = payload['user_meta'] as Map<String, dynamic>?;
    final userName = overrideName?.isNotEmpty == true
        ? overrideName!
        : (meta?['userId'] as String? ?? 'there')
              .replaceAll(RegExp(r'[_\-]'), ' ')
              .split(' ')
              .first;

    final sleepSummary = payload['sleep_summary'] as Map?;
    final sleepHours =
        (sleepSummary?['total_hours'] as num?)?.toDouble() ?? 0.0;

    return PandaSessionData(
      openerMessage: _buildWarmOpener(
        userName: userName,
        hasSpikes: hasSpikes,
        overallNotes: '',
        sleepHours: sleepHours,
      ),
      questions: const [],
      overallNotes: '',
      rawSpikes: const [],
      dashboardMetrics: _dashboardMetricsFromPayload(payload),
      insightsContext: _insightsContextFromPayload(payload),
    );
  }

  /// Session for a user who HAS data but no NEW spike to analyze (e.g. every
  /// detected spike day was already surfaced once — AppFlags.dedupeAnalyzedSpikes).
  ///
  /// There is nothing to label, so this skips the spike-analysis LLM call
  /// entirely and opens the chat instantly instead of waiting on a round trip
  /// that would just return `spikes: []`. Schedule + insights context still
  /// travel with it so the dialogue keeps full context.
  static PandaSessionData noSpikesSession(
    Map<String, dynamic> payload, {
    String? overrideName,
  }) => bootstrapSession(payload, overrideName: overrideName, hasSpikes: false);

  /// Rough token estimate: 1 token ≈ 4 chars for English text.
  /// Intentionally conservative (over-counts) — the safe direction for budget checks.
  /// Used by both GeminiService and ClaudeService before every API call.
  static int estimateTokens(String text) => (text.length / 4).ceil();

  /// Fits the dynamic conversation into the token budget WITHOUT ever refusing
  /// to reply: caps history to the last 6 turns, truncates a single runaway
  /// message, then drops the oldest turns until it fits.
  ///
  /// This replaces the old hard token guard, which returned a canned
  /// "we've covered a lot of ground — let's wrap up" message and abruptly ended
  /// the chat before the user was done. Panda now always answers, so the
  /// conversation reaches its own natural conclusion.
  static ({List<Map<String, String>> history, String message}) fitConversation(
    List<Map<String, String>> history,
    String message, {
    int budget = kMaxInputTokens,
  }) {
    final h = history.length > 6
        ? List<Map<String, String>>.from(history.sublist(history.length - 6))
        : List<Map<String, String>>.from(history);

    // Truncate a single oversized message to at most half the budget.
    final maxMsgChars = (budget * 4) ~/ 2;
    final msg = message.length > maxMsgChars
        ? '${message.substring(0, maxMsgChars).trimRight()}…'
        : message;

    String histText(List<Map<String, String>> hh) =>
        hh.map((t) => '${t['role']}: ${t['text']}').join('\n');

    // Drop the oldest turns until the conversation fits.
    while (h.isNotEmpty && estimateTokens(histText(h) + msg) > budget) {
      h.removeAt(0);
    }
    return (history: h, message: msg);
  }

  // =========================================================================
  // Spike de-duplication  (public static — reused by ClaudeService)
  //
  // Spikes are identified by their DAY (metrics are daily aggregates). Once a
  // day's spike is surfaced for analysis it is recorded on the user doc so it
  // is never re-detected. Gated by AppFlags.dedupeAnalyzedSpikes.
  // =========================================================================

  /// The set of spike days (YYYY-MM-DD) present in a compact payload.
  static List<String> spikeDaysFromCompact(Map<String, dynamic> compact) {
    final cands = compact['spike_candidates'] as List? ?? const [];
    return cands
        .map((s) => (s as Map)['start']?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .map((s) => s.contains('T') ? s.split('T').first : s)
        .toSet()
        .toList();
  }

  /// Records [days] as analyzed on the user doc so their spikes aren't re-asked.
  static Future<void> markSpikeDaysAnalyzed(
    String userId,
    List<String> days,
  ) async {
    if (days.isEmpty) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(userId).set({
        'analyzed_spike_days': FieldValue.arrayUnion(days),
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      if (kDebugMode) debugPrint('[spike-dedupe] mark failed: $e');
    }
  }

  static String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static const _weekdayAbbr = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  static const _monthAbbr = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  /// Human day label for a spike (e.g. "Wed, Jun 17"). Health metrics are daily
  /// aggregates, so this is the finest real granularity — never a clock time.
  static String _dayPhrase(String? iso) {
    if (iso == null || iso.isEmpty) return 'that day';
    try {
      final d = DateTime.parse(iso).toLocal();
      return '${_weekdayAbbr[d.weekday - 1]}, ${_monthAbbr[d.month - 1]} ${d.day}';
    } catch (_) {
      return 'that day';
    }
  }

  /// Normalised key for de-duplicating chip options — lowercased with emoji and
  /// punctuation stripped, so "Something else 🙋" and "Something else!" collide.
  static String _optionKey(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// True when a normalised option already acts as the "none of these" choice.
  static bool _isEscapeHatch(String key) =>
      key.contains('something else') || key.contains('other');

  /// Strips the time component from an ISO timestamp, leaving the date only.
  static String _dateOnly(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final t = iso.indexOf('T');
    return t == -1 ? iso : iso.substring(0, t);
  }

  /// Builds a per-day schedule digest for the next 7 days (from [dayStart],
  /// inclusive) in local time, e.g.:
  ///   Mon 2026-06-22: 09:00–10:00 Standup; 14:00–15:30 Project review
  ///   Tue 2026-06-23: (no events)
  /// Each day is listed so free days are explicit. Returns '' when there are
  /// no timed events in the window (nothing useful to plan around).
  static String _buildScheduleDigest(
    List<gcal.Event> events,
    DateTime dayStart,
  ) {
    final windowEnd = dayStart.add(const Duration(days: 7));

    // Group timed events by local calendar day.
    final byDay = <String, List<String>>{};
    var hasAny = false;
    for (final e in events) {
      final startDt = e.start?.dateTime;
      if (startDt == null) continue;
      final localStart = startDt.toLocal();
      if (localStart.isBefore(dayStart) || !localStart.isBefore(windowEnd)) {
        continue;
      }
      final dayKey = _fmtDate(localStart);
      final startHm =
          '${localStart.hour.toString().padLeft(2, '0')}:'
          '${localStart.minute.toString().padLeft(2, '0')}';
      final endLocal = e.end?.dateTime?.toLocal();
      final endHm = endLocal == null
          ? ''
          : '–${endLocal.hour.toString().padLeft(2, '0')}:'
                '${endLocal.minute.toString().padLeft(2, '0')}';
      final title = (e.summary ?? 'event').trim();
      (byDay[dayKey] ??= []).add(
        '$startHm$endHm ${title.isEmpty ? 'event' : title}',
      );
      hasAny = true;
    }

    if (!hasAny) return '';

    final lines = <String>[];
    for (int i = 0; i < 7; i++) {
      final day = dayStart.add(Duration(days: i));
      final key = _fmtDate(day);
      final label = '${_weekdayAbbr[day.weekday - 1]} $key';
      final dayEvents = byDay[key];
      lines.add(
        dayEvents == null || dayEvents.isEmpty
            ? '$label: (no events)'
            : '$label: ${dayEvents.join('; ')}',
      );
    }
    return lines.join('\n');
  }

  // =========================================================================
  // Prompt builders  (public static — reused by ClaudeService)
  // =========================================================================

  /// Builds the user-role prompt for spike analysis.
  /// [compact] must already contain user_context and _variability_seed.
  static String buildSpikeUserPrompt(Map<String, dynamic> compact) {
    return '''
Use ONLY the heart rate spikes detected in DATA. Do NOT invent symptoms, events, journal entries, goals, or any context not present in DATA.

If DATA.user_context is non-empty, mention it briefly in summary.overall_notes.

For each question, generate 2–3 depth_prompts (open-ended follow-ups that
encourage the user to elaborate further if they want to go deeper).

Vary the question phrasing — do not reuse wording from previous calls.
(Hint: _variability_seed = ${compact["_variability_seed"]})

Include every schema key (use "", 0, [] for unknowns).

DATA: ${jsonEncode(compact)}
''';
  }

  /// Builds the user-role prompt for the end-of-session insight summary.
  /// Caps the conversation to the last 8 turns to bound token cost; slots and
  /// labeled answers are included compactly so the model can synthesise context
  /// rather than merely echo answers.
  static String buildSummaryPrompt({
    required List<Map<String, String>> conversation,
    required Map<String, String> slots,
    required Map<String, String> labeledAnswers,
  }) {
    final capped = conversation.length > 8
        ? conversation.sublist(conversation.length - 8)
        : conversation;
    final convoText = capped
        .map(
          (t) =>
              "${t['role'] == 'user' ? 'User' : 'Panda'}: ${t['text'] ?? ''}",
        )
        .join('\n');

    final slotsText = slots.isNotEmpty ? jsonEncode(slots) : 'none';
    final answersText = labeledAnswers.isNotEmpty
        ? jsonEncode(labeledAnswers)
        : 'none';

    return '''
EXTRACTED SLOTS: $slotsText

LABELED ANSWERS: $answersText

CONVERSATION:
$convoText

Write the continuity note now.''';
  }

  /// Builds the full dialogue prompt for a single conversation turn.
  /// Caps history to the last 6 items (≈3 exchanges, ≤350 tokens) and
  /// trims spike context automatically.
  ///
  /// [embedSpikeContext] — pass false when the caller already provides spike
  /// context in a cached system block (ClaudeService), to avoid sending it
  /// twice and wasting ~40–60 uncached tokens per turn.
  ///
  /// [embedPersona] — pass false when the persona intro ("You are Panda 🐼…")
  /// is already in a cached system block, saving ~17 uncached tokens per turn.
  ///
  /// [embedTaskInstructions] — pass false when the TASKS section is already
  /// in a cached system block, saving ~90 uncached tokens per turn.
  ///
  /// [scheduleContext] — optional per-day calendar digest (next 7 days). When
  /// present and [embedScheduleContext] is true, it is included so Panda can
  /// answer availability questions. ClaudeService passes embedScheduleContext
  /// false and puts the (session-stable) schedule in a cached system block.
  static String buildDialoguePrompt({
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
    bool embedSpikeContext = true,
    bool embedPersona = true,
    bool embedTaskInstructions = true,
    bool embedScheduleContext = true,
    bool embedInsightsContext = true,
  }) {
    final cappedHistory = conversationHistory.length > 6
        ? conversationHistory.sublist(conversationHistory.length - 6)
        : conversationHistory;

    final historyText = cappedHistory
        .map((t) => "${t['role'] == 'user' ? 'User' : 'Panda'}: ${t['text']}")
        .join('\n');

    final StringBuffer pathCtx = StringBuffer();
    if (isInDigression) {
      pathCtx.writeln('STATE: IN_DIGRESSION');
      pathCtx.writeln(
        'Digression topic: "${digressionTopic ?? "unknown"}", depth: $digressionTurnCount turn(s).',
      );
      pathCtx.writeln(
        'If the user seems satisfied / wrapping up, set intent = "digression_complete".',
      );
    } else if (isOnPredefinedPath && pendingQuestionPrompt != null) {
      pathCtx.writeln('STATE: ON_PREDEFINED_PATH');
      pathCtx.writeln(
        'Current question (ID: $pendingQuestionId): "$pendingQuestionPrompt"',
      );
    } else {
      pathCtx.writeln('STATE: FREE_CONVERSATION (predefined path complete)');
    }

    final slotsCtx = (accumulatedSlots != null && accumulatedSlots.isNotEmpty)
        ? 'SLOTS SO FAR: ${jsonEncode(accumulatedSlots)}'
        : 'SLOTS SO FAR: none';

    final spikeCtxLine = embedSpikeContext
        ? 'SPIKE CONTEXT: ${jsonEncode(trimSpikeContext(spikeContext))}\n\n'
        : '';

    final scheduleLine =
        (embedScheduleContext &&
            scheduleContext != null &&
            scheduleContext.isNotEmpty)
        ? 'SCHEDULE (next 7 days, local time):\n$scheduleContext\n\n'
        : '';

    final insightsLine =
        (embedInsightsContext &&
            insightsContext != null &&
            insightsContext.isNotEmpty)
        ? 'PAST INSIGHTS (from previous sessions):\n$insightsContext\n\n'
        : '';

    final dashboardLine =
        (dashboardContext != null && dashboardContext.isNotEmpty)
        ? 'DASHBOARD METRICS (real HealthKit daily aggregates; use only these values):\n$dashboardContext\n\n'
        : '';

    final personaLine = embedPersona
        ? 'You are Panda 🐼, a warm, empathetic wellness companion in Vivordo.\n\n'
        : '';

    final tasksSection = embedTaskInstructions
        ? '\n\nTASKS:\n\n'
              '1. INTENT (pick one): "answer_label" | "want_deeper_answer" | "digress" |\n'
              '   "digression_complete" | "new_stressor" | "recommend" | "chitchat" | "skip" | "calendar_action"\n'
              '\n'
              '2. MESSAGE (2–4 sentences):\n'
              '   • Never ask the next predefined question — the app handles that automatically.\n'
              '   • Deliver advice immediately with concrete examples — never just promise it.\n'
              '   • intent=="recommend": one warm intro sentence; the app shows the rec cards.\n'
              '   • intent=="want_deeper_answer": include one probing follow-up question.\n'
              '   • Digression depth ≥ 3: warmly begin wrapping up the side conversation.\n'
              '   • Availability/planning asks ("when am I free / mentally available"):\n'
              '     use SCHEDULE to find open windows, then weigh them against the\n'
              '     user\'s stress/energy patterns (spikes, intensity) to suggest the\n'
              '     best time(s). Name specific day + time range. If SCHEDULE is absent,\n'
              '     say their calendar isn\'t connected. intent stays "chitchat".\n'
              '   • Calendar mutation asks: set intent="calendar_action" and fill calendar_action.\n'
              '     operation is create/update/delete; target_title identifies an existing event.\n'
              '     start/end must be local ISO-8601 date-times. Resolve relative dates using the\n'
              '     dates shown in SCHEDULE. Ask for missing required title/date/time instead of\n'
              '     guessing. The app always asks the user to confirm before changing anything.\n'
              '   • You DO have memory of past sessions — PAST INSIGHTS holds the\n'
              '     user\'s recurring stressors, emotions, coping, and recent recaps.\n'
              '     Reference it when relevant; never claim you lack access to it.\n'
              '   • Tone: warm, peer-like. Never clinical. No diagnoses; use "may be related to".\n'
              '   • NEVER use the 💜 emoji or any heart emoji (❤️🩷💙 etc.).\n'
              '\n'
              '3. DEPTH_FOLLOW_UP: one open-ended probe (intent=="want_deeper_answer" only).\n'
              '\n'
              '4. INJECTED_QUESTION: targeted Q + 3–5 chip options + "Something else 🙋"\n'
              '   (intent=="new_stressor" only).\n'
              '\n'
              '5. REC_HINT: comma-separated keywords for the rec engine\n'
              '   (intent=="recommend" only). E.g. "music, sleep", "breathing, anxiety".\n'
              '\n'
              '6. FILLED_SLOTS: stressor, emotion, intensity (low/medium/high),\n'
              '   physical_symptom, activity, location, time_context, coping_strategy,\n'
              '   sleep_quality, social_context, other. Use "" for anything not mentioned.\n'
        : '';

    return '$personaLine$pathCtx\n$spikeCtxLine$scheduleLine$insightsLine$dashboardLine$slotsCtx\n\nCONVERSATION:\n$historyText\n\nUSER: "$userMessage"$tasksSection';
  }

  // =========================================================================
  // Data processing  (public static — reused by ClaudeService)
  // =========================================================================

  /// Builds the compact spike-candidate payload from raw health data.
  static Map<String, dynamic> buildCompactPayload(
    Map<String, dynamic> raw, {
    int topK = 3,
  }) {
    final profile = raw['user_profile'] ?? {};
    final window = raw['data_window'] ?? {};
    final events = (raw['events'] as List? ?? []).cast<Map>();
    final samples = (raw['samples_5min'] as List? ?? []).cast<Map>();
    final baselineHr = (profile['resting_hr_typical'] ?? 62).toDouble();
    final baselineHrv = (profile['hrv_rmssd_typical'] ?? 52).toDouble();

    var spikeCandidates = _detectSpikes(samples, baselineHr, baselineHrv);
    spikeCandidates.sort(
      (a, b) => _severity(
        b,
        baselineHr,
        baselineHrv,
      ).compareTo(_severity(a, baselineHr, baselineHrv)),
    );
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

      // Health metrics are DAILY aggregates — there is no real time-of-day for
      // a spike. Expose a day label and strip the placeholder clock time from
      // start/end so the model references the day, never a fabricated hour.
      s['day'] = _dayPhrase(s['start']?.toString());
      s['start'] = _dateOnly(s['start']?.toString());
      s['end'] = _dateOnly(s['end']?.toString());
      s['granularity'] = 'daily';
    }

    final userSetup = profile['user_setup'] as Map?;
    final insightsSummary = profile['insights_summary'] as Map?;
    final recentEvents = profile['recent_events'] as List?;
    final upcomingEvents = profile['upcoming_events'] as List?;
    return {
      'user_profile': {
        'timezone': profile['timezone'] ?? 'UTC',
        'age_range': profile['age_range'] ?? 'adult',
        'resting_hr_typical': baselineHr,
        'hrv_rmssd_typical': baselineHrv,
        if (userSetup != null && userSetup.isNotEmpty) 'user_setup': userSetup,
        if (insightsSummary != null && insightsSummary.isNotEmpty)
          'insights_summary': insightsSummary,
        if (recentEvents != null && recentEvents.isNotEmpty)
          'recent_events': recentEvents,
        if (upcomingEvents != null && upcomingEvents.isNotEmpty)
          'upcoming_events': upcomingEvents,
      },
      'data_window': window,
      'user_context': raw['user_context'] ?? '',
      'spike_candidates': spikeCandidates,
    };
  }

  /// Parses raw spike-analysis JSON into a PandaSessionData.
  static PandaSessionData parsePandaSession(
    String raw,
    Map<String, dynamic> rawSample, {
    String? overrideName,
  }) {
    final userMeta = rawSample['user_meta'] as Map<String, dynamic>?;

    final userName = overrideName?.isNotEmpty == true
        ? overrideName!
        : (userMeta?['userId'] as String? ?? 'there')
              .replaceAll(RegExp(r'[_\-]'), ' ')
              .split(' ')
              .first;

    // Schedule + insights travel with the payload — surface them on every
    // return path so each dialogue turn has calendar + past-session context.
    final scheduleContext = rawSample['upcoming_schedule'] as String?;
    final insightsContext = _insightsContextFromPayload(rawSample);
    final dashboardMetrics = _dashboardMetricsFromPayload(rawSample);

    final obj = _extractJson(raw);

    if (obj == null) {
      return _fallbackSession(
        userName,
        'earlier today',
        [],
        scheduleContext: scheduleContext,
        insightsContext: insightsContext,
        dashboardMetrics: dashboardMetrics,
      );
    }

    final overallNotes = (obj['summary']?['overall_notes'] as String? ?? '')
        .trim();

    final spikes = obj['spikes'] as List?;
    final rawSpikes = spikes?.whereType<Map<String, dynamic>>().toList() ?? [];

    final sleepSummary = rawSample['sleep_summary'] as Map?;
    final sleepHours =
        (sleepSummary?['total_hours'] as num?)?.toDouble() ?? 0.0;

    final openerMessage = _buildWarmOpener(
      userName: userName,
      hasSpikes: spikes != null && spikes.isNotEmpty,
      overallNotes: overallNotes,
      sleepHours: sleepHours,
    );

    if (spikes == null || spikes.isEmpty) {
      return PandaSessionData(
        openerMessage: openerMessage,
        questions: [],
        overallNotes: overallNotes,
        rawSpikes: rawSpikes,
        scheduleContext: scheduleContext,
        insightsContext: insightsContext,
        dashboardMetrics: dashboardMetrics,
      );
    }

    final spike = spikes.first as Map<String, dynamic>;
    // Daily data — reference the day, not a fabricated clock time.
    final timePhrase = _dayPhrase(spike['start'] as String?);

    final questions = <PandaQuestion>[];
    final qs = spike['questions'] as List?;

    if (qs != null) {
      for (final q in qs) {
        if (q is! Map) continue;

        final qid = q['question_id']?.toString() ?? 'q_${questions.length + 1}';
        final qp = q['prompt']?.toString() ?? '';
        if (qp.isEmpty) continue;

        // De-dupe options (the model sometimes repeats one) — compare
        // case/emoji/punctuation-insensitively.
        final opts = <String>[];
        final optKeys = <String>{};
        if (q['options'] is List) {
          for (final o in q['options'] as List) {
            final t = o.toString().trim();
            if (t.isEmpty) continue;
            if (optKeys.add(_optionKey(t))) opts.add(t);
          }
        }

        // Only add the escape hatch when the model didn't already supply one.
        // (The old check looked for "other", which "Something else 🙋" does not
        // contain — so it appended a duplicate every time.)
        if (opts.isNotEmpty && !optKeys.any(_isEscapeHatch)) {
          opts.add('Something else 🙋');
        }

        final depths = <String>[];
        if (q['depth_prompts'] is List) {
          for (final d in q['depth_prompts'] as List) {
            final t = d.toString().trim();
            if (t.isNotEmpty) depths.add(t);
          }
        }

        questions.add(
          PandaQuestion(
            questionId: qid,
            prompt: qp,
            options: opts,
            depthPrompts: depths,
          ),
        );
      }
    }

    if (questions.isEmpty) {
      return _fallbackSession(
        userName,
        timePhrase,
        rawSpikes,
        notes: overallNotes,
        scheduleContext: scheduleContext,
        insightsContext: insightsContext,
        dashboardMetrics: dashboardMetrics,
      );
    }

    return PandaSessionData(
      openerMessage: openerMessage,
      questions: questions,
      overallNotes: overallNotes,
      rawSpikes: rawSpikes,
      scheduleContext: scheduleContext,
      insightsContext: insightsContext,
      dashboardMetrics: dashboardMetrics,
    );
  }

  static Map<String, Map<String, dynamic>> _dashboardMetricsFromPayload(
    Map<String, dynamic> payload,
  ) {
    final raw = payload['dashboard_metrics'];
    if (raw is! Map) return const {};
    return raw.map(
      (date, metrics) => MapEntry(
        date.toString(),
        metrics is Map
            ? Map<String, dynamic>.from(metrics)
            : <String, dynamic>{},
      ),
    );
  }

  /// Formats the payload's insights_summary into a compact PAST-SESSIONS block
  /// for the dialogue context. Returns null when there is no usable history.
  static String? _insightsContextFromPayload(Map<String, dynamic> rawSample) {
    final profile = rawSample['user_profile'];
    if (profile is! Map) return null;
    final s = profile['insights_summary'];
    if (s is! Map) return null;

    final lines = <String>[];
    List<String> asList(Object? v) =>
        (v as List?)?.whereType<String>().where((e) => e.isNotEmpty).toList() ??
        const [];

    final stressors = asList(s['top_stressors']);
    final emotions = asList(s['top_emotions']);
    final coping = asList(s['top_coping']);
    final intensity = (s['typical_intensity'] as String?)?.trim() ?? '';
    final recents = asList(s['recent_sessions']);
    final counts = s['stressor_counts'] is Map
        ? (s['stressor_counts'] as Map)
        : const {};

    if (stressors.isNotEmpty) {
      // Annotate with frequency so priority is explicit, e.g.
      // "academia (5×), work stress (3×)" — higher count = higher priority,
      // but all listed stressors still matter.
      final rendered = stressors
          .map((st) {
            final c = (counts[st] as num?)?.toInt() ?? 0;
            return c > 1 ? '$st (${c}×)' : st;
          })
          .join(', ');
      lines.add('Recurring stressors (by frequency): $rendered');
    }
    if (emotions.isNotEmpty)
      lines.add('Common emotions: ${emotions.join(', ')}');
    if (coping.isNotEmpty)
      lines.add('Coping that came up: ${coping.join(', ')}');
    if (intensity.isNotEmpty) lines.add('Typical intensity: $intensity');
    if (recents.isNotEmpty) {
      lines.add('Recent session recaps:');
      for (final r in recents) {
        lines.add('• $r');
      }
    }

    if (lines.isEmpty) return null;
    return lines.join('\n');
  }

  /// Parses a raw dialogue-turn JSON string into a PandaTurnReply.
  static PandaTurnReply parseTurnReply(String raw) {
    try {
      final obj = _extractJson(raw);
      if (obj == null) throw FormatException('no JSON');

      final intentStr = obj['intent']?.toString() ?? 'chitchat';
      final intent = _parseIntent(intentStr);
      final message = obj['message']?.toString().trim().isNotEmpty == true
          ? obj['message'].toString().trim()
          : 'Got it';

      final depthFollowUp = (intent == PandaIntent.wantDeeperAnswer)
          ? obj['depth_follow_up']?.toString().trim()
          : null;

      PandaQuestion? injected;
      if (intent == PandaIntent.newStressor) {
        final iqRaw = obj['injected_question'];
        if (iqRaw is Map<String, dynamic>) {
          final qid = iqRaw['question_id']?.toString() ?? '';
          final qp = iqRaw['prompt']?.toString() ?? '';
          final opts = <String>[];
          final optKeys = <String>{};
          if (iqRaw['options'] is List) {
            for (final o in iqRaw['options'] as List) {
              final t = o.toString().trim();
              if (t.isEmpty) continue;
              if (optKeys.add(_optionKey(t))) opts.add(t); // de-dupe
            }
          }
          if (opts.isNotEmpty && !optKeys.any(_isEscapeHatch)) {
            opts.add('Something else 🙋');
          }
          if (qid.isNotEmpty && qp.isNotEmpty && opts.isNotEmpty) {
            injected = PandaQuestion(
              questionId: qid,
              prompt: qp,
              options: opts,
            );
          }
        }
      }

      Map<String, String>? slots;
      if (obj['filled_slots'] is Map<String, dynamic>) {
        final rawSlots = obj['filled_slots'] as Map<String, dynamic>;
        final m = <String, String>{};
        rawSlots.forEach((k, v) {
          final val = v?.toString().trim() ?? '';
          if (val.isNotEmpty) m[k] = val;
        });
        if (m.isNotEmpty) slots = m;
      }

      final recHint = (intent == PandaIntent.recommend)
          ? (obj['rec_hint']?.toString().trim().isNotEmpty == true
                ? obj['rec_hint'].toString().trim()
                : null)
          : null;

      PandaCalendarAction? calendarAction;
      if (intent == PandaIntent.calendarAction &&
          obj['calendar_action'] is Map) {
        final rawAction = Map<String, dynamic>.from(
          obj['calendar_action'] as Map,
        );
        final operation = switch (rawAction['operation']
            ?.toString()
            .toLowerCase()) {
          'create' => PandaCalendarOperation.create,
          'update' => PandaCalendarOperation.update,
          'delete' => PandaCalendarOperation.delete,
          _ => null,
        };
        DateTime? parseDate(String key) {
          final value = rawAction[key]?.toString().trim();
          return value == null || value.isEmpty
              ? null
              : DateTime.tryParse(value);
        }

        final title = rawAction['title']?.toString().trim();
        final targetTitle = rawAction['target_title']?.toString().trim();
        final start = parseDate('start');
        final end = parseDate('end');
        final valid =
            operation != null &&
            ((operation == PandaCalendarOperation.create &&
                    title?.isNotEmpty == true &&
                    start != null &&
                    end != null) ||
                (operation != PandaCalendarOperation.create &&
                    targetTitle?.isNotEmpty == true));
        if (valid) {
          calendarAction = PandaCalendarAction(
            operation: operation,
            title: title,
            targetTitle: targetTitle,
            start: start,
            end: end,
            recurrence: rawAction['recurrence']?.toString().trim() ?? 'none',
          );
        }
      }

      return PandaTurnReply(
        intent: intent,
        message: message,
        depthFollowUp: depthFollowUp,
        injectedQuestion: injected,
        filledSlots: slots,
        recHint: recHint,
        calendarAction: calendarAction,
      );
    } catch (_) {
      return PandaTurnReply(intent: PandaIntent.chitchat, message: 'Got it');
    }
  }

  /// Strips spike objects to (spike_id, window, top_hypothesis) to bound
  /// per-turn prompt token cost regardless of signal count.
  static List<Map<String, dynamic>> trimSpikeContext(
    List<Map<String, dynamic>> spikes,
  ) {
    return spikes.map((s) {
      final hypotheses = s['hypotheses'] as List? ?? [];
      final topLabel = hypotheses.isNotEmpty
          ? (hypotheses.first as Map<String, dynamic>)['label']?.toString() ??
                ''
          : '';
      return {
        'spike_id': s['spike_id'] ?? '',
        'start': s['start'] ?? '',
        'end': s['end'] ?? '',
        'top_hypothesis': topLabel,
      };
    }).toList();
  }

  // =========================================================================
  // Private static helpers
  // =========================================================================

  static Map<String, dynamic>? _extractJson(String raw) {
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

  static PandaIntent _parseIntent(String s) {
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
      case 'calendar_action':
        return PandaIntent.calendarAction;
      default:
        return PandaIntent.chitchat;
    }
  }

  static String _buildWarmOpener({
    required String userName,
    required bool hasSpikes,
    required String overallNotes,
    double sleepHours = 0.0,
  }) {
    final spikeSnippet = hasSpikes
        ? 'I noticed some elevated heart rate patterns in your recent data — '
              'I\'ve put together a few questions to help us understand what was going on. '
        : 'Your heart rate looks fairly steady in the data I have. ';

    final sleepSnippet = sleepHours >= 6
        ? 'You got ${sleepHours.toStringAsFixed(1)}h of sleep last night. '
        : sleepHours > 0
        ? 'You only got ${sleepHours.toStringAsFixed(1)}h of sleep — that can amplify stress. '
        : '';

    const invite =
        'What would you like to explore — your patterns, how to plan today, '
        'or something else on your mind?';

    return 'Hey $userName! $spikeSnippet$sleepSnippet$invite';
  }

  static PandaSessionData _fallbackSession(
    String userName,
    String timePhrase,
    List<Map<String, dynamic>> spikes, {
    String notes = '',
    String? scheduleContext,
    String? insightsContext,
    Map<String, Map<String, dynamic>> dashboardMetrics = const {},
  }) {
    return PandaSessionData(
      openerMessage:
          'Hey $userName! 🌿 Ive pulled up your health data for today. '
          'What would you like to explore — your stress patterns, how to plan your day, '
          'or something else on your mind?',
      questions: [
        PandaQuestion(
          questionId: 'q_fallback',
          prompt: 'What was happening on $timePhrase?',
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
      scheduleContext: scheduleContext,
      insightsContext: insightsContext,
      dashboardMetrics: dashboardMetrics,
    );
  }

  static double _severity(
    Map<String, dynamic> s,
    double baselineHr,
    double baselineHrv,
  ) {
    final hr = (s['signals']?['heart_rate']?['peak'] ?? 0).toDouble();
    final hrvMin = (s['signals']?['hrv']?['min'] ?? baselineHrv).toDouble();
    final steps = (s['signals']?['steps']?['peak_window'] ?? 0).toDouble();
    return (hr - baselineHr).clamp(0, 100) +
        (baselineHrv - hrvMin).clamp(0, 100) +
        (steps / 200.0).clamp(0, 30);
  }

  static List<Map<String, dynamic>> _detectSpikes(
    List<Map> samples,
    double baselineHr,
    double baselineHrv,
  ) {
    bool isSpike(Map s) {
      final hr = (s['hr'] ?? baselineHr).toDouble();
      final hrv = (s['hrv'] ?? baselineHrv).toDouble();
      final stress = (s['stress_score'] ?? 0).toDouble();
      return hr >= baselineHr + 25 || hrv <= baselineHrv - 18 || stress >= 65;
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
            'steps': {'peak_window': 0.0},
          },
        };
        cur['end'] = t;
        if (hr > peakHr) peakHr = hr;
        if (hrv < minHrv) minHrv = hrv;
        if (steps > peakSteps) peakSteps = steps;
        cur['signals']['heart_rate']['peak'] = peakHr;
        cur['signals']['hrv']['min'] = (minHrv == 1e9) ? baselineHrv : minHrv;
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

  static List<Map<String, dynamic>> _eventsNear({
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

  // =========================================================================
  // User data enrichment placeholders
  // =========================================================================

  Future<void> appendEntitiesToUserData({
    required String userId,
    required Map<String, String> sessionSlots,
    required Map<String, String> labeledAnswers,
    required DateTime sessionDate,
  }) async {
    // ignore: avoid_print
    print('[PandaService] PLACEHOLDER — would write to user $userId:');
    // ignore: avoid_print
    print('  Session date : ${sessionDate.toIso8601String()}');
    // ignore: avoid_print
    print('  Slots        : $sessionSlots');
    // ignore: avoid_print
    print('  Labeled Q→A  : $labeledAnswers');
  }

  Future<void> updateLabeledAnswer({
    required String userId,
    required DateTime sessionDate,
    required String questionId,
    required String oldAnswer,
    required String newAnswer,
  }) async {
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
}
