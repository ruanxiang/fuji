;; 请在你的 Emacs 中执行：M-x eval-buffer（在这个 buffer 中）
;; 这会告诉我们你的 Emacs 实际看到的文件内容

(let* ((file "/home/ruan/Repositories/EmacsPaperreadingWorkflowAtGithub/fuji.el")
       (buf (find-file-noselect file)))
  (with-current-buffer buf
    (let ((total-lines (line-number-at-pos (point-max))))
      (message "=== Emacs Buffer Analysis ===")
      (message "Total lines in buffer: %d" total-lines)
      (message "Buffer coding system: %s" buffer-file-coding-system)
      (message "Buffer multibyte: %s" enable-multibyte-characters)
      
      ;; 查看最后 10 行
      (message "\nLast 10 lines:")
      (goto-char (point-max))
      (forward-line -10)
      (dotimes (i 10)
        (let ((line-num (line-number-at-pos))
              (line-content (buffer-substring-no-properties 
                            (line-beginning-position) 
                            (line-end-position))))
          (message "Line %d: %S" line-num line-content))
        (forward-line 1))
      
      ;; 计算括号
      (goto-char (point-min))
      (let ((opens 0) (closes 0))
        (while (re-search-forward "[()]" nil t)
          (if (string= (match-string 0) "(")
              (setq opens (1+ opens))
            (setq closes (1+ closes))))
        (message "\nBracket count in buffer:")
        (message "  Opens: %d" opens)
        (message "  Closes: %d" closes)
        (message "  Diff: %d" (- opens closes)))
      
      (message "\n=== Check *Messages* buffer for results ===")
      (switch-to-buffer "*Messages*"))))
