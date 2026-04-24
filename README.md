# PianobarGUI

Native macOS Pandora client built on [pianobar](https://github.com/promyloph/pianobar).

## Development

Prerequisites:

    brew install pianobar xcodegen

Generate the Xcode project and run tests:

    xcodegen generate
    cd Packages/PianobarCore && swift test

Open `PianobarGUI.xcodeproj` in Xcode to build and run the app.

## Running the app (Plan 1 scope)

The app requires pianobar to be installed on the dev machine until Plan 3
bundles it. With `brew install pianobar` in place, run:

    xcodegen generate
    xcodebuild -project PianobarGUI.xcodeproj -scheme PianobarGUI \
               -destination 'platform=macOS' -configuration Debug \
               -derivedDataPath build build
    open build/Build/Products/Debug/PianobarGUI.app

Credentials are stored in the macOS Keychain under the service
`org.pianobar-gui.PianobarGUI.pandora`.

## Running tests

    cd Packages/PianobarCore
    swift test
