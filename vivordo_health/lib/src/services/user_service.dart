import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:vivordo_health/src/models/goal_model.dart';
import 'package:vivordo_health/src/models/questionnaire_response.dart';
import 'package:vivordo_health/src/models/metadata.dart';
import 'package:vivordo_health/src/models/user_model.dart';
import 'package:vivordo_health/src/models/preferences.dart';


class UserService {
  static Future<void> createUser(User authUser) async {
    UserModel firestoreUser = UserModel(
      uid: authUser.uid,
      displayName: authUser.displayName,
      photoUrl: authUser.photoURL,
      email: authUser.email,
      onboardingCompleted: false,
      createdAt: Timestamp.fromDate(authUser.metadata.creationTime as DateTime),
      updatedAt: Timestamp.fromDate(authUser.metadata.creationTime as DateTime),
    );
    await FirebaseFirestore.instance
        .collection('users')
        .doc(authUser.uid)
        .set(firestoreUser.toMap());
  }

  static Future<void> setScannerTutorialSeen(bool value) async {
    User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception('User unavailable');
    }

    final userDocRef = FirebaseFirestore.instance.collection('users').doc(user.uid);

    await userDocRef.update({
      'preferences.${Preferences.scannerTutorialSeenKey}': value,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }


  static Future<void> createGoal({
    required User theUser,
    required String userId,
    required String title,
    required String status,
    String? description,
    String? category,
    String? targetMetricType,
    double? targetValue,
    String? targetUnit,
    String? direction,
    String? endDate,
    String? progressCurrentValue,
    String? progressCompletionPercent,
  }) async {
    Map<String, dynamic>? progress;
    if (progressCurrentValue != null) {
      progress = {
        "currentValue": progressCurrentValue,
        "completionPercent": progressCompletionPercent,
        "lastUpdated": FieldValue.serverTimestamp(),
      };
    }


    GoalModel newGoal = GoalModel(
      userId: theUser.uid,
      title: title,
      description: description,
      category: category,
      targetMetricType: targetMetricType,
      targetValue: targetValue,
      targetUnit: targetUnit,
      direction: direction,
      status: status,
      progress: progress,
    );


    await FirebaseFirestore.instance.collection('goals').add(
      newGoal.toMap(
        newStartDate: FieldValue.serverTimestamp(),
        newCreatedAt: FieldValue.serverTimestamp(),
      ),
    );
  }


  static Future<void> submitQuestionnaire({
    required User? user,
    required Map<String, dynamic> userdata,
  }) async {
    final metadata = Metadata.create().toMap();


    if (user != null) {
      try {
      final answers = Map<String, dynamic>.from(userdata["responses"] ?? {});
      
      QuestionnaireResponse firestoreResponse = QuestionnaireResponse(
        userId: user.uid,
        questionnaireType: "baseline",
        submittedAt: FieldValue.serverTimestamp(),
        metadata: metadata,
        answers: answers,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      );

      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('questionnaire_responses')
          .add(firestoreResponse.toMap());

      final preferences = _derivePreferences(answers);

      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('preferences')
          .doc('onboarding')
          .set({
            'preferences': preferences,
            'onboardingCompleted': true,
            'onboardingCompletedAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'onboardingCompleted': true,
        'onboardingCompletedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'preferences.timezone': preferences['timezone'],
        'preferences.locale': preferences['locale'],
        'preferences.units': preferences['units'],
        'preferences.notificationsEnabled': preferences['notificationsEnabled'],
      }, SetOptions(merge: true));
    } catch (e) {
        rethrow;
      }
    } else {
      throw Exception("User unavailable");
    }
  }


  static Map<String, dynamic> _derivePreferences(Map<String, dynamic> answers) {
    double? slider(String key) {
      final v = answers[key];
      if (v == null) return null;
      return (v as num).toDouble();
    }

    String? choice(String key) => answers[key] as String?;

    double stressSum = 0;
    int count = 0;
    for (final key in ['q2', 'q4', 'q6', 'q8']) {
      final v = slider(key);
      if (v == null) continue;
      stressSum += (key == 'q4') ? (11 - v) : v;
      count++;
    }

    String? stressRisk;
    if (count > 0) {
      final avg = stressSum / count;
      if (avg <= 4)        stressRisk = 'low';
      else if (avg <= 6.5) stressRisk = 'moderate';
      else                 stressRisk = 'high';
    }

    return {
      'timezone':             answers['timezone']             ?? 'America/Edmonton',
      'locale':               answers['locale']               ?? 'en_CA',
      'units':                answers['units']                ?? 'metric',
      'notificationsEnabled': answers['notificationsEnabled'] == true,
      Preferences.scannerTutorialSeenKey: false,
      'workSetup':          choice('q1'),
      'mentalDrainScore':   slider('q2'),
      'dailyHoursWorked':   choice('q3'),
      'disconnectScore':    slider('q4'),
      'skipsMeals':         choice('q5'),
      'afterHoursPressure': slider('q6'),
      'typicalSleepNight':  choice('q7'),
      'deadlineAnxiety':    slider('q8'),
      'perceivedWorkload':  choice('q9'),
      'stressRiskTier':     stressRisk,
      'onboardingVersion':  'v1',
    };
  }


  static Future<void> updateDisplayName(String newName) async {
    User? user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await user.updateDisplayName(newName);
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update({
            'displayName': newName,
            'updatedAt': FieldValue.serverTimestamp(),
          });
    }
  }


  static Future<void> updateEmail(String newEmail) async {
    User? user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await user.verifyBeforeUpdateEmail(newEmail);
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update({
            'pendingEmail': newEmail,
            'pendingEmailRequestedAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
    }
  }


  /// Re-proves the user's identity with their current password. Firebase
  /// requires a "recent" sign-in before it will allow sensitive updates
  /// (password change, email change) — without this, updatePassword()
  /// throws 'requires-recent-login' whenever the session is more than a
  /// few minutes old.
  static Future<void> reauthenticate(String currentPassword) async {
    final user = FirebaseAuth.instance.currentUser;
    final email = user?.email;
    if (user == null || email == null) {
      throw Exception('No signed-in email/password user to reauthenticate');
    }
    final credential = EmailAuthProvider.credential(
      email: email,
      password: currentPassword,
    );
    await user.reauthenticateWithCredential(credential);
  }

  static Future<void> updatePassword(String newPassword) async {
    User? user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await user.updatePassword(newPassword);
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update({'updatedAt': FieldValue.serverTimestamp()});
    }
  }


  /// Submits a bug report to the top-level `bug_reports` collection.
  /// This is intentionally NOT under the user's document so reports are
  /// collected centrally for the team to triage.
  static Future<void> submitBugReport(String message) async {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      throw Exception('Bug report message cannot be empty');
    }

    final user = FirebaseAuth.instance.currentUser;

    await FirebaseFirestore.instance.collection('bug_reports').add({
      'message': trimmed,
      'userId': user?.uid,
      'userEmail': user?.email,
      'status': 'open',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }


  /// Syncs Firebase Auth email with Firestore.
  ///
  /// Returns true ONLY when all three conditions are true simultaneously:
  ///   1. There is a pendingEmail in Firestore
  ///   2. Auth email now matches that pendingEmail (verification was clicked)
  ///   3. Firestore email is still the OLD email (hasn't been updated yet)
  ///
  /// Returns false in all other cases — no logout will occur.
  static Future<bool> syncEmailWithAuth() async {
    User? user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;


    await user.reload();
    user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;


    final docRef = FirebaseFirestore.instance.collection('users').doc(user.uid);
    final docSnap = await docRef.get();
    if (!docSnap.exists) return false;


    final data = docSnap.data()!;
    final String? firestoreEmail = data['email'];
    final String? pendingEmail = data['pendingEmail'];
    final Timestamp? requestedAt = data['pendingEmailRequestedAt'] as Timestamp?;


    // Auth email already matches Firestore — fully in sync.
    // Clean up any leftover pending fields and stop. Never logout.
    if (user.email == firestoreEmail) {
      if (pendingEmail != null) {
        await docRef.update({
          'pendingEmail': FieldValue.delete(),
          'pendingEmailRequestedAt': FieldValue.delete(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
      return false;
    }


    // No pending request — emails drifted without one, just sync silently. Never logout.
    if (pendingEmail == null) {
      if (user.email != null) {
        await docRef.update({
          'email': user.email,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
      return false;
    }


    // Pending request exists — check if it has expired (3 days, matching Firebase link expiry)
    final bool isExpired = requestedAt != null &&
        DateTime.now().difference(requestedAt.toDate()).inDays >= 3;


    if (isExpired) {
      await docRef.update({
        'pendingEmail': FieldValue.delete(),
        'pendingEmailRequestedAt': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return false;
    }


    // The one true "just verified" state:
    // Auth email matches pending AND Firestore is still on the old email
    if (user.email == pendingEmail && user.email != firestoreEmail) {
      await docRef.update({
        'email': user.email,
        'pendingEmail': FieldValue.delete(),
        'pendingEmailRequestedAt': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      await FirebaseAuth.instance.signOut();
      return true;
    }


    return false;
  }
}