# MetaStream

Ray-Ban Meta Gen 2 glasses → Kick/Twitch/custom RTMP, with chat, built and
signed entirely without a Mac. See the plan doc for design rationale; this is
the operational checklist.

## Setup checklist (one-time)

1. **Meta developer account.** Sign up at https://wearables.developer.meta.com.
   Create a project named `MetaStream`, platform iOS, bundle ID
   `com.saeedkolivand.metastream` (no hyphens allowed in the bundle ID — Meta firmware
   rule). Leave Apple Team ID blank for now; you'll fill it in during the
   bootstrap build (step 4). Copy the **MetaAppID** and **ClientToken** it
   gives you.
2. **Enable Developer Mode in the Meta AI app.** Settings → App Info → tap
   the version number 5 times → Developer Mode toggles on.
3. **Check firmware/app versions.** Glasses firmware ≥ v126, Meta AI app ≥
   V282. Update either from the Meta AI app if below that.
4. **GitHub repo.** Create a public repo, push this project, then add three
   repo secrets (Settings → Secrets and variables → Actions):
   - `META_APP_ID`
   - `CLIENT_TOKEN`
   - `TEAM_ID` (leave empty for the first run — see bootstrap below)
5. **Windows prerequisites.** Install iTunes and iCloud from
   https://apple.com (NOT the Microsoft Store versions — they don't expose
   the drivers Sideloadly needs), then install Sideloadly from
   https://sideloadly.io.
6. **iPhone Developer Mode.** Settings → Privacy & Security → Developer Mode
   → on (requires a restart).

## Bootstrap Team ID (two builds)

The Info.plist needs your Apple Team ID, but you don't know it until you've
signed once with your free Apple ID.

1. Run the `build-ipa` workflow (Actions tab → Run workflow) with the
   `TEAM_ID` secret empty. The build still succeeds; expect a `TEAM_ID secret
   empty` warning in the log — that's expected for this bootstrap build.
2. Download the `MetaStream-ipa` artifact, sideload it with Sideloadly
   (sign in with your free Apple ID), install over USB, open the app.
3. The app shows your Apple Team ID on screen. Copy it into the `TEAM_ID`
   GitHub secret.
4. Re-run the workflow. This second IPA is the real one — reinstall it.

## Weekly re-sign

Free Apple ID certs expire after 7 days. Turn on Sideloadly's "Wi-Fi auto
refresh" so it re-signs automatically; otherwise plug the phone in and click
Start again in Sideloadly before the week is up. Free accounts are capped at
3 sideloaded apps.

## Going live

- Kick: stream URL `rtmps://fa723fc1b171.global-contribute.live-video.net:443/app/`
  + your stream key. Chat popout: `https://kick.com/popout/<you>/chat`.
- Twitch (affiliate/partner only in v1, see limitations):
  `rtmps://live.twitch.tv:443/app/`. Chat popout:
  `https://www.twitch.tv/popout/<you>/chat`.

## Limitations (v1)

| Limitation | Why |
|---|---|
| 720x1280 portrait, 30 fps max | Hard cap of the DAT SDK's camera stream. |
| Twitch only if affiliate/partner | Twitch requires HEVC senders to be Partner/Affiliate tier; everyone else needs H.264, which isn't implemented yet. v1 targets Kick and custom RTMP servers. |
| One registered app at a time | The glasses only allow one third-party app registered in Developer Mode. Registering MetaStream unregisters StreamHand (or vice versa). |
| Glasses mic is 8 kHz mono | Bluetooth HFP audio quality is a hardware/protocol limit. Default is the phone mic; toggle to glasses mic if you want it anyway. |

## Troubleshooting

- **"Internal error" during Meta registration**, seen on iPhone 17e / iOS
  26.5.1: known SDK bug, tracked at
  https://github.com/facebook/meta-wearables-dat-ios/issues/205. Nothing to
  fix in this app; retry, or use a different iPhone/iOS version if it
  persists.
- **"Device unavailable" immediately after starting a glasses session**, on
  SDK 0.9.0: known bug, tracked at
  https://github.com/facebook/meta-wearables-dat-ios/issues/292. Workaround:
  set `exactVersion: 0.8.0` for the DAT package in `project.yml`, run
  `xcodegen generate` again, and rebuild.

## Alternative: build locally with xtool (WSL)

`xtool` (https://github.com/xtool-org/xtool) builds and signs SwiftPM
projects from WSL without GitHub Actions, but it needs a ~5 GB `Xcode.xip`
download from Apple first, its handling of the DAT SDK's binary
xcframeworks is unproven, and it has an open `@Observable` macro bug on
Linux — avoid that macro in this codebase if you plan to try it.
