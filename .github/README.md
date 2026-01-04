# GitHub Actions CI/CD

This directory contains automated workflows for ensuring code quality and correctness.

## Workflows

### CI (`workflows/ci.yml`)

Runs on every push and pull request to `main`. Includes:

1. **ShellCheck**: Lints all shell scripts for common issues
2. **Syntax Check**: Validates bash and zsh syntax for all modules
3. **YAML Validation**: Ensures all YAML files are properly formatted
4. **Pre-commit Hooks**: Runs security and quality checks
5. **Installation Tests**: Tests on Ubuntu 22.04 and 24.04
6. **Security Scan**: Runs gitleaks for secret detection
7. **Documentation Check**: Validates markdown links and required docs

## Local Testing

Before pushing, you can test locally:

```bash
# Install act (https://github.com/nektos/act)
# Then run specific jobs:
act -j shellcheck
act -j syntax-check
act -j pre-commit

# Or run all checks
pre-commit run --all-files
```

## Configuration

- **Markdown Link Check**: `.github/workflows/markdown-link-check-config.json`
- **Pre-commit Hooks**: `.pre-commit-config.yaml`
- **YAML Lint**: Inline configuration in `ci.yml`

## Badges

Add to README.md:

```markdown
![CI](https://github.com/quantivly/dotfiles/workflows/CI/badge.svg)
```

## Maintenance

- **Actions versions**: Updated quarterly or when security fixes available
- **Pre-commit hooks**: Updated via `pre-commit autoupdate`
- **Test matrices**: Add new Ubuntu LTS versions as released
