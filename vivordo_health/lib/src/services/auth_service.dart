import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:vivordo_health/src/services/calendar_service.dart';
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
    // When provided, password-specific errors (e.g. weak-password) are
    // routed here instead of a SnackBar, so callers can surface them
    // inline next to the password field instead of as a bottom toast.
    void Function(String message)? onPasswordError,
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
        // Firebase can't confirm the address is real/deliverable at signup
        // time — the only way to prove that is a link the user has to
        // actually open in their inbox. AuthGate blocks app access until
        // emailVerified is true, so this is what gates account creation on
        // a real address rather than the createUser call itself.
        await refreshedUser.sendEmailVerification();
      } else {
        throw Exception("Error creating user");
      }
      return true;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'weak-password') {
        const message = 'Password should be at least 6 characters';
        if (onPasswordError != null) {
          onPasswordError(message);
        } else if (context.mounted) {
          SnackBars.authMessage(context: context, message: message);
        }
      } else if (context.mounted) {
        if (e.code == 'email-already-in-use') {
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
      await FirebaseAuth.instance.sendPasswordResetEmail(
        email: emailAddress.trim(),
      );
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

  // Google sign-in — returns true on success, false on failure/cancellation.
  // Firebase automatically marks a federated Google account's emailVerified
  // as true (Google already proved ownership of the address), so these
  // users skip EmailVerificationScreen entirely via AuthGate.
  static Future<bool> signInWithGoogle({required BuildContext context}) async {
    try {
      // GoogleSignIn.instance is a singleton that can only be initialized
      // once app-wide — CalendarService already owns that initialization
      // (it also configures the serverClientId needed for idToken here), so
      // reuse it rather than calling initialize() a second time.
      await CalendarService.initialize();

      if (!GoogleSignIn.instance.supportsAuthenticate()) {
        if (context.mounted) {
          SnackBars.authMessage(
            context: context,
            message: 'Google Sign-In is not supported on this device.',
          );
        }
        return false;
      }

      final googleUser = await GoogleSignIn.instance.authenticate();
      CalendarService.registerSignedInAccount(googleUser);
      final idToken = googleUser.authentication.idToken;
      if (idToken == null) {
        throw Exception('Google Sign-In did not return an ID token');
      }

      final credential = GoogleAuthProvider.credential(idToken: idToken);
      final userCredential = await FirebaseAuth.instance.signInWithCredential(
        credential,
      );
      final user = userCredential.user;
      if (user == null) {
        throw Exception('Error signing in with Google');
      }

      if (userCredential.additionalUserInfo?.isNewUser ?? false) {
        await UserService.createUser(user);
      }

      // Google identity authentication does not automatically grant access to
      // Google Calendar. Request it before navigating to the home screen so
      // the first calendar load does not race the authentication event stream.
      await CalendarService.authorizeCalendarAccess();
      return true;
    } on GoogleSignInException catch (e) {
      // Don't show an error toast for a plain cancel — that's not a failure.
      if (e.code != GoogleSignInExceptionCode.canceled && context.mounted) {
        SnackBars.authMessage(
          context: context,
          message: 'Google sign-in failed. Please try again.',
        );
      }
      return false;
    } on FirebaseAuthException catch (e) {
      if (context.mounted) {
        final message = e.code == 'account-exists-with-different-credential'
            ? 'An account already exists with this email using a different sign-in method.'
            : e.message ?? e.code;
        SnackBars.authMessage(context: context, message: message);
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
          .signInWithEmailAndPassword(email: emailAddress, password: password);

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
