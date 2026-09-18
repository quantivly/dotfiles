# Alacritty, `$TERM` and key delivery

The maintainer's record behind the **terminal gotchas** in [CLAUDE.md](../CLAUDE.md): why the
Alacritty config cannot be symlinked, which Ctrl+Shift chords Alacritty silently swallows and how
that was probed at the keyboard, why `$TERM` depends on how Alacritty was *installed* rather than on
its config, and the measured cost of the snap build rendering on the CPU. Two fragments of CLAUDE.md
are collected here because they are one subject: the first came from `### Symlink Structure`, the
second from `## Command Behavior Changes`.

> **Moved verbatim from CLAUDE.md on 2026-09-18 (DO-627), from the tree at `18c70fb`.** Nothing
> was rewritten, so "this file" below means CLAUDE.md, and "above", "below" and "N sections up"
> refer to its layout at that commit; `git show 18c70fb:CLAUDE.md` restores the context. **Add new
> evidence here, not to CLAUDE.md** — the rules stay there, the evidence lives here.

---

## From `### Symlink Structure`: the Alacritty config is not symlinked

- `~/.config/alacritty/alacritty.toml` — Terminator-style tmux keybindings require CSI u key entries here. Template: `examples/alacritty.toml.template`, install with `alacritty-init`. **Gotcha:** Live config diverges from template — updating the template doesn't propagate. Also, Ctrl+Shift+letter combos that have Alacritty built-in defaults (e.g., F=SearchForward) must have explicit entries to override. **CORRECTED 2026-08-30 — `O` IS one of them.** This line previously listed (E, O, W, T, S) as "no defaults, work automatically"; `ctrl+shift+o` is in fact swallowed by an Alacritty default. **Where it is documented (corrected again after review):** it is a shipped `[[hints.enabled]]` default — `man 5 alacritty` shows `binding = { key = "O", mods = "Control|Shift" }`. It is a *hints* binding, not a `keyboard.bindings` one, which is why it does not appear in `man 5 alacritty-bindings` and why an earlier note here wrongly said "no man page". Look in the hints section. It left herdr's split-down silently dead. Verified at the keyboard with `scripts/herdr-keyprobe.sh`: the signature is a **release event with no matching key-press** (`ESC[111:79;6:3u` arriving alone), because Alacritty bindings fire on press and consume it while the kitty protocol still reports the release. E, W and T were re-probed and do deliver presses; S was not re-tested. **Do not infer from one working letter that the class works — probe each chord you bind.** Preferred override is `action = "ReceiveChar"` ("treat as unbound") rather than a hardcoded `chars` CSI u string, since it follows whatever encoding mode is active instead of forcing kitty sequences into a legacy-mode terminal.

## From `## Command Behavior Changes`: terminal gotchas

**Terminal gotchas:**
- **`$TERM` follows the terminfo, not the config.** Alacritty reports `alacritty` when that terminfo entry exists and falls back to `xterm-256color` when it doesn't — so the value depends on *how Alacritty was installed*, not on `alacritty.toml`. The snap ships no terminfo (→ `xterm-256color`); the apt package pulls `ncurses-term`, which has it (→ `alacritty`). `tmux.conf:94-95` deliberately sets `terminal-features` for **both** patterns, so either value works. Truecolor rides the catch-all `terminal-overrides ",*:RGB"` — note `*256col*` does *not* match `alacritty`.
- **Install Alacritty from apt, not snap** — the snap renders on the CPU. It bundles its own Mesa (23.2.1, from base `core22`) rather than the host's, so a GPU newer than that Mesa isn't recognized by `iris` and Mesa silently falls back to `swrast`/llvmpipe. On this hardware (Intel Lunar Lake, Arc 130V/140V Xe2 — silicon a year newer than the bundled driver) that cost 24.5% of a core sustained at idle and ~73% while rendering a busy TUI. The apt build bundles no driver, so it always uses host Mesa and can't go stale this way. Verify on the running process: no `swrast` in `/proc/<pid>/maps`, ≥1 `/dev/dri` fd, and no `llvmpipe-*` threads in `ps -o comm= -L -p <pid>` (`libgallium-<version>.so` and a `gdrv` thread are the healthy signs; `libLLVM` is *not* by itself a software-rendering signal — Mesa links it for shader compilation on the GPU path too).
- Ctrl+Shift+Arrow works natively in tmux (xterm modifier encoding). Ctrl+Shift+**letter** needs Alacritty key bindings sending CSI u sequences + tmux extended-keys
- tmux `extended-keys` and `terminal-features` are server-level — require `tmux kill-server`, not just config reload
