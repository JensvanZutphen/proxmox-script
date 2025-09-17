#!/bin/bash
# Quick formatting fix script for the entire project

echo "🔧 Fixing formatting issues in proxmox-script project..."

# Fix tab characters in shell scripts
echo "Converting tabs to spaces..."
find . -name "*.sh" -exec sed -i 's/\t/    /g' {} +

# Remove trailing whitespace from shell scripts
echo "Removing trailing whitespace..."
find . -name "*.sh" -exec sed -i 's/[[:space:]]*$//' {} +

echo "✅ Formatting fixes applied!"
echo ""
echo "💡 To install the pre-commit hook (auto-fixes on commit):"
echo "   ln -sf ../../.github/pre-commit-hook.sh .git/hooks/pre-commit"
echo ""
echo "💡 To check what was changed:"
echo "   git diff"
