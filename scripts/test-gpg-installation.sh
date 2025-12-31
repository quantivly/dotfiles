#!/bin/bash
# Test GPG utilities installation
# Usage: ./scripts/test-gpg-installation.sh

set -e

DOTFILES_ROOT="${HOME}/.dotfiles"
SCRIPTS_DIR="${DOTFILES_ROOT}/scripts"
BIN_DIR="${HOME}/.local/bin"

echo "Testing GPG Utilities Installation"
echo "===================================="
echo ""

errors=0
warnings=0

# Test 1: Scripts exist in repository
echo "1. Checking repository scripts..."
for script in gpg-prime-cache git-check-gpg-cache install-gpg-hooks; do
    if [ -f "${SCRIPTS_DIR}/${script}" ]; then
        echo "  ✓ ${script} exists"
        if [ -x "${SCRIPTS_DIR}/${script}" ]; then
            echo "    ✓ Executable"
        else
            echo "    ✗ Not executable"
            ((errors++))
        fi
    else
        echo "  ✗ ${script} missing"
        ((errors++))
    fi
done
echo ""

# Test 2: Symlinks created correctly
echo "2. Checking symlinks..."
for script in gpg-prime-cache git-check-gpg-cache install-gpg-hooks; do
    if [ -L "${BIN_DIR}/${script}" ]; then
        echo "  ✓ ${script} symlinked"
        target=$(readlink "${BIN_DIR}/${script}")
        if [[ "$target" == *"dotfiles/scripts/${script}" ]]; then
            echo "    ✓ Correct target"
        else
            echo "    ⚠ Unexpected target: $target"
            ((warnings++))
        fi
    elif [ -f "${BIN_DIR}/${script}" ]; then
        echo "  ⚠ ${script} exists but is not a symlink"
        ((warnings++))
    else
        echo "  ✗ ${script} not found"
        ((errors++))
    fi
done
echo ""

# Test 3: Scripts in PATH
echo "3. Checking PATH accessibility..."
for script in gpg-prime-cache git-check-gpg-cache install-gpg-hooks; do
    if command -v "$script" &> /dev/null; then
        echo "  ✓ ${script} in PATH"
    else
        echo "  ✗ ${script} not in PATH"
        ((errors++))
    fi
done
echo ""

# Test 4: Alias exists
echo "4. Checking gpg-prime alias..."
if grep -q "alias gpg-prime='gpg-prime-cache'" "${DOTFILES_ROOT}/zsh/zshrc.aliases"; then
    echo "  ✓ gpg-prime alias defined"
else
    echo "  ⚠ gpg-prime alias not found"
    ((warnings++))
fi
echo ""

# Test 5: Documentation exists
echo "5. Checking documentation..."
if [ -f "${DOTFILES_ROOT}/examples/gpg-setup-guide.md" ]; then
    lines=$(wc -l < "${DOTFILES_ROOT}/examples/gpg-setup-guide.md")
    echo "  ✓ gpg-setup-guide.md exists ($lines lines)"
else
    echo "  ⚠ gpg-setup-guide.md missing"
    ((warnings++))
fi
if [ -f "${DOTFILES_ROOT}/docs/GPG_SIGNING_SETUP.md" ]; then
    echo "  ✓ GPG_SIGNING_SETUP.md exists"
else
    echo "  ⚠ GPG_SIGNING_SETUP.md missing"
    ((warnings++))
fi
echo ""

# Test 6: Pre-commit hook
echo "6. Checking pre-commit hook..."
HOOK_PATH="${HOME}/.config/git/hooks/pre-commit"
if [ -f "$HOOK_PATH" ]; then
    echo "  ✓ Pre-commit hook exists"
    if grep -q "git-check-gpg-cache" "$HOOK_PATH"; then
        echo "    ✓ References git-check-gpg-cache"
    else
        echo "    ⚠ Doesn't reference git-check-gpg-cache"
        ((warnings++))
    fi
    if [ -x "$HOOK_PATH" ]; then
        echo "    ✓ Executable"
    else
        echo "    ✗ Not executable"
        ((errors++))
    fi
else
    echo "  ✗ Pre-commit hook missing"
    ((errors++))
fi
echo ""

# Summary
echo "===================================="
if [ $errors -eq 0 ] && [ $warnings -eq 0 ]; then
    echo "✓ All tests passed!"
    echo ""
    echo "GPG utilities are properly installed."
    echo "Run 'gpg-prime' to get started!"
    exit 0
elif [ $errors -eq 0 ]; then
    echo "⚠ Tests passed with ${warnings} warning(s)"
    echo ""
    echo "GPG utilities should work, but some"
    echo "optional components may be missing."
    exit 0
else
    echo "✗ Tests failed: ${errors} error(s), ${warnings} warning(s)"
    echo ""
    echo "Try running: cd ~/.dotfiles && ./install"
    exit 1
fi
