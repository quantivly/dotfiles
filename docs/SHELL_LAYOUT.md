# The zsh layer: module layout, load order and conventions

The elaboration behind the orientation tables in [CLAUDE.md](../CLAUDE.md) — the two
tool-availability patterns and when each is used, the full annotated load order, and the module
breakdown. CLAUDE.md keeps the maps an agent navigates by (which file a function lives in, what
loads after what); this page keeps the examples and the reasoning, so the maps stay short enough
to be read.

> **Moved verbatim from CLAUDE.md on 2026-09-18 (DO-627), from the tree at `18c70fb`.** Nothing
> was rewritten, so "this file" below means CLAUDE.md, and "above", "below" and "N sections up"
> refer to its layout at that commit; `git show 18c70fb:CLAUDE.md` restores the context. **Add new
> evidence here, not to CLAUDE.md** — the rules stay there, the evidence lives here.

---

## From `### Tool Availability Checks`: the two patterns

Use two patterns depending on context:

**1. Direct `command -v` check** - For conditionals and standalone scripts:
```bash
if command -v colorls &>/dev/null; then
    alias ls='colorls --sd --sf'
fi
```

**2. `has_command()` function** - For cleaner syntax in functions:
```bash
has_command() { command -v "$1" &>/dev/null; }

setup_fzf() {
    if has_command fzf; then
        # Configure fzf
    fi
}
```

**Guidelines:**
- Use `command -v` in `zshrc.conditionals` and standalone scripts
- Use `has_command()` inside functions for readability
- Both are fast (~1-2ms); no caching needed
- **One name per call.** `command -v a b c` takes a single operand in POSIX sh, and the
  shells disagree about the rest: measured here, `command -v bash nosuchtool` prints only
  `/usr/bin/bash` and exits **0** in bash and dash, and **1** in zsh — so the same line is a
  silent pass with two tools missing in one shell and an unexplained failure naming none of
  them in the other. It is not academic: `docs/HERDR_GUIDE.md` §2.3 carries this warning in a
  comment, and the team-facing write-up derived from it then used exactly that shape as a
  verification step. Loop, or call it once per tool.

**Historical note:** Tool cache was removed after benchmarks showed 81ms overhead.

## From `### Configuration Loading Order`: the annotated order

```
1. Locale export (LANG/LC_ALL — must be before p10k for icon rendering)
2. Powerlevel10k instant prompt (performance)
3. oh-my-zsh core and plugins
4. p10k.zsh theme
5. zsh/zshrc.history
6. zsh/functions/*.sh (core, development, system, github, claude — github and
   claude after system, which defines the shared _doctor_* emitters they use)
7. zsh/zshrc.aliases
8. zsh/zshrc.conditionals → loads three focused modules:
   - zsh/zshrc.conditionals.tools (CLI tool overrides)
   - zsh/zshrc.conditionals.fzf (FZF integration)
   - zsh/zshrc.conditionals.plugins (mise, direnv, etc.)
9. zsh/zshrc.buildlimits (build/test worker caps)
10. zsh/zshrc.herdr (herdr layer — before company, and independent of it:
    a modular adopter sources this one file and nothing else)
11. zsh/zshrc.company
12. ~/.zshrc.local (machine-specific secrets)
13. PATH additions
14. Dotfiles live-config guard — registers a one-shot `precmd` hook that runs
    `_dotfiles_live_config_warn` on the FIRST prompt, then removes itself.
    Deferred rather than run here because p10k's instant prompt turns any output
    during initialization into a warning box.
```

**Key Insight:** Conditionals load AFTER aliases, so tools that are installed get priority configuration.
