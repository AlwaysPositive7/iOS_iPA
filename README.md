# Daymark Health

Flutter iPhone bridge that reads the Apple Health metrics selected in the app
and sends today's data to the Daymark HTTPS endpoint.

## Build the IPA

The GitHub Actions workflow builds an unsigned IPA on a macOS runner and uploads
it as the `Daymark-Health-IPA` artifact. Open the pull request's Checks tab to
watch the build. After merging, the same workflow can be run manually from the
Actions tab.

## First launch

1. Open Daymark Health on the iPhone.
2. Leave the prefilled webhook URL as
   `https://daymark-eight-sepia.vercel.app/api/health`.
3. Leave the bearer token blank for the current unauthenticated endpoint.
4. Choose the health metrics and whether to keep only Apple Watch samples.
5. Tap **Request HealthKit Permission** and allow the categories in iOS.
6. Tap **Send Today Now** to test the webhook.
7. Tap **Enable Background Sync**.

## iOS behavior

- The deployment target is iOS 15 because the current `health` package requires
  iOS 15 or newer.
- Background HealthKit delivery is event-driven. The chosen interval is a
  minimum delay between webhook posts, not an exact timer guaranteed by iOS.
- Health data may be unavailable while the phone is locked. A later HealthKit
  event or a manual foreground sync catches the dashboard up.
- The IPA is unsigned. The sideloading service must re-sign the HealthKit
  entitlements for HealthKit access to work on the device.
