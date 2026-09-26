# Blueprint Shopping List

Keeps a housing blueprint's "what am I still missing" window usable from anywhere, instead of it vanishing the moment you leave the housing zone.

## The problem

The stock blueprint contents window is parented to the House Editor frame. Leave your plot and that parent disappears, which tears down the window's data and its "reparent to UIParent" callback before either can save you — so the list is just gone, even though nothing about the missing-decor data was actually tied to your location.

## What this addon does

- Keeps its own copy of the blueprint contents payload, so the window can always be rebuilt regardless of what Blizzard's frame does.
- Requests contents against an explicit house GUID, which is what makes the server fill in missing-item counts even when you're nowhere near your plot.
- Adds a "Keep open" checkbox that re-shows the window after a House Editor close, a plot exit, or a parent swap — closing it yourself still closes it.
- Remembers the last known snapshot per share code, so you still see missing counts if the server won't give you a house context.
- Only trusts the house you're currently standing in if you actually own it, so visiting a neighbour's plot doesn't skew your own counts.

## Usage

- `/bsl` or `/blueprintlist` — reopen the window.
- `LoadBlueprint("<CODE>")` — macro-friendly global to load a specific blueprint's shopping list by share code.

## Compatibility

Targets WoW: Midnight (`## Interface: 120100`).

## License

MIT, see [LICENSE](LICENSE).
