# Elva Scanner – technical documentation

This document is for developers and maintainers. End-user documentation is in [README.md](README.md).

- [1. Overview](#1-overview)
- [2. Repository layout](#2-repository-layout)
- [3. How scanning works](#3-how-scanning-works)
- [4. The app](#4-the-app)
- [5. Building](#5-building)
- [6. Code signing and notarization](#6-code-signing-and-notarization)
- [7. Releases (manual and GitHub Actions)](#7-releases)
- [8. Updates](#8-updates)
- [9. Testing](#9-testing)
- [10. Adding or verifying scanner models](#10-adding-or-verifying-scanner-models)
- [11. Troubleshooting](#11-troubleshooting)
- [12. Credits and licensing](#12-credits-and-licensing)

## 1. Overview

Elva Scanner is a native SwiftUI app (macOS 15+, built and tested on macOS 26 Tahoe) with two ways
to reach a scanner:

| Route | Used for | Implementation |
|---|---|---|
| **Elva driver** | Canon PIXMA/MAXIFY network models whose Mac driver is no longer maintained (e.g. MG7150) | `PixmaKit`: Canon BJNP transport + PIXMA scan protocol, written from scratch in Swift |
| **via macOS** | Anything Image Capture can see: AirPrint/eSCL scanners and devices with an installed ICA driver | `ICABackend` on top of `ImageCaptureCore` |

Both routes feed the same pipeline: preview → area selection / auto-crop → scan → non-destructive
corrections → save as document (PDF/TIFF) or photos (JPEG/HEIC/PNG/TIFF).

## 2. Repository layout

```
Package.swift                 SwiftPM package (no Xcode project needed)
VERSION                       app version used by the build scripts
Sources/
  PixmaKit/                   protocol library (no UI)
    BJNPConnection.swift        BJNP over UDP/TCP 8612
    PixmaScanner.swift          PIXMA command set, scan sequence, line assembly
    Models.swift                model profiles, IEEE-1284 parsing, errors, request types
    ModelTable.swift            GENERATED list of ~190 supported models
    Discovery.swift             Bonjour + subnet sweep + AirScan host detection
    RawImage+CG.swift           memory-mapped raw scan → CGImage
  elvascan/                   command-line tool (discovery, diagnostics, scripted scans)
  ElvaScanner/                the app
    Backends/                   ScannerBackend protocol, PixmaBackend, ICABackend, ScannerManager
    Model/                      settings, modes, pages, AppModel (workflow), localization,
                                update checker, self-test
    Processing/                 Core Image pipeline, item detector (auto-crop), exporter + OCR
    Views/                      SwiftUI
    Resources/                  Info.plist, InfoPlist.strings (en, tr)
Tests/PixmaKitTests/          unit tests
scripts/                      build, DMG, notarization, release, icon and model-table generators
.github/workflows/            CI (build + test) and release automation
assets/                       README images
```

## 3. How scanning works

### 3.1 Why a custom driver

The MG7150 (2013) only scans over Canon's proprietary **BJNP** protocol; it does not offer
AirPrint scanning (eSCL, `_uscan._tcp`). Canon's last MG7100-series Mac driver was an Intel-only
ICA bundle for macOS ≤ 10.15, and Canon's current ICA 5.x drivers don't list the model, so on modern
macOS the scanner is invisible. `PixmaKit` implements the protocol directly.

### 3.2 BJNP transport (`BJNPConnection`)

Every packet starts with a 16-byte header:

```
"BJNP" | devType (2 = scanner) | command | status (2) | sequence (2) | session (2) | payload length (4)
```

| Command | Transport | Purpose |
|---|---|---|
| `0x01` discover | UDP | MAC address (also used by the subnet sweep) |
| `0x30` get ID | UDP | IEEE-1284 device ID, e.g. `MFG:Canon;CMD:MultiPass 2.1,IVEC;MDL:MG7100 series;…` |
| `0x10` job details | UDP | host/user/job title; the reply carries the TCP session ID |
| `0x21` send / `0x20` request | TCP 8612 | scanner commands / pull response data |
| `0x11` close | UDP | ends the session |

Observed behaviour that the code relies on:

- **Job-details status `0x8502`** means another session still owns the scanner. While it does, the
  scanner refuses TCP connections. A BJNP *close* releases a stale session; the driver sends one and
  retries once.
- The scanner never answers a TCP *request* when it has no data, so the driver always computes the
  exact response length (from the PIXMA header) instead of polling.

### 3.3 PIXMA scan protocol (`PixmaScanner`)

Commands are `be16 code | 0[10] | be16 length | data… | checksum` (data sums to 0 mod 256); replies
start with a status (`0x0606` OK, `0x1414` busy, `0x1515` failed/cancelled).

Scan sequence for protocol generations 3–5:

1. Generation 4+: XML `StartJob` and `ModeShift` dialogs. `PCScanning`/`DeviceBusy` answers mean the
   previous job is still closing; the driver retries for 30 s.
2. `0xDB20` start session (retry while busy).
3. `0xEE20` gamma table ×3 (1024 × 16-bit LE).
4. `0xD820` scan parameters: resolution, origin, raw width, height, colour/gray, calibration flag.
5. `0xD920` start scan, then poll `0xDA20` status until calibration/warm-up is done.
6. `0xD420` read image blocks (≤ 512 KiB) until the end-of-image flags `0x28` are set.
7. `0xEF20` abort/finish session, XML `EndJob`, BJNP close.

Geometry details:

- Resolutions are 75 × 2ⁿ up to the model's optical maximum (2400 dpi for the MG7150).
- The X origin is 32-pixel aligned and lines are padded to a multiple of 32 pixels; the driver
  over-scans to the left and crops.
- Models with `interleaveUnit > 0` (generation 3/4 and a few generation-5 models) send lines above
  600 dpi as interleaved sub-images; `PixmaScanner.deinterleave` restores pixel order. The MG7150 does not.
- Raw lines are streamed to a temporary file and memory-mapped, so a full-page 2400 dpi scan
  (~1.7 GB) never has to fit in RAM.

### 3.4 Discovery (`ScannerDiscovery`)

1. **Bonjour** (`_scanner._tcp`, `_canon-bjnp1._tcp`) through mDNSResponder.
2. **Subnet sweep**: BJNP *discover* to every host of each local /22-or-smaller IPv4 subnet, in
   batches of 128, over **connected** UDP sockets. A broadcast would be simpler, but the macOS
   application firewall drops unsolicited replies to apps that aren't Developer-ID signed; replies on a
   connected socket count as part of an outgoing flow.
3. **AirScan hosts** (`_uscan._tcp`, `_uscans._tcp`): a Canon that is *not* in the model table but
   offers AirScan is left to the macOS route instead of getting an experimental native profile.

### 3.5 Image Capture route (`ICABackend`)

- Opening a session is shared between concurrent callers and times out after 30 s.
- After the session opens, the device announces its functional unit by itself (`didSelect`).
  **Settings and scan requests sent before that callback are silently ignored**, so `prepare()` waits
  for it.
- Feeder scans deliver one file per page (or one multi-page TIFF); every image becomes a page.
  Duplex is enabled when `ICScannerFunctionalUnitDocumentFeeder.supportsDuplexScanning`.

## 4. The app

| Area | Files | Notes |
|---|---|---|
| Workflow | `Model/AppModel.swift` | preview → auto-crop, multi-area scans (one pass, cut into pages), batch mode, save flow |
| Modes | `Model/ScanSettings.swift` (`ScanMode`) | Photo, Document, B&W Document, Magazine, Color/B&W Negative; each sets dpi, colour, corrections, save defaults and tips |
| Auto-crop / Split Photos | `Processing/ItemDetector.swift` | foreground mask vs. lid colour → 1.5 mm grid → dilation → connected components; boxes near the glass edge snap to it |
| Corrections | `Processing/ImageProcessor.swift` | Core Image in gamma-encoded sRGB; negatives via per-channel levels (removes the orange mask) |
| Saving | `Processing/Exporter.swift`, `Views/SaveSheet.swift` | PDF pages embedded as JPEG; OCR text layer (Vision) drawn invisibly; multi-page TIFF (LZW) |
| Localization | `Model/Localization.swift` | in-app switchable English/Turkish; `L("English text")` lookups |
| Updates | `Model/UpdateChecker.swift` | see [§8](#8-updates) |

Settings are stored as JSON in `UserDefaults` (`ScanSettings.v2`) with tolerant decoding, so new
fields never reset existing preferences.

## 5. Building

Requirements: macOS 15+, Xcode 26 (Swift 6 toolchain; the app is built with the macOS 26 SDK so it
gets the Tahoe look).

```sh
swift build                          # debug build of everything
swift test                           # unit tests
scripts/build-app.sh                 # universal "build/Elva Scanner.app"
scripts/build-app.sh --install       # … and copy to /Applications
scripts/make-dmg.sh                  # build/Elva-Scanner.dmg (+ .sha256)
```

`build-app.sh` builds for `arm64` and `x86_64`, writes `VERSION`/build number into `Info.plist`,
generates the icon (`scripts/make-icon.swift`) and signs: with the first **Developer ID Application**
identity in the keychain (hardened runtime, timestamp) or ad-hoc when there is none. Override with
`SIGN_IDENTITY`, `VERSION`, `BUILD_NUMBER`, `ARCHS`.

## 6. Code signing and notarization

Apps distributed outside the Mac App Store need a **Developer ID Application** certificate and
**notarization**; otherwise Gatekeeper blocks the first launch (users then have to use *Open Anyway*).

### 6.1 One-time setup (Apple Developer Program, account holder)

1. **Create the certificate.** Xcode → Settings → Accounts → select the team → *Manage Certificates…*
   → **+** → **Developer ID Application**. (Only the team's *Account Holder* can create it; it can also
   be made at developer.apple.com → Certificates.) Check with:
   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
2. **Create notarization credentials.** Make an app-specific password at
   [account.apple.com](https://account.apple.com) → Sign-In and Security → App-Specific Passwords, then:
   ```sh
   xcrun notarytool store-credentials elva-notary \
     --apple-id "you@example.com" --team-id "TEAMID" --password "abcd-efgh-ijkl-mnop"
   ```
   This stores the credentials in the login keychain under the profile name `elva-notary`, which
   `scripts/notarize.sh` uses by default (`NOTARY_PROFILE` overrides it).

### 6.2 What `scripts/release.sh` does with them

1. Signs `elvascan` and the app with `--options runtime --timestamp` and `scripts/Elva.entitlements`
   (empty: the app is not sandboxed and needs no hardened-runtime exceptions).
2. Zips the app, submits it with `notarytool --wait`, staples the ticket to the app.
3. Builds the DMG, signs it, notarizes it, staples it, and checks it with `spctl`.

Without a Developer ID identity the script still produces a working, ad-hoc signed DMG and says so
in the release notes.

Notarization normally takes a few minutes, but the **first submissions from a new Developer ID can
stay "In Progress" for hours** (Elva's first one took several hours). `notarize.sh` waits up to 3 h;
if it still times out, the submission keeps running at Apple. Check it with
`xcrun notarytool info <submission-id> --keychain-profile elva-notary`, and once it is *Accepted*
run `xcrun stapler staple "build/Elva Scanner.app"` and continue with `scripts/make-dmg.sh` and
`scripts/notarize.sh build/Elva-Scanner.dmg`.

### 6.3 GitHub Actions secrets (optional)

To sign and notarize in CI, add these repository secrets (Settings → Secrets and variables → Actions):

| Secret | Content |
|---|---|
| `MACOS_CERTIFICATE_P12` | base64 of the exported Developer ID certificate + private key (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERTIFICATE_PASSWORD` | the .p12 export password |
| `NOTARY_KEY_P8` | base64 of an App Store Connect API key (`AuthKey_XXXX.p8`, role *Developer*) |
| `NOTARY_KEY_ID` | the key ID |
| `NOTARY_ISSUER_ID` | the issuer ID (App Store Connect → Users and Access → Integrations) |

Export the certificate from Keychain Access (*My Certificates* → right-click → Export → .p12).
Without these secrets the workflow still builds and publishes an ad-hoc signed DMG.

## 7. Releases

The download button in the README points to
`https://github.com/qokalp/elva-macos-scanner/releases/latest/download/Elva-Scanner.dmg`, so **every
release must upload an asset named exactly `Elva-Scanner.dmg`** (the scripts do).

**Manual (recommended while CI has no signing secrets):**

```sh
echo "1.0.1" > VERSION
git commit -am "Release 1.0.1" && git tag v1.0.1 && git push --follow-tags
scripts/release.sh --publish        # tests, builds, signs, notarizes, creates GitHub release v1.0.1
```

**Automatic:** pushing a tag `v*` runs `.github/workflows/release.yml` on a GitHub macOS runner.
The workflow takes the version from the tag, runs the tests, builds, signs and notarizes when the
secrets exist, and creates or updates the GitHub release with `Elva-Scanner.dmg` and its SHA-256.
`.github/workflows/ci.yml` builds and tests every push and pull request.

## 8. Updates

Updates are deliberately simple: users download the new DMG and replace the app; settings live in
`UserDefaults` (`com.qokalp.ElvaScanner`) and survive.

`UpdateChecker` asks `api.github.com/repos/qokalp/elva-macos-scanner/releases/latest` at most once a
day (and from *Elva Scanner → Check for Updates…*), compares the tag (`v1.2.3`) with
`CFBundleShortVersionString`, and shows an alert with a download link when a newer version exists.
It can be turned off in *Advanced*. No other data is sent. (A Sparkle-based in-place updater could
be added later; it would need an EdDSA signing key and an appcast.)

## 9. Testing

```sh
swift test                                              # protocol, geometry, model table, deinterleave
swift run elvascan discover                             # Bonjour + sweep
swift run elvascan info 192.168.1.40                    # identity and model profile
swift run elvascan scan 192.168.1.40 --dpi 300 -v -o test.png
ELVA_SELFTEST=/tmp/elva.pdf "build/Elva Scanner.app/Contents/MacOS/ElvaScanner"
```

The **self-test** drives the real app code against the first scanner it finds: preview, item
detection, multi-area scan, searchable PDF, then the same flow through `AppModel` (mode → preview +
auto-crop → Split Photos → scan) and, if present, the Image Capture route. It writes a log next to the
PDF and quits.

Hardware verification status: Canon PIXMA MG7150 (firmware 4.060) over Wi-Fi at 75–2400 dpi, colour
and gray, offset crops, back-to-back scans; Image Capture route through an AirScan bridge for the
same printer. No HP/Brother/Epson hardware has been tested.

## 10. Adding or verifying scanner models

`Sources/PixmaKit/ModelTable.swift` is generated from SANE's `pixma_mp150.c` device table (model names,
USB product IDs, resolution limits, glass sizes; only protocol generations 3–5):

```sh
git clone https://gitlab.com/sane-project/backends.git /tmp/sane
scripts/generate-model-table.py /tmp/sane/backend/pixma/pixma_mp150.c
```

When a user confirms a model works, add its token (e.g. `"MX920"`) to `PixmaModel.verifiedModels`.
Models not in the table get an experimental generic profile (A4, 1200 dpi, generation 5) unless they
offer AirScan.

Not supported: USB-only devices (the app has no USB transport), Canon models that use other SANE
sub-drivers (`mp810`, `mp750`, `mp730`, imageCLASS/i-SENSYS), PIXMA document feeders (flatbed only),
48-bit scanning.

## 11. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| No scanner found | Local Network permission denied: System Settings → Privacy & Security → Local Network → enable Elva Scanner. Router client isolation also blocks discovery; try *Add Manually…* |
| "Reserved by another job or app" | Another program (Canon IJ Scan Utility, VueScan, an AirScan bridge) holds the BJNP session. Close it or wait. |
| Same printer listed twice | It is reachable natively and via AirPrint; both work. "Elva driver" offers more options. |
| Image Capture scanner never starts | Check that it works in Apple's Image Capture app; the ICA route has 30 s time-outs and reports an error instead of hanging. |
| Gatekeeper blocks the app | The build isn't notarized; see §6 or use *Open Anyway*. |

Logs: run the binary from Terminal (`"/Applications/Elva Scanner.app/Contents/MacOS/ElvaScanner"`) or use
`elvascan … -v` for protocol traces.

## 12. Credits and licensing

Elva Scanner is MIT-licensed (see [LICENSE](LICENSE)). The PIXMA/BJNP protocol knowledge comes from
the [SANE project](https://gitlab.com/sane-project/backends)'s `pixma` backend (GPL), which documents
what Canon never published. PixmaKit is an independent Swift implementation and contains no SANE code;
the model table reproduces factual data (model names, IDs, limits) from SANE's device list.
Canon, PIXMA, MAXIFY and other names are trademarks of their owners.
