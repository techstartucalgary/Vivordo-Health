// Shared data types for the Panda AI service abstraction.
// Imported by GeminiService, ClaudeService, AIService, and PandaScreen.

class PandaSessionData {
  PandaSessionData({
    required this.openerMessage,
    required this.questions,
    required this.overallNotes,
    required this.rawSpikes,
    this.dashboardMetrics = const {},
    this.scheduleContext,
    this.insightsContext,
  });

  final String openerMessage;
  final List<PandaQuestion> questions;
  final String overallNotes;

  /// Raw spike JSON kept so the dialogue LLM has health data for context.
  final List<Map<String, dynamic>> rawSpikes;

  /// Recent daily aggregates already used by the Dashboard. Kept in memory and
  /// selectively summarized by PandaScreen; the full map is never sent to the
  /// model.
  final Map<String, Map<String, dynamic>> dashboardMetrics;

  /// Per-day Google Calendar digest for the next 7 days (local time), passed
  /// into each dialogue turn so Panda can answer availability / "when am I
  /// mentally free" planning questions. Null when Calendar isn't connected.
  final String? scheduleContext;

  /// Compact recap of PAST sessions (recurring stressors/emotions/coping +
  /// recent session summaries), passed into each dialogue turn so Panda can
  /// reference prior insights. Null when the user has no insight history.
  final String? insightsContext;
}

/// Result of a fast session bootstrap.
///
/// [session] is ready IMMEDIATELY (opener + contexts, no labeling questions) so
/// the chat opens without waiting on the LLM. [spikeAnalysis] resolves later
/// with the full session INCLUDING the questions; it is null when there is
/// nothing to analyze (no new spike), in which case the chat is already final.
class PandaSessionBootstrap {
  PandaSessionBootstrap({required this.session, this.spikeAnalysis});

  final PandaSessionData session;
  final Future<PandaSessionData>? spikeAnalysis;
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
  final List<String> depthPrompts;
}

// ---------------------------------------------------------------------------
// Intent classification (ICM+LLM hybrid pattern)
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
  calendarAction,
}

enum PandaCalendarOperation { create, update, delete }

/// A proposed calendar mutation. The UI must obtain explicit confirmation
/// before passing this to CalendarService.
class PandaCalendarAction {
  const PandaCalendarAction({
    required this.operation,
    this.title,
    this.targetTitle,
    this.start,
    this.end,
    this.recurrence = 'none',
  });

  final PandaCalendarOperation operation;
  final String? title;
  final String? targetTitle;
  final DateTime? start;
  final DateTime? end;
  final String recurrence;
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
    this.calendarAction,
  });

  final PandaIntent intent;

  /// What Panda says (always present, never empty).
  final String message;

  /// When intent == wantDeeperAnswer: a follow-up probing question.
  final String? depthFollowUp;

  /// When intent == newStressor: inject this question into the queue.
  final PandaQuestion? injectedQuestion;

  /// Slot values extracted from this turn (accumulated across session).
  final Map<String, String>? filledSlots;

  /// When intent == recommend: comma-separated keywords for the rec engine.
  final String? recHint;

  /// Present only when [intent] is [PandaIntent.calendarAction].
  final PandaCalendarAction? calendarAction;
}
