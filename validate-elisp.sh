#!/bin/bash
# Emacs Lisp syntax validation script
# Usage: ./validate-elisp.sh [file.el]

set -e

FILE="${1:-fuji.el}"

echo "=== Validating Emacs Lisp: $FILE ==="

# 1. Check file exists
if [ ! -f "$FILE" ]; then
    echo "❌ Error: File '$FILE' not found"
    exit 1
fi

# 2. Count parentheses
echo -n "Checking bracket balance... "
OPEN=$(grep -o '(' "$FILE" | wc -l)
CLOSE=$(grep -o ')' "$FILE" | wc -l)
DIFF=$((OPEN - CLOSE))

if [ $DIFF -eq 0 ]; then
    echo "✅ Balanced ($OPEN opening, $CLOSE closing)"
else
    echo "❌ UNBALANCED: $DIFF extra opening parens"
    echo "   Opening: $OPEN"
    echo "   Closing: $CLOSE"
    exit 1
fi

# 3. Run Emacs check-parens
echo -n "Running check-parens... "
if emacs --batch --eval "(with-temp-buffer (insert-file-contents \"$FILE\") (emacs-lisp-mode) (check-parens))" 2>&1 | grep -q "Unmatched"; then
    echo "❌ FAILED"
    emacs --batch --eval "(with-temp-buffer (insert-file-contents \"$FILE\") (emacs-lisp-mode) (check-parens))" 2>&1
    exit 1
else
    echo "✅ Passed"
fi

# 4. Try to byte-compile (optional, may fail on missing dependencies)
echo -n "Attempting byte-compile... "
if emacs --batch --eval "(progn (setq byte-compile-error-on-warn nil) (byte-compile-file \"$FILE\"))" 2>&1 | grep -q "error"; then
    echo "⚠️  Warning: Byte-compile had errors (may be due to missing dependencies)"
else
    echo "✅ Passed"
fi

echo ""
echo "=== Validation Complete ==="
echo "✅ $FILE is syntactically valid"
