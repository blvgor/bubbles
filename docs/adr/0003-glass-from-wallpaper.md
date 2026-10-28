# ADR 0003. Glass is drawn from the wallpaper image, not with the system Liquid Glass

> Superseded by [ADR 0007](0007-soap-film-instead-of-glass.md): the bubbles became a soap film with a transparent centre, and the wallpaper image is no longer needed.

## Context

The bubbles live in a transparent window at desktop level and must look like Liquid Glass. The system `glassEffect` in such a window does not see the wallpaper beneath it, and the glass comes out empty.

## Decision

The app draws the glass itself. The source is the file of the screen's current wallpaper, re-read when the wallpaper changes. Inside the bubble's shape the wallpaper is shown with a slight magnification, refraction towards the edge and a soft blur; along the outline runs a thin light highlight from the top left and a soft glow from the bottom right; the glass colour is a light tint on top. A surfaced bubble (the window above other windows) uses the system glass or `NSVisualEffectView`, because there are real windows beneath it and the system shows them correctly. The fallback for the desk is `NSVisualEffectView` under a shape mask, switched on by a flag in the app settings.

## Why

- Under a bubble on the desk there is always the same thing: the wallpaper. So its image can be substituted directly, and the result is predictable.
- This is the only way to get the Liquid Glass features the design needs: magnification, refraction at the edge, a highlight along the outline.

Considered and rejected:

- **The system `glassEffect(.clear)` for the desk.** It was the first choice. At desktop level it neither blurs nor refracts the wallpaper, so the bubble looks like a transparent hole.
- **`NSVisualEffectView(.behindWindow)` as the main path.** It blurs, but flatly: no magnification and no refraction. Kept as the fallback.

## Consequences

- The bubble sees only the wallpaper file. Desktop icons and anything lying on the desk do not get into the glass.
- Wallpapers that change on their own during the day or differ between Spaces may not match the file the system returns. Then the glass shows something other than what is behind it. One main screen is supported.
- The refraction, highlight and blur are our code, not the system's: they will not update by themselves with a new macOS version, and we are responsible for their cost per frame.
- A bubble on the desk and a surfaced bubble have two different ways of drawing the glass; they have to be kept visually close by hand.
- A wallpaper change must be noticed and redrawn, otherwise the glass shows the old image.
