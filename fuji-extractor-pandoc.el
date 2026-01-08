;;; fuji-extractor-pandoc.el --- Pandoc Document Extractor Plugin -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Ruan Xiang

;; Author: Ruan Xiang
;; Keywords: pandoc, extraction, docx, epub
;; Version: 0.8.0

;;; Commentary:

;; This file implements the Pandoc extractor plugin for Fuji.
;; Pandoc can extract text from various formats: PDF, DOCX, EPUB, HTML, etc.

;;; Code:

(require 'fuji-extractor)

;;; Extractor Implementation

(defun fuji--pandoc-available-p ()
  "Check if Pandoc is available."
  (executable-find "pandoc"))

(defun fuji--pandoc-extract (input-file output-dir)
  "Extract INPUT-FILE to OUTPUT-DIR using Pandoc.
Returns the path to the generated markdown file.
Works with PDF, DOCX, EPUB, HTML, and other formats."
  (let* ((input-file (expand-file-name input-file))
         (output-dir (expand-file-name output-dir))
         (output-file (expand-file-name 
                       (concat (file-name-base input-file) ".md")
                       output-dir)))
    
    (unless (file-directory-p output-dir)
      (make-directory output-dir t))
    
    ;; Check cache first
    (if (file-exists-p output-file)
        (progn
          (message "Fuji: Using cached Pandoc results")
          output-file)
      
      ;; Extract with Pandoc
      (message "Fuji: Extracting with Pandoc...")
      (let ((exit-code (call-process "pandoc" nil nil nil
                                     input-file
                                     "-o" output-file
                                     "-t" "markdown"
                                     "--wrap=none")))
        (if (zerop exit-code)
            (progn
              (message "Fuji: Pandoc extraction complete")
              output-file)
          (error "Pandoc failed with exit code %d" exit-code))))))

;;; Register Plugin

(fuji-register-extractor
 (make-fuji-extractor
  :name "pandoc"
  :description "Universal document converter (PDF, DOCX, EPUB, HTML)"
  :available-p #'fuji--pandoc-available-p
  :extract-fn #'fuji--pandoc-extract
  :priority 30))  ; Lower priority - general purpose fallback

(provide 'fuji-extractor-pandoc)

;;; fuji-extractor-pandoc.el ends here
