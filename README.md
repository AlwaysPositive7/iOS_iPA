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
   Sleep includes total time asleep, core, deep, REM, awake, and time in bed.
5. Tap **Request HealthKit Permission** and allow the categories in iOS.
6. Tap **Send Today Now** to test the webhook.
7. Tap **Enable Background Sync**.

## COLMI R04 sleep import

This build connects to a COLMI R04 in the same Daymark Health app and writes its
sleep stages into Apple Health. It supports the QRing Bluetooth firmware family:

1. Charge and wake the ring, then fully close the QRing app so it releases the
   Bluetooth connection.
2. In Daymark Health, tap **Scan** in the COLMI R04 section.
3. Select the ring and tap **Connect**. Some QRing models advertise a generic
   name such as `SMART_RING`, so Daymark lists every named nearby Bluetooth
   device and ranks likely ring names first. It verifies the protocol after
   connection before sending any command.
4. Wait for “Ready to sync sleep.”
5. Tap **Sync Ring Sleep** and approve Apple Health write access when the app
   was installed with a HealthKit-capable signing profile.
6. Use **Send Today Now**, or leave background sync enabled, to send the newly
   imported sleep data to Daymark.

HealthKit requires `com.apple.developer.healthkit` in the provisioning profile
that signs the installed app. Free SideStore/Personal Team profiles do not grant
that advanced capability. If HealthKit authorization fails for that reason,
Daymark still downloads the current overnight sleep window and posts the decoded
stages directly to the configured Daymark webhook. Direct fallback data does not
appear inside Apple's Health app; actual Health insertion requires a paid Apple
Developer Program profile with HealthKit enabled or App Store/TestFlight signing.

COLMI has shipped similar model names with different protocol families. If the
R04 was supplied for the SmartHealth app rather than QRing, it will not expose
the QRing sleep service and this build will report that a different driver is
needed. PulseLoop documents the broader R0x family but does not list an R04 as a
hardware-verified model, so real-device testing is required.

## iOS behavior

- The deployment target is iOS 15 because the current `health` package requires
  iOS 15 or newer.
- Background HealthKit delivery is event-driven. The chosen interval is a
  minimum delay between webhook posts, not an exact timer guaranteed by iOS.
- The sleep window starts at 6 PM on the previous day so an overnight session
  that crosses midnight is included with the day on which you wake up.
- Health data may be unavailable while the phone is locked. A later HealthKit
  event or a manual foreground sync catches the dashboard up.
- The IPA is unsigned. The sideloading service must re-sign the HealthKit
  entitlements for HealthKit access to work on the device.
- Ring sleep requests are manual and local. The app does not use a COLMI cloud
  account; it reads the QRing BLE history and writes category samples directly
  to HealthKit.

Protocol attribution and licensing are recorded in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
