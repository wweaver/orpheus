# Orpheus Plan 3 — Packaging & Distribution

> Drafted under the working title PianobarGUI; ships as Orpheus.
> The script names, paths, and product references below assume the
> original title — substitute "Orpheus" for the user-facing strings
> when (if) this plan is executed.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a signed, notarized, double-clickable `.app` with pianobar bundled inside — no Homebrew required on the end user's machine. Distribute via a GitHub release (DMG + appcast) and a Homebrew cask, with Sparkle-powered auto-update.

**Architecture:** Pianobar and its runtime libraries (libao, libfaad, libgcrypt, libgnutls, libjson-c) are built from source in a reproducible CI script, assembled into `Contents/Frameworks/` inside the `.app`, and re-signed so every Mach-O has the Developer ID identity the outer app uses. A universal (arm64 + x86_64) build is produced by building each dep twice and using `lipo` to merge. The signed `.app` is then notarized via `notarytool`, stapled, and packaged into a signed DMG. Sparkle 2 handles updates via an EdDSA-signed appcast hosted on GitHub Pages.

**Tech Stack:** bash/shell for the build script, Xcode 16+ for compiling and signing, `notarytool` for notarization, `create-dmg` for the installer image, Sparkle 2.x, GitHub Actions for CI.

---

## Prerequisites

Before starting Task 1:

- Plan 2 complete and merged to `main`. `swift test` shows 32/32 passing. `xcodebuild build` succeeds.
- **Apple Developer account** ($99/yr) — required for a Developer ID Application certificate, which is the only way to produce an installer users can double-click without right-click → "Open anyway" every time.
- Developer ID Application certificate in your Keychain (`security find-identity -p codesigning -v | grep "Developer ID Application"` returns a match).
- An App-specific password (or notarytool keychain profile) for automated notarization. See <https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow>.
- Homebrew on the build Mac (`brew install create-dmg xcodegen`).
- A GitHub repository with Pages enabled for serving the appcast.

If you don't have an Apple Developer account yet, Tasks 1-3 (bundling pianobar, producing a universal `.app`) still work — you just can't sign and notarize. The resulting `.app` will run locally but other users will need to right-click → Open the first time. Plan on getting the account before shipping.

## File Structure

Created during this plan:

```
scripts/
├── build-deps.sh           # Build pianobar + libs as universal binaries
├── bundle.sh               # Assemble .app with Frameworks/ and re-sign
├── sign-and-notarize.sh    # Developer ID sign + notarytool submit
├── make-dmg.sh             # Produce signed DMG
└── release.sh              # End-to-end: build-deps → bundle → sign → notarize → dmg
.github/
└── workflows/
    └── release.yml         # CI: runs on tag push, attaches DMG to release
appcast/
├── appcast.xml             # Sparkle feed (generated, hosted via GitHub Pages)
└── index.html              # Landing page (optional)
Packages/PianobarCore/
└── Package.swift            # modified to add Sparkle dependency
```

Modified files:

- `project.yml` — add Sparkle dependency, update runtime search paths so the bundled pianobar resolves its dylibs at `@executable_path/../Frameworks`.
- `App/PianobarGUIApp.swift` — initialize Sparkle's updater controller and expose a "Check for Updates…" menu item.
- `App/AppBootstrap.swift` — resolve the bundled pianobar binary path (`Bundle.main.url(forAuxiliaryExecutable: "pianobar")`) instead of Homebrew.
- `README.md` — replace the "Plan 1 scope" dev instructions with user-facing install steps.

---

### Task 1: Build pianobar and its deps as a universal binary

Produces a staging directory at `build/stage/` containing arm64+x86_64 universal `pianobar` and its required dylibs.

**Files:**
- Create: `scripts/build-deps.sh`

**Why from source, not Homebrew:** Homebrew's binaries are architecture-specific and Homebrew's install paths are baked into the dylibs' load commands. We need universal binaries with relocatable load paths so they work on both Intel and Apple Silicon Macs at any install location.

- [ ] **Step 1: Write `scripts/build-deps.sh`**

```bash
#!/usr/bin/env bash
# Build pianobar and its runtime dependencies as arm64+x86_64 universal
# binaries, staged at build/stage/ ready for app-bundle inclusion.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="$ROOT/build/stage"
SRC="$ROOT/build/src"
ARCHS=("arm64" "x86_64")

# Pinned versions — bump deliberately.
PIANOBAR_TAG="2024.12.21"
LIBAO_VER="1.2.2"
FAAD2_VER="2.11.1"
LIBGCRYPT_VER="1.11.0"
LIBGPG_ERROR_VER="1.50"
GNUTLS_VER="3.8.5"
NETTLE_VER="3.10"
GMP_VER="6.3.0"
JSONC_VER="0.17"

rm -rf "$STAGE" "$SRC"
mkdir -p "$STAGE/bin" "$STAGE/lib" "$SRC"

fetch() {
    local url=$1 dest=$2
    if [ ! -f "$dest" ]; then
        curl -fsSL -o "$dest" "$url"
    fi
}

build_arch() {
    local arch=$1 prefix=$2
    local cflags="-arch $arch -mmacosx-version-min=13.0"
    local ldflags="-arch $arch -mmacosx-version-min=13.0"
    local host
    case "$arch" in
        arm64)  host="aarch64-apple-darwin" ;;
        x86_64) host="x86_64-apple-darwin"  ;;
    esac

    # Each dep builds in its own per-arch prefix. We lipo them together at
    # the end.
    mkdir -p "$prefix"

    # ... (each dep's configure+make+install, with CFLAGS/LDFLAGS/host)
    # gmp → nettle → gnutls
    # libgpg-error → libgcrypt
    # libao
    # faad2
    # json-c
    # pianobar (links all of the above)
    #
    # Full dep build invocations expanded below.

    build_autotools_dep() {
        local name=$1 tarball=$2 url=$3 extra=${4:-}
        local dir="$SRC/$arch/$name"
        mkdir -p "$dir"
        fetch "$url" "$SRC/$tarball"
        tar -xf "$SRC/$tarball" -C "$dir" --strip-components=1
        pushd "$dir" > /dev/null
        CFLAGS="$cflags" LDFLAGS="$ldflags" \
            ./configure --host="$host" --prefix="$prefix" \
                        --enable-static --disable-shared \
                        $extra
        make -j"$(sysctl -n hw.ncpu)"
        make install
        popd > /dev/null
    }

    build_autotools_dep gmp         "gmp-$GMP_VER.tar.xz" \
        "https://ftp.gnu.org/gnu/gmp/gmp-$GMP_VER.tar.xz"

    build_autotools_dep nettle      "nettle-$NETTLE_VER.tar.gz" \
        "https://ftp.gnu.org/gnu/nettle/nettle-$NETTLE_VER.tar.gz" \
        "--disable-documentation"

    build_autotools_dep gnutls      "gnutls-$GNUTLS_VER.tar.xz" \
        "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-$GNUTLS_VER.tar.xz" \
        "--without-p11-kit --with-included-libtasn1 --with-included-unistring --disable-doc --disable-tests"

    build_autotools_dep libgpg-error "libgpg-error-$LIBGPG_ERROR_VER.tar.bz2" \
        "https://www.gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-$LIBGPG_ERROR_VER.tar.bz2"

    build_autotools_dep libgcrypt   "libgcrypt-$LIBGCRYPT_VER.tar.bz2" \
        "https://www.gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-$LIBGCRYPT_VER.tar.bz2" \
        "--with-libgpg-error-prefix=$prefix"

    build_autotools_dep libao       "libao-$LIBAO_VER.tar.gz" \
        "https://downloads.xiph.org/releases/ao/libao-$LIBAO_VER.tar.gz"

    build_autotools_dep json-c      "json-c-$JSONC_VER.tar.gz" \
        "https://s3.amazonaws.com/json-c_releases/releases/json-c-$JSONC_VER.tar.gz"

    # faad2: no autotools in recent versions; use cmake
    local faad2_dir="$SRC/$arch/faad2"
    mkdir -p "$faad2_dir"
    fetch "https://github.com/knik0/faad2/archive/refs/tags/$FAAD2_VER.tar.gz" \
          "$SRC/faad2-$FAAD2_VER.tar.gz"
    tar -xf "$SRC/faad2-$FAAD2_VER.tar.gz" -C "$faad2_dir" --strip-components=1
    cmake -S "$faad2_dir" -B "$faad2_dir/build" \
          -DCMAKE_OSX_ARCHITECTURES="$arch" \
          -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
          -DCMAKE_INSTALL_PREFIX="$prefix" \
          -DBUILD_SHARED_LIBS=OFF
    cmake --build "$faad2_dir/build" --target install

    # pianobar (Makefile-based, not autotools)
    local pianobar_dir="$SRC/$arch/pianobar"
    mkdir -p "$pianobar_dir"
    fetch "https://github.com/promyloph/pianobar/archive/refs/tags/$PIANOBAR_TAG.tar.gz" \
          "$SRC/pianobar-$PIANOBAR_TAG.tar.gz"
    tar -xf "$SRC/pianobar-$PIANOBAR_TAG.tar.gz" -C "$pianobar_dir" --strip-components=1
    pushd "$pianobar_dir" > /dev/null
    CFLAGS="$cflags -I$prefix/include" \
    LDFLAGS="$ldflags -L$prefix/lib" \
    PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
        make -j"$(sysctl -n hw.ncpu)"
    cp pianobar "$prefix/bin/pianobar"
    popd > /dev/null
}

# Per-arch builds into build/per-arch/<arch>/
for arch in "${ARCHS[@]}"; do
    prefix="$ROOT/build/per-arch/$arch"
    build_arch "$arch" "$prefix"
done

# Lipo into STAGE — for each file that exists in both per-arch dirs.
find "$ROOT/build/per-arch/${ARCHS[0]}/bin" -type f -perm +111 | while read -r f; do
    rel="${f#$ROOT/build/per-arch/${ARCHS[0]}/}"
    out="$STAGE/$rel"
    mkdir -p "$(dirname "$out")"
    lipo -create "$f" "$ROOT/build/per-arch/${ARCHS[1]}/$rel" -output "$out"
done
find "$ROOT/build/per-arch/${ARCHS[0]}/lib" -type f \( -name "*.dylib" -o -name "*.a" \) | while read -r f; do
    rel="${f#$ROOT/build/per-arch/${ARCHS[0]}/}"
    out="$STAGE/$rel"
    mkdir -p "$(dirname "$out")"
    if [[ "$f" == *.dylib ]]; then
        lipo -create "$f" "$ROOT/build/per-arch/${ARCHS[1]}/$rel" -output "$out"
    else
        # Static libs can stay per-arch; they're not shipped.
        cp "$f" "$out"
    fi
done

echo "✓ Universal binaries staged at $STAGE"
file "$STAGE/bin/pianobar"
```

- [ ] **Step 2: Make the script executable**

```bash
chmod +x scripts/build-deps.sh
```

- [ ] **Step 3: Run it**

```bash
./scripts/build-deps.sh
```
Expected output ends with `file $STAGE/bin/pianobar` showing:
```
…/pianobar: Mach-O universal binary with 2 architectures:
  (for architecture x86_64):    …
  (for architecture arm64):     …
```

This takes 10-20 minutes the first time; subsequent runs skip already-downloaded tarballs.

- [ ] **Step 4: Commit**

```bash
git add scripts/build-deps.sh
git commit -m "Add universal build script for pianobar and runtime dylibs"
```

---

### Task 2: Bundle pianobar into the `.app`

Copies the staged binary + dylibs into `Contents/MacOS/` / `Contents/Frameworks/` and rewrites their load paths so they resolve at runtime via `@executable_path/../Frameworks`.

**Files:**
- Create: `scripts/bundle.sh`
- Modify: `App/AppBootstrap.swift` — prefer the bundled pianobar over Homebrew at runtime.
- Modify: `project.yml` — add `LD_RUNPATH_SEARCH_PATHS` = `@executable_path/../Frameworks`.

- [ ] **Step 1: Write `scripts/bundle.sh`**

```bash
#!/usr/bin/env bash
# Place staged pianobar + dylibs into a built .app bundle and rewrite
# their @rpath / install_name load commands so they resolve at runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/build/Build/Products/Release/PianobarGUI.app}"
STAGE="$ROOT/build/stage"

if [ ! -d "$APP" ]; then
    echo "App bundle not found at $APP. Build the app first (xcodebuild)." >&2
    exit 1
fi

MACOS="$APP/Contents/MacOS"
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"

# Copy binary.
cp "$STAGE/bin/pianobar" "$MACOS/pianobar"
chmod +x "$MACOS/pianobar"

# Copy dylibs.
cp "$STAGE/lib/"*.dylib "$FRAMEWORKS/" 2>/dev/null || true

# Rewrite install_name on each dylib so pianobar can find it at
# @rpath/<name>. We set rpath on pianobar to @executable_path/../Frameworks.
for dylib in "$FRAMEWORKS"/*.dylib; do
    base=$(basename "$dylib")
    install_name_tool -id "@rpath/$base" "$dylib"
done

# Rewrite pianobar's load commands.
for dep in $(otool -L "$MACOS/pianobar" | awk 'NR>1 {print $1}' | grep -v "^/usr/lib\|^/System\|^@"); do
    base=$(basename "$dep")
    if [ -f "$FRAMEWORKS/$base" ]; then
        install_name_tool -change "$dep" "@rpath/$base" "$MACOS/pianobar"
    fi
done

# Ensure @executable_path/../Frameworks is in the rpath.
if ! otool -l "$MACOS/pianobar" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/pianobar"
fi

# Each dylib may depend on others; rewrite those too.
for dylib in "$FRAMEWORKS"/*.dylib; do
    for dep in $(otool -L "$dylib" | awk 'NR>1 {print $1}' | grep -v "^/usr/lib\|^/System\|^@"); do
        base=$(basename "$dep")
        if [ -f "$FRAMEWORKS/$base" ]; then
            install_name_tool -change "$dep" "@rpath/$base" "$dylib"
        fi
    done
done

echo "✓ Bundled pianobar into $APP"
echo "  Load commands (pianobar):"
otool -L "$MACOS/pianobar"
```

- [ ] **Step 2: Modify `project.yml` to set runtime search paths**

Inside the `PianobarGUI` target's `settings.base`, add:
```yaml
        LD_RUNPATH_SEARCH_PATHS: "@executable_path/../Frameworks"
```

Regenerate: `xcodegen generate`.

- [ ] **Step 3: Modify `App/AppBootstrap.swift` to prefer the bundled binary**

Replace `resolvePianobarPath()`:

```swift
private func resolvePianobarPath() -> String? {
    // Prefer the pianobar binary shipped inside the .app. Fall back to
    // Homebrew for dev builds where the binary hasn't been bundled yet.
    if let bundled = Bundle.main.url(forAuxiliaryExecutable: "pianobar"),
       FileManager.default.isExecutableFile(atPath: bundled.path) {
        return bundled.path
    }
    for candidate in ["/opt/homebrew/bin/pianobar", "/usr/local/bin/pianobar"] {
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}
```

- [ ] **Step 4: Test the bundle-and-run path**

```bash
chmod +x scripts/bundle.sh
xcodegen generate
xcodebuild -project PianobarGUI.xcodeproj -scheme PianobarGUI -destination 'platform=macOS' -configuration Release -derivedDataPath build build
./scripts/bundle.sh
open build/Build/Products/Release/PianobarGUI.app
```
Expected: the app launches, logs in, auto-resumes the last station, plays audio — without Homebrew's pianobar on the PATH. Verify with:
```bash
brew uninstall pianobar     # or temporarily move it out of the way
open build/Build/Products/Release/PianobarGUI.app
```

- [ ] **Step 5: Commit**

```bash
git add scripts/bundle.sh project.yml App/AppBootstrap.swift PianobarGUI.xcodeproj
git commit -m "Bundle pianobar + dylibs inside .app with @rpath fixups"
```

---

### Task 3: Sign and notarize

**Files:**
- Create: `scripts/sign-and-notarize.sh`
- Create: `App/PianobarGUI.entitlements`

- [ ] **Step 1: Write `App/PianobarGUI.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key>
    <false/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <false/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
```

Rationale: `disable-library-validation` is needed because the bundled dylibs are signed with our Developer ID, not Apple's — hardened runtime otherwise refuses to load them. `network.client` is required for pianobar's Pandora API calls and album art fetches.

- [ ] **Step 2: Update `project.yml` to point at the entitlements file**

In the `PianobarGUI` target's `settings.base`:
```yaml
        CODE_SIGN_ENTITLEMENTS: App/PianobarGUI.entitlements
```

- [ ] **Step 3: Write `scripts/sign-and-notarize.sh`**

```bash
#!/usr/bin/env bash
# Sign every Mach-O in the .app (dylibs first, outer app last), submit to
# notarytool, and staple the ticket. Requires:
#   - DEVELOPER_ID: the Developer ID Application identity (e.g.
#     "Developer ID Application: William Weaver (TEAMID123)")
#   - NOTARY_PROFILE: the keychain profile configured via
#     `xcrun notarytool store-credentials`
set -euo pipefail

APP="${1:-build/Build/Products/Release/PianobarGUI.app}"
: "${DEVELOPER_ID:?DEVELOPER_ID env var required}"
: "${NOTARY_PROFILE:?NOTARY_PROFILE env var required}"

ENTITLEMENTS="App/PianobarGUI.entitlements"

echo "▶︎ Signing dylibs"
for dylib in "$APP/Contents/Frameworks/"*.dylib; do
    codesign --force --timestamp --options runtime \
             --sign "$DEVELOPER_ID" "$dylib"
done

echo "▶︎ Signing bundled pianobar"
codesign --force --timestamp --options runtime \
         --entitlements "$ENTITLEMENTS" \
         --sign "$DEVELOPER_ID" "$APP/Contents/MacOS/pianobar"

echo "▶︎ Signing outer app"
codesign --force --timestamp --options runtime \
         --entitlements "$ENTITLEMENTS" \
         --sign "$DEVELOPER_ID" "$APP"

echo "▶︎ Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "▶︎ Submitting to notarytool"
ZIP="$(dirname "$APP")/$(basename "$APP" .app).zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "▶︎ Stapling ticket"
xcrun stapler staple "$APP"
rm -f "$ZIP"

echo "✓ Signed, notarized, stapled: $APP"
spctl --assess --type execute --verbose=2 "$APP"
```

- [ ] **Step 4: Store notarization credentials (one time)**

```bash
xcrun notarytool store-credentials pianobar-gui-notary \
    --apple-id "<your-apple-id>" \
    --team-id "<TEAMID>" \
    --password "<app-specific-password>"
```

- [ ] **Step 5: Run end-to-end**

```bash
chmod +x scripts/sign-and-notarize.sh
export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE="pianobar-gui-notary"
./scripts/sign-and-notarize.sh
```
Expected final line: `source=Notarized Developer ID`.

- [ ] **Step 6: Commit**

```bash
git add App/PianobarGUI.entitlements scripts/sign-and-notarize.sh project.yml PianobarGUI.xcodeproj
git commit -m "Add hardened-runtime entitlements and sign/notarize script"
```

---

### Task 4: DMG installer

**Files:**
- Create: `scripts/make-dmg.sh`

- [ ] **Step 1: Write `scripts/make-dmg.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
APP="${1:-build/Build/Products/Release/PianobarGUI.app}"
: "${DEVELOPER_ID:?DEVELOPER_ID env var required}"

VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
DMG="build/PianobarGUI-$VERSION.dmg"

rm -f "$DMG"
create-dmg \
    --volname "PianobarGUI $VERSION" \
    --window-pos 200 120 \
    --window-size 540 360 \
    --icon-size 120 \
    --icon "PianobarGUI.app" 140 180 \
    --hide-extension "PianobarGUI.app" \
    --app-drop-link 400 180 \
    "$DMG" "$APP"

echo "▶︎ Signing DMG"
codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"

echo "▶︎ Notarizing DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "✓ Ready: $DMG"
```

- [ ] **Step 2: Install create-dmg if needed**

```bash
brew install create-dmg
```

- [ ] **Step 3: Run and verify**

```bash
chmod +x scripts/make-dmg.sh
./scripts/make-dmg.sh
open build/PianobarGUI-*.dmg
```
Expected: mounts a window with the app icon and an Applications shortcut. `spctl --assess --type open --context context:primary-signature -v build/PianobarGUI-*.dmg` reports `accepted`.

- [ ] **Step 4: Commit**

```bash
git add scripts/make-dmg.sh
git commit -m "Add signed + notarized DMG build script"
```

---

### Task 5: Sparkle auto-update

**Files:**
- Modify: `Packages/PianobarCore/Package.swift` (add Sparkle dep) — actually Sparkle is an Xcode framework; cleaner to add via project.yml.
- Modify: `project.yml` — add Sparkle via SPM dependency.
- Modify: `App/PianobarGUIApp.swift` — instantiate `SPUStandardUpdaterController`, add menu item.
- Create: `appcast/appcast.xml`
- Create: `scripts/release.sh` (end-to-end: build → bundle → sign → dmg → appcast)

- [ ] **Step 1: Add Sparkle SPM dependency to `project.yml`**

```yaml
packages:
  PianobarCore:
    path: Packages/PianobarCore
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: "2.6.0"
```

In the `PianobarGUI` target's `dependencies`:
```yaml
      - package: PianobarCore
      - package: Sparkle
        product: Sparkle
```

Regenerate: `xcodegen generate`.

- [ ] **Step 2: Generate a Sparkle EdDSA key pair (one time)**

Sparkle's `generate_keys` tool lives in the checked-out SPM package after an Xcode build. After `xcodegen generate && xcodebuild … build`:

```bash
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -name generate_keys -perm +111 | head -n1)
"$SPARKLE_BIN"
```

It prints a public key to paste into `Info.plist` and stores the private key in your Keychain.

- [ ] **Step 3: Add Sparkle keys to `Info.plist` via `project.yml`**

In the app target's `info.properties`:
```yaml
        SUFeedURL: https://<your-username>.github.io/pianobar-gui/appcast.xml
        SUPublicEDKey: <paste-from-generate_keys-output>
        SUEnableAutomaticChecks: true
```

Regenerate.

- [ ] **Step 4: Modify `App/PianobarGUIApp.swift`**

Add `import Sparkle`, then inside the `App`:

```swift
@main
struct PianobarGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var bootstrap = AppBootstrap()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    // ... existing init and body ...

    var body: some Scene {
        // ... existing WindowGroup and Settings ...

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(bootstrap)
            Divider()
            Button("Check for Updates…") {
                updaterController.checkForUpdates(nil)
            }
        } label: {
            MenuBarLabel().environmentObject(bootstrap)
        }
        .menuBarExtraStyle(.menu)
    }
}
```

- [ ] **Step 5: Write an initial `appcast/appcast.xml`**

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>PianobarGUI</title>
        <link>https://<your-username>.github.io/pianobar-gui/appcast.xml</link>
        <description>PianobarGUI updates</description>
        <language>en</language>
        <!-- Items are appended by scripts/release.sh for each release -->
    </channel>
</rss>
```

- [ ] **Step 6: Write `scripts/release.sh` that automates the full cycle**

```bash
#!/usr/bin/env bash
set -euo pipefail
: "${DEVELOPER_ID:?required}"
: "${NOTARY_PROFILE:?required}"
: "${SPARKLE_PRIVATE_KEY_FILE:?required}"

VERSION="$1"
[ -z "$VERSION" ] && { echo "Usage: $0 <version>"; exit 1; }

# Bump Info.plist version — we prefer xcodegen-managed values.
sed -i '' "s/CFBundleShortVersionString: .*/CFBundleShortVersionString: \"$VERSION\"/" project.yml
xcodegen generate

./scripts/build-deps.sh
xcodebuild -project PianobarGUI.xcodeproj -scheme PianobarGUI -destination 'platform=macOS' -configuration Release -derivedDataPath build build
./scripts/bundle.sh
./scripts/sign-and-notarize.sh
./scripts/make-dmg.sh

DMG="build/PianobarGUI-$VERSION.dmg"
SIGN_TOOL=$(find ~/Library/Developer/Xcode/DerivedData -name sign_update -perm +111 | head -n1)
SIGNATURE=$("$SIGN_TOOL" "$DMG" -f "$SPARKLE_PRIVATE_KEY_FILE")

# Append item to appcast/appcast.xml
LENGTH=$(stat -f%z "$DMG")
PUBDATE=$(date -R)
cat >> /tmp/appcast-item.xml <<EOF
        <item>
            <title>Version $VERSION</title>
            <pubDate>$PUBDATE</pubDate>
            <sparkle:version>$VERSION</sparkle:version>
            <enclosure
                url="https://github.com/<user>/pianobar-gui/releases/download/v$VERSION/PianobarGUI-$VERSION.dmg"
                length="$LENGTH"
                type="application/x-apple-diskimage"
                $SIGNATURE />
        </item>
EOF
# Insert before </channel>
sed -i '' "/<\/channel>/i\\
$(cat /tmp/appcast-item.xml)
" appcast/appcast.xml

echo "✓ Release $VERSION ready."
echo "  DMG:     $DMG"
echo "  Appcast: appcast/appcast.xml"
echo "  Publish by committing appcast.xml and attaching the DMG to a GitHub release."
```

- [ ] **Step 7: Commit**

```bash
chmod +x scripts/release.sh
git add project.yml App/PianobarGUIApp.swift appcast/ scripts/release.sh PianobarGUI.xcodeproj
git commit -m "Integrate Sparkle for auto-update and add release script"
```

---

### Task 6: GitHub Actions CI

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Write `.github/workflows/release.yml`**

```yaml
name: Release
on:
  push:
    tags: ['v*']

jobs:
  release:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Import signing certificate
        env:
          DEVELOPER_ID_BASE64: ${{ secrets.DEVELOPER_ID_BASE64 }}
          DEVELOPER_ID_PASSWORD: ${{ secrets.DEVELOPER_ID_PASSWORD }}
        run: |
          echo "$DEVELOPER_ID_BASE64" | base64 -d > /tmp/cert.p12
          security create-keychain -p actions build.keychain
          security default-keychain -s build.keychain
          security unlock-keychain -p actions build.keychain
          security import /tmp/cert.p12 -k build.keychain -P "$DEVELOPER_ID_PASSWORD" -T /usr/bin/codesign
          security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k actions build.keychain
      - name: Store notary credentials
        env:
          APPLE_ID: ${{ secrets.APPLE_ID }}
          TEAM_ID: ${{ secrets.TEAM_ID }}
          APP_PASSWORD: ${{ secrets.APP_PASSWORD }}
        run: |
          xcrun notarytool store-credentials pianobar-gui-notary \
              --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD"
      - name: Install build tools
        run: brew install create-dmg xcodegen
      - name: Build universal dylibs
        run: ./scripts/build-deps.sh
      - name: Xcode build
        run: |
          xcodegen generate
          xcodebuild -project PianobarGUI.xcodeproj -scheme PianobarGUI \
                     -destination 'platform=macOS' -configuration Release \
                     -derivedDataPath build build
      - name: Bundle pianobar
        run: ./scripts/bundle.sh
      - name: Sign and notarize
        env:
          DEVELOPER_ID: ${{ secrets.DEVELOPER_ID }}
          NOTARY_PROFILE: pianobar-gui-notary
        run: ./scripts/sign-and-notarize.sh
      - name: Make DMG
        env:
          DEVELOPER_ID: ${{ secrets.DEVELOPER_ID }}
          NOTARY_PROFILE: pianobar-gui-notary
        run: ./scripts/make-dmg.sh
      - name: Create GitHub release
        uses: softprops/action-gh-release@v2
        with:
          files: build/PianobarGUI-*.dmg
```

Secrets required in the GitHub repo settings (Settings → Secrets and variables → Actions):
- `DEVELOPER_ID_BASE64`, `DEVELOPER_ID_PASSWORD` — `.p12` export of the cert, base64-encoded.
- `APPLE_ID`, `TEAM_ID`, `APP_PASSWORD` — notarization credentials.
- `DEVELOPER_ID` — string like `Developer ID Application: Your Name (TEAMID)`.

- [ ] **Step 2: Test with a draft tag**

Push a throwaway tag (e.g., `v0.1.0-dev`) and watch the action. First run reveals missing secrets or script bugs.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "Add GitHub Actions release workflow"
```

---

### Task 7: Homebrew cask

Optional but recommended — most Mac devs install apps via Homebrew.

**Files:**
- Create: A new file in the `homebrew-cask` tap (separate repo).

- [ ] **Step 1: Create the cask file**

File: `Casks/pianobar-gui.rb` in a repo named `homebrew-<your-tap>` (e.g., `homebrew-pianobar-gui`).

```ruby
cask "pianobar-gui" do
  version "1.0.0"
  sha256 "<sha256 of the .dmg>"

  url "https://github.com/<user>/pianobar-gui/releases/download/v#{version}/PianobarGUI-#{version}.dmg"
  name "PianobarGUI"
  desc "Native macOS Pandora client built on pianobar"
  homepage "https://github.com/<user>/pianobar-gui"

  app "PianobarGUI.app"

  zap trash: [
    "~/Library/Application Support/PianobarGUI",
    "~/Library/Logs/PianobarGUI",
    "~/Library/Preferences/org.pianobar-gui.PianobarGUI.plist",
  ]
end
```

`sha256` is the DMG's hash. Compute with `shasum -a 256 build/PianobarGUI-1.0.0.dmg`.

- [ ] **Step 2: Install and verify**

```bash
brew tap <user>/pianobar-gui
brew install --cask pianobar-gui
open /Applications/PianobarGUI.app
```

- [ ] **Step 3: Commit (in the tap repo)**

```bash
git add Casks/pianobar-gui.rb
git commit -m "Add PianobarGUI cask"
git push
```

---

### Task 8: Update README for end users

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace current README with user-facing copy**

```markdown
# PianobarGUI

A native macOS Pandora client built on [pianobar](https://github.com/promyloph/pianobar).
Menu-bar presence, media-key control, Now Playing widget, notifications, station
list, thumbs up/down, history, and pause-on-quit/resume-on-launch.

## Install

### Homebrew (recommended)

    brew install --cask <user>/pianobar-gui/pianobar-gui

### Direct download

Grab the latest `.dmg` from [Releases](https://github.com/<user>/pianobar-gui/releases).
Drag PianobarGUI.app to /Applications, launch, and sign in with your Pandora
account.

## Requirements

- macOS 13 Ventura or later (Intel or Apple Silicon).
- An active Pandora account.

## Development

    brew install xcodegen
    xcodegen generate
    cd Packages/PianobarCore && swift test
    open ../../PianobarGUI.xcodeproj

Building a release locally:

    ./scripts/release.sh 1.2.3

Requires a Developer ID cert and notarytool keychain profile — see
`docs/superpowers/plans/2026-04-24-pianobar-gui-plan-3-packaging.md`.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "Rewrite README for end users"
```

---

## Plan 3 Done Criteria

- A user can download the DMG, drag PianobarGUI.app to /Applications, and run it with no extra installation steps.
- Gatekeeper accepts the app on a fresh Mac: `spctl --assess --type execute -v /Applications/PianobarGUI.app` → `source=Notarized Developer ID`.
- pianobar is bundled inside the `.app`; `brew uninstall pianobar` doesn't affect the app.
- CI release workflow produces signed DMGs on tag push.
- Sparkle's "Check for Updates…" menu item works end-to-end against a published appcast.
- Homebrew cask installs and launches successfully.

At that point, PianobarGUI is a real Mac app. Subsequent plans (Plan 4+) would be feature work — scrobbling, sleep timer, full hotkey recorder UI, lyrics, etc.
