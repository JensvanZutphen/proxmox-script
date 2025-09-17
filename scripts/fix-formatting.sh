#!/bin/bash
set -euo pipefail
# Quick formatting fix script for the entire project

echo "🔧 Fixing formatting issues in proxmox-script project..."

# Determine sed -i option
SED_INPLACE=(-i'')
if sed --version >/dev/null 2>&1; then SED_INPLACE=(-i); fi

# Process tracked shell scripts only
git ls-files -z -- '*.sh' '*.bash' | while IFS= read -r -d '' f; do
  sed "${SED_INPLACE[@]}" $'s/\t/    /g' "$f"
  sed "${SED_INPLACE[@]}" $'s/[[:space:]]*$//' "$f"
done

echo "✅ Formatting fixes applied!"
echo ""
echo "💡 To install the pre-commit hook (auto-fixes on commit):"
echo "   ln -sf ../../.github/pre-commit-hook.sh .git/hooks/pre-commit"
echo ""
echo "💡 To check what was changed:"
echo "   git diff"
echo ""
echo "GNU find/sed one‑liner:"
echo "   find . -type f \\( -name '*.sh' -o -name '*.bash' \\) -exec sed -i -e 's/\\t/    /g' -e 's/[[:space:]]*$//' {} +"
echo "macOS/BSD sed variant:"
echo "   find . -type f \\( -name '*.sh' -o -name '*.bash' \\) -exec sed -i '' -e 's/\\t/    /g' -e 's/[[:space:]]*$//' {} +"
