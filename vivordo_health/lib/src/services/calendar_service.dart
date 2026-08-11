import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;
import 'package:flutter/foundation.dart';

class CalendarService {
  static bool _initialized = false;
  static GoogleSignInAccount? _currentUser;

  static Future<void> initialize() async {
    if (_initialized) return;
    await GoogleSignIn.instance.initialize(
      clientId: '226030806435-d4nqtstrlhtm1cltipnat2bpo5eqn0mj.apps.googleusercontent.com',
    );
    GoogleSignIn.instance.authenticationEvents.listen((event) {
      switch (event) {
        case GoogleSignInAuthenticationEventSignIn():
          _currentUser = event.user;
        case GoogleSignInAuthenticationEventSignOut():
          _currentUser = null;
      }
    }).onError((e) => debugPrint('Auth error: $e'));
    _initialized = true;
  }

  static Future<List<gcal.Event>> getWeekEvents(DateTime weekStart) async {
    try {
      await initialize();

      if (_currentUser == null) {
        if (GoogleSignIn.instance.supportsAuthenticate()) {
          await GoogleSignIn.instance.authenticate();
        } else {
          return [];
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }

      final user = _currentUser;
      if (user == null) return [];

      const scopes = [gcal.CalendarApi.calendarReadonlyScope];

      var authorization = await user.authorizationClient
          .authorizationForScopes(scopes);
      authorization ??= await user.authorizationClient.authorizeScopes(scopes);

      if (authorization == null) return [];

      final client = authorization.authClient(scopes: scopes);
      final calendarApi = gcal.CalendarApi(client);
      final weekEnd = weekStart.add(const Duration(days: 7));

      final events = await calendarApi.events.list(
        'primary',
        timeMin: weekStart.toUtc(),
        timeMax: weekEnd.toUtc(),
        singleEvents: true,
        orderBy: 'startTime',
      );

      return events.items ?? [];
    } catch (e) {
      debugPrint('CalendarService error: $e');
      return [];
    }
  }

  static Future<bool> isSignedIn() async {
    return _currentUser != null;
  }

  static Future<void> signOut() async {
    await GoogleSignIn.instance.signOut();
    _currentUser = null;
  }
}