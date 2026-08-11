import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:vivordo_health/main.dart' show navigatorKey;
import 'dart:io';

/// Function to handle background messages
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  print('Handling background message: ${message.messageId}');
}

/// Notification Service - Singleton pattern for managing FCM notifications
/// Handles iOS push notifications using Firebase Cloud Messaging
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();

  factory NotificationService() {
    return _instance;
  }

  NotificationService._internal();

  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  bool _isInitialized = false;

  /// Initialize the notification service
  /// Should be called once in main() after Firebase.initializeApp()
  Future<void> initialize() async {
    if (_isInitialized) return;

    if (kIsWeb) {
      print('NotificationService: Web platform detected, skipping initialization');
      _isInitialized = true;
      return;
    }

    try {
      // Request IOS permissions
      if (Platform.isIOS) {
        NotificationSettings settings = await _firebaseMessaging.requestPermission(
          alert: true,
          badge: true,
          sound: true,
          provisional: false,
        );

        print('NotificationService: Permission status: ${settings.authorizationStatus}');

        if (settings.authorizationStatus == AuthorizationStatus.authorized) {
          print('NotificationService: User granted permission');
        } else if (settings.authorizationStatus == AuthorizationStatus.provisional) {
          print('NotificationService: User granted provisional permission');
        } else {
          print('NotificationService: User declined or has not accepted permission');
        }
      }

      // Initialize Local Notifications Plugin
      const DarwinInitializationSettings initializationSettingsIOS =
          DarwinInitializationSettings(
        requestSoundPermission: true,
        requestBadgePermission: true,
        requestAlertPermission: true,
      );

      const InitializationSettings initializationSettings = InitializationSettings(
        iOS: initializationSettingsIOS,
      );

      await _localNotificationsPlugin.initialize(
        initializationSettings,
        onDidReceiveNotificationResponse: _onNotificationTapped,
      );

      // Get and log FCM token
      try {
        String? token = await _firebaseMessaging.getToken();
        print('NotificationService: FCM Token: $token');

        // Listen for token refresh
        _firebaseMessaging.onTokenRefresh.listen((newToken) {
          print('NotificationService: FCM Token refreshed: $newToken');
        });
      } catch (e) {
        print('NotificationService: Warning - Could not get FCM token (normal on simulator): $e');
      }

      // Handle foreground messages
      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

      // Handle background messages
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

      // Handle notification tap when app is in background but not terminated
      FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

      // Check if app was opened from a terminated state by tapping notification
      RemoteMessage? initialMessage = await _firebaseMessaging.getInitialMessage();
      if (initialMessage != null) {
        _handleNotificationTap(initialMessage);
      }

      _isInitialized = true;
      print('NotificationService: Initialization complete');
    } catch (e) {
      print('NotificationService: Error during initialization: $e');
    }
  }

  /// Handle foreground messages by showing local notification
  void _handleForegroundMessage(RemoteMessage message) {
    print('NotificationService: Foreground message received: ${message.messageId}');

    if (message.notification != null) {
      showLocalNotification(
        title: message.notification?.title ?? 'New Notification',
        body: message.notification?.body ?? '',
        payload: message.data.toString(),
      );
    }
  }

  /// Handle notification tap
  void _handleNotificationTap(RemoteMessage message) {
    print('NotificationService: Notification tapped, data: ${message.data}');
    
    // Use navigatorKey to navigate even from background or context-less states
    final context = navigatorKey.currentContext;
    if (context != null) {
      if (message.data['screen'] == 'home' || message.data['screen'] == 'goals') {
        Navigator.of(context).pushNamedAndRemoveUntil('/home', (route) => false);
      }
    }
  }

  /// Handle local notification tap
  void _onNotificationTapped(NotificationResponse response) {
    print('NotificationService: Local notification tapped, payload: ${response.payload}');
    
    // Parse payload if it's JSON
    final context = navigatorKey.currentContext;
    if (context != null) {
      Navigator.of(context).pushNamedAndRemoveUntil('/home', (route) => false);
    }
  }

  /// Show a local notification for testing purposes
  Future<void> showTestNotification() async {
    await showLocalNotification(
      title: 'Test Notification',
      body: 'This is a test notification from Vivordo Health',
      payload: '{"screen": "home"}',
    );
  }

  /// Show a notification when a new goal is created
  Future<void> showGoalCreatedNotification(String goalTitle) async {
    await showLocalNotification(
      title: 'Goal Created! 🎯',
      body: 'Successfully added: "$goalTitle". Let\'s get to work!',
      payload: '{"screen": "goals"}',
    );
  }

  /// Show a local notification
  /// Used to display notifications when app is in foreground
  Future<void> showLocalNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    if (kIsWeb) {
      print('NotificationService: Cannot show local notification on web');
      return;
    }

    const DarwinNotificationDetails iOSPlatformChannelSpecifics =
        DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      presentBanner: true,
      presentList: true,
    );

    const NotificationDetails platformChannelSpecifics = NotificationDetails(
      iOS: iOSPlatformChannelSpecifics,
    );

    await _localNotificationsPlugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000, 
      title,
      body,
      platformChannelSpecifics,
      payload: payload,
    );

    print('NotificationService: Local notification shown - $title');
  }

  /// Get the current FCM token
  Future<String?> getToken() async {
    if (kIsWeb) return null;
    return await _firebaseMessaging.getToken();
  }

  /// Subscribe to a topic
  Future<void> subscribeToTopic(String topic) async {
    if (kIsWeb) return;
    await _firebaseMessaging.subscribeToTopic(topic);
    print('NotificationService: Subscribed to topic: $topic');
  }

  /// Unsubscribe from a topic
  Future<void> unsubscribeFromTopic(String topic) async {
    if (kIsWeb) return;
    await _firebaseMessaging.unsubscribeFromTopic(topic);
    print('NotificationService: Unsubscribed from topic: $topic');
  }
}
