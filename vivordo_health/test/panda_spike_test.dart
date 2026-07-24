// ignore_for_file: avoid_print

// =============================================================================
// panda_spike_test.dart
//
// Confirms the full spike → question → insight flow using the pure-logic
// static helpers on GeminiService.
//
// These tests do NOT need Firebase — they exercise only the in-process
// data-processing pipeline.  Run with:
//
//   flutter test test/panda_spike_test.dart
//
// The test user is gbupweX0Wbe5hr5S86nHohhHYFd2.
// To also verify end-to-end (Firestore fetch + LLM call), seed Firestore
// with the script at test/seed_spike_data.js, then open the Panda screen
// on a device logged in as that user.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:vivordo_health/src/services/ai_service.dart';
import 'package:vivordo_health/src/services/gemini_service.dart';

// ---------------------------------------------------------------------------
// Test fixture: simulated fetchRealUserPayload output for a user who has
// 7 days of heart_rate data with a spike on the most recent day.
// Mirrors the exact map shape that fetchRealUserPayload returns.
// ---------------------------------------------------------------------------

const _testUserId = 'gbupweX0Wbe5hr5S86nHohhHYFd2';

Map<String, dynamic> _buildSpikePayload() {
  // Baseline: avg HR across 6 normal days ≈ 62 bpm → spike threshold = 87 bpm.
  // Day 7 (today): max HR = 115 bpm → exceeds threshold → spike detected.
  final today = DateTime.now();
  final samples = <Map<String, dynamic>>[];

  for (int i = 6; i >= 0; i--) {
    final day = today.subtract(Duration(days: i));
    final dateStr =
        '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
    final isSpike = i == 0; // only the most recent day has a spike
    samples.add({
      't': '${dateStr}T12:00:00',
      'hr': isSpike ? 115 : 68, // spike: 115 bpm; normal: 68 bpm
      'hrv': 52,
      'steps': isSpike ? 2200 : 5400,
      'activity': isSpike ? 'work_focus' : 'light',
      'tag': '',
    });
  }

  final today0 = today;
  final week0 = today.subtract(const Duration(days: 6));

  return {
    'user_profile': {
      'timezone': 'UTC',
      'age_range': 'adult',
      'resting_hr_typical': 62.0, // 7-day avg of normal readings
      'hrv_rmssd_typical': 52.0,
    },
    'data_window': {
      'start': '${week0.year}-${week0.month.toString().padLeft(2, '0')}-${week0.day.toString().padLeft(2, '0')}T00:00:00',
      'end': '${today0.year}-${today0.month.toString().padLeft(2, '0')}-${today0.day.toString().padLeft(2, '0')}T23:59:59',
    },
    'samples_5min': samples,
    'events': <Map<String, dynamic>>[],
    'demo_user': {'userId': _testUserId},
  };
}

// ---------------------------------------------------------------------------
// Minimal spike-analysis JSON that would be returned by the LLM.
// Used to test parsePandaSession without a real LLM call.
// ---------------------------------------------------------------------------

const _mockSpikeJson = '''
{
  "summary": {
    "data_window_start": "2026-06-09T00:00:00",
    "data_window_end": "2026-06-16T23:59:59",
    "overall_notes": "Heart rate reached 115 bpm — notably above your baseline."
  },
  "spikes": [
    {
      "spike_id": "spk_1",
      "start": "2026-06-16T12:00:00",
      "end": "2026-06-16T12:00:00",
      "signals": {
        "heart_rate": { "baseline": 62.0, "peak": 115.0 },
        "hrv": { "baseline": 52.0, "min": 52.0 },
        "steps": { "peak_window": 2200.0 }
      },
      "context": { "nearby_events": [], "confidence": 0.55 },
      "hypotheses": [
        { "label": "work_stress", "reason": "Elevated HR mid-day", "confidence": 0.7 }
      ],
      "questions": [
        {
          "question_id": "q_1",
          "prompt": "What were you doing when your heart rate spiked this afternoon?",
          "type": "multiple_choice",
          "options": ["Work / study 📚", "Exercise 🏃", "Social situation 👥", "Commute 🚗"],
          "depth_prompts": [
            "Can you tell me more about what made that stressful?",
            "How were you feeling physically during that time?"
          ]
        },
        {
          "question_id": "q_2",
          "prompt": "How stressed did you feel in the hour leading up to it?",
          "type": "multiple_choice",
          "options": ["Very stressed 😰", "Somewhat stressed 😕", "Not really 😌", "Hard to say 🤔"],
          "depth_prompts": [
            "What was the main thing on your mind?",
            "Did anything help you calm down afterwards?"
          ]
        }
      ],
      "ml_labels_to_collect": ["stressor_type", "stress_intensity"]
    }
  ]
}
''';

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Spike detection — buildCompactPayload', () {
    test('detects spike when peak HR exceeds baseline + 25', () {
      final payload = _buildSpikePayload();
      final compact = GeminiService.buildCompactPayload(payload, topK: 3);

      final spikes = compact['spike_candidates'] as List;
      expect(spikes, isNotEmpty,
          reason: 'Peak HR of 115 bpm against 62 bpm baseline should produce a spike');

      final spike = spikes.first as Map<String, dynamic>;
      final peakHr = spike['signals']['heart_rate']['peak'] as num;
      expect(peakHr, greaterThanOrEqualTo(87),
          reason: 'Spike peak HR must be >= baseline (62) + 25');
    });

    test('no spikes when all HR readings are within normal range', () {
      final payload = _buildSpikePayload();
      // Overwrite samples with all-normal readings
      final normalSamples = (payload['samples_5min'] as List<Map<String, dynamic>>)
          .map((s) => {...s, 'hr': 70})
          .toList();
      payload['samples_5min'] = normalSamples;

      final compact = GeminiService.buildCompactPayload(payload, topK: 3);
      final spikes = compact['spike_candidates'] as List;
      expect(spikes, isEmpty,
          reason: 'HR at 70 bpm against 62 bpm baseline is below the 25-bpm threshold');
    });

    test('compact payload contains no journal or goals keys', () {
      final payload = _buildSpikePayload();
      final compact = GeminiService.buildCompactPayload(payload, topK: 3);

      expect(compact.containsKey('journal'), isFalse,
          reason: 'Journal does not exist and must never be sent to the LLM');
      expect(compact.containsKey('goals'), isFalse,
          reason: 'Goals do not exist and must never be sent to the LLM');
    });
  });

  group('Spike prompt — buildSpikeUserPrompt', () {
    test('prompt does not reference journal or goals', () {
      final payload = _buildSpikePayload();
      final compact = GeminiService.buildCompactPayload(payload, topK: 1);
      compact['user_context'] = '';
      compact['_variability_seed'] = 12345;

      final prompt = GeminiService.buildSpikeUserPrompt(compact);

      // "journal" may appear in the "Do NOT invent journal entries" guardrail —
      // what must NOT appear is a positive instruction to USE journal data.
      expect(prompt.contains('DATA.journal'), isFalse,
          reason: 'Prompt must not tell the LLM to read from a DATA.journal key');
      expect(prompt.contains('use.*journal'), isFalse,
          reason: 'Prompt must not instruct the LLM to use journal content');
      expect(prompt.contains('DATA.goals'), isFalse,
          reason: 'Prompt must not tell the LLM to read from a DATA.goals key');
      expect(prompt.contains('Do NOT invent'), isTrue,
          reason: 'Prompt must explicitly forbid the LLM from inventing context');
    });
  });

  group('Spike session parsing — parsePandaSession', () {
    test('parses questions from valid LLM JSON', () {
      final payload = _buildSpikePayload();
      final session = GeminiService.parsePandaSession(
        _mockSpikeJson,
        payload,
        overrideName: 'TestUser',
      );

      expect(session.questions, isNotEmpty,
          reason: 'Spike JSON contains 2 questions — both must be parsed');
      expect(session.questions.length, equals(2));
      expect(session.questions.first.questionId, equals('q_1'));
      expect(session.questions.first.options, contains('Work / study 📚'));
    });

    test('opener mentions heart rate spike, not journal or mood', () {
      final payload = _buildSpikePayload();
      final session = GeminiService.parsePandaSession(
        _mockSpikeJson,
        payload,
        overrideName: 'TestUser',
      );

      final opener = session.openerMessage.toLowerCase();
      expect(opener.contains('heart rate'), isTrue,
          reason: 'Opener must reference heart rate — the only data source');
      expect(opener.contains('journal'), isFalse);
      expect(opener.contains('mood'), isFalse);
      expect(opener.contains('stress score'), isFalse);
    });

    test('empty-state session returned when no LLM JSON', () {
      final payload = _buildSpikePayload();
      final session = GeminiService.parsePandaSession(
        'not json at all',
        payload,
        overrideName: 'TestUser',
      );

      // Fallback session: still has at least one question to keep the flow alive
      expect(session.questions, isNotEmpty,
          reason: 'Fallback session must include a question so the path does not dead-end');
    });
  });

  // ---------------------------------------------------------------------------
  // AC: Token guard — 50-turn history is rejected before API is called
  //
  // The guard in both ClaudeService and GeminiService checks RAW inputs
  // (before buildDialoguePrompt caps to 10 turns) so a 50-turn history is
  // always caught.  If estimatedTokens > kMaxInputTokens, the method returns
  // a fallback PandaTurnReply immediately — the Cloud Function / Gemini model
  // is NEVER called.
  // ---------------------------------------------------------------------------

  group('Token guard', () {
    // ~210 chars per turn — representative of a real Panda exchange
    // (user explains situation, assistant asks follow-up, ~50–60 words each).
    const _realisticTurn =
        "I've been feeling really overwhelmed with everything happening at work. "
        "The deadlines keep piling up and I'm struggling with the anxiety it causes. "
        "My heart rate spikes whenever I think about the meeting tomorrow morning.";

    test('estimateTokens: 50-turn history exceeds kMaxInputTokens (2500)', () {
      final history = List.generate(50, (i) => {
        'role': i.isEven ? 'user' : 'assistant',
        'text': _realisticTurn,
      });
      final rawHistoryText =
          history.map((t) => '${t['role']}: ${t['text']}').join('\n');

      // Include typical Claude dialogue system blocks in the estimate,
      // mirroring what ClaudeService.processTurn passes to estimateTokens.
      const systemContext =
          'Return ONLY a valid JSON object — no markdown, no backticks, no prose.\n'
          'Required keys: intent, message, depth_follow_up, injected_question, '
          'filled_slots, rec_hint.\n'
          'APPLE HEALTH CONTEXT\n{"spikes":[]}\n'
          'STRESS SCORE / AVAILABILITY\n{}';

      final estimated =
          GeminiService.estimateTokens(systemContext + rawHistoryText);

      expect(estimated, greaterThan(kMaxInputTokens),
          reason: '50 turns of realistic content + system context must exceed '
              'the $kMaxInputTokens-token budget so the guard fires');
    });

    test('estimateTokens: normal 10-turn history stays under kMaxInputTokens', () {
      final history = List.generate(10, (i) => {
        'role': i.isEven ? 'user' : 'assistant',
        'text': _realisticTurn,
      });
      final rawHistoryText =
          history.map((t) => '${t['role']}: ${t['text']}').join('\n');
      const systemContext =
          'Return ONLY a valid JSON object — no markdown, no backticks, no prose.\n'
          'Required keys: intent, message, depth_follow_up, injected_question, '
          'filled_slots, rec_hint.\n'
          'APPLE HEALTH CONTEXT\n{"spikes":[]}\n'
          'STRESS SCORE / AVAILABILITY\n{}';

      final estimated =
          GeminiService.estimateTokens(systemContext + rawHistoryText);

      expect(estimated, lessThanOrEqualTo(kMaxInputTokens),
          reason: '10 turns must stay under the $kMaxInputTokens-token budget');
    });

    test('kMaxOutputTokensChat is 300 and kMaxOutputTokensSpike is 1800', () {
      expect(kMaxOutputTokensChat, equals(300));
      expect(kMaxOutputTokensSpike, equals(1800));
    });

    test('estimateTokens: 1 token per 4 chars (conservative)', () {
      // 400 chars → 100 tokens
      expect(GeminiService.estimateTokens('a' * 400), equals(100));
      // 401 chars → ceil → 101 tokens
      expect(GeminiService.estimateTokens('a' * 401), equals(101));
    });

    // Guard contract (not automated here — requires Firebase init):
    //
    // GeminiService.processTurn: guards on RAW conversationHistory — the
    //   system prompt is inline (~125 tokens), so 50 raw turns comfortably
    //   exceeds 2500 tokens. Test above confirms this.
    //
    // ClaudeService.processTurn: guards on CAPPED history (last 6 items) —
    //   _dialogueSystem is ~1,800 tokens, so guarding on raw turns would fire
    //   after only 6 turns.  The 6-item cap is the primary defence; the guard
    //   catches unexpectedly large health context or message payloads.
    //
    // Both services return:
    //   PandaTurnReply(intent: PandaIntent.chitchat, message: "We've covered ...")
    // and PandaScreen shows that message in-chat rather than an error dialog.
  });

  group('Insight persistence contract', () {
    test('spike → questions exist → session can be completed', () {
      final payload = _buildSpikePayload();
      final compact = GeminiService.buildCompactPayload(payload, topK: 1);

      expect((compact['spike_candidates'] as List).isNotEmpty, isTrue);

      // Simulate what PandaScreen does: if questions are generated from a real
      // LLM call, _persistCompletedSession is called.  We verify the precondition
      // (questions exist) so the code path that calls saveSessionInsight is reached.
      final session = GeminiService.parsePandaSession(
        _mockSpikeJson,
        payload,
        overrideName: 'TestUser',
      );

      expect(session.questions.isNotEmpty, isTrue,
          reason: 'With a spike detected, parsePandaSession must produce questions; '
              'PandaScreen then calls _persistCompletedSession once all are answered');
    });
  });

  group('On-demand dashboard context', () {
    test('dialogue prompt includes only the supplied metric context', () {
      final prompt = GeminiService.buildDialoguePrompt(
        userMessage: 'How were my steps?',
        conversationHistory: const [],
        spikeContext: const [],
        isOnPredefinedPath: false,
        isInDigression: false,
        digressionTurnCount: 0,
        dashboardContext: 'steps:2026-07-16=7241,2026-07-15=6810',
      );

      expect(prompt, contains('DASHBOARD METRICS'));
      expect(prompt, contains('2026-07-16=7241'));
    });

    test('dialogue prompt has no dashboard block for ordinary chat', () {
      final prompt = GeminiService.buildDialoguePrompt(
        userMessage: 'I had a difficult meeting.',
        conversationHistory: const [],
        spikeContext: const [],
        isOnPredefinedPath: false,
        isInDigression: false,
        digressionTurnCount: 0,
      );

      expect(prompt, isNot(contains('DASHBOARD METRICS')));
    });
  });
}
