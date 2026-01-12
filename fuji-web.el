;;; fuji-web.el --- Web content handler for Fuji -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Ruan Xiang

;; Author: Ruan Xiang
;; Keywords: web, pdf, chrome, headless

;;; Commentary:

;; This module handles Web URL inputs for Fuji.
;; It uses Headless Chrome to convert web pages to PDF, which are then
;; processed by the standard Fuji PDF extraction pipeline.

;;; Code:

(require 'fuji-configure)

(defun fuji--chrome-available-p ()
  "Check if Chrome/Chromium is configured and available."
  (let ((cmd (or (bound-and-true-p fuji-chrome-executable)
                 (fuji--auto-detect-chrome))))
    (and cmd (file-executable-p cmd))))

(defun fuji--web-to-pdf (url output-dir)
  "Convert URL to a PDF file in OUTPUT-DIR using Headless Chrome.
Returns the absolute path to the generated PDF file."
  (unless (fuji--chrome-available-p)
    (error "Headless Chrome is required for Web URL support. Please install Google Chrome or Chromium and run M-x fuji-configure"))

  (let* ((chrome-bin (or (bound-and-true-p fuji-chrome-executable)
                         (fuji--auto-detect-chrome)))
         ;; Generate filename from URL (or timestamp if complex)
         ;; We'll try to keep it simple: domain-timestamp.pdf
         (url-obj (url-generic-parse-url url))
         (domain (url-host url-obj))
         (clean-url (replace-regexp-in-string "[^a-zA-Z0-9]" "-" url))
         ;; Limit filename length
         (short-name (if (> (length clean-url) 50)
                         (substring clean-url 0 50)
                       clean-url))
         (filename (format "web-%s-%s.pdf" 
                           (format-time-string "%Y%m%d%H%M%S")
                           short-name))
         (output-file (expand-file-name filename output-dir)))

    (unless (file-directory-p output-dir)
      (make-directory output-dir t))
    
    (message "Fuji: Converting URL to PDF with Chrome: %s" url)
    
    ;; Run Chrome in headless mode
    ;; Command: google-chrome --headless --print-to-pdf=output.pdf URL
    ;; Note: --no-sandbox might be needed in some environments (e.g. Docker), but we'll stick to standard first.
    ;; Note: --disable-gpu is often recommended for headless.
    (let ((exit-code (call-process chrome-bin nil "*Fuji Web Convert*" nil
                                   "--headless"
                                   "--disable-gpu"
                                   (format "--print-to-pdf=%s" output-file)
                                   url)))
      (if (and (zerop exit-code) (file-exists-p output-file))
          (progn
            (message "Fuji: Web conversion successful: %s" output-file)
            output-file)
        (error "Chrome failed to convert URL to PDF (exit code %d). Check *Fuji Web Convert* buffer for details" exit-code)))))

(provide 'fuji-web)
;;; fuji-web.el ends here
