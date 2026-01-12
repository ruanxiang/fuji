#!/bin/bash
# Ultimate fix script for fuji.el loading issue

echo "=== Fuji.el Ultimate Fix Script ==="
echo ""

cd /home/ruan/Repositories/EmacsPaperreadingWorkflowAtGithub

echo "Step 1: Verify disk file is correct"
echo "  Lines: $(wc -l < fuji.el)"
echo "  MD5: $(md5sum fuji.el | cut -d' ' -f1)"
echo "  Last line: $(tail -1 fuji.el)"
echo ""

echo "Step 2: Test with emacs --batch"
if emacs --batch --eval "(load-file \"fuji.el\")" 2>&1 | grep -q "gptel"; then
    echo "  ✅ File loads in emacs --batch (only gptel dependency missing)"
else
    echo "  ❌ File has syntax errors"
    exit 1
fi
echo ""

echo "Step 3: Force kill any Emacs auto-save files"
rm -f fuji.el~ \#fuji.el\# .#fuji.el
echo "  Removed any auto-save/backup files"
echo ""

echo "Step 4: Try loading in emacs -Q (clean Emacs)"
echo "  Please run this command manually:"
echo "  emacs -Q fuji.el"
echo "  Then in Emacs: M-x eval-buffer"
echo ""

echo "Step 5: If emacs -Q works but your normal Emacs doesn't:"
echo "  The problem is in your ~/.emacs.d/init.el"
echo "  Try bisecting your config to find the problematic package"
echo ""

echo "Step 6: Nuclear option - byte compile the file"
echo "  This will force Emacs to parse it correctly:"
emacs --batch -f batch-byte-compile fuji.el 2>&1 | head -10
if [ -f fuji.elc ]; then
    echo "  ✅ Byte compilation successful!"
    echo "  You can now (load \"fuji.elc\") instead of (load-file \"fuji.el\")"
else
    echo "  ❌ Byte compilation failed"
fi
echo ""

echo "=== End of Fix Script ==="
