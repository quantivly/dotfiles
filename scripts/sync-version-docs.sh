#!/usr/bin/env bash
# sync-version-docs.sh - Synchronize tool versions from .mise.toml to TOOL_VERSION_UPDATES.md
# This script prevents documentation drift by auto-updating the version table

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MISE_CONFIG="${DOTFILES_ROOT}/.mise.toml"
VERSION_DOC="${DOTFILES_ROOT}/docs/TOOL_VERSION_UPDATES.md"

# Tool names and their descriptions (order matters for table)
declare -A TOOL_DESCRIPTIONS=(
    ["bat"]="Better cat with syntax highlighting"
    ["fd"]="Better find with .gitignore support"
    ["eza"]="Better ls with icons and colors"
    ["delta"]="Git diff with syntax highlighting"
    ["zoxide"]="Smart cd that learns patterns"
    ["duf"]="Beautiful disk usage"
    ["dust"]="Intuitive directory sizes"
    ["lazygit"]="Interactive git TUI"
    ["just"]="Modern command runner"
    ["glow"]="Terminal markdown renderer"
    ["gitleaks"]="Secret detection"
    ["pre-commit"]="Git hook framework"
    ["sops"]="Encrypted secrets management"
    ["fastfetch"]="System info display"
)

# Tool order for table (must match documentation order)
TOOL_ORDER=("bat" "fd" "eza" "delta" "zoxide" "duf" "dust" "lazygit" "just" "glow" "gitleaks" "pre-commit" "sops" "fastfetch")

# Validate tool coverage - warn if tools in .mise.toml lack descriptions
validate_tool_coverage() {
    local mise_tools
    mise_tools=$(sed -n '/^\[tools\]/,/^\[/p' "$MISE_CONFIG" | grep -oP '^\K\w+(?=\s*=)' || echo "")

    local missing_descriptions=()
    local missing_from_order=()

    while IFS= read -r tool; do
        [[ -z "$tool" ]] && continue

        # Check if tool has a description
        if [[ -z "${TOOL_DESCRIPTIONS[$tool]:-}" ]]; then
            missing_descriptions+=("$tool")
        fi

        # Check if tool is in TOOL_ORDER
        local in_order=0
        for ordered_tool in "${TOOL_ORDER[@]}"; do
            if [[ "$ordered_tool" == "$tool" ]]; then
                in_order=1
                break
            fi
        done
        if [[ $in_order -eq 0 ]]; then
            missing_from_order+=("$tool")
        fi
    done <<< "$mise_tools"

    # Report warnings if any
    if [[ ${#missing_descriptions[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Warning: Tools in .mise.toml missing descriptions in TOOL_DESCRIPTIONS:${NC}"
        for tool in "${missing_descriptions[@]}"; do
            echo -e "  ${YELLOW}⚠${NC} $tool"
        done
        echo ""
    fi

    if [[ ${#missing_from_order[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Warning: Tools in .mise.toml missing from TOOL_ORDER array:${NC}"
        for tool in "${missing_from_order[@]}"; do
            echo -e "  ${YELLOW}⚠${NC} $tool"
        done
        echo ""
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Synchronize tool versions from .mise.toml to TOOL_VERSION_UPDATES.md

OPTIONS:
    -c, --check    Check if versions are in sync (exit 1 if not)
    -u, --update   Update the documentation with current versions
    -h, --help     Show this help message

EXAMPLES:
    # Check if versions are in sync
    $(basename "$0") --check

    # Update documentation with current versions
    $(basename "$0") --update

NOTE: Run this script after updating tool versions in .mise.toml
EOF
}

# Parse .mise.toml to extract tool versions
parse_mise_versions() {
    local tool_name="$1"
    # Extract version from .mise.toml: bat = "0.24.0"
    grep "^${tool_name} = " "$MISE_CONFIG" | sed 's/.*= "\(.*\)".*/\1/' || echo ""
}

# --- Locating the Core Tools table -------------------------------------------
#
# The table is found by its HEADER ROW and read to the first line that is not a
# table row. It used to be read as `sed -n '48,61p'`, which coupled it both to
# every line above it in the file and to its own length. Both directions bit
# (DO-631):
#
#   - Loudly, on any line added above the table. DO-627: a one-line correction
#     on line 12 became two lines, the last row fell out of the window, and CI
#     failed with `fastfetch: missing from docs`. The workaround at the time was
#     to keep the correction to one line -- writing around the checker.
#   - Silently, when the table gains a row TOOL_ORDER does not name: the window
#     never saw it, nothing compared it, and the run still ended
#     `All tool versions are in sync!`. Measured rather than assumed --
#     scripts/test-sync-version-docs.sh keeps a row on it.
#
# The header is matched in FULL, so the "Known Compatibility Issues" table lower
# in the same file (`| Tool | Version | Issue | Workaround |`) cannot be read by
# mistake -- which is what the old window's 48,61 was really defending against.
TABLE_HEADER='| Tool | Purpose | Current Version |'

# Populated by load_doc_table(). DOC_ROW_NAMES preserves order and duplicates,
# so it -- not the associative array -- is what the row count is taken from.
DOC_TABLE_START=0
DOC_TABLE_END=0
DOC_ROW_NAMES=()
declare -A DOC_VERSIONS

# Print "<header line> <first data line> <last data line>", each 0 if absent.
# `exit` still runs END, so the bounds survive the stop at the first non-row.
doc_table_bounds() {
    awk -v header="$TABLE_HEADER" '
        !found { if ($0 == header) { found = NR } ; next }
        /^\|[-: |]*\|[ \t]*$/ { next }
        /^\|/ { if (!start) { start = NR } ; end = NR ; next }
        { exit }
        END { print found + 0, start + 0, end + 0 }
    ' "$VERSION_DOC"
}

# Read the table once. A checker that cannot find its input must never report a
# clean tree, and "could not run" must not read as "out of sync" -- so this
# exits 2, distinct from the 1 that means drift.
load_doc_table() {
    local bounds header_line

    # Checked by STATUS, not by whether anything came out. awk here is mawk, and
    # an awk that fails prints nothing and exits non-zero: reading the bounds
    # straight into `read` made that empty output look like a legitimate parse
    # and the script exited 1, with no output at all, from `set -e` -- a CI job
    # failing as "out of sync" over a tool that never ran. Measured with a stub
    # awk on PATH; test-sync-version-docs.sh keeps a row on it.
    if ! bounds=$(doc_table_bounds) || [[ -z "$bounds" ]]; then
        echo -e "${RED}Error: could not read the table out of ${VERSION_DOC}${NC}" >&2
        echo -e "${RED}       (awk produced no bounds -- is awk working?)${NC}" >&2
        exit 2
    fi
    read -r header_line DOC_TABLE_START DOC_TABLE_END <<< "$bounds"

    if [[ "$header_line" -eq 0 ]]; then
        echo -e "${RED}Error: could not find the Core Tools table in ${VERSION_DOC}${NC}" >&2
        echo -e "${RED}       expected a header row reading exactly:${NC}" >&2
        echo -e "${RED}       ${TABLE_HEADER}${NC}" >&2
        exit 2
    fi
    if [[ "$DOC_TABLE_START" -eq 0 ]]; then
        echo -e "${RED}Error: the Core Tools table at ${VERSION_DOC}:${header_line} has no data rows${NC}" >&2
        exit 2
    fi

    local name version
    while IFS=$'\t' read -r name version; do
        [[ -z "$name" ]] && continue
        DOC_ROW_NAMES+=("$name")
        DOC_VERSIONS["$name"]="$version"
    done < <(sed -n "${DOC_TABLE_START},${DOC_TABLE_END}p" "$VERSION_DOC" |
             awk -F'|' 'BEGIN { OFS = "\t" }
                        { n = $2 ; v = $4
                          gsub(/^[ \t]+|[ \t]+$/, "", n)
                          gsub(/^[ \t]+|[ \t]+$/, "", v)
                          print n, v }')
}

# Version for a tool as the documentation table records it, empty if absent.
parse_doc_version() {
    printf '%s' "${DOC_VERSIONS[$1]:-}"
}

# Check if versions are in sync
check_sync() {
    local out_of_sync=0
    local changes=()

    echo -e "${BLUE}Checking version synchronization...${NC}"
    echo ""

    # A row TOOL_ORDER does not name is a row nothing compares. That is the
    # silent direction this checker was blind to: it read a fixed 14-line
    # window, so an extra row was invisible and the run still ended
    # "All tool versions are in sync!".
    local doc_only=()
    local name known ordered_tool
    for name in "${DOC_ROW_NAMES[@]}"; do
        known=0
        for ordered_tool in "${TOOL_ORDER[@]}"; do
            if [[ "$ordered_tool" == "$name" ]]; then
                known=1
                break
            fi
        done
        if [[ $known -eq 0 ]]; then
            doc_only+=("$name")
        fi
    done

    for name in "${doc_only[@]}"; do
        echo -e "${RED}✗ ${name}: in the docs table but not in TOOL_ORDER (never checked)${NC}"
        out_of_sync=1
        changes+=("${name}: row in docs is not in TOOL_ORDER, so nothing verifies it")
    done

    # Independently of the above, the two must be the same LENGTH. A duplicated
    # row leaves the sets equal and the counts unequal, and would otherwise be
    # checked twice and reported once.
    if [[ ${#DOC_ROW_NAMES[@]} -ne ${#TOOL_ORDER[@]} ]]; then
        echo -e "${RED}✗ docs table has ${#DOC_ROW_NAMES[@]} rows, TOOL_ORDER has ${#TOOL_ORDER[@]}${NC}"
        out_of_sync=1
        changes+=("row count: docs table has ${#DOC_ROW_NAMES[@]}, TOOL_ORDER has ${#TOOL_ORDER[@]}")
    fi

    for tool in "${TOOL_ORDER[@]}"; do
        local mise_version
        mise_version=$(parse_mise_versions "$tool")
        local doc_version
        doc_version=$(parse_doc_version "$tool")

        if [[ -z "$mise_version" ]]; then
            echo -e "${YELLOW}⚠ ${tool}: Not found in .mise.toml${NC}"
            continue
        fi

        if [[ -z "$doc_version" ]]; then
            echo -e "${YELLOW}⚠ ${tool}: Not found in documentation${NC}"
            out_of_sync=1
            changes+=("${tool}: missing from docs (should be ${mise_version})")
            continue
        fi

        if [[ "$mise_version" != "$doc_version" ]]; then
            echo -e "${RED}✗ ${tool}: ${doc_version} → ${mise_version} (out of sync)${NC}"
            out_of_sync=1
            changes+=("${tool}: ${doc_version} → ${mise_version}")
        else
            echo -e "${GREEN}✓ ${tool}: ${mise_version} (in sync)${NC}"
        fi
    done

    echo ""
    if [[ $out_of_sync -eq 1 ]]; then
        echo -e "${RED}Documentation is OUT OF SYNC with .mise.toml${NC}"
        echo ""
        echo "Changes needed:"
        for change in "${changes[@]}"; do
            echo "  - $change"
        done
        echo ""
        echo "Run: $(basename "$0") --update"
        return 1
    else
        echo -e "${GREEN}All tool versions are in sync!${NC}"
        return 0
    fi
}

# Update documentation with current versions
update_docs() {
    echo -e "${BLUE}Updating documentation with current versions...${NC}"
    echo ""

    # Create backup
    cp "$VERSION_DOC" "${VERSION_DOC}.backup"

    # Generate new table rows
    local new_rows=""
    for tool in "${TOOL_ORDER[@]}"; do
        local version
        version=$(parse_mise_versions "$tool")
        if [[ -z "$version" ]]; then
            echo -e "${YELLOW}⚠ ${tool}: Not found in .mise.toml, skipping${NC}"
            continue
        fi

        local description="${TOOL_DESCRIPTIONS[$tool]}"
        new_rows+="| ${tool} | ${description} | ${version} |"$'\n'
        echo -e "${GREEN}✓ ${tool}: ${version}${NC}"
    done

    # The data rows are replaced in place, between the bounds load_doc_table
    # found. These bounds were hardcoded 48 and 61 alongside the read path's
    # window, and on a shifted file that rewrite ate the |---| separator row --
    # so the table stopped rendering -- and left a duplicate last row below the
    # table. All while being the remedy the failing --check tells you to run.
    #
    # printf, not `echo -e "$new_rows"`: new_rows already ends in a newline, so
    # echo added one more on EVERY run. The blank lines that accumulated under
    # the table in the tracked doc are that bug's fossil record.
    {
        sed -n "1,$((DOC_TABLE_START - 1))p" "$VERSION_DOC"
        printf '%s' "$new_rows"
        sed -n "$((DOC_TABLE_END + 1)),\$p" "$VERSION_DOC"
    } > "${VERSION_DOC}.tmp"

    # Replace original file
    mv "${VERSION_DOC}.tmp" "$VERSION_DOC"
    rm -f "${VERSION_DOC}.backup"

    echo ""
    echo -e "${GREEN}Documentation updated successfully!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Review changes: git diff docs/TOOL_VERSION_UPDATES.md"
    echo "  2. Commit changes: git add docs/TOOL_VERSION_UPDATES.md"
    echo "  3. Create PR with updated versions"
}

# Main execution
main() {
    local mode="check"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--check)
                mode="check"
                shift
                ;;
            -u|--update)
                mode="update"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo -e "${RED}Error: Unknown option: $1${NC}"
                echo ""
                usage
                exit 1
                ;;
        esac
    done

    # Verify files exist
    if [[ ! -f "$MISE_CONFIG" ]]; then
        echo -e "${RED}Error: .mise.toml not found at: $MISE_CONFIG${NC}"
        exit 1
    fi

    if [[ ! -f "$VERSION_DOC" ]]; then
        echo -e "${RED}Error: TOOL_VERSION_UPDATES.md not found at: $VERSION_DOC${NC}"
        exit 1
    fi

    # Locate and read the documentation table. Exits 2 if it cannot be found:
    # that is "could not run", which is neither a pass nor "out of sync".
    load_doc_table

    # Validate tool coverage
    validate_tool_coverage

    # Execute requested mode
    case "$mode" in
        check)
            check_sync
            ;;
        update)
            update_docs
            ;;
    esac
}

main "$@"
