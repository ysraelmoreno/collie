# Custom themes — Design

Date: 2026-11-20. Status: direction approved by the owner (the merge of options B and C of
`docs/pages/temas-opcoes`; prototype: `docs/pages/temas-editor`). Nothing here is built.
PRDs: `docs/superpowers/roadmap/2026-11-20-temas/`.

## Why

The app has three choices (Escuro, Claro, Sistema) over two fixed palettes of 18 colours
(`Sources/CollieTheme/Palette.swift`). The owner wants users to make their own themes, edit them in the app, and
pass them around.

## Goal

A user can create a theme, edit its colours as a list or as JSON, see it on a preview while editing, and apply it to
the whole app. A theme is a file they can copy to someone else.

## Non-goals

- The terminal's 16 ANSI colours. The app leaves them to SwiftTerm today (`TerminalNodeView.applyColors`); they stay
  that way. The file format keeps the key `terminal` reserved for them.
- Importing terminal themes (Ghostty, iTerm). Sketched as a later PRD (T7).
- A custom theme that follows the system's light/dark switch. "Sistema" keeps pairing the two built-in themes.
- Fonts, spacing, corner radii: a theme is colours only.
- A catalogue or a download of themes.

## Anti-goals

- A theme that an agent can write or change. Themes live outside every project, where terminals cannot write; a theme
  could otherwise hide an approval card's text. The app never loads a theme from a project folder.
- A broken theme that takes the app down or leaves it unreadable with no way back. A file that fails to load is shown
  as broken and never applied; the built-in themes can't be edited or removed.
- Rebuilding the terminals when the theme changes.

## The theme file

`~/Library/Application Support/Collie/themes/<id>.json`. `<id>` is the file name without the extension:
`[a-z0-9][a-z0-9-]{0,47}`.

```json
{
  "name": "Tinta",
  "extends": "dark",
  "colors": {
    "background": "#15171C",
    "surface": "#1F232B",
    "accent": "#6E9BFF"
  }
}
```

| Key | Rule |
|---|---|
| `name` | 1–48 characters, no control characters. Shown on the card. |
| `extends` | `"dark"` or `"light"`. The built-in palette the missing colours come from, and the appearance (dark or light window chrome, system controls) the theme runs under. |
| `colors` | Any subset of the 18 roles. The key is the `Palette` property name (`background`, `surface`, `sidebar`, `sunken`, `raised`, `border`, `borderSoft`, `grid`, `scrim`, `text`, `textSecondary`, `muted`, `accent`, `onAccent`, `attention`, `attentionTint`, `secondary`, `danger`). The value is `#RRGGBB`. |
| `terminal` | Reserved. Ignored now. |

Unknown top-level keys are ignored (a newer file still loads). An unknown role, a malformed colour, a missing `name`
or `extends`, invalid JSON, or a file over 64 KiB: the theme is **broken**; the reason is one line in Portuguese.

A theme has one palette. Someone who wants a light and a dark version makes two themes (the owner's decision).

Writes are atomic (temporary file, then rename) and keep the user's key order as: `name`, `extends`, `colors` in the
order of the role table.

## How it applies

Today `CollieColor.<role>` is a dynamic `NSColor` that picks `Palette.dark` or `Palette.light` from the drawing
appearance. Those two become the **active** dark and light palettes, held in `CollieTheme` and replaceable at run time:

- A built-in choice sets both to the built-in palettes.
- A custom theme sets the palette of its `extends` side to "built-in + overrides" and the window appearance to that
  side.

`appearance.theme` in `UserDefaults` accepts `dark`, `light`, `system` and `custom:<id>`. A `custom:<id>` whose file
is gone or broken reads as `dark` (the tolerant read that exists today).

After a swap, everything on screen has to show the new colours without being rebuilt:

- views that draw with `CollieColor` (dynamic colours are resolved again when the window is asked to redraw);
- the terminals' fixed colours (`applyColors`: background, text, caret, selection);
- layer colours set by hand (`cgColor` of borders and backgrounds);
- the tokens handed to plug-in pages (`WebPluginPanel.themeJSON`, the `collie-theme` event) and to Prévia pages.

How to trigger that redraw without a visible flash is the one unknown of this design; T2 starts by proving it.

## The library

The app (not the daemon) owns the folder: it creates it on first use, lists it, and watches it, so a file saved in
any editor reloads within a second. At most 200 files are read. The list is: the built-in themes, then the user's by
name. Operations: new from a theme (a copy with a free id), import a `.json` (validated, copied in), delete (to the
Trash), show in Finder.

## The screen

Preferences › Aparência, replacing today's three-way picker (prototype: `docs/pages/temas-editor`):

- **Gallery.** One card per theme: a thumbnail drawn from its palette, the name, and where it comes from ("do Collie"
  or the file name). A broken theme's card shows the reason and can't be selected. Selecting a card applies the
  theme. "Sistema" stays as a card.
- **Editor**, shown for a custom theme. A switch "Lista | JSON" picks the view; both edit the same file.
  - *Lista*: the 18 roles in groups (Fundos, Texto, Destaques, Outros). Each row: the role's name in Portuguese, a
    colour well, the hex, "alterado" or "herdado" with a reset, and the contrast against the background the role is
    drawn on. Below 4.5:1 the number turns amber with "baixo"; the theme is still saved.
  - *JSON*: the file's text, editable. While the text is not a valid theme the reason shows under it and nothing is
    applied or written.
- **Preview**, beside the editor: a small canvas (a terminal node with an approval, a memory card, the rail) drawn
  from the palette being edited, not from the app's active colours.

Editing applies live to the preview at once and to the file after 300 ms without changes. If the edited theme is the
selected one, the app follows.

## Calls I made (the owner can veto)

1. **ANSI colours stay out** of this delivery. The owner confirmed the design without choosing between "in the
   theme" and "in Terminal e fontes"; the app does not set them at all today, so leaving them out changes nothing.
2. **"Importar…" imports Collie theme files only.** The gallery of the prototype shows an imported Gruvbox; that
   waits for T7.
3. **The app owns the themes folder**, with no daemon command. Themes are a look of the app; agents have no use for
   them, and keeping them off the daemon keeps them off the agents' reach.
4. **Contrast is a warning, never a block.** The built-in themes pass AA (`PaletteTests`); a user may want otherwise.

## Left to the builder

- The redraw trigger (T2's first task).
- Whether the gallery and the editor are one SwiftUI file or two.
- The thumbnail's drawing.
