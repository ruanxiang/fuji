;;; fuji-init-fix.el --- Workaround for Gemini variable issue -*- lexical-binding: t; -*-

;; This file provides a workaround for the "void-variable Gemini" error
;; that occurs when loading fuji.el in certain Emacs configurations.

;; Add this to your Emacs init file BEFORE loading fuji:
;; (load-file "/path/to/fuji-init-fix.el")

;;; Code:

;; Define Gemini as nil if it doesn't exist
;; This prevents "void-variable Gemini" errors
(unless (boundp 'Gemini)
  (defvar Gemini nil
    "Placeholder variable to prevent void-variable errors.
This is a workaround for compatibility with certain Emacs configurations."))

(provide 'fuji-init-fix)

;;; fuji-init-fix.el ends here
