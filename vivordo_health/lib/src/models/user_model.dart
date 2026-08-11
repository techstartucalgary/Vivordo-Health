import 'dart:core';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'preferences.dart';


class UserModel {
  final String uid;
  String? displayName;
  String? email;
  String? pendingEmail;
  String? photoUrl;
  String? orgId;
  List<String>? roles;
  bool onboardingCompleted;
  Timestamp? onboardingCompletedAt;
  Map<String, dynamic>? preferences;
  Map<String, dynamic>? homeConfig;
  final Timestamp? createdAt;
  Timestamp? updatedAt;


  UserModel({
    required this.uid,
    required this.displayName,
    required this.email,
    this.pendingEmail,
    required this.onboardingCompleted,
    required this.createdAt,
    required this.updatedAt,
    this.photoUrl,
    this.orgId,
    this.roles,
    this.onboardingCompletedAt,
    this.homeConfig,
    this.preferences,
  });

  bool get scannerTutorialSeen =>
      preferences?[Preferences.scannerTutorialSeenKey] == true;

  set scannerTutorialSeen(bool value) {
    preferences ??= <String, dynamic>{};
    preferences![Preferences.scannerTutorialSeenKey] = value;
  }


  factory UserModel.fromMap(Map<String, dynamic> firestoreData, String id) {
    return UserModel(
      uid: id,
      displayName: firestoreData['displayName'],
      email: firestoreData['email'],
      pendingEmail: firestoreData['pendingEmail'],
      onboardingCompleted: firestoreData['onboardingCompleted'] == true,
      createdAt: firestoreData['createdAt'],
      updatedAt: firestoreData['updatedAt'],
      photoUrl: firestoreData['photoUrl'],
      orgId: firestoreData['orgId'],
      roles: (firestoreData['roles'] as List<dynamic>?)
          ?.map((role) => role.toString())
          .toList(),
      onboardingCompletedAt: firestoreData['onboardingCompletedAt'],
      homeConfig: firestoreData['homeConfig'],
      preferences: firestoreData['preferences'],
    );
  }


  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'displayName': displayName,
      'email': email,
      'pendingEmail': pendingEmail,
      'onboardingCompleted': onboardingCompleted,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      'photoUrl': photoUrl,
      'orgId': orgId,
      'roles': roles,
      'onboardingCompletedAt': onboardingCompletedAt,
      'homeConfig': homeConfig,
      'preferences': preferences,
    };
  }
}
