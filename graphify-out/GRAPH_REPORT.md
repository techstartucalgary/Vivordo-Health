# Graph Report - .  (2026-06-21)

## Corpus Check
- 50 files · ~61,144 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 1302 nodes · 1530 edges · 51 communities (46 shown, 5 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Panda Chat Screen|Panda Chat Screen]]
- [[_COMMUNITY_Stress Spike Test Page|Stress Spike Test Page]]
- [[_COMMUNITY_Home Screen|Home Screen]]
- [[_COMMUNITY_Scan Screen (PPG Camera)|Scan Screen (PPG Camera)]]
- [[_COMMUNITY_Insight & Gemini Services|Insight & Gemini Services]]
- [[_COMMUNITY_Insights Model|Insights Model]]
- [[_COMMUNITY_Dashboard & Profile Charts|Dashboard & Profile Charts]]
- [[_COMMUNITY_Goal Model|Goal Model]]
- [[_COMMUNITY_Panda Recommendations|Panda Recommendations]]
- [[_COMMUNITY_PPG Heart-Rate Algorithm|PPG Heart-Rate Algorithm]]
- [[_COMMUNITY_Demo Pages & Charts|Demo Pages & Charts]]
- [[_COMMUNITY_AI Service Factory|AI Service Factory]]
- [[_COMMUNITY_Health Service|Health Service]]
- [[_COMMUNITY_Signup & Questionnaire|Signup & Questionnaire]]
- [[_COMMUNITY_Recommendation Engine|Recommendation Engine]]
- [[_COMMUNITY_Goals Scan Screen|Goals Scan Screen]]
- [[_COMMUNITY_Demo User Data|Demo User Data]]
- [[_COMMUNITY_ProfileLogin Settings|Profile/Login Settings]]
- [[_COMMUNITY_Demo User Generator|Demo User Generator]]
- [[_COMMUNITY_App Main Entry|App Main Entry]]
- [[_COMMUNITY_Notification Service|Notification Service]]
- [[_COMMUNITY_Onboarding Screen|Onboarding Screen]]
- [[_COMMUNITY_User Model|User Model]]
- [[_COMMUNITY_Insight Service|Insight Service]]
- [[_COMMUNITY_Functions Package Manifest|Functions Package Manifest]]
- [[_COMMUNITY_Login & Main Nav|Login & Main Nav]]
- [[_COMMUNITY_Metrics Daily Model|Metrics Daily Model]]
- [[_COMMUNITY_Panda Session Types|Panda Session Types]]
- [[_COMMUNITY_Welcome Beta Screen|Welcome Beta Screen]]
- [[_COMMUNITY_Main Navigation Bar|Main Navigation Bar]]
- [[_COMMUNITY_User Service|User Service]]
- [[_COMMUNITY_AI Service Core|AI Service Core]]
- [[_COMMUNITY_Calendar Service|Calendar Service]]
- [[_COMMUNITY_Preferences Model|Preferences Model]]
- [[_COMMUNITY_Backfill Insights Script|Backfill Insights Script]]
- [[_COMMUNITY_Goal UI Model|Goal UI Model]]
- [[_COMMUNITY_Misc Widgets|Misc Widgets]]
- [[_COMMUNITY_Metadata Model|Metadata Model]]
- [[_COMMUNITY_Cloud Functions Entry|Cloud Functions Entry]]
- [[_COMMUNITY_Firebase Options|Firebase Options]]
- [[_COMMUNITY_Home Config Model|Home Config Model]]
- [[_COMMUNITY_Auth Service|Auth Service]]
- [[_COMMUNITY_Connect Card UI|Connect Card UI]]
- [[_COMMUNITY_Snackbar Util|Snackbar Util]]
- [[_COMMUNITY_Auth Gate|Auth Gate]]
- [[_COMMUNITY_Area Chart Painter|Area Chart Painter]]
- [[_COMMUNITY_Dashboard Screen State|Dashboard Screen State]]
- [[_COMMUNITY_Settings Screen State|Settings Screen State]]
- [[_COMMUNITY_Example Node|Example Node]]
- [[_COMMUNITY_Vivordo Namespace|Vivordo Namespace]]

## God Nodes (most connected - your core abstractions)
1. `_state` - 19 edges
2. `scripts` - 7 edges
3. `timestamp` - 5 edges
4. `_AuthGateState` - 4 edges
5. `_AreaChartState` - 4 edges
6. `_animation` - 4 edges
7. `_GoalsScreenState` - 4 edges
8. `_PandaScreenState` - 4 edges
9. `_TypingIndicatorState` - 4 edges
10. `_SettingsScreenState` - 4 edges

## Surprising Connections (you probably didn't know these)
- `_AuthGateState` --inherits--> `_state`  [EXTRACTED]
  vivordo_health/lib/main.dart → vivordo_health/lib/screens/panda_screen.dart
- `_DashboardScreenState` --inherits--> `_state`  [EXTRACTED]
  vivordo_health/lib/screens/dashboard_screen.dart → vivordo_health/lib/screens/panda_screen.dart
- `_LoginScreenState` --inherits--> `_state`  [EXTRACTED]
  vivordo_health/lib/screens/login_screen.dart → vivordo_health/lib/screens/panda_screen.dart
- `_MainNavigationScreenState` --inherits--> `_state`  [EXTRACTED]
  vivordo_health/lib/screens/main_navigation.dart → vivordo_health/lib/screens/panda_screen.dart
- `_OnboardingScreenState` --inherits--> `_state`  [EXTRACTED]
  vivordo_health/lib/screens/onboarding_screen.dart → vivordo_health/lib/screens/panda_screen.dart

## Import Cycles
- None detected.

## Communities (51 total, 5 thin omitted)

### Community 0 - "Panda Chat Screen"
Cohesion: 0.01
Nodes (142): , package:flutter_svg/flutter_svg.dart, package:url_launcher/url_launcher.dart, PandaQuestion? get, _Role, _activeCategoryLabel, _advanceOrComplete, _anims (+134 more)

### Community 1 - "Stress Spike Test Page"
Cohesion: 0.02
Nodes (81): _activeSpikeId, _addHistory, answers, _answerWithOption, _answerWithOtherText, assistant, build, _buildChatbot (+73 more)

### Community 2 - "Home Screen"
Cohesion: 0.03
Nodes (75): Event>, package:vivordo_health/src/services/calendar_service.dart, package:vivordo_health/src/services/stress_score_service.dart, accentPurple, bg, bgColor, _border, build (+67 more)

### Community 3 - "Scan Screen (PPG Camera)"
Cohesion: 0.03
Nodes (60): DateTime, package:camera/camera.dart, accentPurple, bgColor, build, _buildError, _buildFirstScanTutorial, _buildIdle (+52 more)

### Community 4 - "Insight & Gemini Services"
Cohesion: 0.04
Nodes (56): and, calendar_service.dart, ../demo/demo_user_data.dart, GenerativeModel, insight_service.dart, package:firebase_ai/firebase_ai.dart, _activeDemoUser, analyzePandaSession (+48 more)

### Community 5 - "Insights Model"
Cohesion: 0.04
Nodes (56): bool?, acknowledged, acknowledgedAt, activity, body, _buildSessionSummary, canonicalStressor, _capitalise (+48 more)

### Community 6 - "Dashboard & Profile Charts"
Cohesion: 0.04
Nodes (50): int get, profile_screen.dart, QuerySnapshot, accentPurple, _allMetricsStream, _avg, bgColor, build (+42 more)

### Community 7 - "Goal Model"
Cohesion: 0.05
Nodes (42): double?, FieldValue, Map, category, createdAt, description, direction, endDate (+34 more)

### Community 8 - "Panda Recommendations"
Cohesion: 0.05
Nodes (39): dart:convert, package:flutter/services.dart, package:http/http.dart, all, byCategory, byId, _cache, category (+31 more)

### Community 9 - "PPG Heart-Rate Algorithm"
Cohesion: 0.05
Nodes (40): double get, static const double, static final List, _aSos1, _aSos2, _b, _bSos1, _bSos2 (+32 more)

### Community 10 - "Demo Pages & Charts"
Cohesion: 0.08
Nodes (36): package:vivordo_health/src/pages/home_demo.dart, package:vivordo_health/src/services/auth_service.dart, build, _counter, createState, _incrementCounter, MyHomePage, MyHomePageState (+28 more)

### Community 11 - "AI Service Factory"
Cohesion: 0.06
Nodes (34): ai_service.dart, claude_service.dart, dart:async, ../demo/demo_user_repository.dart, gemini_service.dart, HYPOTHESIS LABEL, OUTPUT, package:cloud_functions/cloud_functions.dart (+26 more)

### Community 12 - "Health Service"
Cohesion: 0.06
Nodes (32): HealthDataType, package:health/health.dart, package:intl/intl.dart, _buildValueMap, clearConsentCache, _computeAndWriteWellness, _consentBroadcast, _consentCacheUid (+24 more)

### Community 13 - "Signup & Questionnaire"
Cohesion: 0.06
Nodes (31): FormState, accentPurple, bgColor, build, _buildAccountSetup, _buildField, _buildMultipleChoiceQuestion, _buildSliderQuestion (+23 more)

### Community 14 - "Recommendation Engine"
Cohesion: 0.06
Nodes (31): int?, panda_recommendations.dart, _biometricNudge, _biometricNudges, _buildSlotTokens, byId, defaultMaxResults, exerciseSessions (+23 more)

### Community 15 - "Goals Scan Screen"
Cohesion: 0.08
Nodes (25): ScanState, accentPurple, bgColor, build, _buildCompleteState, _buildIdleState, _buildMetricCard, _buildScanningState (+17 more)

### Community 16 - "Demo User Data"
Cohesion: 0.08
Nodes (24): age, dailyStressLevel, date, DemoUserData, exerciseSessions, gender, goalAchieved, hrv (+16 more)

### Community 17 - "Profile/Login Settings"
Cohesion: 0.08
Nodes (24): login_screen.dart, package:vivordo_health/src/services/metrics_service.dart, _authSubscription, _autoSyncData, build, _buildCard, _buildDivider, _buildInfoRow (+16 more)

### Community 18 - "Demo User Generator"
Cohesion: 0.09
Nodes (22): dart:math, _clampDouble, _clampInt, DemoUserGenerator, generate, _highStressKeywords, _highStressMoods, _highStressSummaries (+14 more)

### Community 19 - "App Main Entry"
Cohesion: 0.08
Nodes (23): DocumentSnapshot, GlobalKey, build, createState, didChangeAppLifecycleState, dispose, initializeApp, initState (+15 more)

### Community 20 - "Notification Service"
Cohesion: 0.09
Nodes (22): @pragma, FlutterLocalNotificationsPlugin, package:firebase_messaging/firebase_messaging.dart, package:flutter_local_notifications/flutter_local_notifications.dart, package:vivordo_health/main.dart, _firebaseMessaging, _firebaseMessagingBackgroundHandler, getToken (+14 more)

### Community 21 - "Onboarding Screen"
Cohesion: 0.09
Nodes (22): IconData, PageController, build, color, count, createState, currentIndex, _currentPage (+14 more)

### Community 22 - "User Model"
Cohesion: 0.09
Nodes (21): bool get, dart:core, createdAt, displayName, email, fromMap, homeConfig, onboardingCompleted (+13 more)

### Community 23 - "Insight Service"
Cohesion: 0.09
Nodes (21): FirebaseFirestore, ../models/insights.dart, acknowledgeInsight, _addWeighted, aggregateSummary, _col, correctAnswer, _db (+13 more)

### Community 24 - "Functions Package Manifest"
Cohesion: 0.09
Nodes (21): dependencies, @anthropic-ai/sdk, firebase-admin, firebase-functions, description, devDependencies, eslint, eslint-config-google (+13 more)

### Community 25 - "Login & Main Nav"
Cohesion: 0.10
Nodes (20): main_navigation.dart, accentPurple, color, createState, dispose, _emailCtrl, _inputDecoration, _isLoading (+12 more)

### Community 26 - "Metrics Daily Model"
Cohesion: 0.10
Nodes (20): avg, computedAt, count, createdAt, dimension, fromMap, max, MetricsDaily (+12 more)

### Community 27 - "Panda Session Types"
Cohesion: 0.10
Nodes (20): depthFollowUp, depthPrompts, filledSlots, injectedQuestion, insightsContext, intent, message, openerMessage (+12 more)

### Community 28 - "Welcome Beta Screen"
Cohesion: 0.12
Nodes (16): AnimationController, _animation, offset, accentPurple, build, _controller, createState, dispose (+8 more)

### Community 29 - "Main Navigation Bar"
Cohesion: 0.14
Nodes (14): dashboard_screen.dart, home_screen.dart, panda_screen.dart, scan_screen.dart, build, _buildFloatingNavBar, createState, initialIndex (+6 more)

### Community 30 - "User Service"
Cohesion: 0.13
Nodes (14): package:vivordo_health/src/models/metadata.dart, package:vivordo_health/src/models/preferences.dart, package:vivordo_health/src/models/questionnaire_response.dart, package:vivordo_health/src/models/user_model.dart, createGoal, createUser, _derivePreferences, setScannerTutorialSeen (+6 more)

### Community 31 - "AI Service Core"
Cohesion: 0.13
Nodes (14): panda_types.dart, AIService, analyzePandaSession, AppFlags, dedupeAnalyzedSpikes, kMaxInputTokens, kMaxOutputTokensChat, kMaxOutputTokensSpike (+6 more)

### Community 32 - "Calendar Service"
Cohesion: 0.14
Nodes (13): package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart, package:google_sign_in/google_sign_in.dart, package:googleapis/calendar/v3.dart, CalendarService, connectAndGetWeekEvents, _currentUser, getEventsBetween, getWeekEvents (+5 more)

### Community 33 - "Preferences Model"
Cohesion: 0.18
Nodes (10): fromMap, locale, notificationsEnabled, Preferences, scannerTutorialSeen, scannerTutorialSeenKey, timezone, toMap (+2 more)

### Community 34 - "Backfill Insights Script"
Cohesion: 0.25
Nodes (8): admin, APPLY, CANON, canonical(), db, jaccard(), normalize(), stressorsMatch()

### Community 35 - "Goal UI Model"
Cohesion: 0.22
Nodes (8): Color, color, days, Goal, id, subtext, title, Set

### Community 36 - "Misc Widgets"
Cohesion: 0.22
Nodes (9): MyApp, _Panel, _GreenDot, _EventDetailRow, _FieldLabel, _Orb, _OnboardingPage, _PageDots (+1 more)

### Community 37 - "Metadata Model"
Cohesion: 0.25
Nodes (7): dart:io, dart:ui, device, locale, Metadata, toMap, String?

### Community 38 - "Cloud Functions Entry"
Cohesion: 0.25
Nodes (7): admin, Anthropic, client, {onCall, HttpsError}, {onDocumentCreated}, {onSchedule}, {setGlobalOptions}

### Community 39 - "Firebase Options"
Cohesion: 0.25
Nodes (7): android, DefaultFirebaseOptions, ios, web, package:firebase_core/firebase_core.dart, package:flutter/foundation.dart, static const FirebaseOptions

### Community 40 - "Home Config Model"
Cohesion: 0.25
Nodes (7): List, fromMap, HomeConfig, lastSeenInsightId, primaryGoalId, toMap, widgets

### Community 41 - "Auth Service"
Cohesion: 0.25
Nodes (7): package:firebase_auth/firebase_auth.dart, package:vivordo_health/src/services/user_service.dart, package:vivordo_health/src/utils/snackbar.dart, AuthService, emailLogin, emailSignup, sendPasswordReset

### Community 42 - "Connect Card UI"
Cohesion: 0.40
Nodes (5): MaterialPageRoute, _buildConnectCard, _buildEmptyState, _buildHeader, build

### Community 43 - "Snackbar Util"
Cohesion: 0.50
Nodes (3): package:flutter/material.dart, authMessage, SnackBars

### Community 44 - "Auth Gate"
Cohesion: 0.67
Nodes (3): AuthGate, _AuthGateState, WidgetsBindingObserver

## Knowledge Gaps
- **1025 isolated node(s):** `DefaultFirebaseOptions`, `web`, `android`, `ios`, `navigatorKey` (+1020 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **5 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `DemoUserData` connect `Demo User Data` to `Insight & Gemini Services`?**
  _High betweenness centrality (0.036) - this node is a cross-community bridge._
- **Why does `_state` connect `Demo Pages & Charts` to `Panda Chat Screen`, `Auth Gate`, `Signup & Questionnaire`, `Dashboard Screen State`, `Settings Screen State`, `Onboarding Screen`, `Login & Main Nav`, `Main Navigation Bar`?**
  _High betweenness centrality (0.015) - this node is a cross-community bridge._
- **Why does `AIService` connect `AI Service Core` to `Panda Chat Screen`?**
  _High betweenness centrality (0.006) - this node is a cross-community bridge._
- **What connects `DefaultFirebaseOptions`, `web`, `android` to the rest of the system?**
  _1025 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Panda Chat Screen` be split into smaller, more focused modules?**
  _Cohesion score 0.013986013986013986 - nodes in this community are weakly interconnected._
- **Should `Stress Spike Test Page` be split into smaller, more focused modules?**
  _Cohesion score 0.024390243902439025 - nodes in this community are weakly interconnected._
- **Should `Home Screen` be split into smaller, more focused modules?**
  _Cohesion score 0.02631578947368421 - nodes in this community are weakly interconnected._