#!/usr/bin/env bash
# Verify Python environment setup across projects

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

check_project() {
    local project_path="$1"
    local expected_version="$2"

    echo ""
    echo "Checking: $project_path"
    echo "Expected Python: $expected_version"

    if [ ! -d "$project_path" ]; then
        echo -e "${RED}✗${RESET} Project directory does not exist"
        return
    fi

    cd "$project_path"

    # Check .mise.toml
    if [[ -f .mise.toml ]]; then
        local mise_version=$(grep 'python =' .mise.toml | awk -F'"' '{print $2}' || echo "")
        if [[ "$mise_version" == "$expected_version" ]]; then
            echo -e "${GREEN}✓${RESET} .mise.toml: python = \"$mise_version\""
        else
            echo -e "${YELLOW}⚠${RESET} .mise.toml: python = \"$mise_version\" (expected \"$expected_version\")"
        fi
    else
        echo -e "${RED}✗${RESET} Missing .mise.toml"
    fi

    # Check .python-version (optional)
    if [[ -f .python-version ]]; then
        local version=$(cat .python-version | tr -d '[:space:]')
        echo -e "${GREEN}✓${RESET} .python-version: $version"
    else
        echo -e "${YELLOW}⚠${RESET} No .python-version (optional)"
    fi

    # Check .envrc
    if [[ -f .envrc ]]; then
        echo -e "${GREEN}✓${RESET} .envrc exists"
        if direnv status 2>/dev/null | grep -q "Found RC allowed true"; then
            echo -e "${GREEN}✓${RESET} direnv trusted"
        else
            echo -e "${YELLOW}⚠${RESET} direnv not trusted (run: cd $project_path && direnv allow)"
        fi
    else
        echo -e "${RED}✗${RESET} Missing .envrc"
    fi

    # Check mise trust
    if mise ls 2>&1 | grep -q "No plugins or tools are installed"; then
        echo -e "${YELLOW}⚠${RESET} mise: no tools installed"
    else
        if mise trust 2>&1 | grep -q "No untrusted"; then
            echo -e "${GREEN}✓${RESET} mise trusted"
        else
            echo -e "${YELLOW}⚠${RESET} mise may need trust (run: cd $project_path && mise trust)"
        fi
    fi

    # Check if Python version is installed via mise
    if mise where python@${expected_version} &>/dev/null; then
        echo -e "${GREEN}✓${RESET} Python ${expected_version} installed via mise"
    else
        echo -e "${YELLOW}⚠${RESET} Python ${expected_version} not installed (run: mise install python@${expected_version})"
    fi

    # Check virtualenv
    if [[ -d .venv ]]; then
        echo -e "${GREEN}✓${RESET} .venv exists"
    else
        echo -e "${YELLOW}⚠${RESET} No .venv directory (will be created on first direnv load)"
    fi

    # Check VSCode settings
    if [[ -f .vscode/settings.json ]]; then
        echo -e "${GREEN}✓${RESET} VSCode settings exist"
        if grep -q "defaultInterpreterPath" .vscode/settings.json 2>/dev/null; then
            echo -e "${GREEN}✓${RESET} Python interpreter configured"
        else
            echo -e "${YELLOW}⚠${RESET} Python interpreter not configured"
        fi
        if grep -q '"python.terminal.activateEnvironment": false' .vscode/settings.json 2>/dev/null; then
            echo -e "${GREEN}✓${RESET} Terminal activation disabled (correct - direnv handles it)"
        else
            echo -e "${YELLOW}⚠${RESET} Terminal activation not disabled"
        fi
    else
        echo -e "${YELLOW}⚠${RESET} No VSCode settings"
    fi
}

echo "Python Environment Verification"
echo "================================"

# Check dotfiles configuration
echo ""
echo "Checking: ~/.dotfiles/.mise.toml"
if grep -q "legacy_version_file = false" ~/.dotfiles/.mise.toml 2>/dev/null; then
    echo -e "${GREEN}✓${RESET} legacy_version_file disabled"
else
    echo -e "${RED}✗${RESET} legacy_version_file should be false"
fi

echo ""
echo "Checking: ~/.config/mise/config.toml (active config)"
if grep -q "legacy_version_file = false" ~/.config/mise/config.toml 2>/dev/null; then
    echo -e "${GREEN}✓${RESET} legacy_version_file disabled in active config"
else
    echo -e "${RED}✗${RESET} legacy_version_file should be false in active config"
fi

# Check projects
check_project "/home/ubuntu/quanticli" "3.10"
check_project "/home/ubuntu/hub" "3.13"
check_project "/home/ubuntu/hub/sre-core" "3.10"
check_project "/home/ubuntu/platform/auto-conf" "3.9"
check_project "/home/ubuntu/platform/src/quantivly-sdk" "3.9"

echo ""
echo "================================"
echo "Verification complete"
echo ""
echo "To test environment activation, run:"
echo "  cd ~/.dotfiles && mise current python  # Should show: No version set"
echo "  cd ~/quanticli && mise current python  # Should show: python 3.10.x"
echo "  cd ~/hub && mise current python        # Should show: python 3.13.x"
