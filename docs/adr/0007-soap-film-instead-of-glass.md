# ADR 0007. A bubble is a soap film with a transparent centre, not glass

## Context

The glass made from the wallpaper image ([ADR 0003](0003-glass-from-wallpaper.md)) looked like a thick glass ball and needed the "Screen Recording" permission on dynamic wallpapers. What was wanted was the look of a holographic soap bubble: transparent inside, with an iridescent film at the edge, from a perfect circle to a crumbly shape.

## Decision

A bubble is drawn as a thin film: rings inward from the outline with the colour of thin-film interference along the angle, a band that is thicker on one side, a soft blur, highlights and a thin rim. The centre is transparent, with only a light radial darkening under the text. The film image is computed on the CPU and refreshed a few times a second; motion and squash are set by the layer transform. The outline uses harmonics 2 to 8; "Shape" 100 gives a circle, 0 gives a crumbly outline with folds of the film.

## Why

The look was agreed on an HTML prototype. The film needs nothing beneath the bubble, so reading the wallpaper, the "Screen Recording" permission and the glass-choice setting all went away. Rejected: the system Liquid Glass (in a desktop-level window it does not see the wallpaper), glass from the wallpaper (a different look and an extra permission), redrawing the film every frame (needless CPU load), a Metal shader (the Command Line Tools have no Metal compiler).

## Consequences

A macOS window cannot do true additive colour blending, so the film is laid on as a screen-like overlay and looks slightly softer than in a browser. The physics still treats bubbles as circles, and at "Shape" 0 the visible outline extends beyond the circle. A surfaced bubble above the windows gets a system blur under the film so that the text is readable over the windows.
