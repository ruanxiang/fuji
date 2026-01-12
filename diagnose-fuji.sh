#!/bin/bash
# Diagnostic script to test fuji.el loading

echo "=== Fuji.el Loading Diagnostic ==="
echo ""

cd /home/ruan/Repositories/EmacsPaperreadingWorkflowAtGithub

echo "1. File info:"
wc -l fuji.el
ls -lh fuji.el
echo ""

echo "2. Bracket balance:"
python3 << 'EOF'
with open('fuji.el', 'r') as f:
    content = f.read()
    opens = content.count('(')
    closes = content.count(')')
    print(f"  Opening: {opens}")
    print(f"  Closing: {closes}")
    print(f"  Balance: {'OK' if opens == closes else 'FAIL'}")
EOF
echo ""

echo "3. Test with emacs --batch (no config):"
emacs --batch --eval "(condition-case err (progn (load-file \"fuji.el\") (message \"SUCCESS\")) (error (message \"FAILED: %s\" (error-message-string err))))" 2>&1 | tail -3
echo ""

echo "4. Test with emacs -Q (no config, GUI):"
echo "   Run this manually:"
echo "   emacs -Q fuji.el"
echo "   Then in Emacs: M-x eval-buffer"
echo ""

echo "5. If emacs -Q works but your normal Emacs doesn't:"
echo "   The problem is in your Emacs configuration"
echo "   Check: ~/.emacs.d/init.el or ~/.emacs"
echo ""

echo "=== End of Diagnostic ==="
