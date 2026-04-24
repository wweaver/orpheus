# PianobarGUI

Native macOS Pandora client built on [pianobar](https://github.com/promyloph/pianobar).

## Development

Prerequisites:

    brew install pianobar xcodegen

Generate the Xcode project and run tests:

    xcodegen generate
    cd Packages/PianobarCore && swift test

Open `PianobarGUI.xcodeproj` in Xcode to build and run the app.
