#!/usr/bin/env bash
# Python environment helper functions for .envrc files
# Source this file in your .envrc: source ~/.dotfiles/shell/python-env-helpers.sh

# Check if dependencies are actually installed (not just a fresh venv)
_check_deps_installed() {
    local venv_dir="$1"
    local site_packages

    # Find site-packages directory
    site_packages=$(find "$venv_dir/lib" -type d -name "site-packages" 2>/dev/null | head -1)
    [ -z "$site_packages" ] && return 1

    # Count non-default packages (exclude pip, setuptools, pkg_resources, _distutils_hack, distutils-precedence.pth)
    local pkg_count
    pkg_count=$(find "$site_packages" -maxdepth 1 -type d ! -name "site-packages" ! -name "__pycache__" ! -name "pip*" ! -name "setuptools*" ! -name "pkg_resources" ! -name "_distutils_hack" ! -name "*.dist-info" 2>/dev/null | wc -l)

    # If we have more than just the default packages, consider deps installed
    [ "$pkg_count" -gt 0 ]
}

check_python_dependencies() {
    local project_root="${1:-.}"
    local venv_dir="${project_root}/.venv"

    # Skip if no .venv exists yet
    [ ! -d "$venv_dir" ] && return 0

    # Poetry project detection
    if [ -f "${project_root}/poetry.lock" ]; then
        # Check if dependencies are actually installed
        if ! _check_deps_installed "$venv_dir"; then
            echo "⚠️  Dependencies not installed. Run: poetry install"
            return 1
        fi
        # Check if lock file is newer
        if [ "${project_root}/poetry.lock" -nt "$venv_dir" ]; then
            echo "⚠️  Dependencies outdated (poetry.lock is newer). Run: poetry install"
            return 1
        fi
        return 0
    fi

    # pip with requirements.txt
    if [ -f "${project_root}/requirements.txt" ]; then
        # Check if dependencies are actually installed
        if ! _check_deps_installed "$venv_dir"; then
            echo "⚠️  Dependencies not installed. Run: pip install -r requirements.txt"
            return 1
        fi
        # Check if requirements file is newer
        if [ "${project_root}/requirements.txt" -nt "$venv_dir" ]; then
            echo "⚠️  Dependencies outdated (requirements.txt is newer). Run: pip install -r requirements.txt"
            return 1
        fi
        return 0
    fi

    # pip with requirements/ directory (Django-style)
    if [ -d "${project_root}/requirements" ]; then
        # Check if dependencies are actually installed
        if ! _check_deps_installed "$venv_dir"; then
            echo "⚠️  Dependencies not installed. Run: pip install -r requirements/local.txt"
            return 1
        fi
        # Check if any requirements file is newer than .venv
        local newest_req
        newest_req=$(find "${project_root}/requirements" -name "*.txt" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

        if [ -n "$newest_req" ] && [ "$newest_req" -nt "$venv_dir" ]; then
            echo "⚠️  Dependencies outdated (requirements/ files are newer). Run: pip install -r requirements/local.txt"
            return 1
        fi
        return 0
    fi

    # pip with pyproject.toml but no poetry.lock (PEP 621 projects)
    if [ -f "${project_root}/pyproject.toml" ] && [ ! -f "${project_root}/poetry.lock" ]; then
        # Check if dependencies are actually installed
        if ! _check_deps_installed "$venv_dir"; then
            echo "⚠️  Dependencies not installed. Run: pip install -e ."
            return 1
        fi
        # Check if pyproject.toml is newer
        if [ "${project_root}/pyproject.toml" -nt "$venv_dir" ]; then
            echo "⚠️  Dependencies outdated (pyproject.toml is newer). Run: pip install -e ."
            return 1
        fi
        return 0
    fi

    return 0
}
