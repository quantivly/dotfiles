# GNOME Configuration Guide

A clean, modern, keyboard-friendly GNOME desktop, applied reproducibly from the
dotfiles repo and built on **stock Ubuntu/GNOME only** — no third-party extensions
or themes to add bulk or instability.

Tested on **Ubuntu 26.04 LTS / GNOME Shell 50 (Wayland)**.

## Quick Start

```bash
gnome-apply     # Apply the curated desktop config (idempotent; safe to re-run)
gnome-init      # Create ~/.gnome-settings.local for machine-specific tweaks
${EDITOR:-vim} ~/.gnome-settings.local   # Set your dock favorites / launch keys
gnome-apply     # Re-apply (now includes your local overrides)
```

`gnome-apply` also runs automatically during `./install` (only on GNOME — it
no-ops on servers / other desktops). **Log out and back in once** after the first
apply to guarantee the dock relayout (see [Wayland note](#wayland-notes)).

## What gets configured

Everything is set via `gsettings` (the schema-validated front end to dconf). The
**portable core** lives in [`scripts/apply-gnome-settings.sh`](../scripts/apply-gnome-settings.sh);
**machine-specific** bits live in `~/.gnome-settings.local` (not tracked in git).

### Appearance — dark, green-tinted
- `color-scheme = prefer-dark`, theme/icons `Yaru-prussiangreen-dark`, accent `teal`
- Crisp font rendering (`font-antialiasing=rgba`, `font-hinting=slight`)
- Weekday + battery percentage in the top bar
- Fonts stay stock **Ubuntu Sans** (purpose-built; your terminal font is set in Alacritty)

### Dock — floating, autohiding, bottom
- Centered floating pill at the **bottom**, hidden until you hover the edge or press `Super`
- `extend-height=false`, `dock-fixed=false`, `autohide=true`, `intellihide=true`
- Slimmer icons (40px), dynamic transparency, **no** mounts/trash clutter
- Pinned apps (favorites) are machine-specific → set them in `~/.gnome-settings.local`

### Desktop — no icons
- All `ding` desktop icons hidden (home/trash/volumes/network/link-emblem/drop-place)
- The lightweight `ding` extension stays enabled, just invisible (fully reversible)

### Keybindings — tmux-friendly
- GNOME workspace switching is moved **off** `Ctrl+Alt+Arrow` onto `Super`-based
  shortcuts, so tmux's `Ctrl+Alt+Arrow` pane-resize works (see
  [CLAUDE.md](../CLAUDE.md) → *Terminal gotchas*, and
  [TMUX_LEARNING_GUIDE.md](TMUX_LEARNING_GUIDE.md)):
  | Action | Shortcut |
  |--------|----------|
  | Workspace left / right | `Super+Alt+←` / `Super+Alt+→` |
  | Workspace up / down | `Super+PageUp` / `Super+PageDown` |

### Extensions — left as-is
No extensions are enabled or disabled. The decluttered look comes purely from
hiding visible items. All stock Canonical extensions stay exactly as Ubuntu ships
them (`ding`, `ubuntu-dock`, `tiling-assistant`, `ubuntu-appindicators`, snapd/web
search providers).

## Keyboard-driven workflow (no extensions needed)

- **`Super`** — Activities overview; just start typing to launch/search (your launcher)
- **`Super+Tab`** / **`Alt+Tab`** — switch apps / windows
- **Tiling** (built-in `tiling-assistant`): `Super+←/→` half-tile, `Super+↑` maximize,
  `Super+↓` restore, corners via `Super` + keypad. Tile side-by-side without an extension.
- Pin only a handful of apps; reach everything else from the overview.

## Customizing

### Pinned dock apps
App IDs differ per machine (snaps are `name_name.desktop`, system apps are
`org.gnome.X.desktop`). List the current ones and edit your local file:
```bash
gsettings get org.gnome.shell favorite-apps
${EDITOR:-vim} ~/.gnome-settings.local   # edit the favorite-apps line
gnome-apply
```

### Custom launch key, peripherals, theme variant
`~/.gnome-settings.local` ships commented examples for a `Super+Return → Alacritty`
binding, laptop touchpad options, and a neutral-grey theme variant. Uncomment and
`gnome-apply`. The helper `gset <schema> <key> <value>` is available inside that file.

## Backup & restore

There is no first-party GNOME export/import; the committed `gsettings` script is the
source of truth. For a full personal snapshot (everything, including machine state):
```bash
gnome-backup                       # → ~/gnome-dconf-YYYY-MM-DD-HHMM.conf
gnome-restore <backup-file>        # load it back (asks for confirmation)
```
These use `dconf dump/load` over `/org/gnome/` and are **not** committed to git.

## Wayland notes

- GNOME 50 is Wayland-only. Appearance, dock, desktop and keybinding changes apply
  **immediately**. Dock relayout / any extension toggles are guaranteed after one
  **log out / log in**.
- Do **not** use `Alt+F2` → `r` or `Meta.restart` — those are X11-only and do nothing
  (or error) on Wayland.

## Troubleshooting

**A setting didn't take.** Confirm GNOME sees it:
```bash
gnome-status
gsettings get org.gnome.desktop.interface color-scheme   # expect 'prefer-dark'
```

**Theme looks wrong / variant missing.** The script warns and skips if a Yaru variant
is absent. Check availability:
```bash
ls /usr/share/themes | grep -i prussiangreen
```

**`gnome-apply` printed success but nothing changed.** This happens when a
snap-confined terminal (e.g. the Alacritty snap) exports `GIO_MODULE_DIR` pointing
at a private cache that lacks the dconf GSettings backend — `gsettings` then
silently writes to an in-memory backend that never reaches the real database. The
apply script and `gnome-status` already drop `GIO_MODULE_DIR` to avoid this. If you
run `gsettings set` **manually** from such a terminal, prefix it:
`env -u GIO_MODULE_DIR gsettings set …`. Tell-tale sign: `gsettings get` and
`dconf read <path>` disagree.

**Dock still full-height after apply.** Log out and back in (Wayland relayout).

**Want desktop icons back.** They're only hidden, not removed:
```bash
gsettings set org.gnome.shell.extensions.ding show-home true   # etc.
```

**Reset everything to GNOME defaults** for a subtree (then re-apply):
```bash
dconf reset -f /org/gnome/shell/extensions/dash-to-dock/
gnome-apply
```

## See also
- [`scripts/apply-gnome-settings.sh`](../scripts/apply-gnome-settings.sh) — the settings, commented
- [`examples/gnome-settings.local.template`](../examples/gnome-settings.local.template) — machine-specific template
- [CLAUDE.md](../CLAUDE.md) — repo conventions and terminal gotchas

## Maintainer's record: the mechanism, the layers and their traps

The bullets below are the record behind the **GNOME Desktop Configuration** rules in
[CLAUDE.md](../CLAUDE.md) — what is applied by what, and the one trap that made `gnome-apply` print
two ticks while silently undoing a setting it had just applied.

> **Moved verbatim from CLAUDE.md on 2026-09-18 (DO-627), from the tree at `18c70fb`.** Nothing
> was rewritten, so "this file" below means CLAUDE.md, and "above", "below" and "N sections up"
> refer to its layout at that commit; `git show 18c70fb:CLAUDE.md` restores the context. **Add new
> evidence here, not to CLAUDE.md** — the rules stay there, the evidence lives here.

---

- **Mechanism:** curated `gsettings` script (schema-validated, idempotent, reviewable), **not** `dconf dump` (which drags in machine-specific cruft). GNOME has no first-party export/import.
- **Source of truth:** `scripts/apply-gnome-settings.sh` (portable core). Runs automatically during `./install` on GNOME only (no-op on servers / other desktops).
- **Machine-specific layer:** `~/.gnome-settings.local` (dock favorites, custom launch keys) — mirrors the `~/.zshrc.local` pattern, sourced by the apply script, never overwritten. Create with `gnome-init`. It runs LAST and silently wins, so a line here can undo one the portable layer just applied: `grp:alt_shift_toggle` was re-enabled that way on every run, killing all four of herdr's `alt+shift+arrow` bindings while `gnome-apply` printed two ✓ lines three apart and `gsettings get` showed the override as if it were the applied value. An overriding set now prints `(overrides <previous>, set above)` — a note, not a warning, since overriding is what the layer is for.
- **Tmux integration:** the script moves GNOME workspace switching off `Ctrl+Alt+Arrow` onto `Super`-based shortcuts so tmux pane-resize works (the previously-manual fix is now baked in).
- **XDG user-dir guard:** `scripts/repair-xdg-user-dirs.sh` (alias `xdg-repair`) keeps `~/Desktop`, `~/Documents`, … as real directories so `snapd-desktop-integration` can't turn them into broken self-referential symlinks. Idempotent; `./install` runs it on graphical workstations (gated on `$XDG_CURRENT_DESKTOP` + `xdg-user-dirs-update`, skipped on servers). See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
- **Wayland gotcha:** changes apply live; dock relayout is guaranteed after one log out / log in. `Alt+F2 r` / `Meta.restart` are X11-only — never use them.
