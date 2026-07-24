import 'panda_types.dart';

export 'panda_types.dart';

// ---------------------------------------------------------------------------
// Token budget constants — shared by every AIService implementation.
// ---------------------------------------------------------------------------

/// Hard-reject any call whose estimated input exceeds this many tokens.
/// Protects against runaway prompt costs and latency spikes.
/// 1 token ≈ 4 characters (conservative English estimate).
const int kMaxInputTokens = 2500;

/// Output cap for a single dialogue turn (processTurn).
const int kMaxOutputTokensChat = 300;

/// Output cap for session spike analysis (analyzePandaSession).
const int kMaxOutputTokensSpike = 1800;

/// Output cap for the end-of-session insight summary (summarizeSession).
const int kMaxOutputTokensSummary = 180;

// ---------------------------------------------------------------------------
// Runtime feature flags (toggle without a rebuild via these static fields).
// ---------------------------------------------------------------------------

class AppFlags {
  AppFlags._();

  /// When true, each detected spike is surfaced for analysis only ONCE per
  /// user. Since metrics are daily aggregates, a spike is identified by its day:
  /// once a day's spike has been analyzed it is recorded on the user doc
  /// (`analyzed_spike_days`) and excluded from future sessions, so Panda never
  /// re-asks about the same spike. Set to false to analyze every detected spike
  /// on every session.
  static bool dedupeAnalyzedSpikes = true;
}

// ---------------------------------------------------------------------------

/// Common interface implemented by GeminiService and ClaudeService.
/// Switch between them at runtime via AIServiceFactory + Remote Config.
abstract class AIService {
  /// Run spike analysis and return the initial Panda session data
  /// (opener message, labeling questions, raw spike context).
  ///
  /// [userId] — real Firebase uid; when null/empty, an empty-state session
  /// is returned (no data to analyze).
  Future<PandaSessionData> analyzePandaSession({
    String? extraUserContext,
    String? userName,
    String? userId,
  });

  /// Fast session bootstrap for progressive loading: does the Firestore reads
  /// only (NO calendar, NO LLM) and returns the opener + contexts immediately so
  /// the chat opens without a wait. The returned bootstrap's `spikeAnalysis`
  /// future resolves later with the labeling questions — or is null when there
  /// is no new spike to analyze, in which case no LLM call is made at all.
  Future<PandaSessionBootstrap> startSession({
    String? extraUserContext,
    String? userName,
    String? userId,
  });

  /// Process a single dialogue turn.
  ///
  /// [scheduleContext] — optional per-day Google Calendar digest for the next
  /// 7 days (from PandaSessionData.scheduleContext) so Panda can answer
  /// availability / planning questions. Null when Calendar isn't connected.
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
  });

  /// Produce a brief (≤55 word) third-person insight recap of a completed
  /// session, written as durable context for a FUTURE session — capturing the
  /// main stressor + trigger, emotional state + intensity, relevant context,
  /// what coping helped, and any pattern. NOT a restatement of the Q&A.
  /// Returns '' on failure so the caller can fall back to a deterministic
  /// summary.
  Future<String> summarizeSession({
    required List<Map<String, String>> conversation,
    required Map<String, String> slots,
    required Map<String, String> labeledAnswers,
  });
}
