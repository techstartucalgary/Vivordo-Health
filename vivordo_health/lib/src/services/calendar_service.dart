import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;
import 'package:flutter/foundation.dart';

class CalendarService {
  static bool _initialized = false;
  static Future<void>? _initializationFuture;
  static GoogleSignInAccount? _currentUser;
  static final ValueNotifier<bool> connectionNotifier = ValueNotifier<bool>(
    false,
  );
  static final Map<String, String> _eventCalendarIds = <String, String>{};

  static String? _calendarIdFor(gcal.Event event) =>
      event.id == null ? null : _eventCalendarIds[event.id!];

  /// Records the account returned directly by an interactive Google sign-in.
  /// This avoids waiting for the asynchronous authentication event before
  /// screens that depend on Google Calendar are built.
  static void registerSignedInAccount(GoogleSignInAccount account) {
    _currentUser = account;
  }

  /// Requests Calendar access for the currently authenticated Google account.
  /// Google identity sign-in and Calendar authorization are separate grants.
  static Future<bool> authorizeCalendarAccess() async {
    try {
      await initialize();
      var user = _currentUser;
      user ??= await GoogleSignIn.instance.attemptLightweightAuthentication();
      _currentUser = user;
      if (user == null) return false;

      const scopes = [gcal.CalendarApi.calendarScope];
      var authorization = await user.authorizationClient.authorizationForScopes(
        scopes,
      );
      authorization ??= await user.authorizationClient.authorizeScopes(scopes);
      connectionNotifier.value = true;
      return true;
    } catch (e) {
      debugPrint('Calendar authorization failed: $e');
      connectionNotifier.value = false;
      return false;
    }
  }

  static Future<gcal.CalendarApi> _authorizedCalendarApi() async {
    await initialize();
    var user = _currentUser;
    user ??= await GoogleSignIn.instance.attemptLightweightAuthentication();
    _currentUser = user;
    if (user == null) throw StateError('Google Calendar is not connected.');

    const scopes = [gcal.CalendarApi.calendarScope];
    var authorization = await user.authorizationClient.authorizationForScopes(
      scopes,
    );
    authorization ??= await user.authorizationClient.authorizeScopes(scopes);
    return gcal.CalendarApi(authorization.authClient(scopes: scopes));
  }

  static Future<void> deleteEvent(gcal.Event event) async {
    final calendarId = _calendarIdFor(event);
    final eventId = event.id;
    if (calendarId == null || eventId == null) {
      throw StateError(
        'This event cannot be removed because its calendar is unknown.',
      );
    }
    final calendarApi = await _authorizedCalendarApi();
    await calendarApi.events.delete(calendarId, eventId);
    _eventCalendarIds.remove(eventId);
  }

  static Future<gcal.Event> createEvent({
    required String title,
    required DateTime start,
    required DateTime end,
    required String recurrence,
  }) async {
    if (!end.isAfter(start)) {
      throw ArgumentError('The end time must be after the start time.');
    }

    final event = gcal.Event()
      ..summary = title
      ..start = (gcal.EventDateTime()..dateTime = start.toUtc())
      ..end = (gcal.EventDateTime()..dateTime = end.toUtc())
      ..recurrence = switch (recurrence) {
        'daily' => <String>['RRULE:FREQ=DAILY'],
        'weekly' => <String>['RRULE:FREQ=WEEKLY'],
        'monthly' => <String>['RRULE:FREQ=MONTHLY'],
        _ => <String>[],
      };

    final calendarApi = await _authorizedCalendarApi();
    final result = await calendarApi.events.insert(event, 'primary');
    if (result.id != null) _eventCalendarIds[result.id!] = 'primary';
    return result;
  }

  static Future<gcal.Event> updateEventTimeAndRecurrence(
    gcal.Event event, {
    required DateTime start,
    required DateTime end,
    required String recurrence,
  }) async {
    final calendarId = _calendarIdFor(event);
    final eventId = event.id;
    if (calendarId == null || eventId == null) {
      throw StateError(
        'This event cannot be edited because its calendar is unknown.',
      );
    }
    if (!end.isAfter(start)) {
      throw ArgumentError('The end time must be after the start time.');
    }

    final updated = gcal.Event()
      ..start = (gcal.EventDateTime()
        ..dateTime = start.toUtc()
        ..timeZone = event.start?.timeZone)
      ..end = (gcal.EventDateTime()
        ..dateTime = end.toUtc()
        ..timeZone = event.end?.timeZone)
      ..recurrence = switch (recurrence) {
        'daily' => <String>['RRULE:FREQ=DAILY'],
        'weekly' => <String>['RRULE:FREQ=WEEKLY'],
        'monthly' => <String>['RRULE:FREQ=MONTHLY'],
        _ => <String>[],
      };

    final calendarApi = await _authorizedCalendarApi();
    final result = await calendarApi.events.patch(updated, calendarId, eventId);
    if (result.id != null) _eventCalendarIds[result.id!] = calendarId;
    return result;
  }

  /// Updates the fields Panda is allowed to propose. Null fields are preserved.
  static Future<gcal.Event> updateEvent(
    gcal.Event event, {
    String? title,
    DateTime? start,
    DateTime? end,
    String? recurrence,
  }) async {
    final calendarId = _calendarIdFor(event);
    final eventId = event.id;
    if (calendarId == null || eventId == null) {
      throw StateError(
        'This event cannot be edited because its calendar is unknown.',
      );
    }
    final originalStart = event.start?.dateTime?.toLocal();
    final originalEnd = event.end?.dateTime?.toLocal();
    final nextStart = start ?? originalStart;
    final nextEnd = end ?? originalEnd;
    if (nextStart == null || nextEnd == null || !nextEnd.isAfter(nextStart)) {
      throw ArgumentError('The event must have a valid start and end time.');
    }
    final updated = gcal.Event()
      ..summary = title?.trim().isNotEmpty == true ? title!.trim() : null
      ..start = (gcal.EventDateTime()..dateTime = nextStart.toUtc())
      ..end = (gcal.EventDateTime()..dateTime = nextEnd.toUtc());
    if (recurrence != null) {
      updated.recurrence = switch (recurrence) {
        'daily' => <String>['RRULE:FREQ=DAILY'],
        'weekly' => <String>['RRULE:FREQ=WEEKLY'],
        'monthly' => <String>['RRULE:FREQ=MONTHLY'],
        _ => <String>[],
      };
    }
    final api = await _authorizedCalendarApi();
    final result = await api.events.patch(updated, calendarId, eventId);
    if (result.id != null) _eventCalendarIds[result.id!] = calendarId;
    return result;
  }

  static Future<void> initialize() async {
    if (_initialized) return;
    if (_initializationFuture != null) return _initializationFuture!;

    _initializationFuture = _initialize();
    try {
      await _initializationFuture;
    } finally {
      _initializationFuture = null;
    }
  }

  static Future<void> _initialize() async {
    // GoogleSignIn.instance is a singleton — this is the one place it gets
    // initialized for the whole app (AuthService.signInWithGoogle reuses it
    // via this same initialize() call rather than calling initialize() a
    // second time, which google_sign_in doesn't support).
    // serverClientId (the Android/web OAuth client, not the iOS one above)
    // is what makes GoogleSignInAccount.authentication.idToken come back
    // non-null — without it, Firebase's GoogleAuthProvider.credential(idToken:)
    // sign-in has nothing to authenticate with, especially on Android.
    await GoogleSignIn.instance.initialize(
      clientId:
          '226030806435-d4nqtstrlhtm1cltipnat2bpo5eqn0mj.apps.googleusercontent.com',
      serverClientId:
          '226030806435-51d18dlptiokmfejr5irqmjefq8han4g.apps.googleusercontent.com',
    );
    GoogleSignIn.instance.authenticationEvents
        .listen((event) {
          switch (event) {
            case GoogleSignInAuthenticationEventSignIn():
              _currentUser = event.user;
            case GoogleSignInAuthenticationEventSignOut():
              _currentUser = null;
              connectionNotifier.value = false;
          }
        })
        .onError((e) => debugPrint('Auth error: $e'));

    try {
      _currentUser = await GoogleSignIn.instance
          .attemptLightweightAuthentication();
    } catch (e) {
      debugPrint('Silent Google sign-in failed: $e');
    }

    _initialized = true;
  }

  static Future<List<gcal.Event>> getWeekEvents(DateTime weekStart) =>
      getEventsBetween(weekStart, weekStart.add(const Duration(days: 7)));

  /// Returns the user's visible Google Calendar events between [start] and [end]
  /// (expanded recurrences, ordered by start time). Returns [] when the user
  /// hasn't connected Google Calendar or on any auth/network error.
  static Future<List<gcal.Event>> getEventsBetween(
    DateTime start,
    DateTime end,
  ) async {
    try {
      await initialize();

      var user = _currentUser;
      user ??= await GoogleSignIn.instance.attemptLightweightAuthentication();
      _currentUser = user;
      if (user == null) return [];

      const scopes = [gcal.CalendarApi.calendarScope];

      final authorization = await user.authorizationClient
          .authorizationForScopes(scopes);

      if (authorization == null) {
        connectionNotifier.value = false;
        return [];
      }

      final client = authorization.authClient(scopes: scopes);
      final calendarApi = gcal.CalendarApi(client);

      final events = await _fetchEventsFromCalendars(
        calendarApi,
        start: start,
        end: end,
      );

      connectionNotifier.value = true;
      return events;
    } catch (e) {
      debugPrint('CalendarService error: $e');
      return [];
    }
  }

  static Future<List<gcal.Event>> connectAndGetWeekEvents(
    DateTime weekStart,
  ) async {
    try {
      await initialize();

      if (_currentUser == null) {
        if (GoogleSignIn.instance.supportsAuthenticate()) {
          _currentUser = await GoogleSignIn.instance.authenticate();
        } else {
          return [];
        }
      }

      final user = _currentUser;
      if (user == null) return [];

      const scopes = [gcal.CalendarApi.calendarScope];

      var authorization = await user.authorizationClient.authorizationForScopes(
        scopes,
      );
      authorization ??= await user.authorizationClient.authorizeScopes(scopes);

      final client = authorization.authClient(scopes: scopes);
      final calendarApi = gcal.CalendarApi(client);
      final weekEnd = weekStart.add(const Duration(days: 7));

      final events = await _fetchEventsFromCalendars(
        calendarApi,
        start: weekStart,
        end: weekEnd,
      );

      connectionNotifier.value = true;
      return events;
    } catch (e) {
      debugPrint('CalendarService connect error: $e');
      return [];
    }
  }

  static Future<bool> isSignedIn() async {
    await initialize();
    _currentUser ??= await GoogleSignIn.instance
        .attemptLightweightAuthentication();
    return _currentUser != null;
  }

  static Future<bool> hasCalendarAccess() async {
    try {
      await initialize();

      var user = _currentUser;
      user ??= await GoogleSignIn.instance.attemptLightweightAuthentication();
      _currentUser = user;
      if (user == null) {
        connectionNotifier.value = false;
        return false;
      }

      const scopes = [gcal.CalendarApi.calendarScope];
      final authorization = await user.authorizationClient
          .authorizationForScopes(scopes);
      final hasAccess = authorization != null;
      connectionNotifier.value = hasAccess;
      return hasAccess;
    } catch (e) {
      debugPrint('CalendarService access check error: $e');
      connectionNotifier.value = false;
      return false;
    }
  }

  static Future<void> signOut() async {
    await initialize();
    await GoogleSignIn.instance.disconnect();
    _currentUser = null;
    connectionNotifier.value = false;
  }

  static Future<List<gcal.Event>> _fetchEventsFromCalendars(
    gcal.CalendarApi calendarApi, {
    required DateTime start,
    required DateTime end,
  }) async {
    final calendarList = await calendarApi.calendarList.list();
    final calendars = (calendarList.items ?? const <gcal.CalendarListEntry>[])
        .where((calendar) => calendar.id != null)
        .where((calendar) => calendar.hidden != true)
        // Google omits `selected` when a calendar is not selected. Requiring an
        // explicit true keeps Vivordo aligned with the calendars visible in the
        // user's Google Calendar sidebar instead of treating null as selected.
        .where((calendar) => calendar.selected == true)
        .toList();

    if (calendars.isEmpty) {
      return [];
    }

    final eventLists = await Future.wait(
      calendars.map((calendar) async {
        try {
          final events = await calendarApi.events.list(
            calendar.id!,
            timeMin: start.toUtc(),
            timeMax: end.toUtc(),
            singleEvents: true,
            orderBy: 'startTime',
          );
          final items = events.items ?? const <gcal.Event>[];
          for (final event in items) {
            if (event.id != null) _eventCalendarIds[event.id!] = calendar.id!;
          }
          return items;
        } catch (e) {
          debugPrint(
            'CalendarService calendar fetch skipped ${calendar.summary ?? calendar.id}: $e',
          );
          return const <gcal.Event>[];
        }
      }),
    );

    final events = eventLists.expand((items) => items).toList();
    events.sort((a, b) {
      final aStart = a.start?.dateTime ?? a.start?.date;
      final bStart = b.start?.dateTime ?? b.start?.date;

      if (aStart == null && bStart == null) return 0;
      if (aStart == null) return 1;
      if (bStart == null) return -1;
      return aStart.compareTo(bStart);
    });

    return events;
  }
}
