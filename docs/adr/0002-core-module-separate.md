# ADR 0002. The BubblesCore module is separate from the app

## Context

Bubble physics, task parsing, ranking, the ladder and storage are logic that has to be tested without a screen, permissions or a running app.

## Decision

The package has two modules. `BubblesCore` is a library without AppKit and SwiftUI: only Foundation, CoreGraphics and Combine. It contains the models, the task store, settings, physics, ranking, the ladder schedule and the parsing of provider answers. `Bubbles` is the executable app: windows, views, speech, the keychain, launch at login. The dependency goes only from the app to the core. The core receives time, screen bounds and the network as parameters instead of taking them itself.

## Why

- A physics or ladder test runs in milliseconds and needs no screen, permissions or network.
- The ban on AppKit in the core keeps logic from growing into views: the glass colour is stored as RGB numbers, not as a system colour.
- The boundaries between modules are written down in `interfaces.md`, so independent pieces of work meet without coordination.

Considered and rejected:

- **One module.** Tests would drag in windows and system permissions, and over time the ladder rules would settle inside views, where they cannot be tested.
- **More modules (physics separately, parsing separately).** For a project this size that is extra manifests and boundaries with no benefit.

## Consequences

- Everything the app needs from the core has to be declared public: more ceremony than in a single module.
- The models know nothing about UI types, so conversions are needed at the seam (colour numbers to a colour, shapes to an outline).
- The core easily turns into a dumping ground for "everything that is not a view". The rule holds only by discipline: not a single AppKit or SwiftUI import in `BubblesCore`.
- What is covered by tests is set by the module boundary: windows, speech and the keychain lie outside and are checked by hand.
