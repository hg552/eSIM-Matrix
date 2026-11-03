# Changelog

All notable changes to NekokoLPA2 will be documented in this file.

## [Unreleased]

### Fixed
- Prepare the main Looper before creating the system `ActivityThread` in the one-time ADB helper; Android 16 `app_process` otherwise crashes while constructing its Handler.
- Use shell-attributed external-provider Binder IPC in the one-time ADB helper; Android 16 rejects `android` as the caller package for shell UID 2000.

### Documentation
- Correct the fork's deployment instructions to the non-root Multi APK. OTBridge APKs and KernelSU/Magisk modules are not required; profile access still depends on authorized OMAPI or an external reader, not on bypassing card rules with multiple signers.


### Added
- Add an Android-only local network-status tab for active subscriptions, voice registration and signal readings. It uses public Telephony callbacks after a user-granted `READ_PHONE_STATE` permission; the view does not read SMS or change profiles.
- Add a non-root eUICC-Nexus Android flavor with read-only telephony status and opt-in inbound SMS relay to an HTTPS webhook or confirmed Telegram private chat. Only this flavor requests `RECEIVE_SMS`; the Nexus reader path ignores OTBridge.
- Encrypt Telegram Bot Tokens with Android Keystore; discover and confirm direct private chats, or explicitly enter and confirm a group/channel destination. No SMS body logging.


## [1.1.0+110]

### Added
- **Smart OTP Extraction & Click-to-Copy (`<code>OTP</code>`)**: Automatically extract 4–8 digit and prefixed (`G-xxxxxx`) verification codes from incoming SMS, format Telegram messages in HTML with one-tap copyable `<code>` tags, and attach quick `[🏠 已收到码，切回主卡]` inline action buttons directly below each forwarded SMS.
- **Offline SMS Retry Queue & One-Click Redelivery**: Retry failed SMS deliveries with exponential backoff and automatically flush undelivered messages when connectivity returns or via `/retry_sms` and UI retry buttons.
- **Dual Switching Modes (Permanent vs. 5-Minute Temporary OTP) & Keep-Alive Cron Engine**: Support both permanent switching (`🔄 启用`) and 5-minute auto-revert OTP switching (`⏱️ 5分接码`), plus a configurable periodic Keep-Alive scheduler (`/keepalive`) that automatically switches to target profiles for 3 minutes of roaming registration and reverts to the default card.
- **Direct QR Image Decoding in Telegram & Remote Profile Renaming (`/rename`)**: Send an eSIM QR code photo/screenshot directly to the Telegram Bot to decode `LPA:1$...` in memory and install the profile; rename any profile remotely via `/rename <index> <new_name>`.
- **eUICC Free NVRAM & EID Reporting**: Display remaining eUICC non-volatile memory (`KB`) and `EID` directly in `/list`, `/status`, and the Web UI.
- **Host Standby Device Health Monitoring & Power/Battery Alerts**: Report battery percentage, charging source (`AC`/`USB`), battery temperature (`°C`), and network transport in `/status`, and push automatic Telegram alerts when AC power is unplugged, battery drops below `20%`, or temperature exceeds `45°C`.
- **Incoming Call Relay (`CallRelayReceiver`)**: Forward incoming call ringing alerts (`PHONE_STATE`) with caller number and SIM slot to Telegram/Webhook and record them in local history.
- **Multi-Reader / Dual-SIM Slot Switching (`/readers`)**: Remotely list and switch between `SIM 1`, `SIM 2`, and external readers from Telegram or the REST API.
## [1.0.0+100]

### Released
- First public 1.0.0 release of **eUICC-Nexus** (built upon NekokoLPA 2 under the MIT License):
  - Android eUICC remote profile switching, download (`LPA:1$...` + one-click Speedtest test profile), and two-step safe deletion over local OMAPI / external readers / OTBridge.
  - Real-time Android 4G/5G/CS/PS baseband roaming registration state machine (`STATE_IN_SERVICE`, `NetworkRegistrationInfo`, signal dBm) with post-switch stale-state protection and 6-second hardware cooldown lock.
  - Automatic local cleanup of `Enable`/`Disable` SGP.22 notifications from eUICC NVRAM after profile switches to prevent OMAPI channel contention (`TRANSMIT_FAILED`) and NVRAM exhaustion, while retaining SM-DP+ `Delete` notification reporting.
  - Incoming SMS & OTP forwarding to Telegram Bot or HTTPS Webhook with Android Keystore AES-GCM credential encryption and local SMS forwarding history UI (up to 100 entries, copy/delete/clear).
  - Interactive Telegram Bot control plane (`setMyCommands` native menu, Inline Keyboard button dashboard, `callback_query` toast feedback, direct `LPA:1$...` paste download) + LAN/Tailscale HTTP REST API & dark-mode Web UI (`:8787`).
  - Public build with all personal Telegram Bot tokens/chat IDs removed.

## [0.0.8-beta0.14+14]

### Fixed
- Sync `_session` with `savedDefault` in `setDefaultProfile` and `_restoreFallback`, and check `savedDefault?.iccid ?? _session?.defaultIccid` when deleting or reverting profiles so a former default profile is no longer blocked from deletion after setting a new default profile.

## [0.0.8-beta0.13+13]

### Fixed
- Allow GSMA Root CI TLS certificates on `SmdpClient` ES9+ connections (`rsp.truphone.com`, etc.), fixing `HandshakeException: CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate` when downloading eSIM profiles while keeping eUICC hardware signature verification (`ES10b.AuthenticateServer`) intact.

## [0.0.8-beta0.12+12]

### Added
- Add one-click Speedtest public test eSIM (`LPA:1$rsp.truphone.com$QRF-SPEEDTEST`) download test option in `DownloadProfilePage`, `SmsRelayPage`, Web UI dashboard, and Telegram Bot.
- Upgrade Telegram Bot with interactive Inline Keyboard button panels (`inline_keyboard`), `callback_query` button execution + toast feedback (`answerCallbackQuery`), native slash command menu registration (`setMyCommands`), and direct `LPA:1$...` message recognition.

## [0.0.8-beta0.11+11]

### Added
- Add persistent SMS forwarding history in `SmsRelayPage` showing full forwarded message content, sender, SIM slot/carrier, delivery status, copy button, single-entry deletion, and one-tap clear-all.
- Add in-app Remote eSIM Control Panel in `SmsRelayPage` and `/help` Telegram menu supporting remote eSIM profile download (`/download`, `/download_test`), two-step safe profile deletion (`/delete`, `/delete_confirm`) with automatic SM-DP+ delete notification reporting, and profile switching.

## [0.0.8-beta0.10+10]

### Fixed
- Enable automatic local deletion (without server upload) of `Enable` and `Disable` SGP.22 notifications after profile switches (`notifProcessAfterSwitch = true`, `notifDeleteWithoutSendingEnable = true`, `notifDeleteWithoutSendingDisable = true`), skipping full certificate reads and running after SIM `REFRESH` / baseband registration completes so chip NVRAM never fills up and OMAPI channels never collide.
- Filter out emergency-only / no-service placeholder carrier strings (`只能拨打紧急求助电话`, `Emergency calls only`, `无服务`) and guard against 1-second stale pre-switch `inService` snapshots before SIM reset completes.
- Shorten profile switch cooldown from 30 seconds to 6 seconds with a friendly Telegram wait message.
## [0.0.8-beta0.08+8]

### Fixed
- Detect both CS voice (`ServiceState.state`) and 4G/5G PS data (`NetworkRegistrationInfoList`) roaming/home registration in `NetworkStatusPlugin`, synchronously read `serviceState` and `signalStrength` on `refresh`, and poll baseband status every 2 seconds while `RemoteGatewayService` awaits network registration.
- Stop reopening an ISD-R OMAPI channel immediately after a successful `enableProfile` with `refreshFlag`, avoiding `6985` card-busy contention while the handset modem processes the SIM `REFRESH`.
- Persist the SMS forwarding toggle immediately in `SmsRelayPage` and avoid overwriting in-progress UI state on `AppLifecycleState.resumed`.
- Pre-configure the test Telegram Bot Token and Chat ID in `SmsRelayStore` and auto-start the remote gateway on launch.

## [0.0.7-beta0.07+7]

### Security
- Remove the global `HttpOverrides` and per-client `badCertificateCallback` TLS bypass from `SmdpClient` and `NotificationsScreen`, preventing SM-DP+ requests from disabling certificate validation across the Dart VM.

### Fixed
- Initialize `OmapiPlugin` background thread and `SEService` on engine attach in the cached-engine Multi variant and keep `SEService` alive across `MainActivity` detach, enabling headless OMAPI operations after boot or after closing the UI.
- Wait for `SEService` connection readiness in `OmapiPlugin.handleConnect` and `getOrCreateSession` during cold headless startup, and retain `SharedPreferencesOmapiSafetyStore` durable crash/poison protection across all variants.
- Verify remote profile switches with `ProfileStateTransition`, hold `ForegroundCardSession` during remote card operations, and stop swallowing switch/revert failures in `RemoteGatewayService`.
- Recreate the Telegram `HttpClient` on gateway stop, hot-reload Telegram polling when credentials change at runtime, start/resume the gateway when Telegram control is configured even if SMS forwarding is off, and enable `/download`, `/download_test`, `/delete`, and `/delete_confirm` in Telegram command parsing (including multi-line arguments).
- Share a single broadcast stream in `NetworkStatusService` so pausing `NetworkStatusPage` does not cancel `RemoteGatewayService` baseband monitoring; re-register `SubscriptionsChangedListener` on `refresh` after runtime permission grants and fall back to active subscriptions when external readers do not embed a slot index in their reader ID.

## [0.0.6-beta0.06+6]

### Security
- Enforce standard TLS certificate validation for TS.43 entitlement connections; untrusted peers are rejected before credentials are sent.
- OTBridge 1.2.2 now requires explicit in-app consent for external applications, pinned to their installed package/UID. Public community signing keys do not grant access. Logical channels are isolated by caller UID; revocation also closes owned channels.

### Fixed
- Preserve permanent profile selections across gateway recovery instead of treating the zero/no-deadline marker as an expired timer; report no countdown for permanent sessions.
- Recheck default and active-session fallback protection at profile deletion confirmation, including changes made after the confirmation token was issued.
- Repair WebCard version-request UID generation and contain synchronous failures within the extension-unavailable fallback.

## [0.0.5-beta0.05+5]

### Fixed
- Forward long inbound SMS without the former 4096-character rejection; preserve Unicode across Telegram chunks.
- Remove the unconditional second `/back` message, so its failure cannot misreport an already-forwarded SMS as failed.
- Include available SIM slot, subscription ID and carrier in Telegram headers and webhook fields; missing metadata stays unknown.
- Allow explicitly confirmed negative Telegram group/channel IDs. Discovery remains private-only; selecting a group destination does not enable group control commands.
- Hold a timeout-bounded partial wake lock during asynchronous SMS delivery, releasing it on success, failure and queue rejection. This does not extend Android broadcast deadlines or provide persistent retry.
- Keep displayed and platform version names consistent using the prerelease version `0.0.5-beta0.05` (build 5).

## [2.4.3+603] - 2026-10-31

### Fixed
- Restore standard iOS Bluetooth discovery so BeeSIM and other name-discovered readers are not excluded by AccessorySetupKit service filters.
- Keep Bluetooth reader setup errors inside the dialog error handler.
- Keep delivered notifications visible while they remain on the eUICC, and verify card removal before reporting success (#42).
- Preserve a minimal delivery receipt when local history is deleted, preventing an already delivered notification from being sent again (#42).
- Queue automatic notification processing after profile operations instead of losing requests during a concurrent badge refresh (#43).
- Send notifications without requiring an unrelated connectivity-probe server to be reachable (#43).

### Build and distribution
- Build Community and rooted Community Android APKs from public source without private credentials, verifying identical signed APKs across two clean builds.
- Publish shared build and release tooling in NekokoLPA2; keep brand data and distribution credentials separate.

## [2.4.2+602] - 2026-10-31

### Fixed
- Keep iOS AccessorySetupKit registration out of the shared macOS Bluetooth implementation.
- Close released cached OMAPI channels immediately when Android enters the background, addressing the restart safety-marker path reported in #58. Keep active operations and reboot protection after a real channel-close failure.
- Retry WebCard AID selection on the basic channel when a driver allocates a logical channel but SELECT returns 6881 (#31).

### Added
- Recognize the optional ATR eUICC capability flag and show OMAPI users a notice about keeping the SIM/eSIM slot enabled in Android system settings.
- Published the 3HK number, line-expiry and package-status plugin. All provider plugins now live in the public repository.
- Added iOS accessory setup for supported Bluetooth readers.

### Changed
- Name the public Android variant Community, retaining the existing package ID and signing certificate for upgrades. Desktop and web builds use NekokoLPA 2.
- Publish the shared Windows/Linux builds to standard desktop update feeds, retaining earlier channel and filename compatibility.
- Move Crowdin synchronization, validation and translation documentation into NekokoLPA2.

### Upgrade notes
- An existing reboot-required OMAPI marker still needs one device restart after updating; clearing app data is unnecessary.
- Xiaomi and WebCard fixes have automated regression coverage; confirmation on the affected hardware is pending. See [issue review](docs/issue-audit-602.md).

## [2.4.1+601] - 2026-10-29

### Performance
- Initialize tabs on first visit and pause inactive Flutter animations while retaining page state.
- Isolate settings-row repaint work, cache profile-size/icon misses, and index/cache size predictions with reference parsing outside the mobile UI isolate.

### Added
- Published eSIM.cc rewards/portal integration and eSIM.gg number, balance and package status integration.

### Fixed
- Clear the OMAPI crash guard only at a verified channel-free idle checkpoint, preventing normal app restarts from hiding built-in readers. Actual failed channel cleanup remains reboot-required.
- Wait for asynchronous OMAPI service connection, refresh discovery when it connects, honor forced reader refresh and show reboot-required discovery errors instead of an empty-reader prompt.
- Keep built-in reader defaults available if an installed OTBridge provider fails discovery.

### Upgrade notes
- If 2.4.0 already left OMAPI blocked with a reboot-required safety marker, install this update and restart the device once. Clearing app data is not required.
- Scrolling work has been reduced and regression-tested; physical-device frame timing has not yet been measured.

## [2.4.0+600] - 2026-10-28

### Added
- Published TYBLE reader support.
- Published experimental desktop VoWiFi/SMS for Windows, macOS and Linux, with explicit opt-in and the existing 9eSIM-build restriction.
- Published plain-SIM identity and operator probing for readers that support raw APDUs.
- Added eSTK.me slot selection, Android SE HAL readers and profile database import/export.
- Moved OTBridge source and APK/Magisk/KernelSU module builds into NekokoLPA2.
- Retained full rooted Android APK/module builds alongside normal and helper-based installations.

### Fixed
- Fixed 9eSIM B0 Plus detection for eight-digit advertised names and authentication using the advertised device UID.
- Enforced the Android and OMAPI VoWiFi restrictions at reader and service entry points.
- Improved desktop IMS authentication with quoted Digest challenges, MCC-independent qop negotiation, AUTS resynchronization, binary RES handling and nonce counts.
- Matched SIP final responses to their transactions, retained registration service routes, honored Min-Expires and serialized overlapping socket writes.

### Documentation
- Added a README banner, getting-started and build instructions, VoWiFi restrictions, troubleshooting and an IMS research/verification guide.

## [2.2.5+587] - 2026-09-24

### Changed
- The macOS app requires macOS 12 or later.

### Fixed
- eUICC signing requests from websites accept a non-standard IMEI or TAC given as integers, instead of failing with "IMEI integer must contain exactly 15 decimal digits".
- When a profile fails to install, the reason (such as insufficient memory) is shown even on cards holding many install notifications, instead of an APDU error over Bluetooth readers.

## [2.2.4+586] - 2026-08-29

### Fixed
- Confirmation codes are hashed over the transaction identifier itself rather than its text form, so a server that issues a short identifier no longer rejects a correct code.
- Carrier eSIM transfers send the device IMEI in the right digit order; carriers that validate it no longer refuse the transfer.
- USB card readers release their connection when disconnected, instead of leaking one per session until connecting stopped working.
- Profile downloads give up on an unresponsive server instead of waiting indefinitely, and the screen now explains why it cannot be dismissed mid-operation.
- Rejecting a previewed profile ends the session with the server, so the next attempt is not refused as already in progress.
- Reader actions such as loading the current SIM to VoWiFi act on the profiles currently on the card rather than a stale list.

## [2.2.1+583] - 2026-08-11

### Fixed
- Fixed eUICC signing when a valid 15-digit IMEI is supplied as unsigned integer bytes.

## [2.1.5+575] - 2026-07-10

### Added
- Added Russian localization from Crowdin.

## [2.1.4+574] - 2026-07-10

### Fixed
- Show and edit the device TAC instead of the internal 16-digit stored IMEI encoding.
- Use TAC `35383741` by default while still accepting a full 15-digit IMEI.

## [2.1.0+569] - 2026-06-01

### Changed
- Prepared public store branding and standard platform icons.
- Restricted GitHub release publishing to the release branch.

## [2.0.10+568] - 2026-05-24

### Added
- Added distinct OMAPI and Telephony API reader icons.
- Added notification send, delete, and completion animations with a session-only pause control.

### Changed
- Improved eSIM switching stability across OMAPI and Telephony API readers.
- Notification processing now follows auto-trigger settings unless paused by the user.

### Fixed
- Fixed launch-time eSIM switching failures and reader deduplication for channels pointing at the same card.
- Fixed notification count taps showing stale sent notifications before fresh metadata finishes loading.

## [2.0.8+564] - 2026-04-03

### Added
- Android now detects rooted devices and shows that OTBridge can be used to enable Telephony support and bypass OMAPI ARA-M restrictions.

### Changed
- Android prefers the external OTBridge provider path when present.
- Android CI no longer builds the privileged NekokoLPA2 variant.

## [2.0.4+555] - 2026-02-15

### Added
- Improved eSTK.me Card support

## [2.0.2+543] - 2026-01-25

RemoCard v2.0 and minor UI fixes

## [2.0.2+542] - 2026-01-25

Added a browser with signing capabilities.

## [2.0.2+541] - 2026-01-25

Profile Size Predictions, Optimized Reset Flag

## [2.0.2+540] - 2026-01-24

### Added
- **IMEI**: Added IMEI to settings.

### Fixed
- **Wrong IMEI generation**: Fixed wrong IMEI generation. Previously it might contain non-numeric characters.

## [2.0.2+538] - 2026-01-22

### Changed
- **Version**: Bumped version to 2.0.2+538 to make Apple Happy.

### Fixed
- **TMAPI Handling**: Now it should work on Android 13- devices.
- **Remote Card Handling**: Now it should work again.

### Added
- **Download Size Prediction**: Allow predicting download size before downloading.

## [2.0.1+537] - 2026-01-22

### Changed
- **Version**: Bumped version to 2.0.1+537 to allow upgrading

### Added
- **Size Data Migration**: Now it's possible to read from v1 App's size stats and migrate them to v2 App with same package name.

## [2.0.1+35] - 2026-01-22

### Added
- **EUICC Signatures**: Added EUICC Signatures support.
- **Connection Stability**: Improved how the app manages smart card connections to prevent "channel busy" errors and ensure smoother profile loading.

## [2.0.1+34] - 2026-01-21

### Added
- **Deep Link Direct Download**: Added Deep Link Direct Download support. Now you can use urls to download profiles directly from the app, including webviews.

## [2.0.1+33] - 2026-01-20

### Added
- **Deep Linking Support**: Added Deep Linking support. Now you can use urls such as https://install.lpa.ee/LPA:1$smdp.example$MATCHING-ID to open the app.


## [2.0.0+32] - 2026-01-20

### Added
- **Linux Support**: Added Linux support.

## [2.0.0+31] - 2026-01-19

### Improved
- **Connection Stability**: Improved how the app manages smart card connections to prevent "channel busy" errors and ensure smoother profile loading.
- **Better User Feedback**: Fixed a bug where the app showed "Not Connected" while still trying to connect to a reader.
- **Connection Recovery**: Added easy "Cancel" and "Retry" buttons if a connection to a card reader takes too long.


## [2.0.0+30] - 2026-01-18

### Added
- **Variant-Specific Branding**: Added dynamic logos for app variants.
- **Improved Variant Detection**: Support for variants via package name and build environment.

### Fixed
- **Rooted Device Support**: Robustified Telephony/TMAPI plugin to prevent crashes on high-privileged builds on some devices.

## [2.0.0+29] - 2026-01-17

### Fixed
- **Multi-Language Support**: Improved translations.
- **Bluetooth Connection**: Improved Bluetooth connection handling.

## [2.0.0+28] - 2026-01-15

### Added
- **Multi-Language Support**: Added support for Spanish, French, Japanese, and Chinese.
- **Bluetooth-on-Windows Support**: Added support for Bluetooth on Windows.

## [2.0.0+27] - 2026-01-14

### Added
- **Phone Number Parsing**: Customizable E.164 / National Number Parsing

### Fixed
- **Card Switch Handling**: Better support for Android on OMAPI

## [2.0.0+26] - 2026-01-14

### Added
- **Custom Profile Icons**: Set custom icons for profiles from gallery, remote Nekoko icons, or eSIM card icons
- **Copy ICCID**: Quick copy profile ICCID to clipboard from context menu
- **Enhanced Tag Notifications**: Tag-based notification scheduling system

### Changed
- **Compact UI**: Improved space efficiency on small screens with scrollable dialogs and menus

### Fixed
- **Permission Handling**: Better support for Linux/macOS with clear unsupported platform messages
