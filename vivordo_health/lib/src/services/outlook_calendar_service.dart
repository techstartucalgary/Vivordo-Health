import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:msal_auth/msal_auth.dart';
import 'package:http/http.dart' as http;

class OutlookEvent {
  const OutlookEvent({
    required this.id,
    required this.subject,
    required this.start,
    required this.end,
    this.location,
    this.isAllDay = false,
  });

  final String id;
  final String subject;
  final DateTime start;
  final DateTime end;
  final String? location;
  final bool isAllDay;
}

class OutlookCalendarService {
  static const String clientId = '07c05b6e-07ad-4ed3-bfd2-35af418decdf';
  static const String authority = 'https://login.microsoftonline.com/common';

  static const List<String> scopes = [
    'https://graph.microsoft.com/User.Read',
    'https://graph.microsoft.com/Calendars.Read',
  ];

  static const String _graphHost = 'graph.microsoft.com';

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  static const String _accessTokenKey = 'outlook_access_token';
  static const String _accessTokenExpiryKey = 'outlook_access_token_expiry';
  static const String _outlookSignedInKey = 'outlook_signed_in';

  static SingleAccountPca? _pca;

  static Future<SingleAccountPca> _getPca() async {
    if (_pca != null) return _pca!;

    debugPrint('Outlook MSAL: creating SingleAccountPca');
    _pca = await SingleAccountPca.create(
      clientId: clientId,
      appleConfig: AppleConfig(
        authority: authority,
        authorityType: AuthorityType.aad,
        broker: Broker.safariBrowser,
      ),
    );
    debugPrint('Outlook MSAL: SingleAccountPca created');

    return _pca!;
  }

  static Future<List<OutlookEvent>> getWeekEvents(DateTime weekStart) {
    return getEventsBetween(weekStart, weekStart.add(const Duration(days: 7)));
  }

  static Future<List<OutlookEvent>> getEventsBetween(
    DateTime start,
    DateTime end,
  ) async {
    try {
      final savedToken = await _getSavedAccessToken();
      if (savedToken != null) {
        debugPrint('Outlook MSAL: using saved access token');
        return _fetchEvents(savedToken, start, end);
      }

      debugPrint('Outlook MSAL: getting token for Graph events');
      final pca = await _getPca();
      final result = await pca.acquireTokenSilent(
        scopes: scopes,
        authority: authority,
      );

      final accessToken = result.accessToken;
      if (accessToken.isEmpty) {
        debugPrint('Outlook MSAL: silent token was empty');
        return [];
      }

      await _saveAuthResult(result);
      return _fetchEvents(accessToken, start, end);
    } on MsalException catch (e) {
      debugPrint('Outlook MSAL silent token error: $e');
      return [];
    } catch (e, stackTrace) {
      debugPrint('Outlook getEventsBetween error: $e');
      debugPrint('$stackTrace');
      return [];
    }
  }

  static Future<List<OutlookEvent>> connectAndGetWeekEvents(
    DateTime weekStart,
  ) async {
    try {
      debugPrint('Outlook MSAL: connecting and fetching week events');
      final pca = await _getPca();
      final result = await pca.acquireToken(
        scopes: scopes,
        prompt: Prompt.selectAccount,
        authority: authority,
      );

      final accessToken = result.accessToken;
      if (accessToken.isEmpty) {
        debugPrint('Outlook MSAL: interactive token was empty');
        return [];
      }

      await _saveAuthResult(result);

      return _fetchEvents(
        accessToken,
        weekStart,
        weekStart.add(const Duration(days: 7)),
      );
    } on MsalException catch (e) {
      debugPrint('Outlook MSAL connect events error: $e');
      return [];
    } catch (e, stackTrace) {
      debugPrint('Outlook connectAndGetWeekEvents error: $e');
      debugPrint('$stackTrace');
      return [];
    }
  }

  static Future<String?> _getSavedAccessToken() async {
    final token = await _secureStorage.read(key: _accessTokenKey);
    final expiryText = await _secureStorage.read(key: _accessTokenExpiryKey);

    if (token == null || token.isEmpty || expiryText == null) return null;

    final expiry = DateTime.tryParse(expiryText);
    if (expiry == null) return null;

    final stillValid = DateTime.now().toUtc().isBefore(
      expiry.toUtc().subtract(const Duration(minutes: 5)),
    );

    return stillValid ? token : null;
  }

  static Future<void> _saveAuthResult(dynamic result) async {
    final accessToken = result.accessToken as String?;
    if (accessToken == null || accessToken.isEmpty) return;

    final dynamic rawExpiry = result.expiresOn;
    final DateTime expiry = rawExpiry is DateTime
        ? rawExpiry
        : DateTime.now().toUtc().add(const Duration(minutes: 50));

    await _secureStorage.write(key: _accessTokenKey, value: accessToken);
    await _secureStorage.write(
      key: _accessTokenExpiryKey,
      value: expiry.toUtc().toIso8601String(),
    );
    await _secureStorage.write(key: _outlookSignedInKey, value: 'true');
  }

  static Future<bool> isSignedIn() async {
    final signedIn = await _secureStorage.read(key: _outlookSignedInKey);
    return signedIn == 'true' && await _getSavedAccessToken() != null;
  }

  static Future<void> signOut() async {
    try {
      final pca = await _getPca();
      await pca.signOut();
    } catch (e) {
      debugPrint('Outlook sign out error: $e');
    }

    await _secureStorage.delete(key: _accessTokenKey);
    await _secureStorage.delete(key: _accessTokenExpiryKey);
    await _secureStorage.delete(key: _outlookSignedInKey);
  }

  static Future<List<OutlookEvent>> _fetchEvents(
    String accessToken,
    DateTime start,
    DateTime end,
  ) async {
    final uri = Uri.https(
      _graphHost,
      '/v1.0/me/calendarView',
      {
        'startDateTime': start.toUtc().toIso8601String(),
        'endDateTime': end.toUtc().toIso8601String(),
        r'$orderby': 'start/dateTime',
        r'$top': '100',
      },
    );

    debugPrint('Outlook Graph request: $uri');

    final response = await http.get(
      uri,
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Accept': 'application/json',
        'Prefer': 'outlook.timezone="UTC"',
      },
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      debugPrint('Outlook Graph error: ${response.statusCode} ${response.body}');
      return [];
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final values = decoded['value'] as List<dynamic>? ?? [];
    debugPrint('Outlook Graph returned ${values.length} raw events');

    final events = values
        .map((item) => _parseEvent(item as Map<String, dynamic>))
        .whereType<OutlookEvent>()
        .toList();

    debugPrint('Outlook parsed ${events.length} events');
    for (final event in events.take(5)) {
      debugPrint(
        'Outlook event: ${event.subject} | ${event.start.toIso8601String()} - ${event.end.toIso8601String()}',
      );
    }

    return events;
  }

  static OutlookEvent? _parseEvent(Map<String, dynamic> json) {
    try {
      final startJson = json['start'] as Map<String, dynamic>?;
      final endJson = json['end'] as Map<String, dynamic>?;
      final locationJson = json['location'] as Map<String, dynamic>?;

      final startText = startJson?['dateTime'] as String?;
      final endText = endJson?['dateTime'] as String?;

      if (startText == null || endText == null) return null;

      return OutlookEvent(
        id: json['id'] as String? ?? '',
        subject: json['subject'] as String? ?? 'Untitled Event',
        start: DateTime.parse(startText).toLocal(),
        end: DateTime.parse(endText).toLocal(),
        location: locationJson?['displayName'] as String?,
        isAllDay: json['isAllDay'] as bool? ?? false,
      );
    } catch (e) {
      debugPrint('Outlook event parse error: $e');
      return null;
    }
  }

  static Future<void> testLogin() async {
    try {
      debugPrint('Outlook MSAL: starting');
      final pca = await _getPca();

      debugPrint('Outlook MSAL: acquiring token');
      final result = await pca.acquireToken(
        scopes: scopes,
        prompt: Prompt.selectAccount,
        authority: authority,
      );

      debugPrint('Outlook MSAL: auth completed');
      debugPrint('Access token present: ${result.accessToken.isNotEmpty}');
      debugPrint('Account username: ${result.account.username}');
      debugPrint('Expires on: ${result.expiresOn}');
      await _saveAuthResult(result);
      final now = DateTime.now();
      final events = await _fetchEvents(
        result.accessToken,
        now,
        now.add(const Duration(days: 7)),
      );
      debugPrint('Outlook MSAL: test fetched ${events.length} events');
    } on MsalException catch (e, stackTrace) {
      debugPrint('Outlook MSAL error: $e');
      debugPrint('$stackTrace');
    } catch (e, stackTrace) {
      debugPrint('Outlook unexpected error: $e');
      debugPrint('$stackTrace');
    }
  }
}