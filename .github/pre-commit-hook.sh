#!/bin/bash
# Pre-commit hook to auto-fix formatting issues
# Install with: ln -sf ../../.github/pre-commit-hook.sh .git/hooks/pre-commit

set -euo pipefail

echo "🔍 Checking for formatting issues..."

# Collect staged shell files (A/C/M) safely
mapfile -d '' STAGED < <(git diff --cached --name-only -z --diff-filter=ACM)

# Choose sed -i flag portable across GNU/BSD
SED_INPLACE=(-i'') # works on BSD/macOS; GNU sed ignores empty suffix
if sed --version >/dev/null 2>&1; then SED_INPLACE=(-i); fi

had_fix=0
for f in "${STAGED[@]}"; do
  case "$f" in
    *.sh|*.bash)
      if grep -q $'\t' -- "$f"; then
        echo "🔧 Converting tabs in $f"
        sed "${SED_INPLACE[@]}" $'s/\t/    /g' "$f"; had_fix=1
      fi
      if grep -q '[[:space:]]$' -- "$f"; then
        echo "🔧 Removing trailing whitespace in $f"
        sed "${SED_INPLACE[@]}" $'s/[[:space:]]*$//' "$f"; had_fix=1
      fi
      ;;
  esac
done

if [[ "${had_fix:-0}" -eq 1 ]]; then
  git add -- *.sh *.bash 2>/dev/null || true
fi

echo "✅ Pre-commit formatting checks passed"
