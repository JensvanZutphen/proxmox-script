#!/bin/bash
# Pre-commit hook to auto-fix formatting issues
# Install with: ln -sf ../../.github/pre-commit-hook.sh .git/hooks/pre-commit

set -e

echo "🔍 Checking for formatting issues..."

# Check for and fix tab characters
if git diff --cached --name-only | grep -E '\.(sh|bash)$' | xargs -r grep -l $'\t' 2>/dev/null; then
    echo "🔧 Auto-fixing tab characters..."
    git diff --cached --name-only | grep -E '\.(sh|bash)$' | xargs -r sed -i 's/\t/    /g'
    echo "✅ Tabs converted to spaces"
fi

# Check for and fix trailing whitespace
if git diff --cached --name-only | grep -E '\.(sh|bash)$' | xargs -r grep -l '[[:space:]]$' 2>/dev/null; then
    echo "🔧 Auto-fixing trailing whitespace..."
    git diff --cached --name-only | grep -E '\.(sh|bash)$' | xargs -r sed -i 's/[[:space:]]*$//'
    echo "✅ Trailing whitespace removed"
fi

# Re-stage the fixed files
git diff --cached --name-only | grep -E '\.(sh|bash)$' | xargs -r git add

echo "✅ Pre-commit formatting checks passed"
