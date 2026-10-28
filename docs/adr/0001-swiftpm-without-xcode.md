# ADR 0001. Swift Package and Command Line Tools instead of Xcode

## Context

The app has to be built with one command on a Mac that has only the Command Line Tools. The public repository must build the same way for anyone who clones it.

## Decision

The project is a Swift Package; there is no Xcode project. A script packs the built executable into an `.app` (its own `Info.plist`, ad-hoc signature), and the `Makefile` provides `make test`, `make app`, `make run`, `make install`. The language is Swift 6 with strict concurrency, the minimum system is macOS 26. Tests use Swift Testing. Anything that builds only in Xcode (asset catalogs, storyboards) is not used.

## Why

- Full Xcode takes tens of gigabytes, and for an app with no main window it gives nothing.
- A package description can be read in a diff, an Xcode project file cannot; a public repository benefits from a short manifest.
- One build command is the same for the developer, for a reader of the README and for the check before a commit.

Considered and rejected:

- **An Xcode project.** It needs Xcode installed, which breaks the original condition.
- **A project generator on top of Xcode (XcodeGen and similar).** It adds one more tool, and the build still has to go through Xcode.

## Consequences

- SwiftUI macros (`@State`, `@Entry`, `#Preview`) do not compile: the macro plugin ships only with Xcode. The same thing is written without a macro instead, and there are no previews in an editor.
- XCTest is not installed, so tests are Swift Testing only; `swift test` needs the path to the test macro plugin passed explicitly.
- Two simultaneous SwiftPM runs can corrupt the shared build cache ("macro plugin not found"); deleting the cache directory fixes it. Builds cannot run in parallel.
- The icon and resources have to be put into the package by hand, with no resource editor.
- The ad-hoc signature changes with a rebuild: system permissions (microphone, speech recognition, screen recording) and keychain access may be requested again. On someone else's Mac the first launch comes with a Gatekeeper warning.
- The macOS 26 minimum excludes everyone with an older system.
