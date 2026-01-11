#!/bin/bash
# Clean up byte-compiled files to avoid stale .elc issues

echo "=== Cleaning Fuji Development Environment ==="
echo ""

cd "$(dirname "$0")"

# Remove all .elc files
if ls *.elc 1> /dev/null 2>&1; then
    echo "Removing byte-compiled files:"
    rm -v *.elc
    echo "✅ Cleaned up .elc files"
else
    echo "✅ No .elc files found"
fi

# Remove auto-save files
if ls \#*\# 1> /dev/null 2>&1; then
    echo "Removing auto-save files:"
    rm -v \#*\#
fi

# Remove backup files
if ls *~ 1> /dev/null 2>&1; then
    echo "Removing backup files:"
    rm -v *~
fi

echo ""
echo "✅ Development environment cleaned!"
echo ""
echo "Note: During development, always use .el source files."
echo "Only byte-compile for production releases."
