# ADR 0004. Core Animation and a display link instead of redrawing SwiftUI

## Context

The first version moved the physics with a 60 Hz timer and redrew SwiftUI from published state. The bubbles moved in jerks.

## Decision

The frame is tied to the display refresh rate (a display link). The physics is computed in substeps of fixed length, and for display the position is interpolated between them. The position, rotation and squash of each bubble are set by Core Animation layer properties; the SwiftUI tree is not rebuilt because of motion. SwiftUI stays for the panel windows: dictation, "Got it", the task card, settings.

## Why

- A timer does not match the display refresh, so frames are repeated and skipped. That is the visible jitter.
- Publishing the state of all bubbles 60 times a second makes SwiftUI recompute views on every frame; a layer with a changed property needs no redrawing.
- Substeps with interpolation make the motion the same on screens with different refresh rates and keep bubbles from flying through each other.

Considered and rejected:

- **Keep the timer and lighten the views.** It does not remove the desync with the display.
- **`TimelineView` or `Canvas` in SwiftUI.** Views are still re-evaluated on every frame, and a shape and glass with a hundred details per bubble make that expensive.

## Consequences

- Rendering is split into two worlds: layers for the desk and the surfaced bubble, SwiftUI for everything else. The shape, glass, highlight and text of a bubble are implemented on layers, which is more hand-written code.
- The display link is tied to a screen: on a screen change, sleep and wake it has to be created again.
- The physics must not depend on the frame rate; a mistake here shows up only on a screen with a different rate.
- Smoothness is checked by eye and by screen recording, not by a test: there is no automatic check for "no jitter".
