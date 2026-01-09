;;; fuji-configure.el --- Configuration wizard for Fuji -*- lexical-binding: t; -*-

;; Copyright (C) 2025 ruanxiang
;; Author: ruanxiang
;; Keywords: convenience

;;; Commentary:
;; Two-tier configuration system for Fuji:
;; - Tier 1: Tool Selection (which extractors/backends to use)
;; - Tier 2: Tool-Specific Configuration (paths, credentials, etc.)

;;; Code:

(require 'fuji-extractor)
(require 'fuji-rag)

(declare-function fuji--get-auth "fuji")
(declare-function fuji--save-auth-entry "fuji")
(declare-function fuji--register-mcp-server "fuji")
(declare-function fuji-apply-proxy "fuji")

;;; Auto-detection Functions

(defun fuji--auto-detect-pdftotext ()
  "Auto-detect pdftotext binary path."
  (or (bound-and-true-p fuji-pdftotext-executable)
      (executable-find "pdftotext")))

(defun fuji--auto-detect-marker ()
  "Auto-detect Marker binary path."
  (or (bound-and-true-p fuji-marker-executable)
      (executable-find "marker_single")
      (executable-find "marker")))

(defun fuji--auto-detect-pandoc ()
  "Auto-detect pandoc binary path."
  (or (bound-and-true-p fuji-pandoc-executable)
      (executable-find "pandoc")))

(defun fuji--get-originals-dir ()
  "Get the originals archive directory path."
  (or (bound-and-true-p fuji-originals-archive-dir)
      (expand-file-name "originals/" 
                        (or (bound-and-true-p fuji-cache-directory)
                            (expand-file-name "fuji-cache/" user-emacs-directory)))))

;;; Tier 1: Tool Selection

(defun fuji-configure-tier1 ()
  "Configure default tool selection (Tier 1).
Returns a plist with selections."
  (interactive)
  (message "=== Fuji Configuration: Tier 1 - Default Tool Selection ===")
  (message "")
  (message "PDF Extraction Type:")
  (message "  - pdftotext: Fast, lightweight (no figures)")
  (message "  - llm-based: High-quality with figures (requires AI models)")
  (message "Note: You can override this default when reading files.")
  (message "")
  (message "RAG/MCP Backend (for knowledge retrieval):")
  (message "  - graphlit: Cloud-based RAG via MCP (requires credentials)")
  (message "  - local-vector: Future local vector database option")
  (message "")
  
  (let* ((pdf-type (completing-read 
                    "Default PDF Extraction Type: "
                    '("pdftotext (fast, lightweight)"
                      "llm-based (high-quality, with figures)")
                    nil t))
         (pdf-type-value (if (string-prefix-p "pdftotext" pdf-type) 
                             "pdftotext" 
                             "llm-based"))
         ;; If LLM-based, ask which specific tool
         (llm-tool (when (string= pdf-type-value "llm-based")
                     (progn
                       (message "")
                       (message "LLM Extraction Tools:")
                       (message "  - marker: Current default (high-quality, with figures)")
                       (message "  - nougat: Future option")
                       (message "")
                       (completing-read
                        "Which LLM extraction tool: "
                        '("marker (current default)"
                          "nougat (future)")
                        nil t))))
         (llm-tool-value (when llm-tool
                          (if (string-prefix-p "marker" llm-tool)
                              "marker"
                            "nougat")))
         (docx-extractor (completing-read
                          "DOCX/EPUB/HTML Extractor: "
                          '("pandoc")
                          nil t (or (bound-and-true-p fuji-docx-extractor) "pandoc")))
         (rag-backend (completing-read
                       "RAG/MCP Backend: "
                       '("graphlit (cloud-based, MCP)" "local-vector (future)")
                       nil t))
         (rag-backend-value (if (string-prefix-p "graphlit" rag-backend)
                                "graphlit"
                              "local-vector")))
    
    (customize-save-variable 'fuji-pdf-extraction-type pdf-type-value)
    (when llm-tool-value
      (customize-save-variable 'fuji-llm-extraction-tool llm-tool-value))
    (customize-save-variable 'fuji-docx-extractor docx-extractor)
    (customize-save-variable 'fuji-rag-backend-name rag-backend-value)
    
    (message "Fuji: Default tools saved.")
    (message "  PDF Extraction Type: %s" pdf-type-value)
    (when llm-tool-value
      (message "  LLM Tool: %s" llm-tool-value))
    (message "  DOCX Extractor: %s" docx-extractor)
    (message "  RAG/MCP Backend: %s" rag-backend-value)
    (list :pdf-type pdf-type-value
          :llm-tool llm-tool-value
          :docx-extractor docx-extractor
          :rag-backend rag-backend-value)))

;;; Tier 2: Tool-Specific Configuration

(defun fuji-configure-tier2 ()
  "Configure tool-specific settings (Tier 2) based on Tier 1 selections.
Returns an alist of configured items."
  (interactive)
  (let ((config-items '()))
    
    ;; pdftotext (always required as fallback)
    (let* ((detected (fuji--auto-detect-pdftotext))
           (pdftotext-path (if detected
                               (read-file-name 
                                (format "Path to pdftotext [%s]: " detected)
                                (file-name-directory detected)
                                detected t nil
                                (lambda (f) (or (file-directory-p f)
                                              (string-suffix-p "pdftotext" f))))
                             (read-file-name "Path to pdftotext: " nil nil t))))
      (when pdftotext-path
        (customize-save-variable 'fuji-pdftotext-executable (expand-file-name pdftotext-path))
        (push (cons "pdftotext" pdftotext-path) config-items)))
    
    
    ;; LLM-based extraction tool (if selected)
    (when (string= (or (bound-and-true-p fuji-pdf-extraction-type) "") "llm-based")
      (let ((llm-tool (or (bound-and-true-p fuji-llm-extraction-tool) "marker")))
        (cond
         ;; Configure Marker
         ((string= llm-tool "marker")
          (message "")
          (message "=== Configuring Marker (LLM-based PDF Extraction) ===")
          (message "Note: Marker uses AI models for high-quality extraction with figure support.")
          (message "First run will download several GB of AI models.")
          (message "")
          (let* ((detected (fuji--auto-detect-marker))
                 (marker-path (if detected
                                  (read-file-name
                                   (format "Path to Marker [%s]: " detected)
                                   (file-name-directory detected)
                                   detected t nil
                                   (lambda (f) (or (file-directory-p f)
                                                 (string-match-p "marker" f))))
                                (read-file-name "Path to Marker: " nil nil t))))
            (when marker-path
              (customize-save-variable 'fuji-marker-executable (expand-file-name marker-path))
              (push (cons "marker" marker-path) config-items))))
         
         ;; Configure Nougat (future)
         ((string= llm-tool "nougat")
          (message "")
          (message "=== Configuring Nougat (LLM-based PDF Extraction) ===")
          (message "Note: Nougat support is coming soon.")
          (message ""))
         
         ;; Other LLM tools (future)
         (t
          (message "Warning: Unknown LLM tool: %s" llm-tool)))))
    
    
    
    ;; Pandoc (required for DOCX)
    (let* ((detected (fuji--auto-detect-pandoc))
           (pandoc-path (if detected
                            (read-file-name
                             (format "Path to pandoc [%s]: " detected)
                             (file-name-directory detected)
                             detected t nil
                             (lambda (f) (or (file-directory-p f)
                                           (string-suffix-p "pandoc" f))))
                          (read-file-name "Path to pandoc: " nil nil t))))
      (when pandoc-path
        (customize-save-variable 'fuji-pandoc-executable (expand-file-name pandoc-path))
        (push (cons "pandoc" pandoc-path) config-items)))
    
    ;; Graphlit credentials (if selected)
    (when (string= (or (bound-and-true-p fuji-rag-backend-name) "") "graphlit")
      (fuji-configure-graphlit))
    
    ;; Cache and archive directories
    (let ((cache-dir (read-directory-name 
                      "Cache Directory: " 
                      (or (bound-and-true-p fuji-cache-directory)
                          (expand-file-name "fuji-cache/" user-emacs-directory))
                      nil t))
          (originals-dir (read-directory-name 
                          "Originals Archive Directory: "
                          (fuji--get-originals-dir) nil t)))
      (customize-save-variable 'fuji-cache-directory (expand-file-name cache-dir))
      (customize-save-variable 'fuji-originals-archive-dir (expand-file-name originals-dir)))
    
    (message "Fuji: Tool-specific configuration saved.")
    config-items))

(defun fuji-configure-graphlit ()
  "Configure Graphlit-specific settings."
  (let* ((auth (condition-case nil (fuji--get-auth "graphlit") (error nil)))
         (org-id (read-string "Graphlit Organization ID: " (or (plist-get auth :user) "")))
         (secret (let ((s (read-passwd (format "Graphlit JWT Secret %s: "
                                               (if (plist-get auth :secret) 
                                                   "(leave empty to keep current)" 
                                                 "")))))
                   (if (string-empty-p s) (plist-get auth :secret) s)))
         (env-id (read-string "Graphlit Environment ID: " 
                              (or (bound-and-true-p fuji-graphlit-environment-id) ""))))
    
    (customize-save-variable 'fuji-graphlit-environment-id env-id)
    
    (when (and (not (string-empty-p org-id)) (not (string-empty-p secret)))
      (fuji--save-auth-entry org-id secret))
    
    (fuji--register-mcp-server)))

;;; gptel Configuration

(defun fuji-configure-gptel ()
  "Configure gptel backends for chat and vision."
  (require 'gptel)
  (let* ((backends (mapcar (lambda (b) (gptel-backend-name (cdr b))) gptel--known-backends))
         (chat-backend-name (completing-read 
                             "Default Chat Backend: " backends nil t 
                             (or (bound-and-true-p fuji-gptel-backend) "")))
         (chat-backend (gptel-get-backend chat-backend-name))
         (chat-model (completing-read 
                      "Default Chat Model: " 
                      (gptel-backend-models chat-backend) nil t 
                      (or (bound-and-true-p fuji-gptel-model) "")))
         (vis-backend-name (completing-read 
                            "Vision Backend (Multimodal): " backends nil t
                            (or (and (bound-and-true-p fuji-gptel-vision-backend)
                                     (symbolp fuji-gptel-vision-backend)
                                     (symbol-name fuji-gptel-vision-backend))
                                "")))
         (vis-backend (gptel-get-backend vis-backend-name))
         (vis-model (completing-read 
                     "Vision Model: " 
                     (gptel-backend-models vis-backend) nil t
                     (or (bound-and-true-p fuji-gptel-vision-model) ""))))
    
    (customize-save-variable 'fuji-gptel-backend chat-backend-name)
    (customize-save-variable 'fuji-gptel-model chat-model)
    
    (unless (string-empty-p vis-backend-name)
      (customize-save-variable 'fuji-gptel-vision-backend (intern vis-backend-name)))
    (unless (string-empty-p vis-model)
      (customize-save-variable 'fuji-gptel-vision-model vis-model))))

;;; Unified Configuration Entry Point

;;;###autoload
(defun fuji-configure ()
  "Interactive configuration wizard for Fuji.
Guides through Tier 1 (tool selection) and Tier 2 (tool-specific config)."
  (interactive)
  (message "Fuji Configuration Wizard - Tier 1: Tool Selection")
  (let ((tier1-result (fuji-configure-tier1)))
    (when (y-or-n-p "Configure tool-specific settings now? ")
      (message "Fuji Configuration Wizard - Tier 2: Tool-Specific Settings")
      (fuji-configure-tier2))
    
    ;; Configure gptel backends
    (when (y-or-n-p "Configure gptel backends (chat/vision)? ")
      (fuji-configure-gptel))
    
    ;; Apply proxy settings
    (let ((proxy (read-string "HTTP Proxy (e.g. 127.0.0.1:7890, leave empty for none): "
                              (or (bound-and-true-p fuji-http-proxy) ""))))
      (if (string-empty-p proxy)
          (customize-save-variable 'fuji-http-proxy nil)
        (customize-save-variable 'fuji-http-proxy proxy))
      (fuji-apply-proxy))
    
    (message "Fuji: Configuration complete! Run M-x fuji-validate-configuration to verify.")))

;;; Configuration Validation

;;;###autoload
(defun fuji-validate-configuration ()
  "Validate that all required tools are properly configured."
  (interactive)
  (let ((errors '())
        (warnings '()))
    
    ;; Check pdftotext (always required)
    (let ((pdftotext (fuji--auto-detect-pdftotext)))
      (if (and pdftotext (file-executable-p pdftotext))
          (message "✓ pdftotext: %s" pdftotext)
        (push "pdftotext not found or not executable (required)" errors)))
    
    
    ;; Check LLM-based extraction if selected
    (when (string= (or (bound-and-true-p fuji-pdf-extraction-type) "") "llm-based")
      (let ((llm-tool (or (bound-and-true-p fuji-llm-extraction-tool) "marker")))
        (cond
         ((string= llm-tool "marker")
          (let ((marker (fuji--auto-detect-marker)))
            (if (and marker (file-executable-p marker))
                (message "✓ Marker (LLM tool): %s" marker)
              (push "LLM-based extraction selected with Marker, but Marker not found or not executable" errors))))
         ((string= llm-tool "nougat")
          (push "Nougat selected but not yet supported" warnings))
         (t
          (push (format "Unknown LLM tool selected: %s" llm-tool) errors)))))
    
    
    
    ;; Check pandoc
    (let ((pandoc (fuji--auto-detect-pandoc)))
      (if (and pandoc (file-executable-p pandoc))
          (message "✓ pandoc: %s" pandoc)
        (push "pandoc not found or not executable (required for DOCX/EPUB)" warnings)))
    
    ;; Check Graphlit if selected
    (when (string= (or (bound-and-true-p fuji-rag-backend-name) "") "graphlit")
      (if (and (bound-and-true-p fuji-graphlit-environment-id)
               (condition-case nil (fuji--get-auth "graphlit") (error nil)))
          (message "✓ Graphlit credentials configured")
        (push "Graphlit selected but credentials not configured" errors)))
    
    ;; Check cache directory
    (if (and (bound-and-true-p fuji-cache-directory)
             (or (file-directory-p fuji-cache-directory)
                 (yes-or-no-p (format "Cache directory %s does not exist. Create it? " 
                                      fuji-cache-directory))))
        (progn
          (unless (file-directory-p fuji-cache-directory)
            (make-directory fuji-cache-directory t))
          (message "✓ Cache directory: %s" fuji-cache-directory))
      (push "Cache directory not configured or creation cancelled" errors))
    
    ;; Display results
    (let ((msg (concat
                (when errors
                  (concat "❌ ERRORS:\n" (mapconcat (lambda (e) (concat "  - " e)) errors "\n") "\n\n"))
                (when warnings
                  (concat "⚠ WARNINGS:\n" (mapconcat (lambda (w) (concat "  - " w)) warnings "\n") "\n\n"))
                (unless (or errors warnings)
                  "✅ All configuration checks passed!"))))
      (if (or errors warnings)
          (display-message-or-buffer msg "*Fuji Configuration Validation*")
        (message "%s" msg))
      (null errors))))

(provide 'fuji-configure)
;;; fuji-configure.el ends here
