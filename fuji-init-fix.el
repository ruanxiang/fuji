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

;; Workaround for "Error during redisplay: (eval (pdf-misc-size-indication) t)"
;; This error happens when pdf-tools returns an invalid type for the modeline.
(with-eval-after-load 'pdf-tools
  (when (fboundp 'pdf-misc-size-indication)
    (advice-add 'pdf-misc-size-indication :around
                (lambda (orig-fun &rest args)
                  (condition-case nil
                      (apply orig-fun args)
                    (error ""))))))

;;; fuji-init-fix.el ends here
