# Fitbit on iOS through Google Health

Vivordo uses the Google Health API, which replaces the legacy Fitbit Web API.
The iOS app opens Google consent using `ASWebAuthenticationSession`. The
authorization code, access token, refresh token, and client secret stay in
Firebase Functions.

## Google Cloud configuration

In the same Google Cloud project used for the OAuth client:

1. Enable the **Google Health API**.
2. Configure the OAuth consent screen and request these scopes:
   - `googlehealth.activity_and_fitness.readonly`
   - `googlehealth.health_metrics_and_measurements.readonly`
   - `googlehealth.sleep.readonly`
3. Use a **Web application** OAuth client.
4. Add this authorized redirect URI, replacing the project ID if necessary:

   `https://us-central1-vivordo-health.cloudfunctions.net/googleHealthOAuthCallback`

The Google client ID ending in `apps.googleusercontent.com` is the value for
`GOOGLE_HEALTH_CLIENT_ID`. Download or copy the matching client secret from the
same Web application OAuth client.

## Firebase secrets and deployment

From `vivordo_health/`:

```sh
firebase functions:secrets:set GOOGLE_HEALTH_CLIENT_ID
firebase functions:secrets:set GOOGLE_HEALTH_CLIENT_SECRET
firebase deploy --only functions:beginFitbitConnection,functions:googleHealthOAuthCallback,functions:syncFitbit,functions:disconnectFitbit
```

The old `FITBIT_CLIENT_ID` and `FITBIT_CLIENT_SECRET` secrets are no longer
used and may be deleted after the migrated functions have deployed and tested.

## Data flow

1. `beginFitbitConnection` creates a short-lived, single-use OAuth state and
   returns Google's authorization URL.
2. Google redirects to the HTTPS `googleHealthOAuthCallback` function.
3. Firebase validates the state, exchanges the code, stores credentials in
   `google_health_credentials/{uid}`, and redirects back to the iOS scheme
   `vivordo-fitbit://oauth2redirect`.
4. `syncFitbit` requests daily Google wearable rollups. This excludes Apple
   Health/HealthKit data from the Fitbit import.
5. Fitbit steps, active calories, distance, floors, heart rate, weight, and
   sleep are normalized into `users/{uid}/metrics_daily/{yyyy-MM-dd}` with
   `source: fitbit`. Sleep sessions are assigned to the day the user wakes and
   store total time asleep in hours. Active calories use Google Health's
   `active-energy-burned.kcalSum` and remain in Vivordo's existing
   `active_calories` field.

The credential and OAuth-state collections are intentionally absent from
`firestore.rules`, so client SDKs cannot read them.
