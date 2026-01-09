;;; fuji-extractor.el --- PDF/Document Extractor Plugin API -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Ruan Xiang

;; Author: Ruan Xiang
;; Keywords: pdf, extraction, plugins
;; Version: 0.8.0

;;; Commentary:

;; This file defines the unified API for PDF/document extractor plugins.
;; It provides:
;; - A base structure for extractor plugins
;; - A plugin registry system
;; - Unified extraction API that dispatches to the appropriate plugin
;; - Auto-selection based on availability and priority

;;; Code:

(require 'cl-lib)

;;; API Definition

(cl-defstruct fuji-extractor
  "Base structure for PDF extractor plugins.
Each extractor plugin should create an instance of this structure
and register it using `fuji-register-extractor'.

Slots:
- name: String identifier (e.g., \"marker\", \"pdftotext\", \"pandoc\")
- description: Human-readable description of the extractor
- available-p: Function () -> bool, checks if extractor is available
- extract-fn: Function (pdf-file output-dir) -> markdown-file-path
- priority: Integer, higher = preferred for auto-selection (default: 50)"
  name
  description
  available-p
  extract-fn
  (priority 50))

;;; Plugin Registry

(defvar fuji--extractors (make-hash-table :test 'equal)
  "Registry of available extractor plugins.
Keys are extractor names (strings), values are `fuji-extractor' structs.")

(defcustom fuji-preferred-extractor nil
  "Preferred PDF extractor plugin name.
If nil, auto-select based on availability and priority.
Valid values: \"marker\", \"pdftotext\", \"pandoc\", or nil for auto-selection."
  :type '(choice (const :tag "Auto-select" nil)
                 (const :tag "Marker" "marker")
                 (const :tag "pdftotext" "pdftotext")
                 (const :tag "Pandoc" "pandoc")
                 (string :tag "Custom extractor name"))
  :group 'fuji)

;;; Registry Functions

(defun fuji-register-extractor (extractor)
  "Register an EXTRACTOR plugin in the global registry.
EXTRACTOR should be a `fuji-extractor' struct."
  (unless (fuji-extractor-p extractor)
    (error "Invalid extractor: must be a fuji-extractor struct"))
  (let ((name (fuji-extractor-name extractor)))
    (puthash name extractor fuji--extractors)
    (message "Fuji: Registered extractor plugin '%s'" name)))

(defun fuji-list-extractors ()
  "List all registered extractors.
Returns a list of extractor names (strings)."
  (let ((names nil))
    (maphash (lambda (name _extractor) (push name names)) fuji--extractors)
    names))

(defun fuji-get-extractor (name)
  "Get extractor plugin by NAME.
Returns the `fuji-extractor' struct or nil if not found."
  (gethash name fuji--extractors))

(defun fuji--available-extractors ()
  "Get list of available (installed) extractors.
Returns a list of extractor names sorted by priority (highest first)."
  (let ((available nil))
    (maphash
     (lambda (name extractor)
       (when (and (fuji-extractor-available-p extractor)
                  (funcall (fuji-extractor-available-p extractor)))
         (push (cons name (fuji-extractor-priority extractor)) available)))
     fuji--extractors)
    ;; Sort by priority (descending)
    (mapcar #'car
            (sort available
                  (lambda (a b) (> (cdr a) (cdr b)))))))

(defun fuji--select-extractor (&optional preferred)
  "Select an extractor to use.
Priority order:
1. PREFERRED argument (if provided and available)
2. Buffer-local session override (fuji--session-extractor)
3. Global configuration default (fuji-pdf-extractor-default from Phase 1)
4. Legacy global preference (fuji-preferred-extractor)
5. Auto-select highest priority available extractor
Returns the extractor name (string) or nil if none available."
  (let ((available (fuji--available-extractors))
        (choice (or preferred
                    (and (boundp 'fuji--session-extractor) fuji--session-extractor)
                    (and (boundp 'fuji-pdf-extractor-default) fuji-pdf-extractor-default)
                    fuji-preferred-extractor)))
    (cond
     ;; Use specified choice if available
     ((and choice (member choice available))
      choice)
     ;; Auto-select highest priority
     (available
      (car available))
     ;; No extractors available
     (t
      (error "No PDF extractors available. Please install marker, pdftotext, or pandoc")))))

;;; Unified Extraction API

(defun fuji--extract (pdf-file output-dir &optional extractor-name)
  "Extract PDF-FILE to OUTPUT-DIR using specified or auto-selected extractor.
EXTRACTOR-NAME: Optional string specifying which extractor to use.
                If nil, auto-select based on availability and priority.
Returns the path to the generated markdown file."
  (unless (file-exists-p pdf-file)
    (error "PDF file does not exist: %s" pdf-file))
  
  ;; Ensure output directory exists
  (unless (file-directory-p output-dir)
    (make-directory output-dir t))
  
  ;; Select extractor
  (let* ((selected-name (fuji--select-extractor extractor-name))
         (extractor (fuji-get-extractor selected-name)))
    
    (unless extractor
      (error "Extractor not found: %s" selected-name))
    
    (message "Fuji: Extracting with %s..." selected-name)
    
    ;; Call the extractor's extract function
    (funcall (fuji-extractor-extract-fn extractor)
             pdf-file
             output-dir)))

;;; Interactive Commands

(defun fuji-set-extractor (extractor-name)
  "Switch to a different PDF extractor globally.
EXTRACTOR-NAME should be a registered extractor name (string) or empty for auto-selection."
  (interactive
   (list (completing-read "Select extractor (empty for auto): "
                          (cons "auto" (fuji-list-extractors))
                          nil t)))
  (if (or (string-empty-p extractor-name) (string= extractor-name "auto"))
      (progn
        (setq fuji-preferred-extractor nil)
        (message "Fuji: Extractor set to auto-select"))
    (let ((extractor (fuji-get-extractor extractor-name)))
      (unless extractor
        (error "Extractor '%s' not registered" extractor-name))
      (unless (and (fuji-extractor-available-p extractor)
                   (funcall (fuji-extractor-available-p extractor)))
        (error "Extractor '%s' not available or not configured" extractor-name))
      (setq fuji-preferred-extractor extractor-name)
      (message "Fuji: Switched to extractor '%s'" extractor-name))))

(defun fuji-show-extractors ()
  "Display information about registered extractors."
  (interactive)
  (let ((extractors (fuji-list-extractors))
        (available (fuji--available-extractors)))
    (with-current-buffer (get-buffer-create "*Fuji Extractors*")
      (erase-buffer)
      (insert "=== Fuji PDF Extractors ===\n\n")
      (insert (format "Preferred: %s\n" (or fuji-preferred-extractor "Auto-select")))
      (insert (format "Available: %s\n\n" (string-join available ", ")))
      (insert "Registered Extractors:\n")
      (dolist (name extractors)
        (let* ((ext (fuji-get-extractor name))
               (avail (member name available)))
          (insert (format "  [%s] %s (priority: %d)\n"
                          (if avail "✓" " ")
                          name
                          (fuji-extractor-priority ext)))
          (insert (format "      %s\n" (fuji-extractor-description ext)))))
      (goto-char (point-min))
      (display-buffer (current-buffer)))))

(provide 'fuji-extractor)

;;; fuji-extractor.el ends here
