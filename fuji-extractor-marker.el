;;; fuji-extractor-marker.el --- Marker PDF Extractor Plugin -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Ruan Xiang

;; Author: Ruan Xiang
;; Keywords: pdf, marker, extraction
;; Version: 0.8.0

;;; Commentary:

;; This file implements the Marker PDF extractor plugin for Fuji.
;; Marker is a high-accuracy OCR tool with figure support.

;;; Code:

(require 'fuji-extractor)
(require 'ansi-color)

;;; Configuration

(defcustom fuji-marker-executable "marker_single"
  "Path to the Marker executable.
Can be 'marker' or 'marker_single' (recommended for single-file processing)."
  :type 'string
  :group 'fuji)

;;; Helper Functions

(defun fuji--marker-find-output (dir)
  "Find the first .md file in DIR or its subfolders."
  (let ((files (directory-files-recursively dir "\\.md$")))
    (when files
      (car files))))

(defun fuji--marker-get-executable ()
  "Get the best available Marker executable.
Prefers marker_single if available, falls back to configured executable."
  (let ((single-exe (expand-file-name "marker_single" 
                                      (file-name-directory (or fuji-marker-executable "")))))
    (cond
     ;; If already configured to use marker_single
     ((and fuji-marker-executable 
           (string-match-p "marker_single$" fuji-marker-executable))
      fuji-marker-executable)
     ;; If marker_single exists in the same directory
     ((and (file-exists-p single-exe) (file-executable-p single-exe))
      single-exe)
     ;; Fall back to configured executable
     (t fuji-marker-executable))))

;;; Extractor Implementation

(defun fuji--marker-available-p ()
  "Check if Marker is available."
  (and fuji-marker-executable
       (or (file-executable-p fuji-marker-executable)
           (executable-find fuji-marker-executable))
       t))

(defun fuji--marker-extract (pdf-file output-dir &optional callback)
  "Extract PDF-FILE to OUTPUT-DIR using Marker.
If CALLBACK is provided, run asynchronously and call CALLBACK with the markdown file path.
If CALLBACK is nil, run synchronously and return the markdown file path.
This dual-mode design supports both sync and async workflows."
  (let* ((pdf-file (expand-file-name pdf-file))
         (output-dir (expand-file-name output-dir))
         (existing-md (fuji--marker-find-output output-dir)))
    
    ;; Check cache first
    (if existing-md
        (progn
          (message "Fuji: Using cached Marker results")
          (if callback
              (funcall callback existing-md)
            existing-md))
      
      ;; Run Marker extraction
      (if callback
          ;; Async mode
          (fuji--marker-extract-async 
           pdf-file output-dir
           callback
           (lambda (err) (error "Marker extraction failed: %s" err)))
        ;; Sync mode (blocking - not recommended for Marker)
        (let ((result-file nil)
              (error-msg nil))
          (fuji--marker-extract-async 
           pdf-file output-dir
           (lambda (md-file) (setq result-file md-file))
           (lambda (err) (setq error-msg err)))
          
          ;; Wait for completion (blocking)
          (while (and (not result-file) (not error-msg))
            (sleep-for 0.1))
          
          (if error-msg
              (error "Marker extraction failed: %s" error-msg)
            result-file))))))

(defun fuji--marker-extract-async (pdf-file output-dir success-callback error-callback)
  "Extract PDF-FILE to OUTPUT-DIR using Marker asynchronously.
Call SUCCESS-CALLBACK with the markdown file path on success.
Call ERROR-CALLBACK with error message on failure."
  (let* ((pdf-file (expand-file-name pdf-file))
         (output-dir (expand-file-name output-dir))
         (marker-exe (fuji--marker-get-executable))
         (marker-args (list "--output_dir" output-dir pdf-file))
         (out-buf (get-buffer-create "*Fuji Marker Output*")))
    
    (unless (file-directory-p output-dir)
      (make-directory output-dir t))
    
    (message "Fuji: Starting Marker extraction for %s..." 
             (file-name-nondirectory pdf-file))
    
    (with-current-buffer out-buf
      (unless enable-multibyte-characters
        (set-buffer-multibyte t))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Fuji: Processing PDF with Marker (PTY mode)...\n")
        (insert "Note: The FIRST run may take several minutes as it downloads AI models (several GB).\n")
        (insert "Command: " (or marker-exe "marker") " " (mapconcat #'identity marker-args " ") "\n")
        (insert (make-string 40 ?-) "\n\n"))
      (display-buffer (current-buffer)))
    
    (let* ((process-environment (cons "PYTHONUNBUFFERED=1" process-environment))
           (process (make-process
                     :name "fuji-marker"
                     :buffer out-buf
                     :command (cons (or marker-exe "marker") marker-args)
                     :connection-type 'pty
                     :filter (lambda (proc string)
                               (when (buffer-live-p (process-buffer proc))
                                 (with-current-buffer (process-buffer proc)
                                   (let ((moving (= (point) (process-mark proc)))
                                         (inhibit-read-only t))
                                     (save-excursion
                                       (goto-char (process-mark proc))
                                       (insert (ansi-color-apply string))
                                       (set-marker (process-mark proc) (point)))
                                     (if moving (goto-char (process-mark proc)))))))
                     :sentinel (lambda (proc event)
                                 (when (memq (process-status proc) '(exit signal))
                                   (let ((exit-status (process-exit-status proc)))
                                     (if (zerop exit-status)
                                         (let ((final-md (fuji--marker-find-output output-dir)))
                                           (if final-md
                                               (progn
                                                 (message "Fuji: Marker finished successfully")
                                                 (funcall success-callback final-md))
                                             (with-current-buffer (get-buffer-create "*Fuji Marker Output*")
                                               (display-buffer (current-buffer))
                                               (funcall error-callback 
                                                        (format "No .md file found in %s" output-dir)))))
                                       (with-current-buffer (get-buffer-create "*Fuji Marker Output*")
                                         (display-buffer (current-buffer))
                                         (funcall error-callback 
                                                  (format "Marker failed (%d): %s" exit-status event))))))))))
      process)))

;;; Register Plugin

(fuji-register-extractor
 (make-fuji-extractor
  :name "marker"
  :description "High-accuracy OCR with figure support (requires AI models)"
  :available-p #'fuji--marker-available-p
  :extract-fn #'fuji--marker-extract
  :priority 100))  ; Highest priority - best quality

(provide 'fuji-extractor-marker)

;;; fuji-extractor-marker.el ends here
