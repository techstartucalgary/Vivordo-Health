import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

class FitbitAccountNotLinkedException implements Exception {
  const FitbitAccountNotLinkedException(this.setupUrl);

  final Uri setupUrl;
}

/// Fitbit account integration for iOS through the Google Health API.
///
/// OAuth tokens and the authorization code stay on Firebase Functions. The
/// app opens Google's consent page and receives only a success callback.
class FitbitService {
  FitbitService._();

  static final FitbitService instance = FitbitService._();

  static const String _callbackScheme = 'vivordo-fitbit';
  final FirebaseFunctions _functions = FirebaseFunctions.instance;
  bool? _connectedCache;
  Future<void>? _activeSync;

  Future<void> connect() async {
    final connection = await _functions
        .httpsCallable('beginFitbitConnection')
        .call<Map<String, dynamic>>();
    final authorizationUrl = connection.data['authorizationUrl'] as String?;
    if (authorizationUrl == null || authorizationUrl.isEmpty) {
      throw StateError('Google Health has not been configured for this build.');
    }

    final callback = await FlutterWebAuth2.authenticate(
      url: authorizationUrl,
      callbackUrlScheme: _callbackScheme,
    );
    final callbackUri = Uri.parse(callback);
    final error = callbackUri.queryParameters['error'];
    if (error != null) {
      throw StateError(
        callbackUri.queryParameters['error_description'] ??
            'Google Health authorization was cancelled.',
      );
    }
    if (callbackUri.queryParameters['status'] != 'success') {
      throw StateError('Google Health did not complete authorization.');
    }

    _connectedCache = true;
    await sync(daysBack: 30);
  }

  Future<void> sync({int daysBack = 30}) {
    final activeSync = _activeSync;
    if (activeSync != null) return activeSync;

    final boundedDays = daysBack.clamp(1, 30);
    final request = _functions
        .httpsCallable('syncFitbit')
        .call<void>({'daysBack': boundedDays})
        .then((_) {})
        .onError<FirebaseFunctionsException>((error, stackTrace) {
          final details = error.details;
          if (details is Map && details['reason'] == 'ACCOUNT_NOT_LINKED') {
            final rawUrl = details['setupUrl'] as String?;
            throw FitbitAccountNotLinkedException(
              Uri.parse(rawUrl ?? 'https://fitbit.google.com/auth/signup'),
            );
          }
          throw error;
        });
    _activeSync = request;
    return request.whenComplete(() {
      if (identical(_activeSync, request)) _activeSync = null;
    });
  }

  Future<void> disconnect() async {
    await _functions.httpsCallable('disconnectFitbit').call<void>();
    _connectedCache = false;
  }

  void syncInBackground({int daysBack = 1}) {
    _syncIfConnected(daysBack: daysBack).catchError((Object error) {
      debugPrint('[FitbitService] Background sync skipped: $error');
    });
  }

  Future<void> _syncIfConnected({required int daysBack}) async {
    var connected = _connectedCache;
    if (connected == null) {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final user = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      connected = user.data()?['fitbitConnected'] == true;
      _connectedCache = connected;
    }
    if (connected) await sync(daysBack: daysBack);
  }
}
