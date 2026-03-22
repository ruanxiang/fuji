;;; fuji.el --- AI-Powered Academic Reading Workflow for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025 ruanxiang
;; Author: ruanxiang
;; Version: 0.1
;; Package-Requires: ((emacs "29.1") (gptel "0.9.0") (mcp "0.1.0"))
;; Keywords: tools, convenience, AI, PDF, research
;; URL: https://github.com/ruanxiang/fuji

;;; Commentary:
;; Fuji provides an AI-powered academic reading workflow for Emacs.
;; It integrates PDF extraction, RAG (Retrieval-Augmented Generation),
;; and chat interfaces to help researchers interact with academic papers.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url)
(require 'mcp nil t)
(require 'gptel)
(require 'gptel-openai)
(require 'gptel-context nil t)

;; Phase 42: Global threshold to prevent "Argument list too long" (vfork)
;; This forces gptel to always use temporary files for curl payloads.
(setq gptel-curl-file-size-threshold 0)

(require 'auth-source)
(require 'subr-x)
(require 'ansi-color)

;; Plugin Architecture (Phase 0)
;; Add the directory containing fuji.el to load-path so plugins can be found
(let ((fuji-dir (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path fuji-dir))

(require 'fuji-extractor)
(require 'fuji-extractor-marker)
(require 'fuji-extractor-pdftotext)
(require 'fuji-web)
(require 'fuji-extractor-pandoc)
(require 'fuji-rag)
(require 'fuji-rag-graphlit)
(require 'fuji-configure)
(require 'fuji-bib)

(defgroup fuji nil
  "Customization group for Fuji."
  :group 'external)

;;; Buffer-Local Session Variables

(defvar-local fuji--session-extractor nil
  "Buffer-local extractor override.
When set, this extractor will be used instead of the global preference.
Valid values: \"marker\", \"pdftotext\", \"pandoc\", or nil to use global setting.")

(defvar-local fuji--session-rag-backend nil
  "Buffer-local RAG backend override.
When set, this backend will be used instead of the global setting.
Valid values: \"graphlit\", \"local-vector\", etc., or nil to use global setting.")

;;;###autoload
(defcustom fuji-marker-executable (or (executable-find "marker_single")
                                      (executable-find "marker"))
  "Path to the Marker executable. 
Note: For processing single files, 'marker_single' is preferred."
  :type '(choice (const :tag "Not Set" nil)
                 file)
  :group 'fuji)

(defcustom fuji-bibtex-file nil
  "Directory where BibTeX files are stored."
  :type '(choice (const :tag "Not Set" nil)
                 directory)
  :group 'fuji)

(defcustom fuji-gptel-vision-backend nil
  "The gptel backend to use for vision analysis.
If nil, use the default gptel-backend."
  :type '(choice (const :tag "Default" nil)
                 symbol)
  :group 'fuji)

(defcustom fuji-gptel-vision-model nil
  "The gptel model to use for vision analysis.
If nil, use the default model for the vision backend."
  :type '(choice (const :tag "Default" nil)
                 string)
  :group 'fuji)

(defcustom fuji-cache-directory (expand-file-name "fuji-cache/" user-emacs-directory)
  "Directory to store parsed Markdown and images."
  :type 'directory
  :group 'fuji)

;;;###autoload
(defcustom fuji-graphlit-environment-id nil
  "Environment ID for Graphlit."
  :type 'string
  :group 'fuji)

(defcustom fuji-http-proxy nil
  "HTTP/HTTPS proxy to use for Fuji (e.g., \"127.0.0.1:7890\")."
  :type '(choice (const :tag "None" nil)
                 string)
  :group 'fuji)

(defcustom fuji-mcp-server-name "graphlit"
  "Name of the Graphlit MCP server registered in Emacs."
  :type 'string
  :group 'fuji)

(defcustom fuji-chat-mode 'hybrid
  "The chat mode for Fuji.
- `proxy': Standard RAG proxy mode (Graphlit is the backend).
- `hybrid': Local context injection mode (Standard gptel backend + Graphlit tool)."
  :type '(choice (const :tag "Hybrid (Recommended)" hybrid)
                 (const :tag "Proxy (Original)" proxy))
  :group 'fuji)

(defcustom fuji-gptel-backend nil
  "The default gptel backend name for chat sessions."
  :type '(choice (const :tag "Default (gptel-backend)" nil)
                 string)
  :group 'fuji)

(defcustom fuji-gptel-model nil
  "The default gptel model name for chat sessions."
  :type '(choice (const :tag "Default (gptel-model)" nil)
                 string)
  :group 'fuji)

;;; Phase 1: Two-Tier Configuration Variables

;; Tier 1: LLM Tool Selection (pdftotext is always configured)
(defcustom fuji-llm-extraction-tool "marker"
  "Which LLM-based extraction tool to use for high-quality PDF extraction.
Both pdftotext and this LLM tool will be configured during setup.
At runtime (fuji-read), user can choose between pdftotext, LLM tool, or offline.
- marker: Current default LLM tool
- nougat: Future option
- ... other LLM tools"
  :type '(choice (const :tag "Marker" "marker")
                 (const :tag "Nougat (Future)" "nougat"))
  :group 'fuji)

(defcustom fuji-docx-extractor "pandoc"
  "DOCX/EPUB/HTML extraction tool to use."
  :type '(choice (const :tag "Pandoc (Required)" "pandoc"))
  :group 'fuji)

(defcustom fuji-rag-backend-name "graphlit"
  "Which RAG/MCP backend to use for knowledge retrieval.
- graphlit: Cloud-based RAG via MCP (requires credentials)
- local-vector: Future local vector database option"
  :type '(choice (const :tag "Graphlit (Cloud RAG via MCP)" "graphlit")
                 (const :tag "Local Vector DB (Future)" "local-vector"))
  :group 'fuji)

;; Load local machine-specific configuration
;; This must be after all defcustom declarations to avoid void-variable errors
(fuji--load-local-config)

;; Tier 2: Tool-Specific Configuration
(defcustom fuji-pdftotext-executable nil
  "Path to pdftotext binary. Auto-detected if nil."
  :type '(choice (const :tag "Auto-detect" nil) file)
  :group 'fuji)

(defcustom fuji-pandoc-executable nil
  "Path to pandoc binary. Auto-detected if nil."
  :type '(choice (const :tag "Auto-detect" nil) file)
  :group 'fuji)

(defcustom fuji-marker-executable nil
  "Path to marker binary. Auto-detected if nil."
  :type '(choice (const :tag "Auto-detect" nil) file)
  :group 'fuji)

(defcustom fuji-bibtex-file nil
  "Path to the bibliography file (or directory)."
  :type '(choice (const :tag "Unconfigured" nil) file)
  :group 'fuji)

(defcustom fuji-chrome-executable nil
  "Path to Chrome/Chromium binary."
  :type '(choice (const :tag "Auto-detect" nil) file)
  :group 'fuji)

(defcustom fuji-http-proxy nil
  "HTTP Proxy URL (e.g. 127.0.0.1:7890)."
  :type '(choice (const :tag "None" nil) string)
  :group 'fuji)

(defcustom fuji-originals-archive-dir nil
  "Directory to archive original files. 
Defaults to 'originals/' relative to cache directory if nil."
  :type '(choice (const :tag "Default (cache/originals/)" nil) directory)
  :group 'fuji)


(defconst fuji-progress-buffer "*Nexus Progress*")

(defvar-local fuji--content-id nil "Graphlit content ID for current session.")
(defvar-local fuji--filename nil "Filename of the paper being read.")
(defvar-local fuji--results-dir nil "Cache directory for Marker results.")
(defvar-local fuji--pdf-buffer nil "Buffer containing the source PDF.")
(defvar-local fuji--prog-buffer nil "Buffer for progress logging.")
(defvar-local fuji--context-buffer nil "Hidden buffer containing paper content for gptel context.")


(defun fuji--log (format-string &rest args)
  "Log a message to the Nexus Progress buffer."
  (let* ((msg (apply #'format format-string args))
         (timestamp (format-time-string "[%H:%M:%S] ")))
    (with-current-buffer (get-buffer-create fuji-progress-buffer)
      (let ((inhibit-read-only t))
        ;; CRITICAL: Ensure buffer is multibyte before inserting.
        (unless enable-multibyte-characters (set-buffer-multibyte t))
        (goto-char (point-max))
        (insert timestamp msg "\n")
        (let ((win (get-buffer-window (current-buffer) t)))
          (when win
            (with-selected-window win
              (goto-char (point-max))
              (recenter -1)))))
      (set-buffer-modified-p nil))
    (message "Fuji: %s" msg)))



(defun fuji--setup-2-buffer-layout (chat-buffer progress-buffer)
  "Arrange windows: Chat full width, Progress at the bottom.
Used for non-visual documents (DOCX, EPUB) where raw buffer is binary."
  (delete-other-windows)
  (let* ((prog-win (split-window-below -5))) ;; Create a 5-line window at the bottom
    (set-window-buffer prog-win progress-buffer)
    (set-window-dedicated-p prog-win t) ;; Make it dedicated
    (set-window-buffer (selected-window) chat-buffer)))

(defun fuji--save-auth-entry (org-id secret)
  "Save Graphlit ORG-ID and SECRET to `~/.authinfo`."
  (let* ((auth-file (expand-file-name "~/.authinfo"))
         (entry (format "machine graphlit login %s password %s\n" org-id secret)))
    (with-temp-buffer
      (when (file-exists-p auth-file)
        (insert-file-contents auth-file))
      (goto-char (point-min))
      ;; Remove old entry if exists
      (while (re-search-forward "^machine graphlit .*\n" nil t)
        (replace-match ""))
      (goto-char (point-max))
      (insert entry)
      (write-region (point-min) (point-max) auth-file nil 'silent))
    (auth-source-forget-all-cached)
    (message "Fuji: Credentials saved to ~/.authinfo and cache cleared.")))



(defun fuji--get-mcp-connection ()
  "Get the current Graphlit MCP connection object, registering it if necessary."
  (let ((conn (gethash fuji-mcp-server-name mcp-server-connections)))
    (unless conn
      (condition-case nil
          (progn
            (fuji--register-mcp-server)
            (setq conn (gethash fuji-mcp-server-name mcp-server-connections)))
        (error nil)))
    conn))

(defcustom fuji-mcp-server-path
  (expand-file-name "node_modules/graphlit-mcp-server/dist/index.js"
                    (file-name-directory (or load-file-name buffer-file-name (locate-library "fuji"))))
  "Path to the Graphlit MCP server executable."
  :type 'file
  :group 'fuji)

(defun fuji--register-mcp-server ()
  "Register the Graphlit MCP server using current credentials."
  (interactive)
  (let* ((auth (fuji--get-auth "graphlit"))
         (org-id (plist-get auth :user))
         (secret (plist-get auth :secret))
         (env-id fuji-graphlit-environment-id))
    (if (and org-id secret env-id)
        (progn
          (fuji--log "Registering/Restarting MCP server: %s" fuji-mcp-server-name)
          ;; Always stop first to ensure new credentials/env are applied
          (when (gethash fuji-mcp-server-name mcp-server-connections)
            (mcp-stop-server fuji-mcp-server-name))
          (mcp-connect-server fuji-mcp-server-name
                              :command "node"
                              :args (list fuji-mcp-server-path)
                              :env `(:GRAPHLIT_ORGANIZATION_ID ,org-id
                                                               :GRAPHLIT_JWT_SECRET ,secret
                                                               :GRAPHLIT_ENVIRONMENT_ID ,env-id
                                                               ,@(when fuji-http-proxy
                                                                   `(:HTTP_PROXY ,fuji-http-proxy
                                                                                 :HTTPS_PROXY ,fuji-http-proxy)))
                              :syncp t))
      (fuji--log "[WARNING] Missing credentials for MCP registration."))))

(defun fuji-apply-proxy ()
  "Apply the configured proxy to Emacs `url-proxy-services`."
  (interactive)
  (if fuji-http-proxy
      (setq url-proxy-services
            `(("http" . ,fuji-http-proxy)
              ("https" . ,fuji-http-proxy)
              ("no_proxy" . "^\\(localhost\\|127.0.0.1\\)")))
    (setq url-proxy-services nil))
  (message "Fuji: Proxy settings applied (%s)" (or fuji-http-proxy "None")))
(defun fuji-check-health ()
  "Check the health of the Fuji environment."
  (interactive)
  (let ((buf (get-buffer-create "*Nexus Health*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Fuji Health Check\n")
        (insert (make-string 30 ?=) "\n\n")
        
        ;; 1. Marker
        (insert "[Marker Settings]\n")
        (let ((marker-exe (or (bound-and-true-p fuji-marker-executable) "marker")))
          (if (executable-find marker-exe)
              (insert (format "   [OK] Marker found: %s\n" (executable-find marker-exe)))
            (insert (format "   [FAIL] Marker NOT FOUND in PATH: %s\n" marker-exe))))
        
        ;; 2. Files
        (insert "\n[File Paths]\n")
        (if (and fuji-bibtex-file (file-exists-p fuji-bibtex-file))
            (insert (format "   [OK] Bib File: %s\n" fuji-bibtex-file))
          (insert (format "   [FAIL] Bib File NOT FOUND: %s\n" fuji-bibtex-file)))

        ;; 3. Credentials
        (insert "\n[Graphlit Credentials]\n")
        (let ((auth (fuji--get-auth "graphlit")))
          (if auth
              (insert (format "   [OK] Found credentials for user: %s\n" (plist-get auth :user)))
            (insert "   [FAIL] No credentials found in ~/.netrc\n")))
        (if fuji-graphlit-environment-id
            (insert (format "   [OK] Environment ID: %s\n" fuji-graphlit-environment-id))
          (insert "   [FAIL] `fuji-graphlit-environment-id` is not set.\n"))
        
        ;; 4. Proxy
        (insert "\n[Proxy Settings]\n")
        (insert (format "   Env HTTPS_PROXY: %s\n" (or (getenv "HTTPS_PROXY") "None")))
        (insert (format "   Env HTTP_PROXY:  %s\n" (or (getenv "HTTP_PROXY") "None")))
        (insert (format "   Emacs Proxy: %s\n" (or fuji-http-proxy "None")))
        
        ;; 5. MCP Server
        (insert "\n[MCP Server Status]\n")
        (insert (format "   Path: %s\n" fuji-mcp-server-path))
        (if (file-exists-p fuji-mcp-server-path)
            (insert "   [OK] JS file exists.\n")
          (insert "   [FAIL] JS file NOT FOUND.\n"))
        
        (let ((conn (gethash fuji-mcp-server-name mcp-server-connections)))
          (if conn
              (condition-case err
                  (let ((proc (mcp-connection-process conn)))
                    (if (and proc (process-live-p proc))
                        (insert (format "   [OK] Server '%s' is RUNNING (PID: %d)\n" 
                                        fuji-mcp-server-name (process-id proc)))
                      (insert (format "   [FAIL] Server '%s' process is NOT LIVE.\n" fuji-mcp-server-name))))
                (error
                 (insert (format "   [WARNING] Server '%s' registered but status unknown\n" fuji-mcp-server-name))))
            (insert (format "   [OFFLINE] Server '%s' not registered.\n" fuji-mcp-server-name))))
        
        (goto-char (point-min))
        (display-buffer (current-buffer))
        (message "Fuji: Health check complete.")))))

(defun fuji--ensure-config ()
  "Ensure all required settings are configured."
  (fuji-apply-proxy)
  (unless (and fuji-marker-executable
               (file-executable-p fuji-marker-executable)
               fuji-bibtex-file
               (file-exists-p fuji-bibtex-file)
               (fuji--get-mcp-connection))
    (when (y-or-n-p "Fuji is not configured. Configure it now? ")
      (call-interactively #'fuji-configure))))

(defun fuji--get-auth (machine)
  "Retrieve auth-source info for MACHINE."
  (let ((auth (auth-source-search :host machine)))
    (if auth
        (let ((user (plist-get (car auth) :user))
              (secret (plist-get (car auth) :secret)))
          (list :user (if (functionp user) (funcall user) user)
                :secret (if (functionp secret) (funcall secret) secret)))
      (error "No credentials found for %s in auth-source" machine))))

(defun fuji--get-pdf-text (pdf-file)
  "Extract text from PDF-FILE using `pdftotext` system utility."
  (let ((pdf-file (expand-file-name pdf-file)))
    (with-temp-buffer
      (call-process "pdftotext" nil t nil pdf-file "-")
      (buffer-string))))

(defun fuji--use-local-marker-result (local-dir cache-dir)
  "Link files from LOCAL-DIR to CACHE-DIR."
  (unless (file-directory-p cache-dir)
    (make-directory cache-dir t))
  (let ((files (directory-files local-dir t directory-files-no-dot-files-regexp)))
    (dolist (file files)
      (let ((dest (expand-file-name (file-name-nondirectory file) cache-dir)))
        (if (fboundp 'make-symbolic-link)
            (make-symbolic-link file dest t)
          (copy-file file dest t))))))

(defun fuji-verify-environment ()
  "Verify that the environment is correctly set up for Fuji."
  (interactive)
  (message "Fuji: Verifying environment...")
  (condition-case err
      (progn
        ;; 1. Check Marker
        (unless fuji-marker-executable
          (error "Marker executable not configured. Please run M-x fuji-configure"))
        (unless (file-executable-p fuji-marker-executable)
          (error "Marker executable not found or not executable at: %s" fuji-marker-executable))
        
        ;; 2. Check Graphlit Credentials
        (let ((auth (fuji--get-auth "graphlit")))
          (unless (and (plist-get auth :user) (plist-get auth :secret))
            (error "Graphlit Organization ID or Secret missing in auth-source")))
        
        ;; 3. Check Bib Path
        (unless fuji-bibtex-file
          (error "Bibliography path not configured. Please run M-x fuji-configure"))
        (unless (file-exists-p fuji-bibtex-file)
          (error "Bibliography file not found: %s" fuji-bibtex-file))

        ;; 4. Ensure Cache exists
        (unless fuji-cache-directory
          (error "Cache directory not configured. Please run M-x fuji-configure"))
        (unless (file-directory-p fuji-cache-directory)
          (make-directory fuji-cache-directory t))

        (message "Fuji: Environment verification SUCCESS!")
        t)
    (error
     (message "Fuji: Environment verification FAILED: %s" (error-message-string err))
     nil)))

(defun fuji--get-cache-path (pdf-file)
  "Generate a cache path for PDF-FILE based on its hash."
  (let* ((hash (secure-hash 'sha256 pdf-file))
         (cache-dir (expand-file-name hash fuji-cache-directory)))
    (unless (file-directory-p cache-dir)
      (make-directory cache-dir t))
    cache-dir))

(defun fuji--find-marker-output (dir)
  "Find the first .md file in DIR or its subfolders."
  (let ((files (directory-files-recursively dir "\\.md$")))
    (when files
      (car files))))

(defun fuji--process-pdf-with-marker (pdf-file callback)
  "Process PDF-FILE with Marker asynchronously, then call CALLBACK.
CALLBACK is called with the directory containing the results."
  (let* ((pdf-file (expand-file-name pdf-file)) ; Ensure absolute path
         (cache-dir (fuji--get-cache-path pdf-file))
         (existing-md (fuji--find-marker-output cache-dir))
         (marker-exe (if (and fuji-marker-executable 
                              (string-match-p "marker_single$" fuji-marker-executable))
                         fuji-marker-executable
                       (let ((single-exe (expand-file-name "marker_single" 
                                                           (file-name-directory (or fuji-marker-executable "")))))
                         (if (and (file-exists-p single-exe) (file-executable-p single-exe))
                             single-exe
                           fuji-marker-executable))))
         ;; marker_single uses [OPTIONS] FPATH
         (marker-args (list "--output_dir" cache-dir pdf-file)))
    
    (if existing-md
        (progn
          (message "Fuji: Using cached Marker results for %s" (file-name-nondirectory pdf-file))
          (funcall callback existing-md))
      (progn
        (fuji--log "Starting Marker (%s) for %s..." 
                   (file-name-nondirectory (or marker-exe "marker"))
                   (file-name-nondirectory pdf-file))
        (let* ((out-buf (get-buffer-create "*Nexus Marker Output*"))
               (_ (with-current-buffer out-buf
                    (unless enable-multibyte-characters
                      (set-buffer-multibyte t))))
               (process-environment (cons "PYTHONUNBUFFERED=1" process-environment))
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
                                         (if moving (goto-char (process-mark proc)))))
                                     ;; Also log to progress if it looks like a stage change
                                     (when (string-match "Processing\\|Converting\\|Saving" string)
                                       (fuji--log "Marker: %s" (string-trim (ansi-color-filter string))))))
                         :sentinel (lambda (proc event)
                                     (when (memq (process-status proc) '(exit signal))
                                       (let ((exit-status (process-exit-status proc)))
                                         (if (zerop exit-status)
                                             (let ((final-md (fuji--find-marker-output cache-dir)))
                                               (if final-md
                                                   (progn
                                                     (fuji--log "Marker finished successfully.")
                                                     (funcall callback final-md))
                                                 (with-current-buffer (get-buffer-create "*Nexus Marker Output*")
                                                   (display-buffer (current-buffer))
                                                   (fuji--log "Marker failed: No .md file found in %s" cache-dir)
                                                   (error "Fuji: Marker finished but no .md file found in %s" cache-dir))))
                                           (with-current-buffer (get-buffer-create "*Nexus Marker Output*")
                                             (display-buffer (current-buffer))
                                             (fuji--log "Marker failed (%d): %s" exit-status event)
                                             (error "Fuji: Marker failed (%d): %s. Check output for details." exit-status event)))))))))
          (with-current-buffer out-buf
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert "Fuji: Processing PDF with Marker (PTY mode)...\n")
              (insert "Note: The FIRST run may take several minutes as it downloads AI models (several GB).\n")
              (insert "Command: " (or marker-exe "marker") " " (mapconcat #'identity marker-args " ") "\n")
              (insert (make-string 40 ?-) "\n\n"))
            (display-buffer (current-buffer))))))))

(defun fuji--is-plain-text-file (file-path)
  "Check if FILE-PATH is a plain text file.
Returns t if the file is plain text (readable as UTF-8/ASCII), nil otherwise.
This checks the actual file content, not just the extension."
  (when (and file-path (file-exists-p file-path))
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents file-path nil 0 1024) ; Read first 1KB
          ;; Check if buffer contains NUL bytes (binary footprint)
          (goto-char (point-min))
          (not (re-search-forward "\x00" nil t)))
      (error nil))))

(defun fuji--select-document ()
  "Select a document file (any format).
If the current buffer is a file, use it. Otherwise, prompt for a file,
favoring bib-search integration if available."
  (cond
   ;; 1. Current buffer has a file
   ((and buffer-file-name (file-exists-p buffer-file-name))
    (let ((abs-path (expand-file-name buffer-file-name)))
      (message "Fuji: Using current buffer: %s" (file-name-nondirectory abs-path))
      abs-path))
   
   ;; 2. Integration with ivy-bibtex (if the user wants to search by title)
   ((and (featurep 'ivy-bibtex)
         (y-or-n-p "Search bibliography for paper? "))
    (user-error "Please use `M-x ivy-bibtex` and pick 'Open PDF' or 'Fuji Chat' (if configured)"))

   ;; 3. Manual selection (fallback)
   ;; 3. Manual selection (fallback)
   (t
    (let* ((file (read-file-name "Select document (or URL): " 
                                (or fuji-bibtex-file default-directory) nil nil))
           (abs-path (expand-file-name (substitute-in-file-name (expand-file-name file))))
           (nondir (file-name-nondirectory (directory-file-name file)))) ;; handle trailing slash
      
      (cond
       ;; A. If it exists as a file, favor the file
       ((file-exists-p abs-path)
        abs-path)
       
       ;; B. Detect URL pattern in the path (handle collapsed slashes e.g. https:/...)
       ((string-match "\\(https?:/+[^\n ]+\\)" file)
        (let ((match (match-string 1 file)))
          (if (string-match "^\\(https?\\):/+\\(.*\\)" match)
              (concat (match-string 1 match) "://" (match-string 2 match))
            match)))
       
       ;; C. Deep Path Scan: Check if any path component looks like a domain
       ;; This handles cases like: /path/to/i.mediatek.com/ai where user typed "i.mediatek.com/ai"
       ((and (not (file-exists-p abs-path))
             (let* ((parts (split-string abs-path "/"))
                    (tlds '("com" "org" "net" "edu" "gov" "mil" "int" 
                            "io" "ai" "co" "uk" "ca" "de" "fr" "jp" 
                            "cn" "ru" "br" "au" "in" "info" "biz" 
                            "me" "tv" "xyz" "tech" "site" "online" "app"
                            "tw" "hk" "sg" "kr" "my" "vn" "ph" "th" "id"))
                    (domain-part-index nil))
               ;; Find first part with valid TLD
               (cl-loop for part in parts
                        for i from 0
                        do (let ((ext (file-name-extension part)))
                             (when (and ext (member (downcase ext) tlds))
                               (setq domain-part-index i)
                               (cl-return))))
               
               (when domain-part-index
                 ;; Reconstruct URL from domain part onwards
                 (let* ((url-path (mapconcat 'identity (nthcdr domain-part-index parts) "/"))
                        (full-url (if (string-match "^https?://" url-path)
                                      url-path
                                    (concat "https://" url-path))))
                   full-url)))))
       
       ;; D. Default: Return absolute path
       (t abs-path))))))

(defun fuji--normalize-string (s)
  "Ensure S is a multibyte string."
  (if (and s (stringp s))
      (if (multibyte-string-p s) s (decode-coding-string s 'utf-8))
    ""))

(defun fuji--mcp-parse-result (result)
  "Parse the JSON result string from an MCP tool RESULT.
Handles various formats of RESULT (plists, hash-tables, symbols)."
  (let* ((content (or (plist-get result :content)
                      (and (hash-table-p result) (gethash "content" result))
                      (and (vectorp result) result)))
         (first-item (when (and content (> (length content) 0))
                       (aref content 0)))
         (text-val (fuji--normalize-string
                    (or (plist-get first-item :text)
                        (and (hash-table-p first-item) (gethash "text" first-item))))))
    (if (or (string-empty-p text-val) (string= text-val "null"))
        (progn
          (message "Fuji: Result text is empty or null.")
          nil)
      (condition-case err
          (let* ((json-object-type 'alist)
                 (parsed (json-read-from-string text-val)))
            (if (or (assoc 'answer parsed) (assoc 'message parsed) (assoc 'id parsed))
                parsed
              ;; If it's valid JSON but doesn't have our keys, 
              ;; return the raw text-val as answer for safety
              `((answer . ,text-val) (id . ,(cdr (assoc 'id parsed))))))
        (error 
         (message "Fuji: JSON parse error for result: %S" text-val)
         `((answer . ,text-val) (message . ,text-val)))))))


(defvar-local fuji--content-id nil "Graphlit content ID for the current paper.")
(defvar-local fuji--filename nil "Filename of the current paper.")
(defvar-local fuji--conversation-id nil "Graphlit conversation ID for the current session.")
(defvar-local fuji--results-dir nil "Directory containing Marker results.")
(defvar-local fuji--pdf-buffer nil "PDF buffer for the current session.")
(defvar-local fuji--prog-buffer nil "Progress buffer for the current session.")

(defun fuji--query-graphlit (prompt success-callback error-callback)
  "Send PROMPT to Graphlit for RAG via MCP.
Calls SUCCESS-CALLBACK with answer on success, or ERROR-CALLBACK on failure."
  (let* ((orig-buffer (current-buffer))
         (conn (fuji--get-mcp-connection))
         (paper-name (or (bound-and-true-p fuji--filename) "this paper")))
    (message "Fuji: Querying Graphlit MCP... (Server: %s)" fuji-mcp-server-name)
    (if (not conn)
        (progn
          (message "Fuji ERROR: No MCP connection found for %s" fuji-mcp-server-name)
          (funcall error-callback "MCP server not connected"))
      (fuji--log "Querying Graphlit RAG (Content: %s, Conversation: %s) with prompt: %S" 
                 (or (bound-and-true-p fuji--content-id) "Global")
                 (or fuji--conversation-id "New")
                 prompt)
      (condition-case outer-err
          (mcp-async-call-tool conn "promptConversation"
                               `((prompt . ,prompt)
                                 ,@(when-let* ((cid (bound-and-true-p fuji--content-id)))
                                     `((contentIds . [,cid])))
                                 ,@(when fuji--conversation-id
                                     `((conversationId . ,fuji--conversation-id))))
                               (lambda (result)
                                 (fuji--log "MCP response received. Rendering...")
                                 (when (buffer-live-p orig-buffer)
                                   (with-current-buffer orig-buffer
                                     (let* ((parsed (fuji--mcp-parse-result result))
                                            (answer (and parsed 
                                                         (or (cdr (assoc 'answer parsed))
                                                             (cdr (assoc 'message parsed)))))
                                            (conv-id (and parsed (cdr (assoc 'id parsed)))))
                                       (if answer
                                           (progn
                                             (message "Fuji: Answer extracted, calling success callback.")
                                             ;; Save conversation ID for continuity
                                             (when conv-id
                                               (setq fuji--conversation-id conv-id))
                                             (funcall success-callback answer))
                                         (let ((err-msg (format "MCP tool returned success but no answer found in result.")))
                                           (fuji--log "[FAILURE] %s" err-msg)
                                           (message "Fuji: %s Raw: %S" err-msg result)
                                           (funcall error-callback err-msg)))))))
                               (lambda (inner-err)
                                 (message "Fuji: MCP error lambda triggered: %S" inner-err)
                                 (when (buffer-live-p orig-buffer)
                                   (with-current-buffer orig-buffer
                                     (let ((err-msg (format "MCP tool call error: %s" (error-message-string inner-err))))
                                       (fuji--log "[FAILURE] %s" err-msg)
                                       (funcall error-callback err-msg)))))))
        (error
         (message "Fuji: MCP call failed: %s" (error-message-string outer-err))
         (funcall error-callback (format "MCP error: %s" (error-message-string outer-err)))))))

;;; gptel Integration

;; FIXME: Temporarily disabled - causes load failure when gptel-backend not available
;; (cl-defstruct (fuji-gptel-backend (:include gptel-backend)))

(require 'gptel-request nil t)

(defun fuji--gptel-handle-wait-advice (orig-fun fsm)
  "Intercept gptel's `WAIT' state to use Graphlit MCP for `fuji' backends."
  (let* ((info (gptel-fsm-info fsm))
         (backend (plist-get info :backend)))
    (if (and backend (fboundp 'fuji-gptel-backend-p) (fuji-gptel-backend-p backend))
        (progn
          (message "Fuji: Intercepting gptel request via WAIT advice.")
          (let ((data (or (plist-get info :data) (plist-get info :prompt))))
            (fuji--gptel-request-handler backend data :fsm fsm)))
      (funcall orig-fun fsm))))

(advice-add 'gptel--handle-wait :around #'fuji--gptel-handle-wait-advice)

;; DISABLED: (cl-defmethod gptel-parse-response ((_backend fuji-gptel-backend) response _info)
;; DISABLED:   "Extract text from RESPONSE. For Nexus, it's already a string."
;; DISABLED:   (if (stringp response) response ""))

;; DISABLED: (cl-defmethod gptel--parse-buffer ((_backend fuji-gptel-backend) &optional max-entries)
;; DISABLED:   "Parse current buffer backwards from point and return a list of prompts.
;; DISABLED: For Nexus, we follow the standard gptel pattern of scanning for 'gptel properties."
;; DISABLED:   (let ((prompts) (prev-pt (point)))
;; DISABLED:     (if (or gptel-mode gptel-track-response)
;; DISABLED:         (while (and (or (not max-entries) (>= max-entries 0))
;; DISABLED:                     (/= prev-pt (point-min))
;; DISABLED:                     (goto-char (max (point-min) 
;; DISABLED:                                     (previous-single-property-change
;; DISABLED:                                      (point) 'gptel nil (point-min)))))
;; DISABLED:           (pcase (get-char-property (point) 'gptel)
;; DISABLED:             ('response
;; DISABLED:              (let ((content (string-trim (buffer-substring-no-properties (point) prev-pt))))
;; DISABLED:                (when (> (length content) 0)
;; DISABLED:                  (push (list :role "assistant" :content content) prompts))))
;; DISABLED:             ('nil
;; DISABLED:              (and max-entries (cl-decf max-entries))
;; DISABLED:              (let ((content (string-trim (buffer-substring-no-properties
;; DISABLED:                                            (point) prev-pt))))
;; DISABLED:                (when (> (length content) 0)
;; DISABLED:                  (push (list :role "user" :content content) prompts))))
;; DISABLED:             ('ignore))
;; DISABLED:           (setq prev-pt (point)))
;; DISABLED:       ;; Fallback: just use the whole buffer as one user prompt
;; DISABLED:       (let ((content (string-trim (buffer-substring-no-properties (point-min) (point-max)))))
;; DISABLED:         (when (> (length content) 0)
;; DISABLED:           (push (list :role "user" :content content) prompts))))
;; DISABLED: 
;; DISABLED: (cl-defmethod gptel--request-data ((_backend fuji-gptel-backend) prompts)
;; DISABLED:   "Prepare the data for a Nexus request.
;; DISABLED: Since we intercept in the WAIT state, we just pass the prompts through."
;; DISABLED:   prompts)

(defun fuji--gptel-request-handler (backend prompt &rest args)
  "Async request handler for Graphlit RAG backend.
PROMPT is the user query (string or list of plists). ARGS contains :fsm or direct plists."
  (message "Fuji: [DEBUG-START] Request Handler Entry")
  (let* ((fsm (plist-get args :fsm))
         (info (if fsm (gptel-fsm-info fsm) args))
         (sep (or (and (boundp 'gptel-model-separator) gptel-model-separator) 
                  "------------------------------------------------------------")))
    
    ;; Ensure default callback if missing
    (unless (plist-get info :callback)
      (setq info (plist-put info :callback #'gptel--insert-response))
      (when fsm (setf (gptel-fsm-info fsm) info)))

    (let* ((callback (plist-get info :callback))
           (buffer (or (plist-get info :buffer) (current-buffer)))
           ;; Extract actual prompt from complex input
           (actual-prompt 
            (cond
             ((stringp prompt)
              (if (string-match (concat "[^\0]*" (regexp-quote (string-trim sep)) "[[:space:]\n]*\\([^\0]*\\)") prompt)
                  (match-string 1 prompt)
                prompt))
             ((listp prompt)
              (let* ((last-msg (car (last prompt)))
                     (raw-content (cond
                                   ((and (listp last-msg) (plist-get last-msg :content)) (plist-get last-msg :content))
                                   ((stringp last-msg) last-msg)
                                   (t ""))))
                (if (string-match (concat "[^\0]*" (regexp-quote (string-trim sep)) "[[:space:]\n]*\\([^\0]*\\)") raw-content)
                    (match-string 1 raw-content)
                  raw-content)))
             (t 
              ""))))
      
      (fuji--log "Fuji: gptel processing prompt (len: %d)" (length actual-prompt))

      (let ((figure-id (fuji--detect-visual-query actual-prompt))
            (success-wrapper (lambda (response)
                               (message "Fuji: SUCCESS callback. Notifying gptel.")
                               (plist-put info :http-status "200")
                               (plist-put info :status "success")
                               (setq response (fuji--normalize-string (or response "")))
                               
                               (with-current-buffer buffer
                                 (unless enable-multibyte-characters
                                   (set-buffer-multibyte t))
                                 (setq-local buffer-file-coding-system 'utf-8)
                                 (if callback 
                                     (condition-case err
                                         (progn
                                           ;; FSM Transition: Move to 'TYPE' state (uppercase in 0.9.x)
                                           (when (and fsm (fboundp 'gptel--fsm-transition))
                                             (gptel--fsm-transition fsm 'TYPE))
                                           
                                           (funcall callback response info)

                                           ;; Prepare for next turn with a foldable heading
                                           (goto-char (point-max))
                                           (unless (string-suffix-p "** " (buffer-substring (max 1 (- (point-max) 3)) (point-max)))
                                             (insert "\n\n** "))
                                           
                                           ;; FSM Transition: Finalize to 'DONE' state
                                           (when (and fsm (fboundp 'gptel--fsm-transition))
                                             (gptel--fsm-transition fsm 'DONE)))
                                       (error
                                        (let ((err-str (error-message-string err)))
                                          (message "Fuji: [CRITICAL] Callback error: %S" err)
                                          (message "Fuji: [CRITICAL] Error detail: %s" err-str)
                                          (fuji--log "Callback error: %S" err))))
                                   
                                   ;; Fallback
                                   (progn
                                     (message "Fuji WARNING: No callback provided, manually inserting.")
                                     (goto-char (point-max))
                                     (insert response)

                                     ;; Prepare for next turn with a foldable heading
                                     (goto-char (point-max))
                                     (unless (string-suffix-p "** " (buffer-substring (max 1 (- (point-max) 3)) (point-max)))
                                       (insert "\n\n** "))

                                     (when (and fsm (fboundp 'gptel--fsm-transition))
                                       (gptel--fsm-transition fsm 'DONE)))))))
            (error-wrapper (lambda (err-msg)
                             (message "Fuji: ERROR callback: %s" err-msg)
                             (plist-put info :http-status "500")
                             (plist-put info :status "error")
                             (plist-put info :error err-msg)
                             
                             (when (and fsm (fboundp 'gptel--fsm-transition))
                               (gptel--fsm-transition fsm 'ERRS))

                             (when callback 
                               (funcall callback (cons 'error err-msg) info)))))
        
        ;; Handle empty prompt
        (if (string-empty-p (string-trim (or actual-prompt "")))
            (progn
              (message "Fuji: Detected empty prompt, skipping Graphlit query.")
              (funcall success-wrapper "How can I help you with this paper?"))
          (if figure-id
              (fuji--handle-visual-query figure-id actual-prompt success-wrapper error-wrapper)
            (fuji--query-graphlit actual-prompt success-wrapper error-wrapper)))
        fsm))))

(defun fuji--detect-visual-query (prompt)
  "Return figure ID if PROMPT is a visual query, nil otherwise."
  (when (and (stringp prompt)
             (string-match "\\(figure\\|fig\\|table\\|chart\\|diagram\\)\\s-+\\([0-9]+\\)" (downcase prompt)))
    (match-string 2 (downcase prompt))))

(defun fuji--handle-visual-query (figure-id prompt success-callback error-callback)
  "Handle a visual query for FIGURE-ID.
Calls SUCCESS-CALLBACK on success, or ERROR-CALLBACK on failure."
  (message "Fuji: Handling visual query for Figure %s" figure-id)
  ;; 1. Query Graphlit for caption
  (fuji--query-graphlit 
   (format "What is the caption and context for Figure %s?" figure-id)
   (lambda (caption)
     ;; 2. Find image
     (let ((image-file (expand-file-name (format "figure-%s.png" figure-id)
                                         (expand-file-name "assets" fuji--results-dir))))
       (if (file-exists-p image-file)
           (progn
             (message "Fuji: Found image %s. Calling Vision API..." image-file)
             ;; 3. Call Vision API (using gptel or direct)
             (fuji--call-vision-api image-file caption prompt success-callback error-callback))
         (let ((err (format "Figure image not found: %s" image-file)))
           (fuji--log "[FAILURE] %s" err)
           (funcall error-callback err)))))
   error-callback))

(defun fuji--call-vision-api (image-file caption prompt success-callback error-callback)
  "Call a multimodal model with IMAGE-FILE, CAPTION and PROMPT."
  (message "Fuji: Vision analysis for %s..." image-file)
  (let* ((vision-prompt (format "Below is Figure %s from a research paper. 
Caption: %s

User Question: %s

Please explain the figure based on the image and the provided context." 
                                (fuji--detect-visual-query prompt)
                                caption prompt))
         (backend (or fuji-gptel-vision-backend gptel-backend))
         (model (or fuji-gptel-vision-model gptel-model)))
    
    (gptel-request 
        vision-prompt
      :callback (lambda (response info)
                  (if (plist-get info :error)
                      (funcall error-callback (plist-get info :error))
                    (funcall success-callback response)))
      :context (list image-file)
      :backend backend
      :model model)))

(defun fuji--cleanup-session ()
  "Prompt to delete Graphlit content on buffer kill.
Also clears any global gptel context to ensure a clean exit."
  (let* ((filename fuji--filename)
         (content-id fuji--content-id)
         (ctx-buf fuji--context-buffer))
    (fuji--log "Session cleanup for: %s" filename)
    ;; 1. Remove all gptel context items
    (when (fboundp 'gptel-context-remove-all)
      (gptel-context-remove-all))
    ;; 2. Kill hidden context buffer if any
    (when (buffer-live-p ctx-buf)
      (kill-buffer ctx-buf))
    ;; 3. Keep Graphlit content for library management
    ;; Content can be managed via M-x fuji-manage-content
    (when content-id
      (fuji--log "Content preserved in Graphlit: %s (manage via M-x fuji-manage-content)" content-id))))


;;;###autoload
(defun fuji-quit ()
  "Unified command to quit the current Fuji session.
Prompts for content deletion and kills related buffers."
  (interactive)
  (let ((chat-buf (current-buffer))
        (pdf-buf fuji--pdf-buffer)
        (prog-buf fuji--prog-buffer)
        (is-group-chat (string-prefix-p "*Fuji-Group-Chat" (buffer-name))))
    (unless (or (and fuji--filename (string-match-p "\\*Fuji-Chat:" (buffer-name chat-buf)))
                is-group-chat)
      (user-error "Fuji: Not in a Fuji-Chat or Group-Chat buffer"))
    
    ;; 1. Run cleanup (asks about Graphlit deletion)
    (fuji--cleanup-session)
    
    ;; 2. Remove the hook to prevent duplicate cleanup when killing buffer
    (remove-hook 'kill-buffer-hook #'fuji--cleanup-session t)

    ;; 3. Restore Library Manager FIRST (to fix window layout)
    (let ((manager-buf (get-buffer "*Fuji-Library*")))
      (when (buffer-live-p manager-buf)
        (switch-to-buffer manager-buf)
        (delete-other-windows)))
    
    ;; 4. Kill buffers (in background)
    (when (buffer-live-p pdf-buf) (kill-buffer pdf-buf))
    (when (buffer-live-p prog-buf) (kill-buffer prog-buf))
    (kill-buffer chat-buf)
    
    (message "Fuji: Session ended.")))

(defun fuji--delete-from-graphlit (content-id)
  "Delete CONTENT-ID from Graphlit via MCP."
  (fuji--log "Deleting content %s via MCP tool 'deleteContent'..." content-id)
  (let ((conn (gethash fuji-mcp-server-name mcp-server-connections)))
    (when conn
      (condition-case outer-err
          (mcp-async-call-tool conn "deleteContent"
                               `((id . ,content-id))
                               (lambda (result)
                                 (let* ((parsed (fuji--mcp-parse-result result))
                                        (deleted-id (cdr (assoc 'id parsed)))
                                        (state (cdr (assoc 'state parsed))))
                                   (if (and deleted-id (string= state "DELETED"))
                                       (progn
                                         (fuji--log "[SUCCESS] Content deleted: %s (state: %s)" deleted-id state)
                                         ;; Remove from metadata cache
                                         (fuji--remove-metadata-entry content-id))
                                     (fuji--log "[INFO] Delete operation completed (response: %s)" result))))
                               (lambda (inner-err)
                                 (fuji--log "[FAILURE] Delete failed: %s" (error-message-string inner-err))))
        (error
         (fuji--log "[FAILURE] Delete session error: %s" (error-message-string outer-err)))))))


(defun fuji--setup-buffer-header (filename content-id)
  "Set up a header for the chat buffer for FILENAME."
  (unless enable-multibyte-characters
    (set-buffer-multibyte t))
  (setq-local buffer-file-coding-system 'utf-8)
  (let ((header (format "Fuji | File: %s | Graphlit ID: %s | Model: %s\n%s\n"
                        filename content-id gptel-model (make-string 60 ?-))))
    (save-excursion
      (goto-char (point-min))
      (insert header))))

(defun fuji-query-graphlit (query)
  "Search the research paper for specific details using Graphlit RAG.
This is used as a gptel tool in hybrid mode."
  (let* ((conn (fuji--get-mcp-connection))
         (all-ids (cond 
               ((bound-and-true-p fuji--content-ids) (vconcat fuji--content-ids))
               ((bound-and-true-p fuji--content-id) (vector fuji--content-id))
               (t nil)))
         ;; Filter out LOCAL- IDs for the tool call
         (ids (cl-remove-if (lambda (id) (string-prefix-p "LOCAL-" (format "%s" id))) all-ids)))
    (unless (and ids (> (length ids) 0))
      (error "Fuji: No content context found in current buffer"))
    (let ((result (mcp-call-tool conn "promptConversation"
                                 `((prompt . ,query)
                                   (contentIds . ,ids)))))
      (fuji--mcp-parse-result result))))

(defvar fuji-gptel-tool-graphlit
  (when (fboundp 'gptel-make-tool)
    (gptel-make-tool
     :name "query_graphlit"
     :function #'fuji-query-graphlit
     :description "Search the research paper for specific details using RAG. Use this when the provided local context is insufficient or when you need to verify facts across the entire document."
     :args '((:name "query" :type string :description "The search query to look up in the paper database"))
     :category "research"))
  "The gptel tool for Graphlit RAG retrieval.")

;;;###autoload


;;; Interactive Configuration Interfaces

(defvar fuji-mode-map (make-sparse-keymap)
  "Keymap for `fuji-mode'.")

(define-key fuji-mode-map (kbd "C-c n m") #'fuji-session-set-model)
(define-key fuji-mode-map (kbd "C-c n a") #'fuji-session-add-context)
(define-key fuji-mode-map (kbd "C-c n s") #'fuji-mcp-manage)
(define-key fuji-mode-map (kbd "C-c n q") #'fuji-quit)
(define-key fuji-mode-map (kbd "C-c n r") #'fuji-retry-current-ingestion)
(define-key fuji-mode-map (kbd "C-c n b") #'fuji-add-bibtex-entry-from-doi)
(define-key fuji-mode-map (kbd "C-c n i") #'fuji-insert-citation)
(define-key fuji-mode-map (kbd "C-c n p") #'fuji-prompt-insert)
(define-key fuji-mode-map (kbd "C-c n e") #'fuji-chat-export-to-library)
(define-minor-mode fuji-mode
  "Minor mode for Fuji chat buffers."
  :lighter " Nexus"
  :keymap fuji-mode-map)

(defun fuji-session-set-model ()
  "Interactively set the gptel model and backend for the current Nexus session, and persist to config."
  (interactive)
  (let* ((backends gptel--known-backends)
         (backend-name (completing-read "Select Backend: " 
                                        (mapcar (lambda (b) (gptel-backend-name (cdr b))) 
                                                backends)))
         (backend (gptel-get-backend backend-name))
         (model-str (completing-read "Select Model: " (gptel-backend-models backend)))
         (model (intern model-str)))
    ;; Local session update
    (setq-local gptel-backend backend)
    (setq-local gptel-model model)
    ;; Global sync and persistence
    (setq fuji-gptel-backend backend-name)
    (setq fuji-gptel-model model)
    (if (fboundp 'fuji--update-persistent-config)
        (fuji--update-persistent-config)
      (message "Fuji: Persistent config function not loaded yet. Restart Emacs or reload fuji-configure.el. Selected model: %s" model))
    (fuji--log "Model updated to %s (%s) and persisted." model backend-name)
    (message "Fuji: Model set to %s and saved permanently" model)))

(defun fuji-session-add-context ()
  "Interactively add a file as context to the current Nexus session."
  (interactive)
  (let ((file (read-file-name "Add file to context: ")))
    (cond
     ((string-match-p "\\.\\(pdf\\|docx\\|pptx\\|xlsx\\|epub\\|mobi\\)$" (downcase file))
      (message "Fuji: [WARNING] gptel cannot process binary formats (PDF/DOCX) directly. Please extract to Markdown/Text first.")
      (when (y-or-n-p "Attempt to add anyway? ")
        (gptel-add-file file)
        (fuji--log "Context added (Binary?): %s" (file-name-nondirectory file))))
     (t
      (gptel-add-file file)
      (fuji--log "Context added: %s" (file-name-nondirectory file))
      (message "Fuji: File '%s' added to context." (file-name-nondirectory file))))))

(defun fuji-mcp-manage ()
  "Interactively manage (restart/register) the MCP server."
  (interactive)
  (if (y-or-n-p "Restart current Graphlit MCP server? ")
      (progn
        (fuji--register-mcp-server)
        (message "Fuji: MCP server restarted."))
    (message "Fuji: MCP management cancelled.")))

;;; Graphlit Content Management UI

(defvar fuji--content-list nil
  "List of content items from Graphlit.
Each item is an alist with keys: id, name, createdDate, fileSize, state.")




(defvar fuji-library-mode-map (make-sparse-keymap)
  "Keymap for `fuji-library-mode'.")

(define-key fuji-library-mode-map (kbd "g") 'fuji-library-refresh)
(define-key fuji-library-mode-map (kbd "d") 'fuji-library-mark-delete)
(define-key fuji-library-mode-map (kbd "u") 'fuji-library-unmark)
(define-key fuji-library-mode-map (kbd "U") 'fuji-library-unmark-all)
(define-key fuji-library-mode-map (kbd "W") 'fuji-library-chat-with-group)
(define-key fuji-library-mode-map (kbd "x") 'fuji-library-execute)
(define-key fuji-library-mode-map (kbd "r") 'fuji-library-retry-ingestion)
(define-key fuji-library-mode-map (kbd "RET") 'fuji-library-open-session)
(define-key fuji-library-mode-map (kbd "+") 'fuji-library-add-file)
(define-key fuji-library-mode-map (kbd "a") 'fuji-library-add-file)
(define-key fuji-library-mode-map (kbd "e") 'fuji-library-edit-title)
(define-key fuji-library-mode-map (kbd "b") 'fuji-library-add-bibtex)
(define-key fuji-library-mode-map (kbd "t") 'fuji-library-edit-tags)
(define-key fuji-library-mode-map (kbd "m") 'fuji-library-edit-tags)
(define-key fuji-library-mode-map (kbd "s") #'fuji-library-search)
(define-key fuji-library-mode-map (kbd "/") #'fuji-library-clear-search)
(define-key fuji-library-mode-map (kbd "S") #'fuji-library-clear-search)
(define-key fuji-library-mode-map (kbd "@") #'fuji-search-by-tag)
(define-key fuji-library-mode-map (kbd "q") #'quit-window)

(define-derived-mode fuji-library-mode tabulated-list-mode "Fuji-Library"
  "Major mode for managing Graphlit content.
\\{fuji-library-mode-map}"
  (setq tabulated-list-format
        [("I" 3 nil)  ; Icon
         ("Title" 40 t)
         ("Tags" 30 nil)
         ("ID" 12 nil)
         ("Date" 12 t)
         ("Size" 10 t)
         ("Type" 10 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "Date" t))
  (tabulated-list-init-header))

;; DISABLED: This function definition fails to load at this location
;; See working version at end of file (before provide statement)
;; (defun fuji--query-all-contents (callback)
;;   "Query all content from Graphlit via MCP and call CALLBACK with results."
;;   (let ((conn (fuji--get-mcp-connection)))
;;     (when conn
;;       (condition-case err
;;           (mcp-async-call-tool conn "queryContents"
;;                                '()  ; No arguments needed for listing all
;;                                (lambda (result)
;;                                  ;; queryContents returns multiple text items, each is a separate content object
;;                                  (let* ((content-array (plist-get result :content))
;;                                         (contents
;;                                          (when (vectorp content-array)
;;                                            (cl-loop for item across content-array
;;                                                     for text = (plist-get item :text)
;;                                                     when (and text (stringp text))
;;                                                     collect (condition-case nil
;;                                                                 (let ((json-object-type 'alist))
;;                                                                   (json-read-from-string text))
;;                                                               (error nil))))))
;;                                    (if contents
;;                                        (funcall callback contents)
;;                                      (message "Fuji: No content found in Graphlit")
;;                                      (funcall callback nil))))
;;                                (lambda (err)
;;                                  (message "Fuji: Failed to query contents: %s" 
;;                                           (error-message-string err))
;;                                  (funcall callback nil)))
;;         (error
;;          (message "Fuji: Query error: %s" (error-message-string err))
;;          (funcall callback nil))))))

;;; Metadata Cache for Content List

(defun fuji--get-metadata-cache-file ()
  "Get the path to the metadata cache file."
  (expand-file-name "metadata-cache.json" fuji-cache-directory))

(defun fuji--load-metadata-cache ()
  "Load metadata cache from JSON file. Returns an alist."
  (let ((cache-file (fuji--get-metadata-cache-file)))
    (if (file-exists-p cache-file)
        (condition-case err
            (with-temp-buffer
              (insert-file-contents cache-file)
              (let ((json-object-type 'alist)
                    (json-key-type 'symbol))
                (json-read-from-string (buffer-string))))
          (error
           (message "Fuji: Failed to load metadata cache: %s" (error-message-string err))
           '()))
      '())))

(defun fuji--save-metadata-cache (cache)
  "Save CACHE (alist) to JSON file."
  (let ((cache-file (fuji--get-metadata-cache-file)))
    (condition-case err
        (with-temp-file cache-file
          (insert (json-encode cache)))
      (error
       (message "Fuji: Failed to save metadata cache: %s" (error-message-string err))))))



(defun fuji--format-date (iso-date)
  "Format ISO-DATE string to readable format."
  (if (stringp iso-date)
      (substring iso-date 0 10)  ; Extract YYYY-MM-DD
    "N/A"))

(defun fuji-library-refresh ()
  "Refresh the content list from the active RAG backend AND local cache."
  (interactive)
  (message "Fuji: Querying %s and Local Cache..." fuji-rag-backend)
  ;; Unified RAG API + Local Merge
  (fuji--rag-list
   (lambda (rag-contents)
     (let* ((metadata-entries (fuji--load-metadata-cache))
            (local-entries
             (cl-loop for entry in metadata-entries
                      for id-raw = (car entry)
                      for id = (format "%s" id-raw) ;; Ensure ID is string
                      for meta = (cdr entry)
                      when (or (string-prefix-p "LOCAL-" id)
                                (string-prefix-p "PENDING-" id))
                      collect
                      `((id . ,id)
                        (name . ,(or (alist-get 'filename meta) "Unknown File"))
                        (createdDate . ,(or (alist-get 'upload_date meta) 
                                            (format-time-string "%Y-%m-%dT%H:%M:%SZ")))
                        (fileSize . 0) ;; Local file size logic can be added later
                        (state . ,(if (string-prefix-p "PENDING-" id) "PENDING" "LOCAL"))))))
       ;; Merge lists (Local + RAG)
       (setq fuji--content-list (append local-entries rag-contents))
       
       (let ((buf (get-buffer "*Fuji-Library*")))
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (fuji-library--populate-buffer))))
       (message "Fuji: Refreshed (%d RAG + %d Local items)" 
                (length rag-contents) (length local-entries))))))


(defun fuji-library--populate-buffer (&optional content-list)
  "Populate the library buffer with CONTENT-LIST or fuji--content-list."
  (let ((entries
         (mapcar
          (lambda (item)
            (let* ((id (cdr (assoc 'id item)))
                   (metadata (fuji--get-metadata-for-id id))
                   ;; Use cached metadata if available
                   (name (if metadata
                             (or (cdr (assoc 'title metadata)) (cdr (assoc 'filename metadata)))
                           (format "Content %s" (substring id 0 8))))
                   (tags (or (and metadata (cdr (assoc 'tags metadata))) ""))
                   (date (if metadata
                             (let ((upload-date (cdr (assoc 'upload_date metadata))))
                               (if (stringp upload-date)
                                   (substring upload-date 0 10)  ; Extract YYYY-MM-DD
                                 "N/A"))
                           "N/A"))
                   (size (if metadata
                             (fuji--format-file-size (cdr (assoc 'file_size metadata)))
                           "N/A"))
                   ;; Use doc_type from metadata for display, fallback to mimeType if missing
                   (display-type (if metadata
                                     (or (cdr (assoc 'doc_type metadata)) "unknown")
                                   (or (cdr (assoc 'mimeType item)) "unknown")))
                   (id-short (substring id 0 (min 8 (length id))))
                   (icon (cond
                          ((string-match-p "pdf" display-type)
                           (if (fboundp 'nerd-icons-faicon) (nerd-icons-faicon "nf-fa-file_pdf_o" :face '(:foreground "red")) "P"))
                          ((string-match-p "word\\|docx?" display-type)
                           (if (fboundp 'nerd-icons-faicon) (nerd-icons-faicon "nf-fa-file_word_o" :face '(:foreground "blue")) "W"))
                          ((string-match-p "html?" display-type)
                           (if (fboundp 'nerd-icons-faicon) (nerd-icons-faicon "nf-fa-html5" :face '(:foreground "orange")) "H"))
                          ((string-match-p "epub" display-type)
                           (if (fboundp 'nerd-icons-faicon) (nerd-icons-faicon "nf-fa-book" :face '(:foreground "green")) "E"))
                          (t (if (fboundp 'nerd-icons-faicon) (nerd-icons-faicon "nf-fa-file_o") "?")))))
              ;; Ensure vector has exactly 7 elements to match tabulated-list-format
              (list id (vector icon name tags id-short date size display-type))))
          (or content-list fuji--content-list))))
    (setq tabulated-list-entries entries)
    (tabulated-list-init-header)
    (tabulated-list-print t)))

(defun fuji-library-mark-delete ()
  "Mark the current entry for deletion."
  (interactive)
  (tabulated-list-put-tag "D" t))

(defun fuji-library-unmark ()
  "Unmark the current entry."
  (interactive)
  (tabulated-list-put-tag " " t))

(defun fuji-library-unmark-all ()
  "Unmark all entries."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward tabulated-list-tag-regexp nil t)
      (replace-match " " nil nil nil 1)))
  (tabulated-list-print t))

;;; Phase 2.2: File Archiving Functions

(defun fuji--get-originals-dir ()
  "Get the originals archive directory path.
  Creates the directory if it doesn't exist."
  (let ((dir (or fuji-originals-archive-dir
                 (expand-file-name "originals/" fuji-cache-directory))))
    (unless (file-directory-p dir)
      (make-directory dir t))
    dir))

(defun fuji--archive-file (file-path)
  "Archive FILE-PATH to originals directory.
Returns the path to the archived file, or nil if archiving fails."
  (when (and file-path (file-exists-p file-path))
    (condition-case err
        (let* ((hash (secure-hash 'sha256 file-path))
               (ext (file-name-extension file-path t))
               (archive-name (concat hash ext))
               (originals-dir (fuji--get-originals-dir))
               (archive-path (expand-file-name archive-name originals-dir)))
          ;; Ensure originals directory exists
          (unless (file-directory-p originals-dir)
            (make-directory originals-dir t))
          ;; Only copy if not already archived
          (unless (file-exists-p archive-path)
            (copy-file file-path archive-path t)
            (fuji--log "Archived original file to: %s" archive-path))
          archive-path)
      (error
       (message "Fuji: Failed to archive file %s: %s" file-path (error-message-string err))
       nil))))

(defun fuji--is-path-in-library-p (file-path)
  "Check if FILE-PATH is currently in the Fuji library (originals directory)."
  (let ((lib-dir (expand-file-name (fuji--get-originals-dir)))
        (path (expand-file-name file-path)))
    (string-prefix-p lib-dir path)))

(defun fuji--resolve-file-path (content-id)
  "Resolve file path for CONTENT-ID with fallback strategy.
Priority:
1. Original path (if exists)
2. Archived path (if exists)
3. Extracted markdown (read-only fallback)
Returns (path . type) where type is 'original, 'archived, or 'markdown.
Signals an error if no file can be found."
  (let* ((metadata (fuji--get-metadata-for-id content-id))
         (original-path (cdr (assoc 'original_path metadata)))
         (raw-archived-path (or (cdr (assoc 'archived_path metadata))
                                (cdr (assoc 'archived-path metadata))))
         (archived-path (if (and raw-archived-path 
                                 (not (file-name-absolute-p raw-archived-path))
                                 (bound-and-true-p fuji-cache-directory))
                            (expand-file-name raw-archived-path fuji-cache-directory)
                          raw-archived-path))
         (results-dir (cdr (assoc 'results_dir metadata))))
    (cond
     ;; 1. Archived file exists (Primary Source of Truth)
     ((and archived-path (file-exists-p archived-path))
      (cons archived-path 'archived))
     ;; 2. Original file exists (Fallback)
     ((and original-path (file-exists-p original-path))
      (fuji--log "Archived file not found, using original copy")
      (cons original-path 'original))
     ;; 3. Fallback to markdown
     ((and results-dir (file-directory-p results-dir))
      (let ((md-file (fuji--find-marker-output results-dir)))
        (when md-file
          (fuji--log "Original and archived files not found, opening extracted markdown (read-only)")
          (cons md-file 'markdown))))
     ;; Nothing found
     (t
      (error "Cannot locate file for content ID: %s" content-id)))))



(defcustom fuji-sessions-directory nil
  "Directory to store persistent chat sessions.
If nil, defaults to `sessions/` inside `fuji-cache-directory`."
  :type '(choice (const :tag "Default" nil)
                 directory)
  :group 'fuji)

(defun fuji--get-sessions-dir ()
  "Get the sessions archive directory path.
Creates the directory if it doesn't exist."
  (let ((dir (or fuji-sessions-directory
                 (expand-file-name "sessions/" fuji-cache-directory))))
    (unless (file-directory-p dir)
      (make-directory dir t))
    dir))

(defun fuji--get-session-file (content-id)
  "Get the path to the saved session file for CONTENT-ID."
  (expand-file-name (format "%s.org" content-id)
                    (fuji--get-sessions-dir)))

(defun fuji-save-session ()
  "Save the current chat buffer content to a session file."
  (interactive)
  (when (and fuji--content-id (buffer-live-p (current-buffer)))
    (let ((file (fuji--get-session-file fuji--content-id))
          (content (buffer-string)))
      (with-temp-file file
        (insert content))
      (fuji--log "Session saved to %s" file))))


(defun fuji--setup-2-buffer-layout (left-buf right-buf)
  "Setup a 2-column layout with LEFT-BUF and RIGHT-BUF."
  (delete-other-windows)
  (switch-to-buffer left-buf)
  (let ((right-win (split-window-right)))
    (set-window-buffer right-win right-buf)
    ;; Enhance UX: ensure right window is focused for chatting
    (select-window right-win)))

;; Define dedicated handler for robustness
(defun fuji--gptel-response-handler (&optional _beg _end)
  "Hook to run after gptel response. 
   Ensures prompt level is correct (**) and moves cursor to bottom."
  ;; 1. Active Correction: Fix PROMPT heading if it became Level 1
  (save-excursion
    (when (re-search-backward "^\\* " nil t)
      (let ((line (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
        (unless (or (string-match-p "Discussion" line)
                    (string-match-p "System Log" line))
          (replace-match "** ")))))
  
  ;; 2. Prepare Next Prompt & Move Cursor (Delayed)
  (run-at-time "0.2 sec" nil 
               (lambda (buf)
                 (when (buffer-live-p buf)
                   (with-current-buffer buf
                     (goto-char (point-max))
                     
                     ;; Check/Fix Prompt Level
                     (if (string-suffix-p "\n* " (buffer-substring (max 1 (- (point-max) 3)) (point-max)))
                         (progn
                           (delete-char -2)
                           (insert "** "))
                       (unless (string-suffix-p "** " (buffer-substring (max 1 (- (point-max) 3)) (point-max)))
                         (insert "\n\n** ")))
                     
                     ;; Scroll
                     (when (get-buffer-window buf)
                       (set-window-point (get-buffer-window buf) (point-max))
                       (with-selected-window (get-buffer-window buf)
                         (recenter -1))))))
               (current-buffer)))

(defun fuji--load-session (content-id)
  "Restore reading session for CONTENT-ID."
  (let* ((metadata (fuji--get-metadata-for-id content-id))
         (filename (or (cdr (assoc 'filename metadata)) "Unknown"))
         ;; Use unified path resolution (Priority: Archived > Original > Markdown)
         (path-info (fuji--resolve-file-path content-id))
         (doc-path (car path-info))
         (results (cdr (assoc 'results_dir metadata)))
         (session-file (fuji--get-session-file content-id))
         (session-content (when (file-exists-p session-file)
                            (with-temp-buffer
                              (insert-file-contents session-file)
                              (buffer-string)))))
    
    (unless (and doc-path (file-exists-p doc-path))
      (error "Critical: Document file not found for %s" filename))

    ;; Open Document
    (let ((doc-buffer (find-file-noselect doc-path))
          (chat-buffer (get-buffer-create (format "*Fuji-Chat: %s*" filename))))
      
      ;; Setup Layout (2-window)
      (fuji--setup-2-buffer-layout doc-buffer chat-buffer)

      ;; Init Chat Buffer
      (with-current-buffer chat-buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          ;; 1. Restore Content
          (if session-content
              (progn
                (insert session-content)
                
                ;; Migration & Cleanup: Enforce rigid 2-level structure
                (message "Fuji: Verifying chat structure...")
                (let ((inhibit-read-only t)
                      (case-fold-search nil)) ;; Case-sensitive match for "* Discussion"
                  
                  ;; 1.0 Ensure System Log is Level 1 (Upgrade if needed) & Move to Top
                  (goto-char (point-min))
                  ;; Match any heading level containing "System Log", case-insensitive
                  (let ((case-fold-search t)
                        (system-log-content nil))
                    (when (re-search-forward "^\\*+[ \t]*.*System Log.*$" nil t)
                      ;; Found it. Extract it.
                      (beginning-of-line)
                      (let ((beg (point)))
                        (org-end-of-subtree)
                        (setq system-log-content (buffer-substring beg (point)))
                        (delete-region beg (point))))
                    
                    ;; If found (and deleted), or if we need to verify its position
                    (when system-log-content
                       ;; Normalize title to Level 1 "* Fuji System Log"
                       (with-temp-buffer
                         (insert system-log-content)
                         (goto-char (point-min))
                         (when (looking-at "^\\*+[ \t]*.*System Log.*$")
                           (replace-match "* Fuji System Log"))
                         (setq system-log-content (buffer-string)))
                       
                       ;; Insert at top (after properties)
                       (goto-char (point-min))
                       (while (looking-at "^#\\+") (forward-line 1))
                       (unless (looking-at "^$") (insert "\n"))
                       (insert "\n" system-log-content "\n")))

                  ;; 1. Demote ALL Level 1 headers that are NOT "* Discussion" or "* Fuji System Log"
                  (goto-char (point-min))
                  (while (re-search-forward "^\\* \\(.*\\)$" nil t)
                    (let ((title (match-string 1)))
                      (unless (or (string-equal title "Discussion")
                                  (string-match-p "System Log" title))
                        ;; Replace "* Title" with "** Title"
                        (replace-match "** \\1"))))

                  ;; 2. Ensure "* Discussion" container exists
                  (goto-char (point-min))
                  (unless (re-search-forward "^\\* Discussion$" nil t)
                     ;; Insert global Discussion header after properties
                     (goto-char (point-min))
                     (while (looking-at "^#\\+")
                       (forward-line 1))
                     (while (re-search-forward "^\\* .*System Log.*" nil t) ;; skip System Log if present at top
                        (org-end-of-subtree))
                     (unless (looking-at "^$") (insert "\n"))
                     (insert "\n* Discussion\n")))

                ;; 3. Enforce Startup Settings
                (goto-char (point-min))
                (if (re-search-forward "^#\\+STARTUP:.*$" nil t)
                    (let ((current-startup (match-string 0)))
                      (unless (string-match-p "overview" current-startup)
                        (end-of-line)
                        (insert " overview")))
                  (goto-char (point-min))
                  (insert "#+STARTUP: indent overview\n"))

                
                ;; 4. Phase 1: Refresh Metadata (Deduplication Fix)
                ;; Always force a refresh to ensure headings are unique and up-to-date
                ;; This replaces the old inline insertion logic
                (fuji--refresh-chat-metadata))

                ;; Default Header if no session
            (insert "#+TITLE: Chat Session: " filename "\n"
                    "#+STARTUP: indent overview\n"
                    "#+PROPERTY: header-args :results silent\n\n"
                    "* Fuji System Log\n:PROPERTIES:\n:Created: " (format-time-string "[%Y-%m-%d %H:%M]") "\n:END:\n"
                    "* Discussion\n\n"
                    "** "))
          
          ;; Initialize Org Mode after content is inserted to parse #+STARTUP
          (org-mode)
          ;; 2. Set Local Variables
          ;; (Moved to end of function to ensure they override any defaults)

          (setq-local fuji--content-id content-id)
          (setq-local fuji--filename filename)
          (setq-local fuji--results-dir results)
          (setq-local fuji--pdf-buffer doc-buffer)
          ;; Note: fuji--prog-buffer is deprecated in Phase 4 UI

          ;; 2.5 Ensure Clean Context
          (when (fboundp 'gptel-context-remove-all)
            (gptel-context-remove-all))

          ;; 3. Context Injection (Hybrid Mode)
          (when (and results (file-exists-p (expand-file-name (concat (file-name-base filename) ".md") results)))
            (fuji-context-add-file (expand-file-name (concat (file-name-base filename) ".md") results)))
          
          
          ;; 4. Final UI Adjustment: Jump to bottom
          (goto-char (point-max))
          (when (get-buffer-window (current-buffer))
            (set-window-point (get-buffer-window (current-buffer)) (point-max))))

          ;; 4. GPTel & Graphlit Config
          (when fuji-gptel-backend
            (let ((be (gptel-get-backend fuji-gptel-backend)))
              (when be (setq-local gptel-backend be))))
          (when fuji-gptel-model
            (setq-local gptel-model (if (stringp fuji-gptel-model)
                                        (intern fuji-gptel-model)
                                      fuji-gptel-model)))

          (setq-local gptel-directives 
                      (cons '(fuji . "You are an academic assistant by Ruan. Answer questions based on the provided document context. If you need more info from the paper using semantic search, use the 'query_graphlit' tool.")
                            gptel-directives))
          (setq-local gptel-default-directive 'fuji)

          (when (and (boundp 'gptel-tools) fuji-gptel-tool-graphlit)
            ;; Hybrid Mode: Only enable Graphlit tool if ID is NOT local
            (if (string-prefix-p "LOCAL-" (format "%s" content-id))
                (progn
                  (setq-local gptel-tools nil)
                  (message "Fuji: Local-only mode (RAG disabled for large file)."))
              (setq-local gptel-tools (list fuji-gptel-tool-graphlit))))

          ;; 5. Enable Modes & Hooks
          (if (fboundp 'gptel-mode) (gptel-mode 1))
          (fuji-mode 1)
          
          ;; Ensure hook is locally set for standard responses
          (add-hook 'gptel-post-response-functions #'fuji--gptel-response-handler nil t)
          
          ;; Ensure prompt prefix is set effectively
          (setq-local gptel-prompt-prefix-alist '((org-mode . "** ") (default . "** ")))
          ;; Auto-save hooks
          (add-hook 'kill-buffer-hook #'fuji-save-session nil t)
          (add-hook 'kill-buffer-hook #'fuji--cleanup-session nil t)
          
          ;; 4. Final UI Adjustment: Jump to bottom
          (goto-char (point-max))
          (ignore-errors (org-show-context)) ;; Use org-show-context to reveal
          (when (get-buffer-window (current-buffer))
            (set-window-point (get-buffer-window (current-buffer)) (point-max))
            (with-selected-window (get-buffer-window (current-buffer))
              (recenter -1)))
          (message "Fuji: Session loaded for %s" filename)))))

(defun fuji--add-metadata-entry (content-id filename file-path &optional results-dir)

  "Add metadata entry for CONTENT-ID with FILENAME and FILE-PATH.
Automatically archives the original file and tracks document type.
If RESULTS-DIR is provided, it is stored to allow deleting extracted content later."
  (let* ((cache (or (fuji--load-metadata-cache) '()))
         (id-key (if (stringp content-id) (intern content-id) content-id))
         (file-size (and (file-exists-p file-path) 
                         (file-attribute-size (file-attributes file-path))))
         ;; Determine document type from extension
         (ext (file-name-extension file-path))
         (doc-type (cond
                    ((string-match-p "\\.pdf$" file-path) "pdf")
                    ((string-match-p "\\.docx?$" file-path) "docx")
                    ((string-match-p "\\.epub$" file-path) "epub")
                    ((string-match-p "\\.html?$" file-path) "html")
                    (ext (downcase ext))
                    (t "unknown")))
         ;; Calculate hash and archive
         ;; Re-calculate hash here to ensure it's stored in metadata even if already archived
         (file-hash (if (file-exists-p file-path)
                        (secure-hash 'sha256 file-path)
                      nil))
         (archived-path (fuji--archive-file file-path))
         (metadata `((filename . ,filename)
                     (title . ,filename)          ; NEW: Adjustable title, defaults to filename
                     (tags . "")                  ; NEW: User tags (was memo)
                     (file_hash . ,file-hash)     ; NEW: For duplicate detection
                     (upload_date . ,(format-time-string "%Y-%m-%dT%H:%M:%S"))
                     (file_size . ,(or file-size 0))
                     (original_path . ,file-path)
                     (archived_path . ,(if archived-path 
                                           (file-relative-name archived-path fuji-cache-directory) 
                                         nil))
                     (results_dir . ,(if results-dir
                                         (file-relative-name results-dir fuji-cache-directory)
                                       nil))
                     (doc_type . ,doc-type))))
    ;; Add or update entry
    (setq cache (cons (cons id-key metadata)
                      (assoc-delete-all id-key cache)))
    (fuji--save-metadata-cache cache)
    (if archived-path
        (message "Fuji: Saved metadata for %s (archived to %s)" filename archived-path)
      (message "Fuji: Saved metadata for %s" filename))))

(defun fuji--get-metadata-for-id (content-id)
  "Get metadata for CONTENT-ID from cache. Returns alist or nil."
  (let* ((cache (fuji--load-metadata-cache))
         (id-key (if (stringp content-id) (intern content-id) content-id)))
    (cdr (assoc id-key cache))))

(defun fuji--remove-metadata-entry (content-id)
  "Remove metadata entry for CONTENT-ID from cache."
  (let* ((cache (or (fuji--load-metadata-cache) '()))
         (id-key (if (stringp content-id) (intern content-id) content-id))
         (updated-cache (assoc-delete-all id-key cache)))
    (fuji--save-metadata-cache updated-cache)
    (message "Fuji: Removed metadata for %s" content-id)))

(defun fuji--update-metadata-entry (content-id new-metadata)
  "Update metadata entry for CONTENT-ID with NEW-METADATA."
  (let* ((cache (fuji--load-metadata-cache))
         (id-key (if (stringp content-id) (intern content-id) content-id))
         ;; Remove old entry
         (clean-cache (assoc-delete-all id-key cache))
         ;; Add new entry
         (updated-cache (cons (cons id-key new-metadata) clean-cache)))
    (fuji--save-metadata-cache updated-cache)))

(defun fuji-migrate-memos-to-tags ()
  "Migrate legacy 'memo' fields to 'tags' in all library metadata."
  (interactive)
  (let ((cache (fuji--load-metadata-cache))
        (migrated-count 0))
    (dolist (entry cache)
      (let* ((metadata (cdr entry))
             (memo (cdr (assoc 'memo metadata)))
             (tags (cdr (assoc 'tags metadata))))
        ;; Migrate if memo exists (and is not nil/empty) AND tags is nil/empty/missing
        (when (and memo (not (string-empty-p memo))
                   (or (not tags) (string-empty-p tags)))
          (if (assoc 'tags metadata)
              (setf (cdr (assoc 'tags metadata)) memo)
            (nconc metadata (list (cons 'tags memo))))
          ;; Clear AND REMOVE memo to allow proper cleanup
          (if (assoc 'memo metadata)
              (setf (cdr (assoc 'memo metadata)) nil))
          (assq-delete-all 'memo metadata) ;; Hard delete
          (cl-incf migrated-count))
      ;; Also delete empty memos if they exist
      (when (assoc 'memo metadata)
        (assq-delete-all 'memo metadata))))
    
    (if (> migrated-count 0)
        (progn
          (fuji--save-metadata-cache cache)
          (message "Fuji: Migrated %d documents from 'memo' to 'tags'." migrated-count))
      (message "Fuji: No documents needed migration."))))

(defun fuji--get-all-tags ()
  "Return a list of all unique tags used across the library."
  (let ((tags '())
        (cache (fuji--load-metadata-cache)))
    (message "DEBUG: Fuji Tag Collection - Cache size: %d" (length cache))
    (dolist (entry cache)
      (let* ((metadata (cdr entry))
             (tag-str (or (cdr (assoc 'tags metadata)) ""))
             (entry-tags (split-string tag-str "[,;：；\t]+" t " "))) ;; Split by common delimiters and trim
        (when entry-tags
           (message "DEBUG: Found tags in document %s: %s" (car entry) entry-tags))
        (dolist (tag entry-tags)
          (unless (member tag tags)
            (push tag tags)))))
    (message "DEBUG: Total unique tags: %d" (length tags))
    (sort tags #'string<)))

(defun fuji--normalize-tags (tag-str)
  "Normalize TAG-STR: split by various delimiters and join with comma-space.
Delimiters: comma, semicolon, colon, chinese comma/semicolon, tabs."
  (if (string-blank-p tag-str)
      ""
    (let ((tags (split-string tag-str "[,;:：；\t]+" t " "))) ;; Split and trim whitespace around tokens
      (mapconcat #'identity tags ", "))))



(defun fuji--format-file-size (bytes)
  "Format BYTES as human-readable file size."
  (cond
   ((>= bytes 1073741824) (format "%.1f GB" (/ bytes 1073741824.0)))
   ((>= bytes 1048576) (format "%.1f MB" (/ bytes 1048576.0)))
   ((>= bytes 1024) (format "%.1f KB" (/ bytes 1024.0)))
   (t (format "%d B" bytes))))

(defun fuji--format-date (iso-date)
  "Format ISO-DATE string to readable format."
  (if (stringp iso-date)
      (substring iso-date 0 10)  ; Extract YYYY-MM-DD
    "N/A"))



(defun fuji-library-open-session ()
  "Resume reading session for the selected document."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (if id
        (fuji--load-session id)
      (user-error "No document selected"))))


(defun fuji-library-edit-title ()
  "Edit the title of the selected document."
  (interactive)
  (let* ((id (tabulated-list-get-id))
         (current-row (and id (assoc id tabulated-list-entries)))
         ;; Title is now at index 1 because index 0 is Icon
         (current-title (and current-row (aref (cadr current-row) 1))))
    (if id
        (let ((new-title (read-string "New Title: " current-title)))
          (when (and new-title (not (string-empty-p new-title)))
            ;; Update Metadata Cache
            (let ((metadata (fuji--get-metadata-for-id id)))
              (when metadata
                (setf (cdr (assoc 'title metadata)) new-title)
                (fuji--update-metadata-entry id metadata)
                ;; Update RAG backend if possible (optional, maybe just local cache for now)
                ;; (fuji--rag-update-title id new-title)
                (message "Fuji: Title updated to '%s'" new-title)
                ;; Refresh current line
                (fuji-library-refresh-current-line)))))
      (user-error "No document selected"))))

(defun fuji-library-edit-tags ()
  "Add or edit tags for the selected document with auto-completion."
  (interactive)
  (let* ((id (tabulated-list-get-id))
         (metadata (and id (fuji--get-metadata-for-id id)))
         (current-tags (and metadata (or (cdr (assoc 'tags metadata)) 
                                         "")))
         (all-tags (fuji--get-all-tags)))
    (if id
        (let* ((crm-separator "[ \t]*,[ \t]*") ;; CRM separator for display
               (selected-tags (completing-read-multiple 
                               (format "Tags (current: %s): " current-tags)
                               all-tags
                               nil nil ;; Predicate required? No.
                               current-tags ;; Initial input? No, messy with CRM. Use current as hint.
                               ;; Better UX: Pre-populate history/default? 
                               ;; CRM is tricky with 'initial-input if it's a list.
                               ;; If we want to EDIT existing tags, read-string is better but no completion.
                               ;; Hybrid: completing-read-multiple returns a LIST of strings.
                               ))
               ;; If user just hits RET, selected-tags might be empty list or ("").
               ;; But wait! CRM with default doesn't quite work like read-string for *editing*.
               ;; It's for *selecting*.
               ;; Let's stick to the request: "Tip previously entered tags".
               ;; If we use CRM, we are essentially re-selecting tags. 
               ;; Let's allow arbitrary input by not requiring match.
               (final-tag-str (mapconcat #'string-trim selected-tags ", ")))

          ;; Wait, CRM is great for selecting multiple *existing* tags. 
          ;; But if I want to add a *new* tag "NewTag", CRM allows it if REQUIRE-MATCH is nil.
          ;; But I can't easily "edit" the string "Tag1, Tag2" -> "Tag1, Tag2, NewTag" in minibuffer 
          ;; unless I pass it as initial input.
          
          ;; Refined approach: Use read-string with completion-at-point? No.
          ;; Let's use CRM but be smart.
          ;; Actually, the user asked for "Candidate hints".
          ;; If we pass current-tags as INITIAL-INPUT to CRM?
          ;; (completing-read-multiple PROMPT TABLE &optional PREDICATE REQUIRE-MATCH INITIAL-INPUT HIST DEF INHERIT-INPUT-METHOD)
          
          (let ((new-tags-list 
                 (completing-read-multiple 
                  "Tags: " 
                  all-tags 
                  nil 
                  nil ;; Confirm: REQUIRE-MATCH = nil (allow new tags)
                  current-tags ;; Initial input = current string (e.g. "AI, Agent")
                  )))
            
            (when new-tags-list
              ;; Join and normalize
              (let ((normalized-tags (mapconcat #'identity new-tags-list ", ")))
                
                ;; Update tags
                (if (assoc 'tags metadata)
                    (setf (cdr (assoc 'tags metadata)) normalized-tags)
                  (nconc metadata (list (cons 'tags normalized-tags))))
                
                ;; Clear old memo if exists AND DELETE IT
                (when (assoc 'memo metadata)
                  (assq-delete-all 'memo metadata))
                
                (fuji--update-metadata-entry id metadata)
                (message "Fuji: Tags updated to '%s'" normalized-tags)
                (fuji-library-refresh-current-line)))))
      (user-error "No document selected"))))

(defun fuji-library-add-bibtex ()
  "Add a BibTeX entry from DOI for the selected document."
  (interactive)
  (let* ((id (tabulated-list-get-id))
         (metadata (and id (fuji--get-metadata-for-id id))))
    (unless id
      (user-error "No document selected"))
    
    (let ((doi (read-string "Enter DOI: "))
          (file-path (or (cdr (assoc 'archived_path metadata))
                         (cdr (assoc 'original_path metadata)))))
      
      (when (and file-path (not (file-name-absolute-p file-path)))
        (setq file-path (expand-file-name file-path fuji-cache-directory)))

      (when (and doi (not (string-empty-p doi)))
        (message "Fuji: Fetching BibTeX for DOI %s..." doi)
        (let ((key (fuji-add-bibtex-entry-from-doi doi file-path)))
          (if key
              (progn
                ;; 1. Update Metadata
                (if (assoc 'bib_key metadata)
                    (setf (cdr (assoc 'bib_key metadata)) key)
                  (nconc metadata (list (cons 'bib_key key))))
                (fuji--update-metadata-entry id metadata)
                
                ;; 2. Update Session File Header
                (fuji--update-session-bib-key id key)
                
                ;; 3. Refresh BibTeX Cache & UI
                (when (fboundp 'bibtex-completion-clear-cache)
                  (bibtex-completion-clear-cache))
                
                ;; If session is open, refresh it
                (let ((session-buf (fuji--find-session-buffer id)))
                  (when session-buf
                    (with-current-buffer session-buf
                      ;; Reload session logic to refresh metadata header
                      (fuji--load-session id)))) ;; Quick revert to re-run fuji--load-session logic
                
                (message "Fuji: Linked BibTeX key '%s' to document." key))
            (message "Fuji: Failed to find or add BibTeX entry.")))))))


(defun fuji--find-session-buffer (id)
  "Find the active session buffer for ID."
  (cl-loop for buf in (buffer-list)
           thereis (with-current-buffer buf
                     (and (boundp 'fuji--content-id)
                          (string= fuji--content-id id)
                          buf))))

(defun fuji--update-session-bib-key (id key)
  "Update the session file for ID to include the BibTeX KEY.
Safe for open buffers."
  (message "DEBUG: update-session-bib-key called for ID %s Key %s" id key)
  (let ((session-file (fuji--get-session-file id))
        (active-buffer (fuji--find-session-buffer id)))
    (if active-buffer
        ;; If active session buffer exists (even if not visiting file), update it
        (with-current-buffer active-buffer
          (message "DEBUG: Found active buffer: %s" (current-buffer))
          (fuji--set-bib-key-in-session key)
          ;; Save via fuji-save-session to ensure disk sync
          (fuji-save-session)
          (message "DEBUG: Saved session buffer"))
      ;; Fallback: Update file on disk directly
      (message "DEBUG: No active buffer found. Checking file: %s" session-file)
      (when (and session-file (file-exists-p session-file))
        (with-current-buffer (find-file-noselect session-file)
          (fuji--set-bib-key-in-session key)
          (save-buffer)
          (kill-buffer)
          (message "DEBUG: Updated and saved file directly"))))))

(defun fuji-library-add-file ()
  "Add a new file to the library (wrapper for `fuji-read`)."
  (interactive)
  (fuji-read))

(defun fuji-library-refresh-current-line ()
  "Refresh the current line in the library view."
  (let ((id (tabulated-list-get-id)))
    (when id
      ;; Update the entry in fuji--content-list is not strictly needed if we pull from metadata
      ;; But populate-buffer uses fuji--content-list + fuji--get-metadata-for-id
      ;; So ensuring metadata is updated is key.
      (save-excursion
        (fuji-library--populate-buffer)
        ;; Restore point? populate-buffer resets everything.
        ;; This is a simple implementation: full refresh from local list
        )
      (fuji-library--restore-point id))))

(defun fuji-library--restore-point (id)
  "Restore point to the entry with ID."
  (goto-char (point-min))
  (while (and (not (eobp))
              (not (string= (tabulated-list-get-id) id)))
    (forward-line 1)))

(defun fuji-library-search (query)
  "Filter the library buffer by QUERY.
Supports multiple space-separated terms with AND logic.
Prefixes:
- t:TAGS (metadata tags)
- title:TITLE (metadata title)
- type:TYPE (metadata file type)
- No prefix: Full-text content search

Example: 'type:pdf t:research attention' matches items that are PDFs AND have 'research' tag AND 'attention' in content."
  (interactive "sSearch (t:Tags title:Title type:PDF content): ")
  (if (string-blank-p query)
      (fuji-library-clear-search)
    (let* ((tokens (split-string query " " t))
           (meta-filters '())
           (content-terms '())
           (filtered-entries fuji--content-list))

      ;; 1. Parse tokens
      (dolist (token tokens)
        (cond
         ((string-prefix-p "title:" token) (push (cons 'title (substring token 6)) meta-filters))
         ((string-prefix-p "t:" token) (push (cons 'tags (substring token 2)) meta-filters))
         ((string-prefix-p "type:" token) (push (cons 'doc_type (substring token 5)) meta-filters))
         (t (push token content-terms))))

      ;; 2. Apply metadata filters (Incremental AND)
      (dolist (filter meta-filters)
        (let ((field (car filter))
              (pattern (regexp-quote (cdr filter))))
          (setq filtered-entries
                (seq-filter
                 (lambda (entry)
                   (let* ((id (cdr (assoc 'id entry)))
                          (metadata (fuji--get-metadata-for-id id))
                          ;; Handle tags fallback to memo for backward compatibility
                          (val (if (eq field 'tags)
                                   (or (cdr (assoc 'tags metadata)) (cdr (assoc 'memo metadata)) "")
                                 (or (cdr (assoc field metadata)) ""))))
                     (string-match-p pattern val)))
                 filtered-entries))))

      ;; 3. Apply content terms (Incremental AND)
      (when (and filtered-entries content-terms)
        (let* ((results-base-dir fuji-cache-directory)
               (originals-name (if (bound-and-true-p fuji-originals-archive-dir)
                                   (file-name-nondirectory (directory-file-name fuji-originals-archive-dir))
                                 "originals")))
          (dolist (term content-terms)
            (when filtered-entries
              (let* ((grep-command
                      (if (executable-find "rg")
                          (format "rg -l -i '%s' '%s' --glob '!metadata' --glob '!sessions' --glob '!%s'"
                                  term results-base-dir originals-name)
                        (format "grep -r -l -i '%s' '%s' --exclude-dir=metadata --exclude-dir=sessions --exclude-dir='%s' --include='*.md'"
                                term results-base-dir originals-name)))
                     (matching-files (split-string (shell-command-to-string grep-command) "\n" t))
                     (matching-ids '()))
                
                ;; Map files to IDs
                (dolist (file matching-files)
                  (dolist (item fuji--content-list)
                    (let* ((id (cdr (assoc 'id item)))
                           (metadata (fuji--get-metadata-for-id id))
                           (raw-res-dir (cdr (assoc 'results_dir metadata)))
                           (res-dir (if (and raw-res-dir 
                                             (not (file-name-absolute-p raw-res-dir))
                                             (bound-and-true-p fuji-cache-directory))
                                        (expand-file-name raw-res-dir fuji-cache-directory)
                                      raw-res-dir)))
                      (when (and res-dir
                                 (string-prefix-p (expand-file-name res-dir) (expand-file-name file)))
                        (push id matching-ids)))))
                
                ;; Filter currently candidates by those matching this term
                (setq filtered-entries
                      (seq-filter
                       (lambda (entry)
                         (member (cdr (assoc 'id entry)) matching-ids))
                       filtered-entries)))))))

      ;; 4. Update Buffer
      (fuji-library--populate-buffer filtered-entries)
      (message "Fuji: Found %d matches for '%s'" (length filtered-entries) query))))

(defun fuji-library-clear-search ()
  "Clear active search and show all items."
  (interactive)
  (fuji-library-refresh)
  (message "Fuji: Search cleared"))

(defun fuji-library-view-details ()
  "View detailed information about the current entry."
  (interactive)
  (let* ((id (tabulated-list-get-id))
         (item (cl-find id fuji--content-list 
                        :key (lambda (x) (cdr (assoc 'id x)))
                        :test #'string=)))
    (if item
        (let ((details (format "Content Details\n%s\n\nID: %s\nName: %s\nCreated: %s\nSize: %s\nState: %s\nType: %s"
                               (make-string 60 ?=)
                               (cdr (assoc 'id item))
                               (cdr (assoc 'name item))
                               (cdr (assoc 'createdDate item))
                               (fuji--format-file-size (or (cdr (assoc 'fileSize item)) 0))
                               (cdr (assoc 'state item))
                               (cdr (assoc '__typename item)))))
          (with-current-buffer (get-buffer-create "*Fuji-Content-Details*")
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert details)
              (goto-char (point-min))
              (view-mode))
            (display-buffer (current-buffer))))
      (message "No details available"))))


(defun fuji-chat-export-to-library (title)
  "Export the current chat buffer to the Fuji library as an Org file.
Prompts for a TITLE, saves the current buffer to a temporary file,
ingests it into Fuji via `fuji-read`, and deletes the temp file."
  (interactive "sEnter title for this chat export: ")
  (unless (derived-mode-p 'org-mode)
    (user-error "Current buffer is not in Org mode!"))
  (when (string-blank-p title)
    (user-error "Title cannot be empty!"))
  (let* ((safe-title (replace-regexp-in-string "[^a-zA-Z0-9_\u4e00-\u9fa5-]" "_" title))
         (filename (concat safe-title ".org"))
         (temp-file (expand-file-name filename temporary-file-directory)))
    (write-region (point-min) (point-max) temp-file nil 'silent)
    (message "Exporting to Fuji library: %s" title)
    (fuji-read temp-file)
    (when (file-exists-p temp-file)
      (delete-file temp-file))
    (message "Chat exported to Fuji successfully.")))

(defun fuji-library-mark-delete ()
  "Mark the current entry for deletion."
  (interactive)
  (tabulated-list-put-tag "D" t))

(defun fuji-library-chat-with-group ()
  "Start a chat session with ALL currently visible documents in the library.
Useful for Knowledge Base Chat (Multi-doc RAG).

Context Strategy:
- < 5 docs: Full context injection + RAG
- > 5 docs: RAG-only mode (Metadata + System Prompt)"
  (interactive)
  ;; 1. Collect visible entries
  ;; tabulated-list-entries is a list of (ID . VECTOR)
  (let* ((entries (mapcar #'car tabulated-list-entries)) ; IDs
         (count (length entries))
         (content-ids '())
         (files '()))
    
    (when (zerop count)
      (user-error "Current view is empty."))
    
    ;; 2. Gather metadata
    (dolist (id entries)
      (let* ((metadata (fuji--get-metadata-for-id id))
             (res-dir (cdr (assoc 'results_dir metadata)))
             (filename (cdr (assoc 'filename metadata))))
        (push id content-ids)
        (when (and res-dir filename)
           (let ((md-file (expand-file-name (concat (file-name-base filename) ".md") 
                                            (if (file-name-absolute-p res-dir) res-dir 
                                              (expand-file-name res-dir fuji-cache-directory)))))
             (when (file-exists-p md-file)
               (push (cons filename md-file) files))))))
    
    ;; 3. Create Chat Buffer
    (let ((buffer-name (format "*Fuji-Group-Chat: %d docs*" count)))
      (switch-to-buffer (get-buffer-create buffer-name))
      (delete-other-windows) ;; Full screen
      
      (let ((inhibit-read-only t))
        (erase-buffer)
        (org-mode)
        (fuji-mode)
        (gptel-mode 1) ;; Enable GPTel interaction
        
        ;; 4. Initialize Context & Hybrid Strategy
        (when (fboundp 'gptel-context-remove-all)
          (gptel-context-remove-all))
        
        (let ((local-files '())
              (remote-ids '()))
          
          ;; Partition IDs & Gather Local Files
           (dolist (id content-ids)
             (let* ((meta (fuji--get-metadata-for-id id))
                    (res-dir (cdr (assoc 'results_dir meta)))
                    (fname (cdr (assoc 'filename meta)))
                    (md-path (when res-dir ;; Check if we have a local cache file
                               (expand-file-name (concat (file-name-base fname) ".md") 
                                                 (if (file-name-absolute-p res-dir) res-dir 
                                                   (expand-file-name res-dir fuji-cache-directory))))))
               
               ;; Always try to add local markdown to context if it exists
               (if (and md-path (file-exists-p md-path))
                   (push md-path local-files)
                 ;; If no markdown, maybe just rely on RAG?
                 nil)

               ;; If NOT a LOCAL-only file, add to RAG IDs
               (unless (string-prefix-p "LOCAL-" (format "%s" id))
                 (push id remote-ids))))

          (let ((load-context-p (y-or-n-p "Add current document list to chat context? ")))
            (if load-context-p
                (progn
                  ;; Inject Local Files (Strong Context)
                  (when (fboundp 'gptel-add-file)
                    (let ((inhibit-message t))
                      (dolist (f local-files)
                        (gptel-add-file f))))

                  ;; 5. Insert Header
                  (insert "#+TITLE: Group Chat (" (number-to-string count) " documents)\n")
                  (insert "#+STARTUP: indent\n\n")
                  (insert "* System: " (number-to-string (length local-files)) " local files loaded into context.\n")
                  (when remote-ids
                     (insert "* System: " (number-to-string (length remote-ids)) " remote files available via RAG.\n"))
                  (insert "\n---\n\n")
                  
                  ;; 6. Setup Local Variables
                  (setq-local fuji--content-ids (nreverse content-ids))
                  
                  ;; 7. GPTel Config
                  (when fuji-gptel-backend
                    (let ((be (gptel-get-backend fuji-gptel-backend)))
                      (when be (setq-local gptel-backend be))))
                  (when fuji-gptel-model
                    (setq-local gptel-model fuji-gptel-model))

                  ;; Tools: Only enable if we have remote content
                  (if remote-ids
                      (when (and (boundp 'gptel-tools) fuji-gptel-tool-graphlit)
                        (setq-local gptel-tools (list fuji-gptel-tool-graphlit))
                        (message "Fuji: Hybrid Chat initialized (%d local, %d remote)" 
                                 (length local-files) (length remote-ids)))
                    ;; Else: No remote content -> No RAG tool
                    (setq-local gptel-tools nil)
                    (message "Fuji: Local Chat initialized (%d docs)" (length local-files)))
                  
                  (setq-local gptel-directives 
                              (cons '(fuji-group . "You are a Knowledge Base Assistant. You have access to a specific group of documents. 
Some documents are provided directly in your context, while others are available via the 'query_graphlit' tool.
If the user asks about the remote documents (listed in the System header), use the tool to search for answers.")
                                    gptel-directives))
                  (setq-local gptel-default-directive 'fuji-group)
                  
                  (message "Fuji: Hybrid Group Chat started with %d documents." count))
              ;; ELSE: Do not load context, start clean
              (insert "#+TITLE: Fuji Clean Chat\n")
              (insert "#+STARTUP: indent\n\n")
              (insert "* System: Clean chat initialized. No documents are loaded into context.\n")
              (insert "\n---\n\n")
              (setq-local fuji--content-ids nil)
              (setq-local gptel-tools nil)
              (when fuji-gptel-backend
                (let ((be (gptel-get-backend fuji-gptel-backend)))
                  (when be (setq-local gptel-backend be))))
              (when fuji-gptel-model
                (setq-local gptel-model fuji-gptel-model))
              (message "Fuji: Clean Chat initialized."))))))))

(defun fuji-library-unmark ()
  "Unmark the current entry."
  (interactive)
  (tabulated-list-put-tag " " t))

(defun fuji-library-unmark-all ()
  "Unmark all entries."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (tabulated-list-put-tag " ")
      (forward-line 1)))
  (message "All marks cleared"))

(defun fuji-library-execute ()
  "Execute marked deletions."
  (interactive)
  (let ((marked-ids '()))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (eq (char-after) ?D)
          (push (tabulated-list-get-id) marked-ids))
        (forward-line 1)))
    (if (null marked-ids)
        (message "No items marked for deletion")
      (when (yes-or-no-p (format "Delete %d item(s) from %s? " (length marked-ids) fuji-rag-backend))
        (dolist (id marked-ids)
          ;; 1. Local Cleanup (Original, Extracted Results, and Session)
          (let ((metadata (fuji--get-metadata-for-id id)))
            (when metadata
              (let* ((raw-archived (or (cdr (assoc 'archived_path metadata))
                                       (cdr (assoc 'archived-path metadata))))
                     ;; Fix: Expand relative paths against cache directory
                     (archived (when raw-archived (expand-file-name raw-archived fuji-cache-directory)))
                     (raw-results (cdr (assoc 'results_dir metadata)))
                     (results (when raw-results (expand-file-name raw-results fuji-cache-directory)))
                     ;; Determine session file path
                     (session-file (fuji--get-session-file id)))
                
                ;; Delete archived file
                (when (and archived (file-exists-p archived))
                  (condition-case err
                      (progn
                        (delete-file archived)
                        (message "Fuji: Deleted archived file %s" archived))
                    (error (message "Fuji: Failed to delete archived file: %s" err))))
                
                ;; Delete results directory
                (when (and results (file-directory-p results))
                  (condition-case err
                      (progn
                        (delete-directory results t)
                        (message "Fuji: Deleted results directory %s" results))
                    (error (message "Fuji: Failed to delete results directory: %s" err))))
                
                ;; Delete session file
                (when (and session-file (file-exists-p session-file))
                  (condition-case err
                      (progn
                        (delete-file session-file)
                        (message "Fuji: Deleted session file %s" session-file))
                    (error (message "Fuji: Failed to delete session file: %s" err))))
                
                ;; Delete BibTeX entry (if linked)
                (let ((bib-key (cdr (assoc 'bib_key metadata))))
                  (when bib-key
                    (condition-case err
                        (fuji-remove-bibtex-entry bib-key)
                      (error (message "Fuji: Failed to delete BibTeX entry: %s" err))))))))
            
            ;; Remove from metadata cache
            (fuji--remove-metadata-entry id)
            
            ;; 2. Remote Deletion (Graphlit)
            (fuji--rag-delete id (lambda (success)
                                   (if success
                                       (message "Fuji: Deleted %s from RAG backend" id)
                                     (message "Fuji: Failed to delete %s from RAG backend" id)))))
        (message "Fuji: Deleting %d items..." (length marked-ids))
        ;; Refresh after a short delay to allow deletions to complete
        (run-with-timer 2 nil #'fuji-library-refresh)))))

(defun fuji-library-retry-ingestion ()
  "Retry Graphlit ingestion for a PENDING entry in the manager."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (unless id
      (error "No item under point"))
    (unless (string-prefix-p "PENDING-" id)
      (error "Can only retry ingestion for PENDING entries"))
    (fuji--execute-retry-ingestion id)
    (message "Fuji: Retry initiated for %s" id)))

(defun fuji-retry-current-ingestion ()
  "Retry Graphlit ingestion for the current fuji-mode session."
  (interactive)
  (unless (and (boundp 'fuji--content-id) fuji--content-id)
    (error "Not in an active Fuji session"))
  (unless (string-prefix-p "PENDING-" fuji--content-id)
    (error "Current session is not PENDING. Ingestion already completed or local"))
  (fuji--execute-retry-ingestion fuji--content-id)
  (save-excursion
    (goto-char (point-max))
    (insert "\n[i] 🔄 Manually retrying RAG ingestion...\n"))
  (message "Fuji: Retry initiated for current session"))

(defun fuji--execute-retry-ingestion (id)
  "Core logic to retry ingestion for PENDING ID."
  (let* ((metadata (fuji--get-metadata-for-id id))
         (results-dir-rel (alist-get 'results_dir metadata))
         (results-dir (when results-dir-rel (expand-file-name results-dir-rel fuji-cache-directory)))
         (md-file (when results-dir (expand-file-name "doc.md" results-dir)))
         (filename (or (alist-get 'filename metadata) "Unknown"))
         (archived-path-rel (alist-get 'archived_path metadata))
         (doc-file (if archived-path-rel 
                       (expand-file-name archived-path-rel fuji-cache-directory)
                     (alist-get 'original_path metadata)))
         (chat-buffer (get-buffer (format "*Fuji-%s*" filename))))
    
    (unless (and md-file (file-exists-p md-file))
      (error "Extracted markdown file not found for %s" id))
    
    (let ((md-content (with-temp-buffer
                        (insert-file-contents md-file)
                        (buffer-string))))
      (fuji--log "[RETRY] Starting async ingestion for %s..." filename)
      (fuji--rag-ingest
       md-content filename metadata
       (lambda (content-id)
         (fuji--log "[SUCCESS] Retry complete (ID: %s). Enabling RAG tools." content-id)
         ;; Swap Metadata
         (fuji--remove-metadata-entry id)
         (fuji--add-metadata-entry content-id filename doc-file results-dir)
         
         ;; Update Running Session if exists
         (let ((current-buf (or chat-buffer (get-buffer (format "*Fuji-%s*" filename)))))
           (when (buffer-live-p current-buf)
             (with-current-buffer current-buf
               (let ((inhibit-read-only t))
                 (setq-local fuji--content-id content-id)
                 (when (and (boundp 'gptel-tools) fuji-gptel-tool-graphlit)
                   (setq-local gptel-tools (list fuji-gptel-tool-graphlit))
                   (message "Fuji: RAG tools enabled for chat."))
                 (save-excursion
                   (goto-char (point-max))
                   (insert (format "\n[i] ✅ Ingestion successful! (ID: %s). RAG Enabled.\n" content-id)))))))
         
         ;; Refresh Library if open
         (let ((lib-buf (get-buffer "*Fuji-Library*")))
           (when (buffer-live-p lib-buf)
             (run-with-timer 0.5 nil (lambda ()
                                       (with-current-buffer lib-buf
                                         (fuji-library-refresh)))))))))))

(defun fuji-library-clear-all-pending ()
  "Clear all orphaned PENDING records from the metadata cache and file system."
  (interactive)
  (let* ((cache (fuji--load-metadata-cache))
         (pending-ids (cl-loop for entry in cache
                               for id = (format "%s" (car entry))
                               when (string-prefix-p "PENDING-" id)
                               collect id))
         (count 0))
    (if (null pending-ids)
        (message "Fuji: No PENDING records found to clear.")
      (when (y-or-n-p (format "Found %d PENDING records. Clear them all? " (length pending-ids)))
        (dolist (id pending-ids)
          (let* ((metadata (fuji--get-metadata-for-id id))
                 (results-dir-rel (alist-get 'results_dir metadata))
                 (archived-path-rel (alist-get 'archived_path metadata))
                 (filename (alist-get 'filename metadata)))
            
            ;; Clean results dir
            (when results-dir-rel
              (let ((dir (expand-file-name results-dir-rel fuji-cache-directory)))
                (when (file-directory-p dir)
                  (delete-directory dir t))))
                  
            ;; Clean archived file
            (when archived-path-rel
              (let ((file (expand-file-name archived-path-rel fuji-cache-directory)))
                (when (file-exists-p file)
                  (delete-file file))))
                  
            ;; Clean session file
            (when filename
              (let ((session-file (expand-file-name (concat filename ".session") fuji-chat-directory)))
                (when (file-exists-p session-file)
                  (delete-file session-file))))
                  
            ;; Remove metadata entry
            (fuji--remove-metadata-entry id)
            (cl-incf count)))
        (message "Fuji: Cleared %d PENDING records." count)
        (let ((lib-buf (get-buffer "*Fuji-Library*")))
          (when (buffer-live-p lib-buf)
            (with-current-buffer lib-buf
              (fuji-library-refresh))))))))

(defun fuji-library-fix-unknown-types ()
  "Fix existing metadata entries that have doc_type 'unknown'."
  (interactive)
  (let ((cache (fuji--load-metadata-cache))
        (fixed 0))
    (dolist (entry cache)
      (let* ((meta (cdr entry))
             (doc-type (cdr (assoc 'doc_type meta)))
             (file-path (or (alist-get 'original_path meta)
                            (alist-get 'filename meta))))
        (when (string= doc-type "unknown")
          (let ((ext (file-name-extension file-path)))
            (when ext
              (setcdr (assoc 'doc_type meta) (downcase ext))
              (cl-incf fixed))))))
    (when (> fixed 0)
      (fuji--save-metadata-cache cache)
      (let ((lib-buf (get-buffer "*Fuji-Library*")))
        (when (buffer-live-p lib-buf)
          (with-current-buffer lib-buf
            (fuji-library-refresh)))))
    (message "Fuji: Fixed %d unknown document types." fixed)))

;;; Prompt Management (Prompt Library)

(defun fuji-prompt-file-path ()
  "Get the path to the prompt library org file.
It resides in the user's digital library (the parent directory of the `originals` folder)."
  (let* ((orig-dir (fuji--get-originals-dir))
         ;; Use directory-file-name to strip trailing slashes before getting the directory
         (lib-dir (file-name-directory (directory-file-name orig-dir))))
    (expand-file-name "prompts.org" lib-dir)))

;;;###autoload
(defun fuji-prompt-add ()
  "Add a new prompt to the Prompt Library.
If there is an active region, use it as the prompt body.
Otherwise, open a temporary buffer to compose the prompt."
  (interactive)
  (let ((prompt-file (fuji-prompt-file-path))
        (region-text (when (use-region-p)
                       (buffer-substring-no-properties (region-beginning) (region-end)))))
    (if region-text
        (fuji--prompt-add-with-body region-text prompt-file)
      (let ((buf (get-buffer-create "*Fuji Prompt Compose*")))
        (with-current-buffer buf
          (erase-buffer)
          (if (fboundp 'org-mode) (org-mode) (text-mode))
          (local-set-key (kbd "C-c C-c")
                         (lambda ()
                           (interactive)
                           (let ((text (buffer-string)))
                             ;; Strip the instructional header
                             (when (string-match "\\`#.*\n#.*\n\n" text)
                               (setq text (substring text (match-end 0))))
                             (quit-window t)
                             (fuji--prompt-add-with-body (string-trim text) prompt-file))))
          (local-set-key (kbd "C-c C-k")
                         (lambda ()
                           (interactive)
                           (quit-window t)
                           (message "Fuji: Prompt addition cancelled.")))
          (insert "# Create your prompt here.\n# Press C-c C-c to save, C-c C-k to cancel.\n\n")
          (goto-char (point-max)))
        (pop-to-buffer buf)))))

(defun fuji--prompt-add-with-body (body prompt-file)
  "Prompt for title and tags, then append the BODY to PROMPT-FILE."
  (let* ((title (read-string "Prompt Title: "))
         (tags-str (read-string "Tags (comma or space separated, e.g. methodology summarize): "))
         (tags (split-string tags-str "[ ,]+" t))
         (tags-formatted (if tags (format ":%s:" (mapconcat #'identity tags ":")) "")))
    (with-current-buffer (find-file-noselect prompt-file)
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert (format "* %s %s\n%s\n" title tags-formatted body))
      (save-buffer)
      (message "Fuji: Prompt '%s' saved to %s" title prompt-file))))

;;;###autoload
(defun fuji-prompt-insert ()
  "Interactively select and insert a prompt from the prompt library."
  (interactive)
  (let ((prompt-file (fuji-prompt-file-path)))
    (unless (file-exists-p prompt-file)
      (error "Fuji: Prompt library not found at %s. Use `fuji-prompt-add` to create one." prompt-file))
    (let ((prompts '()))
      (with-temp-buffer
        (insert-file-contents prompt-file)
        (goto-char (point-min))
        ;; Parse elements: ^\* Title :tags:\nBody
        (while (re-search-forward "^\\* \\(.*?\\)\\(?:[ \t]+\\(:[a-zA-Z0-9_@:]+:\\)\\)?[ \t]*$" nil t)
          (let* ((title (match-string-no-properties 1))
                 (tags-match (match-string-no-properties 2))
                 (tags (when tags-match (replace-regexp-in-string "^:\\|:$" "" tags-match)))
                 (tags-list (when tags (split-string tags ":" t)))
                 (start (point))
                 (end (if (re-search-forward "^\\*" nil t)
                          (progn (goto-char (match-beginning 0)) (point))
                        (point-max)))
                 (body (string-trim (buffer-substring-no-properties start end))))
            (goto-char end)
            ;; Format for completion: [tag1, tag2] Title
            (let ((display (if tags-list
                               (format "[%s] %s" (mapconcat #'identity tags-list ", ") title)
                             title)))
              (push (cons display body) prompts)))))
      (if (null prompts)
          (message "Fuji: No prompts found in library.")
        (let* ((candidates (nreverse (mapcar #'car prompts)))
               (selection (completing-read "\\[Fuji\\] Insert Prompt: " candidates nil t))
               (body (cdr (assoc selection prompts))))
          (when body
            (insert body)))))))

;;;###autoload
(defun fuji-manage-content ()
  "Open the Graphlit content management interface."
  (interactive)
  (fuji--ensure-config)
  (let ((buf (get-buffer-create "*Fuji-Library*")))
    (with-current-buffer buf
      (fuji-library-mode)
      ;; Ensure MCP is connected if using Graphlit
      (when (and (eq fuji-rag-backend 'graphlit)
                 (not (fuji--get-mcp-connection)))
        (message "Fuji: Connecting to Graphlit MCP server...")
        (fuji--register-mcp-server))
      
      (if (fuji-verify-environment)
          (fuji-library-refresh)
        (message "Fuji: Environment check failed. Please run M-x fuji-configure.")))
    (switch-to-buffer buf)))

;;;; Compatibility Aliases (Deprecated, will be removed in v1.0)
;; These aliases maintain backward compatibility with the old nexus-paper naming.

;; Interactive commands
(defalias 'rx/gptel-ref-chat 'fuji-read
  "Deprecated: Use `fuji-read' instead. This alias will be removed in v1.0.")
(defalias 'nexus-paper-configure 'fuji-configure
  "Deprecated: Use `fuji-configure' instead. This alias will be removed in v1.0.")
(defalias 'nexus-paper-manage-content 'fuji-manager
  "Deprecated: Use `fuji-manager' instead. This alias will be removed in v1.0.")
(defalias 'rx/nexus-paper-set-model 'fuji-set-model
  "Deprecated: Use `fuji-set-model' instead. This alias will be removed in v1.0.")
(defalias 'rx/nexus-paper-add-context 'fuji-add-context
  "Deprecated: Use `fuji-add-context' instead. This alias will be removed in v1.0.")
(defalias 'rx/nexus-paper-manage-mcp 'fuji-manage-mcp
  "Deprecated: Use `fuji-manage-mcp' instead. This alias will be removed in v1.0.")
(defalias 'rx/nexus-paper-quit 'fuji-quit
  "Deprecated: Use `fuji-quit' instead. This alias will be removed in v1.0.")
(defalias 'nexus-paper-library-refresh 'fuji-refresh
  "Deprecated: Use `fuji-refresh' instead. This alias will be removed in v1.0.")
(defalias 'nexus-paper-library-delete-marked 'fuji-delete-marked
  "Deprecated: Use `fuji-delete-marked' instead. This alias will be removed in v1.0.")

;; Mark as obsolete
(make-obsolete 'rx/gptel-ref-chat 'fuji-read "0.6.0")
(make-obsolete 'nexus-paper-configure 'fuji-configure "0.6.0")
(make-obsolete 'nexus-paper-manage-content 'fuji-manager "0.6.0")
(make-obsolete 'rx/nexus-paper-set-model 'fuji-set-model "0.6.0")
(make-obsolete 'rx/nexus-paper-add-context 'fuji-add-context "0.6.0")
(make-obsolete 'rx/nexus-paper-manage-mcp 'fuji-manage-mcp "0.6.0")
(make-obsolete 'rx/nexus-paper-quit 'fuji-quit "0.6.0")
(make-obsolete 'nexus-paper-library-refresh 'fuji-refresh "0.6.0")
(make-obsolete 'nexus-paper-library-delete-marked 'fuji-delete-marked "0.6.0")



;;; Session-Specific Plugin Switching

(defun fuji-set-session-extractor (extractor-name)
  "Set extractor for current buffer/session only.
EXTRACTOR-NAME should be a registered extractor or empty to clear override."
  (interactive
   (list (completing-read "Session extractor (empty to clear): "
                          (cons "clear" (fuji-list-extractors))
                          nil t)))
  (if (or (string-empty-p extractor-name) (string= extractor-name "clear"))
      (progn
        (setq-local fuji--session-extractor nil)
        (message "Fuji: Session extractor override cleared"))
    (setq-local fuji--session-extractor extractor-name)
    (message "Fuji: Session extractor set to '%s'" extractor-name)))

(defun fuji-set-session-rag-backend (backend-name)
  "Set RAG backend for current buffer/session only.
BACKEND-NAME should be a registered backend or empty to clear override."
  (interactive
   (list (completing-read "Session RAG backend (empty to clear): "
                          (cons "clear" (fuji-list-rag-backends))
                          nil t)))
  (if (or (string-empty-p backend-name) (string= backend-name "clear"))
      (progn
        (setq-local fuji--session-rag-backend nil)
        (message "Fuji: Session RAG backend override cleared"))
    (setq-local fuji--session-rag-backend backend-name)
    (message "Fuji: Session RAG backend set to '%s'" backend-name)))

(defun fuji--extract-pdf-text (pdf-file output-dir callback)
  "Extract PDF-FILE text using pdftotext (plugin wrapper).
Calls CALLBACK with the resulting markdown file."
  (let ((md-file (fuji--pdftotext-extract pdf-file output-dir)))
    (if md-file
        (funcall callback md-file)
      (error "pdftotext extraction failed"))))

(defun fuji--extract-binary-pandoc (doc-file output-dir callback)
  "Extract DOC-FILE using Pandoc (plugin wrapper).
Calls CALLBACK with the resulting markdown file."
  (let ((md-file (fuji--pandoc-extract doc-file output-dir)))
    (if md-file
        (funcall callback md-file)
      (error "Pandoc extraction failed"))))



;;;###autoload
(defun fuji-read (&optional file-path)
  "Start reading and chatting with a research document.

Supported formats: PDF, DOCX, EPUB, HTML

This is the main entry point for Fuji. It will:
1. Let you select a document file
2. Extract text using appropriate tool (Marker for PDF, Pandoc for others)
3. Upload to RAG backend for semantic search
4. Open a chat interface

Choose extraction method:
- High Quality: Use LLM-based tool (marker) for better accuracy with figure support (PDF only)
- Fast: Use pdftotext (PDF) or pandoc (DOCX/EPUB/HTML) for quick extraction
- Offline: Load pre-extracted markdown from a directory"
  (interactive)
  (fuji--ensure-config)
  (unless (fuji-verify-environment)
    (error "Fuji: Environment not ready. Run M-x fuji-configure"))
  
  (let* ((raw-input (or file-path (fuji--select-document)))
         ;; If input is a URL, convert it to PDF first (in temp dir)
         (initial-doc-file (if (string-match-p "^https?://" raw-input)
                               (progn
                                 (message "Fuji: Web URL detected. Converting to PDF...")
                                 (fuji--web-to-pdf raw-input temporary-file-directory))
                             raw-input))
         
         ;; ENFORCE LIBRARY POLICY:
         ;; If file is NOT in library, prompt to import.
         (doc-info 
          (if (fuji--is-path-in-library-p initial-doc-file)
              (cons initial-doc-file (file-name-nondirectory initial-doc-file))
            ;; Not in library: Prompt
            (if (y-or-n-p (format "File '%s' is not in Fuji library. Import it? " 
                                  (file-name-nondirectory initial-doc-file)))
                (let ((archived (fuji--archive-file initial-doc-file)))
                  (unless archived (error "Failed to import file to library"))
                  ;; Return (archived-path . original-filename)
                  (cons archived (file-name-nondirectory initial-doc-file)))
              (user-error "Aborted: Fuji only operates on library files."))))
         
         (doc-file (car doc-info))
         (display-filename (cdr doc-info))

         ;; HASH CHECK: Check if file already exists in library
         (file-hash (when (file-exists-p doc-file) (secure-hash 'sha256 doc-file)))
         (existing-entry (when file-hash
                           (cl-find-if (lambda (entry) 
                                         (string= (cdr (assoc 'file_hash (cdr entry))) file-hash))
                                       (fuji--load-metadata-cache)))))
    
    (if (and existing-entry (y-or-n-p (format "File already in library (ID: %s). Resume session? " 
                                              (car existing-entry))))
        ;; RESUME EXISTING SESSION
        (fuji--load-session (car existing-entry))
      
      ;; START NEW SESSION
      (let* ((is-plain-text (fuji--is-plain-text-file doc-file))
             (doc-type (if is-plain-text
                           "text"
                         (cond
                          ((string-match-p "\\.pdf$" doc-file) "pdf")
                          ((string-match-p "\\.docx$" doc-file) "docx")
                          ((string-match-p "\\.doc$" doc-file) "doc")
                          ((string-match-p "\\.xlsx?$" doc-file) "xlsx")
                          ((string-match-p "\\.pptx?$" doc-file) "pptx")
                          ((string-match-p "\\.epub$" doc-file) "epub")
                          ((string-match-p "\\.html?$" doc-file) "html")
                          (t "binary"))))
             (llm-tool (or fuji-llm-extraction-tool "marker"))
             (mode-map (cond
                        ((string= doc-type "text")
                         '(("Direct (no extraction needed)" . direct)))
                        ((string= doc-type "pdf")
                         `((,(format "High Quality (%s) - Better accuracy, supports figures" 
                                     (capitalize llm-tool)) . llm)
                           ("Fast (pdftotext) - Quick text-only extraction" . fast)
                           ("Offline - Use pre-extracted markdown" . offline)))
                        ((member doc-type '("docx" "epub" "html"))
                         `(("Extract with Pandoc" . fast)
                           ("Offline - Use pre-extracted markdown" . offline)))
                        ((string= doc-type "doc")
                         (user-error "Legacy .doc format is not supported. Please convert to .docx or PDF and try again."))
                        ((member doc-type '("xlsx" "pptx"))
                         (user-error "Spreadsheets/Slides are not supported directly. Please convert to .docx or PDF and try again."))
                        (t
                         (error "Unsupported file type: %s" doc-file))))
             (mode-label (completing-read "Extraction method: " (mapcar #'car mode-map) nil t))
             (mode (cdr (assoc mode-label mode-map)))
             (filename display-filename) ;; Use preserved display name (from original)
             (results-dir (fuji--get-cache-path doc-file))
             (doc-buffer (cond
                          ((or (string= doc-type "pdf") (string= doc-type "text"))
                           (find-file-noselect doc-file))
                          (t
                           (let ((buf (get-buffer-create (format "*Fuji View: %s*" filename))))
                             (with-current-buffer buf
                               (let ((inhibit-read-only t))
                                 (view-mode 0)
                                 (erase-buffer)
                                 (insert (format "Extracting content from %s...\n\nPreview will appear here shortly." filename))
                                 (view-mode 1)))
                             buf))))
             (chat-buffer (get-buffer-create (format "*Fuji-Chat: %s*" filename))))

        ;; Initial UI Setup (2-Window)
        (with-current-buffer chat-buffer
          (let ((inhibit-read-only t))
            (set-buffer-multibyte t)
            (erase-buffer)
            (org-mode)
            (insert "#+TITLE: Chat Session: " filename "\n\n")
            (insert "* Fuji System Log\n:PROPERTIES:\n:Created: " (format-time-string "[%Y-%m-%d %H:%M]") "\n:END:\n")
            (insert ":LOGBOOK:\n")
            (insert "- [ ] Workflow started for " doc-type " document in mode: " (format "%s" mode) "\n")
            (insert "- [ ] Waiting for document ingestion...\n")
            (insert ":END:\n\n")
            (insert "* Discussion\n")
            (insert "** ")))
        
        (fuji--setup-2-buffer-layout doc-buffer chat-buffer)
        (fuji--log "Workflow started for %s document in mode: %s" doc-type mode)

        ;; Define Callback Logic
        (let ((extraction-callback
               (lambda (md-file)
                 ;; Update doc buffer for binary files
                 (unless (or (string= doc-type "pdf") (string= doc-type "text"))
                   (with-current-buffer doc-buffer
                     (let ((inhibit-read-only t))
                       (view-mode 0)
                       (erase-buffer)
                       (insert-file-contents md-file)
                       (markdown-mode)
                       (view-mode 1))))
                 
                 (let* ((md-content (with-temp-buffer
                                      (insert-file-contents md-file)
                                      (buffer-string)))
                        (metadata `((filename . ,filename)
                                    (pdf-path . ,doc-file)
                                    (results-dir . ,results-dir))))
                   
                   ;; 1. Initialize Chat UI immediately (show PENDING status)
                   (with-current-buffer chat-buffer
                     (let ((inhibit-read-only t)
                           (temp-id (format "PENDING-%s" (secure-hash 'md5 filename))))
                       
                       ;; Register Pending Metadata
                       (fuji--add-metadata-entry temp-id filename doc-file results-dir)

                       ;; Basic Setup
                       (setq-local fuji--content-id temp-id)
                       (setq-local fuji--filename filename)
                       (setq-local fuji--results-dir results-dir)
                       (setq-local fuji--pdf-buffer doc-buffer)

                       ;; Context Injection (Local Markdown)
                       (let* ((local-md-file (expand-file-name (concat (file-name-base doc-file) ".md")
                                                               fuji--results-dir)))
                         (with-temp-file local-md-file
                           (insert md-content))
                         (when (fboundp 'gptel-add-file)
                           (let ((inhibit-message t))
                             (gptel-add-file local-md-file))))

                       ;; GPTel Configuration
                       (when fuji-gptel-backend
                         (let ((be (gptel-get-backend fuji-gptel-backend)))
                           (when be (setq-local gptel-backend be))))
                       (when fuji-gptel-model
                         (setq-local gptel-model (if (stringp fuji-gptel-model)
                                                     (intern fuji-gptel-model)
                                                   fuji-gptel-model)))

                       ;; Directives
                       (setq-local gptel-directives 
                                   (cons '(fuji . "You are an academic assistant. Answer questions based on the provided document context. If you need more info from the paper using semantic search, use the 'query_graphlit' tool.")
                                         gptel-directives))
                       (setq-local gptel-default-directive 'fuji)

                       ;; Initialize Mode and UI
                       (insert "* Session Started\n")
                       (if (fboundp 'gptel-mode) (gptel-mode 1))
                       (fuji-mode 1)
                       
                       ;; Ensure hook is locally set for standard responses
                       (add-hook 'gptel-post-response-functions #'fuji--gptel-response-handler nil t)
                       
                       ;; Ensure prompt prefix is set effectively
                       (setq-local gptel-prompt-prefix-alist '((org-mode . "** ") (default . "** ")))
                       
                       ;; Hooks
                       (add-hook 'kill-buffer-hook #'fuji-save-session nil t)
                       (add-hook 'kill-buffer-hook #'fuji--cleanup-session nil t)
                       
                       ;; Add Ingestion Log safely
                       (save-excursion
                         (goto-char (point-min))
                         (if (re-search-forward ":END:" nil t)
                             (progn
                               (backward-char 5) ;; Move before :END:
                               (insert "- [ ] Ingesting to RAG backend (Async)... (ID: " temp-id ")\n"))
                           ;; Fallback if drawer is somehow missing (unlikely)
                           (goto-char (point-max))
                           (insert "\n- [ ] Ingesting to RAG backend (Async)... (ID: " temp-id ")\n")))
                   
                   ;; Ensure Chat is Visible
                   (pop-to-buffer chat-buffer)

                   (let ((text-size (string-bytes md-content)))
                     (if (> text-size 102400) ;; 100KB threshold
                         ;; Case A: Large File -> Local Only
                         (let ((local-id (format "LOCAL-%s" (secure-hash 'md5 filename))))
                           (fuji--log "[INFO] File too large for RAG (%d bytes). Using Local Mode." text-size)
                           
                           ;; Register Local Metadata
                           (fuji--remove-metadata-entry temp-id)
                           (fuji--add-metadata-entry local-id filename doc-file results-dir)
                           
                           ;; Update Chat Session
                           (with-current-buffer chat-buffer
                             (let ((inhibit-read-only t))
                               (setq-local fuji--content-id local-id)
                               (setq-local gptel-tools nil) ;; Disable RAG
                               
                               ;; Update Log
                               (save-excursion
                                 (goto-char (point-min))
                                 (when (re-search-forward "- \\[ \\] Ingesting to RAG backend (Async)..." nil t)
                                   (replace-match (format "- [X] Large file (>100KB). Indexed Locally Only (ID: %s)." local-id)))))))

                       ;; Case B: Small File -> Graphlit Ingestion
                       (progn
                         (fuji--log "[STEP 3/3] Starting async ingestion for %s..." filename)
                         (fuji--rag-ingest
                          md-content filename metadata
                          (lambda (content-id)
                            (fuji--log "[SUCCESS] Ingestion complete (ID: %s). Enabling RAG tools." content-id)
                            
                            ;; Swap Metadata: Remove PENDING, Add Real
                            (fuji--remove-metadata-entry temp-id)
                            (fuji--add-metadata-entry content-id filename doc-file results-dir)
                            
                            ;; Update Running Session
                            (when (buffer-live-p chat-buffer)
                              (with-current-buffer chat-buffer
                                (let ((inhibit-read-only t))
                                  ;; Update ID
                                  (setq-local fuji--content-id content-id)
                                  
                                  ;; Enable RAG Tools
                                  (when (and (boundp 'gptel-tools) fuji-gptel-tool-graphlit)
                                    (setq-local gptel-tools (list fuji-gptel-tool-graphlit))
                                    (message "Fuji: RAG tools enabled for chat."))
                                  
                                  ;; Update Log in Buffer
                                  (save-excursion
                                    (goto-char (point-min))
                                    (when (re-search-forward "- \\[ \\] Ingesting to RAG backend (Async)..." nil t)
                                      (replace-match (format "- [X] Ingestion complete using Graphlit (ID: %s)." content-id))))
                                  (goto-char (point-max))))))))))))))))

          ;; Execute Workflow
          (pcase mode
            ('direct
             (if (string= doc-type "text")
                 (funcall extraction-callback doc-file)
               (funcall extraction-callback doc-file)))
            ('offline
             (let ((local-dir (read-directory-name "Select directory with pre-extracted results: " nil nil t)))
               (fuji--log "[STEP 1/3] Loading pre-extracted results from: %s" local-dir)
               (fuji--use-local-marker-result local-dir results-dir)
               (let ((md-file (fuji--find-marker-output results-dir)))
                 (if md-file
                     (progn
                       (fuji--log "[STEP 2/3] Pre-extracted results loaded. Ingesting content...")
                       (funcall extraction-callback md-file))
                   (error "Fuji: No .md file found in the selected directory!")))))
            ('llm
             (let ((extractor (fuji-get-extractor llm-tool)))
               (unless extractor
                 (error "Extractor '%s' not found. Please run M-x fuji-configure" llm-tool))
               (funcall (fuji-extractor-extract-fn extractor)
                        doc-file results-dir
                        (lambda (md-file)
                          (fuji--log "[STEP 2/3] Extraction finished. Ingesting content...")
                          (funcall extraction-callback md-file)))))
            ('fast
             (if (string= doc-type "pdf")
                 (fuji--extract-pdf-text doc-file results-dir extraction-callback)
               (fuji--extract-binary-pandoc doc-file results-dir extraction-callback)))))))))




(defun fuji--refresh-chat-metadata ()
  "Refresh the * Paper Metadata drawer in the current chat buffer."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (let ((inhibit-read-only t)
          (key (when (re-search-forward "^#\\+FUJI_BIB_KEY: \\(.*\\)$" nil t)
                 (match-string 1))))
      
      ;; 1. Remove ALL existing metadata drawers (Deduplication)
      ;; Use org-mode APIs if possible, or robust regex
      (save-excursion
        (goto-char (point-min))
        ;; Unfold everything first to ensure regex matches hidden text
        (ignore-errors (org-show-all))
        (while (re-search-forward "^\\*+ Paper Metadata" nil t)
          (let ((beg (match-beginning 0))
                (end (save-excursion 
                       (forward-line 1)
                       ;; Search for next heading at same level or higher
                       (if (re-search-forward "^\\* " nil t)
                           (match-beginning 0)
                         (point-max)))))
            (delete-region beg end))))
      
      ;; 2. Re-insert if we have a key
      (when key
        ;; Fetch entry
        (let* ((entry (or (and (fboundp 'bibtex-completion-get-entry)     
                               (let ((bibtex-completion-bibliography (list fuji-bibtex-file)))
                                 (bibtex-completion-get-entry key)))
                          (fuji-get-bibtex-entry-direct key))))
          (when entry
            (goto-char (point-min))
            ;; Find insertion point (after properties or before first headline)
            (if (re-search-forward "^\\* " nil t)
                (beginning-of-line)
              (goto-char (point-max)))
            
            (insert "* Paper Metadata\n:PROPERTIES:\n:VISIBILITY: children\n:END:\n")
            (insert (format "** %s\n" (or (cdr (assoc "title" entry)) "Untitled")))
            (insert (format "- *Authors*: %s\n" (or (cdr (assoc "author" entry)) "Unknown")))
            (insert (format "- *Year*: %s\n" (or (cdr (assoc "year" entry)) "N/A")))
            (insert (format "- *Journal*: %s\n" (or (cdr (assoc "journal" entry)) 
                                                    (cdr (assoc "booktitle" entry)) "N/A")))
            (insert (format "- *DOI*: [[https://doi.org/%s][%s]]\n" 
                            (or (cdr (assoc "doi" entry)) "") 
                            (or (cdr (assoc "doi" entry)) "Link")))
            (insert "\n")
            (message "Fuji: Metadata refresh complete for key '%s'" key)))))))

(defun fuji--after-add-bibtex-entry-wrapper (key &rest args)
  "Advice to link KEY to the current session after `fuji-add-bibtex-entry-from-doi`.
This ensures that when a user adds a specific DOI while reading a paper,
the session is permanently linked to that new BibTeX entry."
  ;; Check if we are in a Fuji session (fuji--content-id is bound)
  (when (and key (bound-and-true-p fuji--content-id))
    (message "Fuji: Automatically linking session to new BibTeX Key: %s" key)
    (fuji--set-bib-key-in-session key)
    (fuji--refresh-chat-metadata))
  key)

(advice-add 'fuji-add-bibtex-entry-from-doi :filter-return #'fuji--after-add-bibtex-entry-wrapper)

(provide 'fuji)
(require 'fuji-search)

;;; fuji.el ends here
