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

# Extract version from documentation table (Core Tools section only)
parse_doc_version() {
    local tool_name="$1"
    # Extract version from markdown table in Core Tools section (lines 48-61)
    # This avoids matching other tables like "Known Compatibility Issues"
    sed -n '48,61p' "$VERSION_DOC" | grep "^| ${tool_name} |" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $4); print $4}' || echo ""
}

# Check if versions are in sync
check_sync() {
    local out_of_sync=0
    local changes=()

    echo -e "${BLUE}Checking version synchronization...${NC}"
    echo ""

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
        new_rows+="| ${tool} | ${description} | ${version} |\n"
        echo -e "${GREEN}✓ ${tool}: ${version}${NC}"
    done

    # Find table boundaries in documentation (lines 46-61)
    # Table header is at line 46, separator at 47, data starts at 48
    local table_start=48  # First data row
    local table_end=61    # Last data row

    # Create temporary file with updated table
    {
        # Copy lines before table
        sed -n "1,$((table_start - 1))p" "$VERSION_DOC"

        # Insert new table rows
        echo -e "$new_rows"

        # Copy lines after table
        sed -n "$((table_end + 1)),\$p" "$VERSION_DOC"
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
