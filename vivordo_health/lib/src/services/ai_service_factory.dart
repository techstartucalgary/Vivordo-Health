import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'ai_service.dart';
import 'claude_service.dart';
import 'gemini_service.dart';

// =============================================================================
// AIServiceFactory
//
// Reads the `ai_provider` Remote Config key to choose the active backend.
//
//   "claude"  (default) → ClaudeService  (Anthropic via Cloud Function)
//   "gemini"            → GeminiService  (Firebase AI / Gemini)
//
// The instance is cached after the first call so subsequent PandaScreen
// navigations reuse the same object without another Remote Config fetch.
// =============================================================================

class AIServiceFactory {
  static AIService? _instance;

  /// Returns (and caches) the active AIService.
  /// Defaults to ClaudeService if Remote Config is unreachable.
  static Future<AIService> get() async {
    if (_instance != null) return _instance!;

    try {
      final rc = FirebaseRemoteConfig.instance;
      await rc.setConfigSettings(RemoteConfigSettings(
        fetchTimeout: const Duration(seconds: 10),
        minimumFetchInterval: const Duration(hours: 1),
      ));
      await rc.fetchAndActivate();
      final provider = rc.getString('ai_provider');
      _instance = (provider == 'gemini') ? GeminiService() : ClaudeService();
    } catch (_) {
      // Fallback: use Claude if Remote Config is unavailable.
      _instance = ClaudeService();
    }

    return _instance!;
  }
}
