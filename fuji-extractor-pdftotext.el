;;; fuji-extractor-pdftotext.el --- pdftotext PDF Extractor Plugin -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Ruan Xiang

;; Author: Ruan Xiang
;; Keywords: pdf, pdftotext, extraction
;; Version: 0.8.0

;;; Commentary:

;; This file implements the pdftotext extractor plugin for Fuji.
;; pdftotext is a lightweight, fast text extraction tool (no figure support).

;;; Code:

(require 'fuji-extractor)

;;; Extractor Implementation

(defun fuji--pdftotext-available-p ()
  "Check if pdftotext is available."
  (executable-find "pdftotext"))

(defun fuji--pdftotext-extract (pdf-file output-dir)
  "Extract PDF-FILE to OUTPUT-DIR using pdftotext.
Returns the path to the generated markdown file."
  (let* ((pdf-file (expand-file-name pdf-file))
         (output-dir (expand-file-name output-dir))
         (output-file (expand-file-name 
                       (concat (file-name-base pdf-file) ".md")
                       output-dir)))
    
    (unless (file-directory-p output-dir)
      (make-directory output-dir t))
    
    ;; Check cache first
    (if (file-exists-p output-file)
        (progn
          (message "Fuji: Using cached pdftotext results")
          output-file)
      
      ;; Extract text
      (message "Fuji: Extracting with pdftotext...")
      (with-temp-buffer
        (let ((exit-code (call-process "pdftotext" nil t nil pdf-file "-")))
          (if (zerop exit-code)
              (let ((text (buffer-string)))
                ;; Write to markdown file
                (with-temp-file output-file
                  (insert "# " (file-name-base pdf-file) "\n\n")
                  (insert text))
                (message "Fuji: pdftotext extraction complete")
                output-file)
            (error "pdftotext failed with exit code %d" exit-code)))))))

;;; Register Plugin

(fuji-register-extractor
 (make-fuji-extractor
  :name "pdftotext"
  :description "Fast text-only extraction (no figures, lightweight)"
  :available-p #'fuji--pdftotext-available-p
  :extract-fn #'fuji--pdftotext-extract
  :priority 50))  ; Medium priority - good fallback

(provide 'fuji-extractor-pdftotext)

;;; fuji-extractor-pdftotext.el ends here
