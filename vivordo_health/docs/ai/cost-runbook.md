# AI Cost Runbook

Owner: Engineering  
Last updated: 2026-06-16

---

## 1. How to read the cost dashboard

### Anthropic Console

1. Go to **console.anthropic.com → Workspaces → Usage**.
2. Filter by **API key** (the key ending in the last 4 chars of your `.env` `ANTHROPIC_API_KEY`).
3. Key columns:
   | Column | What it means |
   |---|---|
   | `input_tokens` | Tokens billed at full price |
   | `cache_creation_input_tokens` | First write to prompt cache (charged at 1.25× input rate) |
   | `cache_read_input_tokens` | Cache hit — charged at 0.1× input rate |
   | `output_tokens` | Response tokens billed at output rate |

4. **Batch API jobs** appear under **Usage → Batch** with a 50% discount applied automatically. Verify that `pandaBatchNightly` and `pandaQuestionnaireBatch` jobs appear here — if they appear under the regular Usage tab, the batch path is broken.

### Firebase Console

Cloud Function invocations and durations are in **Firebase Console → Functions → Dashboard**. Scheduled functions (`pandaBatchNightly`, `pandaBatchPoller`, `pandaQuestionnaireBatch`) appear with their run history. Unexpected failures trigger alerts in **Firebase Console → Alerting**.

### Reading cache efficiency (VIV-307)

In Cloud Function logs (`firebase functions:log --only pandaClaude`), each call emits:

```
[pandaClaude] usage {"input":540,"output":87,"cache_create":512,"cache_read":0}
[pandaClaude] usage {"input":28,"output":91,"cache_create":0,"cache_read":512}
```

Turn 1: `cache_create > 0`, `cache_read == 0` — cache written.  
Turn 2+: `cache_read ≈ input turn-1` — cache hit; effective cost ≈ 10% of a full-input call.  
If `cache_read` stays at 0 after turn 2, the cache is being invalidated (check that the cached system blocks are truly stable between calls — slots must NOT be in a cached block).

---

## 2. Per-user cost caps

### Current token budgets

Defined in `lib/src/services/ai_service.dart`:

```dart
const int kMaxInputTokens       = 2500;   // hard reject above this
const int kMaxOutputTokensChat  = 300;    // per dialogue turn
const int kMaxOutputTokensSpike = 1800;   // per spike-analysis session
```

To **raise or lower a cap**, edit those constants and redeploy the app. The same constants flow to `functions/index.js` via the `maxTokens` field on each callable request; the Cloud Function uses the client-supplied value (with a 300-token fallback).

### Conversation history cap

`buildDialoguePrompt` in `lib/src/services/gemini_service.dart` keeps only the **last 6 items** (~3 exchanges). Increase or decrease the `> 6` threshold to tune history cost vs. context quality. The in-app `_turns` list and Firestore history record are never trimmed.

### Token guard

Both `GeminiService.processTurn` and `ClaudeService.processTurn` estimate input tokens on raw history before calling any API. If the estimate exceeds `kMaxInputTokens`, the call is aborted with a user-facing message. This is a last-resort safety net — normal sessions never reach it with the 6-item cap in place.

---

## 3. What to do when costs spike

### Step 1 — identify the source

```bash
firebase functions:log --only pandaClaude | grep '"input"' | sort -t: -k2 -n -r | head -20
```

High `cache_create` with no `cache_read` → caching is broken (most common cause).  
High `input` on normal turns → history cap is too large or cap constant was changed.  
Many calls in short succession → client is retrying aggressively; check Flutter timeout handling.

### Step 2 — kill switch

Set `ai_provider` in **Firebase Remote Config** to `"off"` (or any value that is not `"claude"` or `"gemini"`). `AIServiceFactory` falls through to a stub that returns empty state. No redeploy needed — Remote Config propagates in ~60 seconds.

### Step 3 — model downgrade

In `functions/index.js`, change `claude-sonnet-4-5` to `claude-haiku-4-5-20251001` for real-time calls. Haiku costs ~20× less than Sonnet but quality degrades noticeably for spike analysis. Redeploy with `firebase deploy --only functions`.

For batch workloads the model is already `claude-haiku-4-5-20251001` — no change needed.

### Step 4 — tighten caps

Lower `kMaxOutputTokensChat` to 150 or `kMaxInputTokens` to 1500. Ship a hotfix build or adjust via Remote Config if you add a remote override for these constants.

---

## 4. How to add a new AI feature without breaking the cost model

Follow these rules. Violating any one of them will break the cost projections.

### Rule 1 — always proxy through `pandaClaude`

The Anthropic API key must never leave the server (VIV-309). All new real-time AI features must go through the `pandaClaude` Cloud Function. Pass `maxTokens` explicitly:

```dart
await _fn.call<dynamic>({
  'system': [_cacheBlock(mySystemPrompt)],
  'user':   [{'type': 'text', 'text': myUserPrompt}],
  'maxTokens': kMaxOutputTokensChat,   // or your own capped constant
});
```

### Rule 2 — batch non-real-time work

If the user does not need the result within the same screen interaction, use the **Anthropic Batch API** (50% off):

- Nightly aggregations → add a request to `pandaBatchNightly`
- On-submission analysis → add a Firestore trigger like `pandaQuestionnaireBatch`
- The poller (`pandaBatchPoller`) handles routing results back by `custom_id` prefix

Add a new `custom_id` prefix (`myfeature-{docId}`) and a corresponding `else if` branch in the poller's result loop.

### Rule 3 — cache stable context

Structure every multi-turn feature so stable blocks (system prompt, session-scoped context) come **first** in the `system` array with `cache_control: {type: "ephemeral"}`. Dynamic content (current turn, user input) goes in the `user` message, never in a cached block.

```javascript
// GOOD — stable first, dynamic last
system: [
  {type: "text", text: stableSystemPrompt, cache_control: {type: "ephemeral"}},
  {type: "text", text: stableSessionData,  cache_control: {type: "ephemeral"}},
]
messages: [{role: "user", content: dynamicTurnContent}]

// BAD — dynamic data in cached block invalidates cache every turn
system: [
  {type: "text", text: stablePrompt,  cache_control: {type: "ephemeral"}},
  {type: "text", text: currentSlots,  cache_control: {type: "ephemeral"}},  // ❌
]
```

### Rule 4 — add a token guard

Any new feature that takes unbounded user-contributed text must estimate tokens before calling the API:

```dart
final estimated = GeminiService.estimateTokens(systemText + userText);
if (estimated > kMaxInputTokens) {
  // return a graceful fallback — do NOT call the API
}
```

### Rule 5 — cap output tokens explicitly

Never rely on the Cloud Function's 300-token fallback. Define a named constant in `ai_service.dart` and pass it:

```dart
const int kMaxOutputTokensMyFeature = 512;
```

---

## 5. Firestore collections written by AI workloads

| Collection | Written by | Contents |
|---|---|---|
| `insights/{id}` | `InsightService.saveSessionInsight` (Flutter) | Panda session slots + Q→A |
| `insights/{id}.questionnaireAnalysis` | `pandaBatchPoller` | Deep Q→A interpretation |
| `weekly_trends/{userId}` | `pandaBatchPoller` | Weekly HR/HRV/sleep trend narrative |
| `insight_summaries/{userId}` | `pandaBatchPoller` | Weekly session theme summary |
| `batch_jobs/{batchId}` | `pandaBatchNightly`, `pandaQuestionnaireBatch` | Batch job status tracking |
