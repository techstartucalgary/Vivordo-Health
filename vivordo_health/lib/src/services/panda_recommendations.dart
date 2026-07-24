// =============================================================================
// panda_recommendations.dart
//
// Loads the Panda recommendation catalog from assets/recommendations.json.
//
// ┌─────────────────────────────────────────────────────────────────────────┐
// │  TO ADD, EDIT, OR REMOVE RECOMMENDATIONS:                               │
// │  Edit  assets/recommendations.json  — no Dart changes needed.           │
// │  The JSON is hot-reloadable in debug and ships with the app bundle.     │
// └─────────────────────────────────────────────────────────────────────────┘
//
// HOW TAGS WORK:
//   Tags are matched (case-insensitive substring) against:
//     • session slot values  (stressor, emotion, intensity, activity…)
//     • user journal mood / keyword
//     • user goals
//   More matching tags → higher score → surfaces higher in the result list.
//
// ASSET PATH:
//   assets/recommendations.json
//   Make sure it is declared in pubspec.yaml:
//     flutter:
//       assets:
//         - assets/recommendations.json
// =============================================================================

import 'dart:convert';
import 'package:flutter/services.dart';

// ---------------------------------------------------------------------------
// Category enum — must match the "category" strings in the JSON.
// ---------------------------------------------------------------------------

enum RecCategory {
  music,
  breathing,
  movement,
  sleep,
  focus,
  social,
  nutrition,
  journal,
}

RecCategory _parseCategory(String s) {
  switch (s.toLowerCase()) {
    case 'music':     return RecCategory.music;
    case 'breathing': return RecCategory.breathing;
    case 'movement':  return RecCategory.movement;
    case 'sleep':     return RecCategory.sleep;
    case 'focus':     return RecCategory.focus;
    case 'social':    return RecCategory.social;
    case 'nutrition': return RecCategory.nutrition;
    case 'journal':   return RecCategory.journal;
    default:          return RecCategory.focus; // safe fallback
  }
}

// ---------------------------------------------------------------------------
// PandaRec — immutable data model for a single recommendation.
// ---------------------------------------------------------------------------

class PandaRec {
  const PandaRec({
    required this.id,
    required this.category,
    required this.title,
    required this.subtitle,
    required this.tags,
    required this.emoji,
    this.deepLink,
    this.durationLabel,
    this.intensity,
  });

  final String id;
  final RecCategory category;
  final String title;
  final String subtitle;

  /// Keywords matched against session slots, journal, and goals.
  /// More matches = higher priority in recommendations.
  final List<String> tags;

  final String emoji;
  final String? deepLink;
  final String? durationLabel;

  /// null | "low" | "medium" | "high"
  final String? intensity;

  factory PandaRec.fromJson(Map<String, dynamic> j) {
    return PandaRec(
      id: j['id'] as String,
      category: _parseCategory(j['category'] as String? ?? ''),
      title: j['title'] as String? ?? '',
      subtitle: j['subtitle'] as String? ?? '',
      emoji: j['emoji'] as String? ?? '✨',
      tags: (j['tags'] as List? ?? []).map((t) => t.toString()).toList(),
      deepLink: j['deepLink'] as String?,
      durationLabel: j['durationLabel'] as String?,
      intensity: j['intensity'] as String?,
    );
  }

  /// Returns a copy with optionally overridden fields.
  PandaRec copyWith({
    String? title,
    String? subtitle,
    String? emoji,
    List<String>? tags,
    String? deepLink,
    String? durationLabel,
    String? intensity,
  }) {
    return PandaRec(
      id: id,
      category: category,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      emoji: emoji ?? this.emoji,
      tags: tags ?? this.tags,
      deepLink: deepLink ?? this.deepLink,
      durationLabel: durationLabel ?? this.durationLabel,
      intensity: intensity ?? this.intensity,
    );
  }
}

// ---------------------------------------------------------------------------
// PandaRecommendations — async loader with in-memory cache.
// ---------------------------------------------------------------------------

class PandaRecommendations {
  PandaRecommendations._();

  static List<PandaRec>? _cache;

  // ── Async loader ────────────────────────────────────────────────────────────

  /// Loads and parses the catalog from assets/recommendations.json.
  /// Result is cached for the app lifetime — subsequent calls are instant.
  ///
  /// Call once during app init (e.g. in GeminiService or PandaScreen.initState)
  /// and then access [all] synchronously thereafter.
  static Future<List<PandaRec>> load() async {
    if (_cache != null) return _cache!;

    try {
      final raw = await rootBundle.loadString('assets/recommendations.json');

      // Strip single-line // comments before parsing (JSON5-ish)
      final stripped = raw.replaceAll(RegExp(r'//[^\n]*'), '');
      final decoded = jsonDecode(stripped) as Map<String, dynamic>;
      final items = decoded['recommendations'] as List? ?? [];

      _cache = items
          .whereType<Map<String, dynamic>>()
          .map(PandaRec.fromJson)
          .toList();
    } catch (e) {
      // Fallback to empty list — engine will use fallback recs
      // ignore: avoid_print
      print('[PandaRecommendations] Failed to load asset: $e');
      _cache = [];
    }

    return _cache!;
  }

  // ── Synchronous accessor ────────────────────────────────────────────────────

  /// Returns the cached catalog. Returns empty list if [load()] hasn't
  /// completed yet — call [load()] during app init to avoid this.
  static List<PandaRec> get all => _cache ?? [];

  /// Force-reload the catalog (useful in tests or after a remote update).
  static Future<List<PandaRec>> reload() {
    _cache = null;
    return load();
  }

  // ── Convenience accessors ───────────────────────────────────────────────────

  static List<PandaRec> byCategory(RecCategory cat) =>
      all.where((r) => r.category == cat).toList();

  static PandaRec? byId(String id) =>
      all.where((r) => r.id == id).firstOrNull;
}