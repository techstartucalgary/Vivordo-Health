import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:vivordo_health/src/services/user_service.dart';
import 'package:vivordo_health/src/utils/snackbar.dart';

//TODO(favour): log flagged items to crashlytics

class AuthService {
  //email sign up — returns true on success
  static Future<bool> emailSignup({
    required String emailAddress,
    required String password,
    required String displayName,
    String photoUrl = 'default photo url', //TODO(favour): add default photo
    required BuildContext context,
  }) async {
    try {
      final credential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(
            email: emailAddress,
            password: password,
          );
      final currentUser = credential.user;
      if (currentUser != null) {
        await currentUser.updateDisplayName(displayName);
        await currentUser.updatePhotoURL(photoUrl);
        // Firebase Auth's User object is NOT automatically refreshed after
        // updateDisplayName — the local object still has displayName: null.
        // reload() forces the SDK to fetch the updated profile, then we use
        // a fresh currentUser reference so Firestore gets the correct name.
        await currentUser.reload();
        final refreshedUser = FirebaseAuth.instance.currentUser!;
        await UserService.createUser(refreshedUser);
      } else {
        throw Exception("Error creating user");
      }
      return true;
    } on FirebaseAuthException catch (e) {
      if (context.mounted) {
        if (e.code == 'weak-password') {
          const message = 'Password should be at least 6 characters';
          SnackBars.authMessage(context: context, message: message);
        } else if (e.code == 'email-already-in-use') {
          const message = 'The account already exists for that email.';
          SnackBars.authMessage(context: context, message: message);
        } else {
          SnackBars.authMessage(context: context, message: e.code);
        }
      }
    } catch (e) {
      debugPrint(e.toString());
    }
    return false;
  }

  // send password reset email — returns true on success
  static Future<bool> sendPasswordReset({
    required String emailAddress,
    required BuildContext context,
  }) async {
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: emailAddress.trim());
      return true;
    } on FirebaseAuthException catch (e) {
      if (context.mounted) {
        final msg = e.code == 'user-not-found'
            ? 'No account found for that email.'
            : e.message ?? 'Failed to send reset email.';
        SnackBars.authMessage(context: context, message: msg);
      }
      return false;
    } catch (e) {
      debugPrint(e.toString());
      return false;
    }
  }

  // email sign in — returns true on success, false on failure
  static Future<bool> emailLogin({
    required String emailAddress,
    required String password,
    required BuildContext context,
  }) async {
    try {
      final userCredential = await FirebaseAuth.instance
          .signInWithEmailAndPassword(
            email: emailAddress,
            password: password,
          );

      final currentUser = userCredential.user;
      if (currentUser == null) {
        throw Exception('Error signing in user');
      }
      // Sync email state on every login. If the user previously verified an
      // email change, this cleans up pendingEmail from Firestore immediately
      // so the profile screen never sees stale pending state.
      await UserService.syncEmailWithAuth();
      return true;

    } on FirebaseAuthException catch (e) {
      if (context.mounted) {
        if (e.code == 'invalid-credential') {
          const message = 'Invalid email or password';
          SnackBars.authMessage(context: context, message: message);
        } else {
          SnackBars.authMessage(context: context, message: e.code);
        }
      }
      return false;
    } catch (e) {
      debugPrint(e.toString());
      return false;
    }
  }
} 