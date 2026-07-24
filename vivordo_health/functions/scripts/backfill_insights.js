/* eslint-disable */
// =============================================================================
// One-off backfill: stamp `stressorKey` + `frequency` on existing panda
// insights and collapse duplicates by canonical/fuzzy stressor match.
//
// Mirrors the Dart de-dup logic in lib/src/models/insights.dart
// (normalizeStressor / canonicalStressor / stressorsMatch) so the collapsed
// history matches how new insights will dedupe going forward.
//
// For each user (grouped from a collectionGroup query over `insights`):
//   • Cluster panda insights whose stressors match.
//   • Keep the most recent doc per cluster; set frequency = sum of the
//     cluster's frequencies; merge pandaLabeledAnswers + pandaCorrections;
//     stamp stressorKey. Delete the other docs in the cluster.
//   • Single-doc clusters are just stamped (idempotent).
//
// SAFETY: dry-run by default — prints the plan and writes nothing.
//         Pass --apply to actually write/delete.
//
// RUN (from the functions/ directory):
//   1. Authenticate Application Default Credentials, either:
//        gcloud auth application-default login
//      or set a service-account key:
//        export GOOGLE_APPLICATION_CREDENTIALS=/path/to/serviceAccount.json
//   2. Dry run:   node scripts/backfill_insights.js
//   3. Apply:     node scripts/backfill_insights.js --apply
// =============================================================================

const admin = require("firebase-admin");

admin.initializeApp({projectId: "vivordo-health"});
const db = admin.firestore();

const APPLY = process.argv.includes("--apply");

// ── Canonical stressor buckets — keep in sync with insights.dart ────────────
const CANON = {
  academia: [
    "academ", "school", "exam", "study", "studies", "class", "homework",
    "assignment", "test", "grade", "university", "college", "course",
    "thesis", "lecture", "tuition", "semester", "midterm", "final",
  ],
  work: [
    "work", "job", "deadline", "meeting", "boss", "project", "career",
    "office", "workload", "coworker", "colleague", "client", "shift",
    "manager", "promotion", "interview",
  ],
  financial: [
    "money", "financ", "bill", "rent", "debt", "budget", "salary", "loan",
    "expense", "afford",
  ],
  family: [
    "family", "parent", "mom", "dad", "mother", "father", "sibling",
    "brother", "sister", "child", "kid", "caregiv",
  ],
  relationship: [
    "partner", "relationship", "boyfriend", "girlfriend", "spouse", "wife",
    "husband", "marriage", "dating", "breakup", "divorce",
  ],
  social: [
    "social", "friend", "argument", "conflict", "people", "crowd", "party",
    "lonel", "isolation",
  ],
  health: [
    "health", "sick", "illness", "pain", "injury", "symptom", "doctor",
    "medical", "diagnos",
  ],
  sleep: ["sleep", "insomnia", "rest", "fatigue", "tired", "exhaust"],
};

function normalize(raw) {
  if (raw === null || raw === undefined) return null;
  const n = String(raw)
      .toLowerCase()
      .replace(/[^a-z0-9 ]/g, " ")
      .replace(/\s+/g, " ")
      .trim();
  return n.length ? n : null;
}

function canonical(raw) {
  const n = normalize(raw);
  if (!n) return null;
  for (const [bucket, kws] of Object.entries(CANON)) {
    for (const kw of kws) {
      if (n.includes(kw)) return bucket;
    }
  }
  return n;
}

function jaccard(a, b) {
  const sa = new Set(a.split(" ").filter(Boolean));
  const sb = new Set(b.split(" ").filter(Boolean));
  if (!sa.size || !sb.size) return 0;
  let inter = 0;
  for (const x of sa) if (sb.has(x)) inter++;
  const union = new Set([...sa, ...sb]).size;
  return inter / union;
}

function stressorsMatch(a, b) {
  const na = normalize(a);
  const nb = normalize(b);
  if (!na || !nb) return false;
  if (na === nb) return true;
  const ca = canonical(a);
  const cb = canonical(b);
  if (ca === cb && Object.prototype.hasOwnProperty.call(CANON, ca)) return true;
  if (na.includes(nb) || nb.includes(na)) return true;
  return jaccard(na, nb) >= 0.5;
}

const stressorOf = (d) =>
  (d.pandaSlots && d.pandaSlots.stressor) ?
    String(d.pandaSlots.stressor) :
    null;

const millis = (d) => {
  const sd = d.sessionDate;
  const cd = d.createdAt;
  if (sd && typeof sd.toMillis === "function") return sd.toMillis();
  if (cd && typeof cd.toMillis === "function") return cd.toMillis();
  return 0;
};

(async () => {
  const snap = await db.collectionGroup("insights").get();

  // Group docs by owning user (skip any root-level `insights` collection).
  const byUser = new Map();
  snap.forEach((doc) => {
    const data = doc.data();
    if ((data.source || "panda") !== "panda") return;
    const userRef = doc.ref.parent.parent; // users/{uid}
    if (!userRef) return;
    const uid = userRef.id;
    if (!byUser.has(uid)) byUser.set(uid, []);
    byUser.get(uid).push({ref: doc.ref, id: doc.id, data});
  });

  let usersTouched = 0;
  let clustersStamped = 0;
  let merges = 0;
  let docsDeleted = 0;

  for (const [uid, docs] of byUser) {
    const withStressor = docs.filter((x) => stressorOf(x.data));
    const noStressor = docs.filter((x) => !stressorOf(x.data));

    // Greedy clustering by stressorsMatch against each cluster's first member.
    const clusters = [];
    for (const x of withStressor) {
      const s = stressorOf(x.data);
      let c = clusters.find((cl) => stressorsMatch(stressorOf(cl[0].data), s));
      if (!c) clusters.push([x]);
      else c.push(x);
    }

    let userChanged = false;

    for (const cluster of clusters) {
      const members = [...cluster].sort((a, b) => millis(b.data) - millis(a.data));
      const keeper = members[0];
      const freq = members.reduce(
          (sum, m) => sum + (Number(m.data.frequency) || 1), 0);

      // Merge answers oldest→newest so newest wins on key conflicts.
      const answers = {};
      for (const m of [...members].sort((a, b) => millis(a.data) - millis(b.data))) {
        const a = m.data.pandaLabeledAnswers || {};
        for (const [k, v] of Object.entries(a)) answers[k] = String(v);
      }
      const corrections = [];
      for (const m of members) {
        if (Array.isArray(m.data.pandaCorrections)) {
          corrections.push(...m.data.pandaCorrections);
        }
      }

      const stressorKey = canonical(stressorOf(keeper.data));
      const update = {
        frequency: freq,
        stressorKey,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      };
      if (Object.keys(answers).length) update.pandaLabeledAnswers = answers;
      if (corrections.length) update.pandaCorrections = corrections;

      const toDelete = members.slice(1);
      console.log(
          `[${uid}] "${stressorKey}" — ${members.length} doc(s), freq=${freq}` +
          (toDelete.length ? `, delete ${toDelete.length} dup(s)` : ""));

      clustersStamped++;
      if (members.length > 1) merges++;
      docsDeleted += toDelete.length;

      if (APPLY) {
        const batch = db.batch();
        batch.set(keeper.ref, update, {merge: true});
        for (const m of toDelete) batch.delete(m.ref);
        await batch.commit();
      }
      userChanged = true;
    }

    // Stamp a default frequency on stressor-less docs (can't be deduped).
    for (const x of noStressor) {
      if (x.data.frequency === null || x.data.frequency === undefined) {
        console.log(`[${uid}] stamp frequency=1 on no-stressor doc ${x.id}`);
        clustersStamped++;
        if (APPLY) await x.ref.set({frequency: 1}, {merge: true});
        userChanged = true;
      }
    }

    if (userChanged) usersTouched++;
  }

  console.log(
      `\n${APPLY ? "APPLIED" : "DRY RUN"} — users:${usersTouched} ` +
      `stamped:${clustersStamped} merges:${merges} docsDeleted:${docsDeleted}`);
  console.log(APPLY ?
    "Done." :
    "Re-run with --apply to write these changes.");
  process.exit(0);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
