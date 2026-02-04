# PR Number Integration in Powerlevel10k Prompt

**Date**: 2026-02-04
**Status**: Approved
**Author**: Design session with user

## Overview

Add GitHub PR number display to the Powerlevel10k prompt when working on branches with associated pull requests. The PR number appears after the branch name in the VCS segment with minimal performance impact.

## User Requirements

- **Display format**: `#123` (compact, widely recognized)
- **Placement**: After branch name, inline with VCS segment
- **Color**: Grey (`%248F` - meta color) matching remote branch indicators
- **Performance**: Reliable data with acceptable latency
- **Behavior**: Updates automatically on branch changes

## Architecture

### Core Components

1. **Cache Helper Function** (`_p10k_get_pr_number`)
   - Fetches PR number via `gh pr view --json number -q .number`
   - Caches result in `~/.cache/p10k-pr-cache/<repo>/<branch>`
   - Returns cached value on subsequent calls

2. **Integration Point**
   - Modifies existing `my_git_formatter()` function in `p10k.zsh`
   - Adds PR display after branch name (line ~402)
   - Uses gitstatus `VCS_STATUS_LOCAL_BRANCH` for branch detection

3. **Caching Strategy**
   - Cache keyed by: repository + branch name
   - Cache invalidation: Manual or natural (branch deletion)
   - No TTL (optimized for performance)

### Performance Profile

| Scenario | Latency | Frequency |
|----------|---------|-----------|
| Cache hit (same branch) | ~2-5ms | 99% of prompts |
| Cache miss (new branch) | ~50-200ms | Once per branch |
| Cache creation | ~1ms | Once per branch |

### Visual Output

```
main #123 ⇡2 !3 ?1
└─┬─┘ └┬─┘ └───┬───┘
  │    │       └─ git status (existing)
  │    └───────── PR number (new)
  └────────────── branch name (existing)
```

## Implementation Details

### Cache Helper Function

```zsh
function _p10k_get_pr_number() {
  emulate -L zsh

  # Early exit if not in a git repo or no branch
  [[ -z $VCS_STATUS_LOCAL_BRANCH ]] && return

  # Build cache paths
  local git_root="${VCS_STATUS_WORKDIR:-.}"
  local repo_slug=$(basename "$git_root")
  local cache_dir="${HOME}/.cache/p10k-pr-cache/${repo_slug}"
  local cache_file="${cache_dir}/${VCS_STATUS_LOCAL_BRANCH}"

  # Return cached value if exists
  if [[ -f "$cache_file" ]]; then
    cat "$cache_file" 2>/dev/null
    return
  fi

  # Cache miss: fetch from GitHub (with timeout and error suppression)
  local pr_num
  pr_num=$(timeout 2s gh pr view --json number -q .number 2>/dev/null)

  # Only cache if we got a valid PR number
  if [[ -n "$pr_num" && "$pr_num" =~ ^[0-9]+$ ]]; then
    mkdir -p "$cache_dir"
    echo "$pr_num" > "$cache_file"
    echo "$pr_num"
  fi
}
```

### Integration into my_git_formatter()

Add after line 402 (after branch display):

```zsh
# Add PR number if current branch has an associated PR
local pr_num=$(_p10k_get_pr_number)
if [[ -n "$pr_num" ]]; then
  res+=" ${meta}#${pr_num}"
fi
```

## Error Handling

### Graceful Failures

- No `gh` CLI → Silent failure, no PR shown
- Not a GitHub repo → Silent failure
- No PR for branch → No display
- GitHub API down → Timeout after 2s, no display
- Permission issues → Continue without caching

### Edge Cases

| Scenario | Behavior |
|----------|----------|
| Forked repo, PR in upstream | Shows PR if `gh` can find it |
| Multiple PRs for same branch | Shows "current" PR (gh default) |
| Draft PR | Shows PR number (no distinction) |
| Branch not pushed | No PR shown (correct) |
| Detached HEAD | No PR shown (no branch) |
| Concurrent shells | Race condition harmless (same data) |

## Testing & Verification

### Manual Testing Steps

```bash
# 1. Create test branch with PR
git checkout -b test/pr-prompt-feature
gh pr create --title "Test PR" --body "Testing"
# Verify: Prompt shows #<number>

# 2. Test cache performance
time zsh -i -c exit  # First run: ~100ms
time zsh -i -c exit  # Cached: ~2-5ms

# 3. Test branch switching
git checkout main         # No PR shown
git checkout test/...     # PR shown (cached)

# 4. Test error handling
unalias gh               # Break gh temporarily
# Verify: Prompt still renders, no PR
alias gh='gh'            # Restore

# 5. Test cache invalidation
rm -rf ~/.cache/p10k-pr-cache/dotfiles/test*
# Verify: Next prompt refetches
```

### Success Criteria

- ✅ PR number appears after branch name
- ✅ Grey color matches metadata style
- ✅ No visible errors on failures
- ✅ Cache provides fast lookups (<5ms)
- ✅ Branch switching updates correctly
- ✅ Startup impact <50ms per branch

## Maintenance

### Cache Management

- **Location**: `~/.cache/p10k-pr-cache/`
- **Growth**: One file per branch per repo
- **Cleanup**: Manual via `rm -rf ~/.cache/p10k-pr-cache`
- **No automatic cleanup** (keeps implementation simple)

### Rollback Plan

Remove added code from `p10k.zsh` and run `source ~/.zshrc`. Feature is self-contained with no modifications to existing functionality.

## Future Enhancements (Not in Scope)

- PR status indicators (draft, approved, changes requested)
- Color coding by PR state
- Cache TTL with background refresh
- Integration with Linear issue IDs
- Configuration options for format/placement
