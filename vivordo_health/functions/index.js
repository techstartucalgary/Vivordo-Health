const {setGlobalOptions} = require("firebase-functions");
const {onCall, onRequest, HttpsError} = require("firebase-functions/v2/https");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {defineSecret} = require("firebase-functions/params");
const Anthropic = require("@anthropic-ai/sdk");
const admin = require("firebase-admin");
const crypto = require("crypto");

admin.initializeApp();
setGlobalOptions({maxInstances: 10});

// Single shared client — reused across all function invocations on the same
// container instance (connection pooling, no per-call allocation overhead).
const client = new Anthropic({apiKey: process.env.ANTHROPIC_API_KEY});

const googleHealthClientId = defineSecret("GOOGLE_HEALTH_CLIENT_ID");
const googleHealthClientSecret = defineSecret("GOOGLE_HEALTH_CLIENT_SECRET");

// =============================================================================
// pandaClaude — real-time HTTPS Callable proxy for Anthropic API
// Security: API key stays server-side (VIV-309).
// =============================================================================

exports.pandaClaude = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }

  const {system, user, maxTokens} = request.data;
  if (!system || !user) {
    throw new HttpsError("invalid-argument", "system and user are required.");
  }

  // maxTokens: 300 for chat turns, 1800 for spike analysis (set by client).
  // Fall back to 300 (chat default) if omitted.
  const outputCap =
      (typeof maxTokens === "number" && maxTokens > 0) ? maxTokens : 300;

  const systemBlocks = Array.isArray(system) ?
    system :
    [
      {
        type: "text",
        text: String(system),
        cache_control: {type: "ephemeral"},
      },
    ];
  const userBlocks = Array.isArray(user) ?
    user :
    [{type: "text", text: String(user)}];

  const msg = await client.messages.create({
    model: "claude-sonnet-4-5",
    max_tokens: outputCap,
    system: systemBlocks,
    messages: [{role: "user", content: userBlocks}],
  });

  const text = (msg.content || []).reduce((acc, block) => {
    if (block && block.type === "text") {
      return acc ? `${acc}\n${block.text}` : block.text;
    }
    return acc;
  }, "");

  // VIV-307: log cache token usage so billing dashboard shows cache hits.
  console.log("[pandaClaude] usage", JSON.stringify({
    input: msg.usage?.input_tokens ?? 0,
    output: msg.usage?.output_tokens ?? 0,
    cache_create: msg.usage?.cache_creation_input_tokens ?? 0,
    cache_read: msg.usage?.cache_read_input_tokens ?? 0,
  }));

  return {
    text,
    usage: msg.usage || {},
  };
});

// =============================================================================
// Fitbit metric sync through the Google Health API
//
// Tokens are stored in a top-level collection that has no client Firestore
// rule, so only Admin SDK code can read them. The user document contains only
// connection status and timestamps.
// =============================================================================

const _GOOGLE_HEALTH_SECRETS = [
  googleHealthClientId,
  googleHealthClientSecret,
];
const _GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";
const _GOOGLE_HEALTH_API = "https://health.googleapis.com/v4";
const _GOOGLE_SCOPES = [
  "https://www.googleapis.com/auth/" +
      "googlehealth.activity_and_fitness.readonly",
  "https://www.googleapis.com/auth/" +
      "googlehealth.health_metrics_and_measurements.readonly",
  "https://www.googleapis.com/auth/googlehealth.sleep.readonly",
];
const _IOS_CALLBACK = "vivordo-fitbit://oauth2redirect";

/* eslint-disable require-jsdoc */
function requireAuth(request) {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }
  return request.auth.uid;
}

function googleHealthCallbackUrl() {
  const project = process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT;
  if (!project) {
    throw new HttpsError("internal", "Firebase project ID is unavailable.");
  }
  return `https://us-central1-${project}.cloudfunctions.net/` +
      "googleHealthOAuthCallback";
}

async function requestGoogleToken(parameters) {
  const response = await fetch(_GOOGLE_TOKEN_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({
      ...parameters,
      client_id: googleHealthClientId.value(),
      client_secret: googleHealthClientSecret.value(),
    }),
  });
  const body = await response.json();
  if (!response.ok) {
    console.error(
        "[Google Health] token request failed",
        response.status,
        body,
    );
    throw new HttpsError(
        "failed-precondition",
        "Google Health could not complete authorization.",
    );
  }
  return body;
}

async function saveGoogleHealthTokens(uid, tokens) {
  const expiresIn = Number(tokens.expires_in || 3600);
  const expiresAt = admin.firestore.Timestamp.fromMillis(
      Date.now() + expiresIn * 1000,
  );
  const values = {
    accessToken: tokens.access_token,
    scope: tokens.scope || "",
    tokenType: tokens.token_type || "Bearer",
    expiresAt,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
  if (tokens.refresh_token) values.refreshToken = tokens.refresh_token;
  await admin.firestore()
      .collection("google_health_credentials")
      .doc(uid)
      .set(values, {merge: true});
}

async function getGoogleHealthAccessToken(uid) {
  const reference =
      admin.firestore().collection("google_health_credentials").doc(uid);
  const snapshot = await reference.get();
  if (!snapshot.exists) {
    throw new HttpsError(
        "failed-precondition",
        "Connect Fitbit through Google Health before syncing.",
    );
  }

  const credentials = snapshot.data();
  const expiresAt = credentials.expiresAt?.toMillis?.() || 0;
  if (expiresAt > Date.now() + 5 * 60 * 1000) {
    return credentials.accessToken;
  }

  if (!credentials.refreshToken) {
    throw new HttpsError(
        "failed-precondition",
        "Reconnect Fitbit to grant offline access.",
    );
  }
  const tokens = await requestGoogleToken({
    grant_type: "refresh_token",
    refresh_token: credentials.refreshToken,
  });
  await saveGoogleHealthTokens(uid, tokens);
  return tokens.access_token;
}

async function googleHealthDailyRollup(accessToken, dataType, start, end) {
  const response = await fetch(
      `${_GOOGLE_HEALTH_API}/users/me/dataTypes/${dataType}/` +
      "dataPoints:dailyRollUp",
      {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          range: {
            start: civilDate(start),
            end: civilDate(end),
          },
          windowSizeDays: 1,
          pageSize: 90,
          dataSourceFamily:
              "users/me/dataSourceFamilies/google-wearables",
        }),
      },
  );
  if (response.status === 403 || response.status === 404) {
    console.warn(`[Google Health] optional data unavailable: ${dataType}`);
    return [];
  }
  if (!response.ok) {
    const body = await response.text();
    console.error(
        "[Google Health] API request failed",
        response.status,
        dataType,
        body,
    );
    throwGoogleHealthError(response.status, body);
  }
  const body = await response.json();
  return body.rollupDataPoints || [];
}

function throwGoogleHealthError(status, body) {
  let googleError;
  try {
    googleError = JSON.parse(body)?.error;
  } catch (_) {
    // Preserve the generic error below when Google returns a non-JSON body.
  }
  const accountDetail = googleError?.details?.find(
      (detail) => detail?.reason === "ACCOUNT_NOT_LINKED",
  );
  if (accountDetail) {
    throw new HttpsError(
        "failed-precondition",
        "Finish setting up Google Health before syncing Fitbit.",
        {
          reason: "ACCOUNT_NOT_LINKED",
          setupUrl:
              accountDetail.metadata?.redirect_uri ||
              "https://fitbit.google.com/auth/signup",
        },
    );
  }
  throw new HttpsError(
      status === 401 ? "unauthenticated" : "unavailable",
      "Fitbit data could not be synced from Google Health.",
  );
}

async function googleHealthSleep(accessToken, start, end) {
  const dataPoints = [];
  let pageToken;
  const filter =
      `sleep.interval.civil_end_time >= "${dateKey(start)}" AND ` +
      `sleep.interval.civil_end_time < "${dateKey(end)}"`;
  do {
    const query = new URLSearchParams({
      filter,
      pageSize: "25",
    });
    if (pageToken) query.set("pageToken", pageToken);
    const response = await fetch(
        `${_GOOGLE_HEALTH_API}/users/me/dataTypes/sleep/dataPoints?${query}`,
        {
          headers: {
            "Authorization": `Bearer ${accessToken}`,
            "Accept": "application/json",
          },
        },
    );
    if (response.status === 403 || response.status === 404) {
      console.warn("[Google Health] optional data unavailable: sleep");
      return [];
    }
    if (!response.ok) {
      const body = await response.text();
      console.error(
          "[Google Health] sleep request failed",
          response.status,
          body,
      );
      throwGoogleHealthError(response.status, body);
    }
    const body = await response.json();
    dataPoints.push(...(body.dataPoints || []));
    pageToken = body.nextPageToken;
  } while (pageToken);
  return dataPoints.filter((point) => {
    const platform = point.dataSource?.platform;
    return platform === "FITBIT" || platform === "FITBIT_WEB_API";
  });
}

function civilDate(date) {
  return {
    date: {
      year: date.getUTCFullYear(),
      month: date.getUTCMonth() + 1,
      day: date.getUTCDate(),
    },
    time: {hours: 0, minutes: 0, seconds: 0, nanos: 0},
  };
}

function civilDateKey(value) {
  const date = value?.date || value;
  if (!date?.year || !date?.month || !date?.day) return null;
  return [
    String(date.year).padStart(4, "0"),
    String(date.month).padStart(2, "0"),
    String(date.day).padStart(2, "0"),
  ].join("-");
}

function dateKey(date) {
  return date.toISOString().slice(0, 10);
}

function metricPayload(values) {
  const payload = {};
  for (const [key, value] of Object.entries(values)) {
    if (value !== undefined && value !== null && Number.isFinite(value)) {
      payload[key] = value;
    }
  }
  return payload;
}

function addMetric(days, day, key, values) {
  if (!day || Object.keys(values).length === 0) return;
  if (!days[day]) days[day] = {};
  days[day][key] = {
    ...values,
    source: "fitbit",
    syncedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

async function fetchGoogleHealthData(accessToken, start, end) {
  const types = [
    "steps",
    "distance",
    "floors",
    "active-energy-burned",
    "heart-rate",
    "weight",
  ];
  const results = await Promise.all(types.map(async (type) => {
    if (type !== "heart-rate") {
      return googleHealthDailyRollup(accessToken, type, start, end);
    }
    const entries = [];
    const chunkStart = new Date(start);
    while (chunkStart < end) {
      const chunkEnd = new Date(chunkStart);
      chunkEnd.setUTCDate(chunkEnd.getUTCDate() + 14);
      if (chunkEnd > end) chunkEnd.setTime(end.getTime());
      entries.push(...await googleHealthDailyRollup(
          accessToken,
          type,
          chunkStart,
          chunkEnd,
      ));
      chunkStart.setTime(chunkEnd.getTime());
    }
    return entries;
  }));
  const data = Object.fromEntries(types.map((type, index) => [
    type,
    results[index],
  ]));
  data.sleep = await googleHealthSleep(accessToken, start, end);
  return data;
}

function sleepMinutes(sleep) {
  const summaryMinutes = Number(sleep.summary?.minutesAsleep);
  if (Number.isFinite(summaryMinutes)) return summaryMinutes;
  return (sleep.stages || []).reduce((total, stage) => {
    if (!["LIGHT", "DEEP", "REM", "ASLEEP"].includes(stage.type)) {
      return total;
    }
    const start = Date.parse(stage.startTime);
    const end = Date.parse(stage.endTime);
    return Number.isFinite(start) && Number.isFinite(end) && end > start ?
      total + (end - start) / 60000 :
      total;
  }, 0);
}

function normalizeGoogleHealthData(data) {
  const days = {};
  for (const [type, entries] of Object.entries(data)) {
    if (type === "sleep") continue;
    for (const entry of entries) {
      const day = civilDateKey(entry.civilStartTime);
      addMetric(days, day, "steps", metricPayload({
        sum: Number(entry.steps?.countSum),
        avg: Number(entry.steps?.countSum),
        unit: "steps",
        dimension: "activity",
      }));
      addMetric(days, day, "distance", metricPayload({
        sum: Number(entry.distance?.millimetersSum) / 1000000,
        avg: Number(entry.distance?.millimetersSum) / 1000000,
        unit: "km",
        dimension: "activity",
      }));
      addMetric(days, day, "flights_climbed", metricPayload({
        sum: Number(entry.floors?.countSum),
        avg: Number(entry.floors?.countSum),
        unit: "flights",
        dimension: "activity",
      }));
      addMetric(days, day, "active_calories", metricPayload({
        sum: Number(entry.activeEnergyBurned?.kcalSum),
        avg: Number(entry.activeEnergyBurned?.kcalSum),
        unit: "kcal",
        dimension: "activity",
      }));
      addMetric(days, day, "heart_rate", metricPayload({
        avg: Number(entry.heartRate?.beatsPerMinuteAvg),
        min: Number(entry.heartRate?.beatsPerMinuteMin),
        max: Number(entry.heartRate?.beatsPerMinuteMax),
        unit: "bpm",
        dimension: "cardiovascular",
      }));
      addMetric(days, day, "weight", metricPayload({
        avg: Number(entry.weight?.weightGramsAvg) / 1000,
        unit: "kg",
        dimension: "body",
      }));
    }
  }
  const sleepByDay = {};
  for (const point of data.sleep || []) {
    const sleep = point.sleep;
    const day = civilDateKey(sleep?.interval?.civilEndTime);
    const minutes = sleepMinutes(sleep || {});
    if (day && minutes > 0) {
      sleepByDay[day] = (sleepByDay[day] || 0) + minutes;
    }
  }
  for (const [day, minutes] of Object.entries(sleepByDay)) {
    const hours = minutes / 60;
    addMetric(days, day, "sleep", metricPayload({
      avg: hours,
      min: hours,
      max: hours,
      unit: "hours",
      dimension: "sleep",
    }));
  }
  return days;
}

function addFitbitWellness(days) {
  for (const metrics of Object.values(days)) {
    let weightedScore = 0;
    let totalWeight = 0;
    const sleep = metrics.sleep?.avg;
    const steps = metrics.steps?.sum;
    const hrv = metrics.hrv?.avg;
    if (Number.isFinite(sleep)) {
      weightedScore += Math.max(0, Math.min(100, sleep / 8 * 100)) * 0.30;
      totalWeight += 30;
    }
    if (Number.isFinite(steps)) {
      weightedScore += Math.max(0, Math.min(100, steps / 10000 * 100)) * 0.20;
      totalWeight += 20;
    }
    if (Number.isFinite(hrv)) {
      weightedScore += Math.max(0, Math.min(100, hrv)) * 0.15;
      totalWeight += 15;
    }
    if (totalWeight > 0) {
      metrics.wellness = {
        avg: weightedScore / totalWeight * 100,
        unit: "score",
        source: "computed",
        computedAt: admin.firestore.FieldValue.serverTimestamp(),
      };
    }
  }
}

exports.beginFitbitConnection = onCall(
    {secrets: [googleHealthClientId]},
    async (request) => {
      const uid = requireAuth(request);
      const state = crypto.randomBytes(32).toString("base64url");
      await admin.firestore()
          .collection("google_health_oauth_states")
          .doc(state)
          .set({
            uid,
            expiresAt: admin.firestore.Timestamp.fromMillis(
                Date.now() + 10 * 60 * 1000,
            ),
          });
      const authorizationUrl = new URL(
          "https://accounts.google.com/o/oauth2/v2/auth",
      );
      authorizationUrl.search = new URLSearchParams({
        response_type: "code",
        client_id: googleHealthClientId.value(),
        redirect_uri: googleHealthCallbackUrl(),
        scope: _GOOGLE_SCOPES.join(" "),
        access_type: "offline",
        prompt: "consent",
        include_granted_scopes: "true",
        state,
      }).toString();
      return {authorizationUrl: authorizationUrl.toString()};
    },
);

exports.googleHealthOAuthCallback = onRequest(
    {secrets: _GOOGLE_HEALTH_SECRETS},
    async (request, response) => {
      const state = request.query.state;
      const code = request.query.code;
      const oauthError = request.query.error;
      const fail = (message) => response.redirect(
          `${_IOS_CALLBACK}?error=authorization_failed&` +
          `error_description=${encodeURIComponent(message)}`,
      );
      if (typeof state !== "string") return fail("Missing OAuth state.");
      const reference = admin.firestore()
          .collection("google_health_oauth_states")
          .doc(state);
      const snapshot = await reference.get();
      await reference.delete();
      const values = snapshot.data();
      if (!snapshot.exists ||
          (values?.expiresAt?.toMillis?.() || 0) < Date.now()) {
        return fail("The authorization request expired.");
      }
      if (oauthError || typeof code !== "string") {
        return fail("Google Health authorization was cancelled.");
      }
      try {
        const tokens = await requestGoogleToken({
          grant_type: "authorization_code",
          code,
          redirect_uri: googleHealthCallbackUrl(),
        });
        await saveGoogleHealthTokens(values.uid, tokens);
        await admin.firestore().collection("users").doc(values.uid).set({
          fitbitConnected: true,
          fitbitConnectedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, {merge: true});
        return response.redirect(`${_IOS_CALLBACK}?status=success`);
      } catch (error) {
        console.error("[Google Health] OAuth callback failed", error);
        return fail("Google Health could not complete authorization.");
      }
    },
);

exports.syncFitbit = onCall(
    {secrets: _GOOGLE_HEALTH_SECRETS, timeoutSeconds: 120},
    async (request) => {
      const uid = requireAuth(request);
      const requestedDays = Number(request.data?.daysBack || 30);
      const daysBack = Math.max(1, Math.min(30, Math.floor(requestedDays)));
      const endDate = new Date();
      const startDate = new Date();
      startDate.setUTCDate(endDate.getUTCDate() - daysBack + 1);
      const exclusiveEndDate = new Date(endDate);
      exclusiveEndDate.setUTCDate(exclusiveEndDate.getUTCDate() + 1);

      const accessToken = await getGoogleHealthAccessToken(uid);
      const raw = await fetchGoogleHealthData(
          accessToken,
          startDate,
          exclusiveEndDate,
      );
      const days = normalizeGoogleHealthData(raw);
      addFitbitWellness(days);
      const batch = admin.firestore().batch();
      for (const [day, metrics] of Object.entries(days)) {
        const reference = admin.firestore()
            .collection("users")
            .doc(uid)
            .collection("metrics_daily")
            .doc(day);
        batch.set(reference, {
          ...metrics,
          date: day,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, {merge: true});
      }
      batch.set(admin.firestore().collection("users").doc(uid), {
        fitbitConnected: true,
        lastFitbitSync: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
      await batch.commit();
      return {daysSynced: Object.keys(days).length};
    },
);

exports.disconnectFitbit = onCall(
    {secrets: _GOOGLE_HEALTH_SECRETS},
    async (request) => {
      const uid = requireAuth(request);
      const reference =
          admin.firestore().collection("google_health_credentials").doc(uid);
      const snapshot = await reference.get();
      if (snapshot.exists) {
        const token = snapshot.data()?.refreshToken ||
            snapshot.data()?.accessToken;
        if (token) {
          await fetch("https://oauth2.googleapis.com/revoke", {
            method: "POST",
            headers: {
              "Content-Type": "application/x-www-form-urlencoded",
            },
            body: new URLSearchParams({token}),
          }).catch((error) => {
            console.warn("[Google Health] revoke request failed", error);
          });
        }
      }
      await reference.delete();
      await admin.firestore().collection("users").doc(uid).set({
        fitbitConnected: false,
        fitbitDisconnectedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
      return {connected: false};
    },
);
/* eslint-enable require-jsdoc */

// =============================================================================
// Batch API helpers
// Model: claude-haiku-4-5-20251001 (cheapest; batch gives additional 50% off)
//
// Workloads:
//   1. weekly-trend-{userId}      nightly
//      → users/{userId}/weekly_trends/{weekOf}
//   2. insight-summary-{userId}   nightly
//      → users/{userId}/insight_summaries/{weekOf}
//   3. questionnaire-{insightId}  on submission
//      → users/{userId}/insights/{insightId}
//
// All batch jobs tracked top-level in batch_jobs/{batchId} — a single nightly
// batch spans many users, so job tracking isn't nested under any one user.
// =============================================================================

const _BATCH_MODEL = "claude-haiku-4-5-20251001";

const _weeklyTrendSystem =
    "You are a health data analyst for Vivordo. You will receive a user's " +
    "heart rate, HRV, steps, and sleep data from the past 7 days as JSON. " +
    "Return ONLY a valid JSON object with two keys: " +
    "\"trend\" (2-3 sentence narrative of the week's patterns) and " +
    "\"actionable\" (one specific, concrete suggestion). " +
    "No prose outside JSON.";

const _insightSummarySystem =
    "You are Panda, a wellness companion. You will receive a user's " +
    "completed wellness check-in sessions from the past 7 days as JSON. " +
    "Return ONLY a valid JSON object with two keys: " +
    "\"summary\" (2-3 sentence overview of recurring themes or patterns) and " +
    "\"highlight\" (the single most significant insight from this week). " +
    "No prose outside JSON.";

// Interprets structured Q→A answers + wellness slots from a single session.
// Output is written back to the originating insight document for the History
// tab and recommendation engine to consume.
const _questionnaireSystem =
    "You are a clinical wellness analyst. You will receive the labeled Q→A " +
    "answers and wellness entity slots from a single Vivordo Panda session. " +
    "Return ONLY a valid JSON object with three keys: " +
    "\"pattern\" (1 sentence — recurring trigger or behavioural pattern " +
    "evident from the answers), " +
    "\"insight\" (1-2 sentences — what the combination of stressor, emotion, " +
    "and context suggests about the user's stress profile), " +
    "\"recommendation\" (1 sentence — one concrete, actionable technique " +
    "tailored to the stressor and intensity). " +
    "No prose outside JSON.";

// =============================================================================
// pandaBatchNightly — workloads 1 & 2 (weekly trend + insight summary)
// =============================================================================

/**
 * Runs at 02:00 PT every night.
 * Queries insights created in the past 7 days, groups by userId, and submits
 * one weekly-trend + one insight-summary batch request per active user.
 * Results are written by pandaBatchPoller once the batch ends.
 */
exports.pandaBatchNightly = onSchedule({
  schedule: "0 2 * * *",
  timeZone: "America/Los_Angeles",
  memory: "256MiB",
}, async () => {
  const db = admin.firestore();

  const sevenDaysAgo = new Date();
  sevenDaysAgo.setDate(sevenDaysAgo.getDate() - 7);

  // insights now lives at users/{userId}/insights — collectionGroup() reaches
  // every user's subcollection in one query.
  const insightsSnap = await db.collectionGroup("insights")
      .where("createdAt", ">=", sevenDaysAgo)
      .get();

  const userInsights = {};
  insightsSnap.forEach((doc) => {
    const data = doc.data();
    if (!data.userId) return;
    if (!userInsights[data.userId]) userInsights[data.userId] = [];
    userInsights[data.userId].push({
      createdAt: data.createdAt?.toDate?.()?.toISOString() ?? null,
      pandaSlots: data.pandaSlots ?? {},
      pandaLabeledAnswers: data.pandaLabeledAnswers ?? {},
      sessionSummary: data.body ?? "",
    });
  });

  const userIds = Object.keys(userInsights);
  if (userIds.length === 0) {
    console.log("[pandaBatchNightly] No active users — skipping.");
    return;
  }

  const requests = [];
  for (const userId of userIds) {
    const sessions = userInsights[userId];

    requests.push({
      custom_id: `weekly-trend-${userId}`,
      params: {
        model: _BATCH_MODEL,
        max_tokens: 512,
        system: [{type: "text", text: _weeklyTrendSystem}],
        messages: [{
          role: "user",
          content: `Weekly sessions:\n${JSON.stringify(sessions, null, 2)}`,
        }],
      },
    });

    requests.push({
      custom_id: `insight-summary-${userId}`,
      params: {
        model: _BATCH_MODEL,
        max_tokens: 256,
        system: [{type: "text", text: _insightSummarySystem}],
        messages: [{
          role: "user",
          content: `Recent sessions:\n${JSON.stringify(sessions, null, 2)}`,
        }],
      },
    });
  }

  const batch = await client.messages.batches.create({requests});

  await db.collection("batch_jobs").doc(batch.id).set({
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    status: "pending",
    type: "nightly",
    requestCount: requests.length,
    userCount: userIds.length,
  });

  console.log(
      `[pandaBatchNightly] Submitted batch ${batch.id} — ` +
      `${userIds.length} users, ${requests.length} requests.`,
  );
});

// =============================================================================
// pandaQuestionnaireBatch — workload 3 (on session submission)
// =============================================================================

/**
 * Fires when a new `users/{userId}/insights` document is created with
 * source == "panda" and at least one labeled answer present.
 * Submits a single-request Batch API job for deep questionnaire analysis;
 * the result is written back to the same document by pandaBatchPoller.
 */
exports.pandaQuestionnaireBatch = onDocumentCreated(
    "users/{userId}/insights/{insightId}",
    async (event) => {
      const data = event.data?.data();
      if (!data) return;

      // Only process completed Panda sessions that have labeled Q→A answers.
      if (data.source !== "panda") return;
      const answers = data.pandaLabeledAnswers ?? {};
      if (Object.keys(answers).length === 0) return;

      const insightId = event.params.insightId;
      const userId = event.params.userId;
      const db = admin.firestore();

      const payload = {
        pandaSlots: data.pandaSlots ?? {},
        pandaLabeledAnswers: answers,
        sessionDate: data.sessionDate?.toDate?.()?.toISOString() ?? null,
      };

      const batch = await client.messages.batches.create({
        requests: [{
          custom_id: `questionnaire-${insightId}`,
          params: {
            model: _BATCH_MODEL,
            max_tokens: 384,
            system: [{type: "text", text: _questionnaireSystem}],
            messages: [{
              role: "user",
              content: `Session data:\n${JSON.stringify(payload, null, 2)}`,
            }],
          },
        }],
      });

      // Track the batch so the poller can retrieve and write results.
      await db.collection("batch_jobs").doc(batch.id).set({
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        status: "pending",
        type: "questionnaire",
        insightId,
        userId,
      });

      // Stamp the insight doc so the UI can show "analysis pending".
      await event.data.ref.update({
        questionnaireBatchId: batch.id,
        questionnaireAnalysisStatus: "pending",
      });

      console.log(
          `[pandaQuestionnaireBatch] Submitted batch ${batch.id} ` +
          `for insight ${insightId} (user ${userId}).`,
      );
    },
);

// =============================================================================
// pandaBatchPoller — collects results for all three workloads
// =============================================================================

/**
 * Polls every 30 min for completed batch jobs and writes results to Firestore.
 *
 * Routing by custom_id prefix:
 *   weekly-trend-{userId}      → users/{userId}/weekly_trends/{weekOf}
 *   insight-summary-{userId}   → users/{userId}/insight_summaries/{weekOf}
 *   questionnaire-{insightId}
 *     → users/{userId}/insights/{insightId}.questionnaireAnalysis
 *     (userId for the questionnaire route comes from the batch_jobs doc
 *     itself, since unlike the other two, its custom_id only carries the
 *     insightId.)
 */
exports.pandaBatchPoller = onSchedule({
  schedule: "every 30 minutes",
  timeZone: "America/Los_Angeles",
  memory: "256MiB",
}, async () => {
  const db = admin.firestore();

  const pendingSnap = await db.collection("batch_jobs")
      .where("status", "==", "pending")
      .get();

  if (pendingSnap.empty) return;

  for (const jobDoc of pendingSnap.docs) {
    const batchId = jobDoc.id;

    let batch;
    try {
      batch = await client.messages.batches.retrieve(batchId);
    } catch (err) {
      console.error(`[pandaBatchPoller] retrieve ${batchId} failed:`, err);
      continue;
    }

    if (batch.processing_status !== "ended") {
      console.log(
          `[pandaBatchPoller] ${batchId} ` +
          `(${batch.processing_status}) — not ready yet.`,
      );
      continue;
    }

    let written = 0;
    const weekOf = new Date().toISOString().split("T")[0];
    const ts = () => admin.firestore.FieldValue.serverTimestamp();
    const jobData = jobDoc.data();

    // Dispatch table — prefix → Firestore write spec.
    // Adding a new batch type = one new entry here, nothing else to touch.
    const routes = [
      {
        prefix: "weekly-trend-",
        // rest = userId
        write: (rest, text) =>
          db.collection("users").doc(rest).collection("weekly_trends")
              .doc(weekOf)
              .set({content: text, generatedAt: ts(), weekOf}, {merge: true}),
      },
      {
        prefix: "insight-summary-",
        // rest = userId
        write: (rest, text) =>
          db.collection("users").doc(rest).collection("insight_summaries")
              .doc(weekOf)
              .set({content: text, generatedAt: ts(), weekOf}, {merge: true}),
      },
      {
        prefix: "questionnaire-",
        // rest = insightId; userId comes from the batch_jobs doc (the
        // custom_id alone doesn't carry it for this workload).
        write: (rest, text) =>
          db.collection("users").doc(jobData.userId)
              .collection("insights").doc(rest).update({
                questionnaireAnalysis: text,
                questionnaireAnalysisStatus: "completed",
                questionnaireAnalyzedAt: ts(),
              }),
      },
    ];

    try {
      for await (const result of
        await client.messages.batches.results(batchId)) {
        if (result.result.type !== "succeeded") {
          console.warn(
              `[pandaBatchPoller] ${result.custom_id} — ` +
              `result type: ${result.result.type}`,
          );
          continue;
        }

        const text = result.result.message.content?.[0]?.text ?? "";
        const route = routes.find((r) => result.custom_id.startsWith(r.prefix));
        if (!route) continue;
        await route.write(result.custom_id.slice(route.prefix.length), text);
        written++;
      }
    } catch (err) {
      console.error(
          `[pandaBatchPoller] results read failed for ${batchId}:`, err,
      );
      continue;
    }

    await jobDoc.ref.update({status: "completed", resultsWritten: written});
    console.log(
        `[pandaBatchPoller] ${batchId} done — ${written} results written.`,
    );
  }
});
