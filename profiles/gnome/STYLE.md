# Spectre GNOME visual language — 0.9

Spectre uses GNOME as the desktop platform and applies a narrow identity layer
rather than maintaining a fork of GNOME Shell.

## Palette

- Base: `#01060f`, `#030a17`, `#07111f`
- Raised surface: `#081426`, `#0a1728`
- Primary accent: `#147ee8`
- Highlight: `#5bcaff`
- Primary text: `#edf5ff`
- Secondary text: `#86a3c4`

## Geometry

- Panel: 40 px
- Panel controls: 11 px radius
- Dock: 20 px radius
- Menus / quick settings: 18 px radius
- Dialogs: 20 px radius
- App controls: 10–14 px radius

## Interaction

- Use blue only for focus, active state and actions.
- Prefer subtle borders to large blocks of saturated blue.
- Keep animations enabled and short.
- Preserve GNOME keyboard/navigation behavior.
- Keep Spectre custom behavior in `spectre-panel@spectre.os`.
- Use libadwaita for branded applications such as Spectre Center and Welcome.


## Native system overview

The `spectre-hud@spectre.os` GNOME Shell extension owns both the optional desktop cards and the compact panel overview. Cards should feel like part of the Shell: dark glass, thin blue border, strong hierarchy and real local telemetry. They remain behind normal windows and disappear from Overview.
