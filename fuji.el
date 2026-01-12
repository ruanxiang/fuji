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

(defcustom fuji-bib-path nil
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

(defun fuji--setup-3-buffer-layout (pdf-buffer chat-buffer progress-buffer)
  "Arrange windows: PDF and Chat side-by-side, Progress at the bottom (minibuffer-like)."
  (delete-other-windows)
  (let* ((prog-win (split-window-below -5))) ;; Create a 5-line window at the bottom
    (set-window-buffer prog-win progress-buffer)
    (set-window-dedicated-p prog-win t) ;; Make it dedicated
    (let ((chat-win (split-window-horizontally)))
      (set-window-buffer (selected-window) pdf-buffer)
      (set-window-buffer chat-win chat-buffer))))

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
        (if (and fuji-bib-path (file-directory-p fuji-bib-path))
            (insert (format "   [OK] Bib Directory: %s\n" fuji-bib-path))
          (insert (format "   [FAIL] Bib Directory NOT FOUND: %s\n" fuji-bib-path)))

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
               fuji-bib-path
               (file-directory-p fuji-bib-path)
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
        (unless fuji-bib-path
          (error "Bibliography path not configured. Please run M-x fuji-configure"))
        (unless (file-directory-p fuji-bib-path)
          (error "Bibliography directory not found: %s" fuji-bib-path))

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
          ;; Check if buffer contains only printable characters
          (goto-char (point-min))
          (not (re-search-forward "[^[:print:]\n\r\t]" nil t)))
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
   (t
    (let ((file (read-file-name "Select document (or URL): " 
                                (or fuji-bib-path default-directory) nil nil))) ;; nil = allow non-matching input (URLs)
      (if (string-match-p "^https?://" (file-name-nondirectory file))
          (file-name-nondirectory file) ;; It's a URL, return it as-is (basename)
        (expand-file-name (substitute-in-file-name (expand-file-name file))))))))

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
(defun rx/fuji-quit ()
  "Unified command to quit the current Fuji session.
Prompts for content deletion and kills related buffers."
  (interactive)
  (let ((chat-buf (current-buffer))
        (pdf-buf fuji--pdf-buffer)
        (prog-buf fuji--prog-buffer))
    (unless (and fuji--filename (string-match-p "\\*Fuji-Chat:" (buffer-name chat-buf)))
      (user-error "Fuji: Not in a Fuji-Chat buffer"))
    
    ;; 1. Run cleanup (asks about Graphlit deletion)
    (fuji--cleanup-session)
    
    ;; 2. Remove the hook to prevent duplicate cleanup when killing buffer
    (remove-hook 'kill-buffer-hook #'fuji--cleanup-session t)
    
    ;; 3. Kill buffers
    (when (buffer-live-p pdf-buf) (kill-buffer pdf-buf))
    (when (buffer-live-p prog-buf) (kill-buffer prog-buf))
    (kill-buffer chat-buf)
    
    (message "Fuji: Session ended and buffers cleaned up.")))

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
         (content-id fuji--content-id))
    (unless content-id
      (error "Fuji: Content ID not found in current buffer"))
    (let ((result (mcp-call-tool conn "promptConversation"
                                 `((prompt . ,query)
                                   (contentIds . [,content-id])))))
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

(defvar fuji-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c n m") #'rx/fuji-set-model)
    (define-key map (kbd "C-c n a") #'rx/fuji-add-context)
    (define-key map (kbd "C-c n s") #'rx/fuji-manage-mcp)
    (define-key map (kbd "C-c n q") #'rx/fuji-quit)
    map)
  "Keymap for `fuji-mode'.")

(define-minor-mode fuji-mode
  "Minor mode for Fuji chat buffers."
  :lighter " Nexus"
  :keymap fuji-mode-map)

(defun rx/fuji-set-model ()
  "Interactively set the gptel model and backend for the current Nexus session."
  (interactive)
  (let* ((backends gptel--known-backends)
         (backend-name (completing-read "Select Backend: " 
                                        (mapcar (lambda (b) (gptel-backend-name (cdr b))) 
                                                backends)))
         (backend (gptel-get-backend backend-name))
         (model (completing-read "Select Model: " (gptel-backend-models backend))))
    (setq-local gptel-backend backend)
    (setq-local gptel-model model)
    (fuji--log "Model updated to %s (%s)" model backend-name)
    (message "Fuji: Model set to %s" model)))

(defun rx/fuji-add-context ()
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

(defun rx/fuji-manage-mcp ()
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

(defvar fuji-library-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") 'fuji-library-refresh)
    (define-key map (kbd "d") 'fuji-library-mark-delete)
    (define-key map (kbd "u") 'fuji-library-unmark)
    (define-key map (kbd "U") 'fuji-library-unmark-all)
    (define-key map (kbd "x") 'fuji-library-execute)
    (define-key map (kbd "RET") 'fuji-library-view-details)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `fuji-library-mode'.")

(define-derived-mode fuji-library-mode tabulated-list-mode "Fuji-Library"
  "Major mode for managing Graphlit content.
\\{fuji-library-mode-map}"
  (setq tabulated-list-format
        [("Title" 40 t)
         ("ID" 12 nil)
         ("Date" 12 t)
         ("Size" 10 t)
         ("Type" 20 t)])
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
         (archived-path (cdr (assoc 'archived_path metadata)))
         (results-dir (cdr (assoc 'results_dir metadata))))
    (cond
     ;; Original file exists
     ((and original-path (file-exists-p original-path))
      (cons original-path 'original))
     ;; Archived file exists
     ((and archived-path (file-exists-p archived-path))
      (fuji--log "Original file not found, using archived copy")
      (cons archived-path 'archived))
     ;; Fallback to markdown
     ((and results-dir (file-directory-p results-dir))
      (let ((md-file (fuji--find-marker-output results-dir)))
        (when md-file
          (fuji--log "Original and archived files not found, opening extracted markdown (read-only)")
          (cons md-file 'markdown))))
     ;; Nothing found
     (t
      (error "Cannot locate file for content ID: %s" content-id)))))


(defun fuji--add-metadata-entry (content-id filename file-path &optional results-dir)
  "Add metadata entry for CONTENT-ID with FILENAME and FILE-PATH.
Automatically archives the original file and tracks document type.
If RESULTS-DIR is provided, it is stored to allow deleting extracted content later."
  (let* ((cache (or (fuji--load-metadata-cache) '()))
         (id-key (if (stringp content-id) (intern content-id) content-id))
         (file-size (and (file-exists-p file-path) 
                         (file-attribute-size (file-attributes file-path))))
         ;; Determine document type from extension
         (doc-type (cond
                    ((string-match-p "\\.pdf$" file-path) "pdf")
                    ((string-match-p "\\.docx?$" file-path) "docx")
                    ((string-match-p "\\.epub$" file-path) "epub")
                    ((string-match-p "\\.html?$" file-path) "html")
                    (t "unknown")))
         ;; Archive the original file
         (archived-path (fuji--archive-file file-path))
         (metadata `((filename . ,filename)
                     (upload_date . ,(format-time-string "%Y-%m-%dT%H:%M:%S"))
                     (file_size . ,(or file-size 0))
                     (original_path . ,file-path)
                     (archived_path . ,archived-path)
                     (results_dir . ,results-dir)   ; NEW: Track results directory
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

(defun fuji-library-refresh ()
  "Refresh the content list from the active RAG backend."
  (interactive)
  (message "Fuji: Querying %s..." fuji-rag-backend)
  ;; Use unified RAG API instead of Graphlit-specific call
  (fuji--rag-list
   (lambda (contents)
     (setq fuji--content-list contents)
     (let ((buf (get-buffer "*Fuji-Library*")))
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (fuji-library--populate-buffer))))
     (message "Fuji: Refreshed (%d items)" (length contents)))))


(defun fuji-library--populate-buffer ()
  "Populate the library buffer with content list."
  (let ((entries
         (mapcar
          (lambda (item)
            (let* ((id (cdr (assoc 'id item)))
                   (metadata (fuji--get-metadata-for-id id))
                   ;; Use cached metadata if available
                   (name (if metadata
                             (cdr (assoc 'filename metadata))
                           (format "Content %s" (substring id 0 8))))
                   (date (if metadata
                             (let ((upload-date (cdr (assoc 'upload_date metadata))))
                               (if (stringp upload-date)
                                   (substring upload-date 0 10)  ; Extract YYYY-MM-DD
                                 ("N/A")))
                           "N/A"))
                   (size (if metadata
                             (fuji--format-file-size (cdr (assoc 'file_size metadata)))
                           "N/A"))
                   (mime (or (cdr (assoc 'mimeType item)) "unknown"))
                   (id-short (substring id 0 (min 8 (length id)))))
              (list id (vector name id-short date size mime))))
          fuji--content-list)))
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
        ;; Use unified RAG API instead of Graphlit-specific call
        (dolist (id marked-ids)
          ;; 1. Local Cleanup (Original and Extracted Results)
          (let ((metadata (fuji--get-metadata-for-id id)))
            (when metadata
              (let ((archived (cdr (assoc 'archived_path metadata)))
                    (results (cdr (assoc 'results_dir metadata))))
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
                    (error (message "Fuji: Failed to delete results directory: %s" err))))))
            ;; Remove from metadata cache
            (fuji--remove-metadata-entry id))
          
          ;; 2. Remote Deletion (Graphlit)
          (fuji--rag-delete id (lambda (success)
                                 (if success
                                     (message "Fuji: Deleted %s from RAG backend" id)
                                   (message "Fuji: Failed to delete %s from RAG backend" id)))))
        (message "Fuji: Deleting %d items..." (length marked-ids))
        ;; Refresh after a short delay to allow deletions to complete
        (run-with-timer 2 nil #'fuji-library-refresh)))))

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

;;;###autoload
(defun fuji-manage-content ()
  "Open the Graphlit content management interface."
  (interactive)
  (let ((buf (get-buffer-create "*Fuji-Library*")))
    (with-current-buffer buf
      (fuji-library-mode)
      (fuji-library-refresh))
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

;;; WORKAROUND: fuji--query-all-contents definition
;; This function fails to load from its original location (line ~1182)
;; Adding it here at the end of the file as a workaround
(defun fuji--query-all-contents (callback)
  "Query all content from Graphlit via MCP and call CALLBACK with results."
  (let ((conn (fuji--get-mcp-connection)))
    (when conn
      (condition-case outer-err
          (mcp-async-call-tool conn "queryContents"
                               '()  ; No arguments needed for listing all
                               (lambda (result)
                                 ;; queryContents returns multiple text items, each is a separate content object
                                 (let* ((content-array (plist-get result :content))
                                        (contents
                                         (when (vectorp content-array)
                                           (cl-loop for item across content-array
                                                    for text = (plist-get item :text)
                                                    when (and text (stringp text))
                                                    collect (condition-case nil
                                                                (let ((json-object-type 'alist))
                                                                  (json-read-from-string text))
                                                              (error nil))))))
                                   (if contents
                                       (funcall callback contents)
                                     (message "Fuji: No content found in Graphlit")
                                     (funcall callback nil))))
                               (lambda (inner-err)
                                 (message "Fuji: Failed to query contents: %s" 
                                          (error-message-string inner-err))
                                 (funcall callback nil)))
        (error
         (message "Fuji: Query error: %s" (error-message-string outer-err))
         (funcall callback nil))))))

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

(provide 'fuji)

;;;###autoload
(defun fuji-read ()
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
  
  (let* ((raw-input (fuji--select-document))
         ;; If input is a URL, convert it to PDF first
         (doc-file (if (string-match-p "^https?://" raw-input)
                       (progn
                         (message "Fuji: Web URL detected. Converting to PDF...")
                         (fuji--web-to-pdf raw-input (fuji--get-originals-dir)))
                     raw-input))
         ;; Determine document type: check if plain text first, then by extension
         (is-plain-text (fuji--is-plain-text-file doc-file))
         (doc-type (if is-plain-text
                       "text"
                     (cond
                      ((string-match-p "\\.pdf$" doc-file) "pdf")
                      ((string-match-p "\\.docx?$" doc-file) "docx")
                      ((string-match-p "\\.epub$" doc-file) "epub")
                      ((string-match-p "\\.html?$" doc-file) "html")
                      (t "binary"))))
         ;; Use configured LLM tool name from Phase 1 configuration
         (llm-tool (or fuji-llm-extraction-tool "marker"))
         ;; Adjust extraction methods based on document type
         (mode-map (cond
                    ;; Plain text files: no extraction needed
                    ((string= doc-type "text")
                     '(("Direct (no extraction needed)" . direct)))
                    ;; PDF: offer high quality or fast extraction
                    ((string= doc-type "pdf")
                     `((,(format "High Quality (%s) - Better accuracy, supports figures" 
                                 (capitalize llm-tool)) . llm)
                       ("Fast (pdftotext) - Quick text-only extraction" . fast)
                       ("Offline - Use pre-extracted markdown" . offline)))
                    ;; Other binary formats: use Pandoc
                    ((member doc-type '("docx" "epub" "html"))
                     `(("Extract with Pandoc" . fast)
                       ("Offline - Use pre-extracted markdown" . offline)))
                    ;; Unknown binary format
                    (t
                     (error "Unsupported file type: %s (not plain text and no known extractor)" doc-file))))
         (mode-label (completing-read "Extraction method: " (mapcar #'car mode-map) nil t))
         (mode (cdr (assoc mode-label mode-map)))
         (filename (file-name-nondirectory doc-file))
         (results-dir (fuji--get-cache-path doc-file))
         (doc-buffer (find-file-noselect doc-file))
         (chat-buffer (get-buffer-create (format "*Fuji-Chat: %s*" filename)))
         (prog-buffer (get-buffer-create fuji-progress-buffer)))

    ;; Initial UI Setup
    (with-current-buffer prog-buffer
      (let ((inhibit-read-only t))
        (set-buffer-multibyte t)
        (erase-buffer)
        (insert "Fuji Progress: " filename "\n" (make-string 40 ?-) "\n\n")
        (setq-local cursor-type nil)
        (view-mode 1)))
    
    (with-current-buffer chat-buffer
      (let ((inhibit-read-only t))
        (set-buffer-multibyte t)
        (erase-buffer)
        (insert "# Waiting for document ingestion...\n\n")
        (insert "Progress is being tracked in the right buffer.")))

    (fuji--setup-3-buffer-layout doc-buffer chat-buffer prog-buffer)
    (fuji--log "Workflow started for %s document in mode: %s" doc-type mode)

    (let ((extraction-callback
           (lambda (md-file)
             (let* ((md-content (with-temp-buffer
                                  (insert-file-contents md-file)
                                  (buffer-string)))
                    ;; Save metadata for library manager
                    (metadata `((filename . ,filename)
                                (pdf-path . ,doc-file)
                                (results-dir . ,results-dir))))
               (fuji--rag-ingest
                md-content filename metadata
                (lambda (content-id)
                  (fuji--log "[STEP 3/3] Ingestion complete (ID: %s). Finalizing chat..." content-id)
                  ;; Archive the original file and save metadata
                  (fuji--add-metadata-entry content-id filename doc-file results-dir)
                  (with-current-buffer chat-buffer
                    (let ((inhibit-read-only t)) 
                      (set-buffer-multibyte t)
                      (erase-buffer)
                      (org-mode)
                      
                      (setq-local fuji--content-id content-id)
                      (setq-local fuji--filename filename)
                      (setq-local fuji--results-dir results-dir)
                      (setq-local fuji--pdf-buffer doc-buffer)
                      (setq-local fuji--prog-buffer prog-buffer)
                      
                      ;; Hybrid mode only (proxy mode disabled)
                      (let* ((md-file (expand-file-name (concat (file-name-base doc-file) ".md")
                                                        fuji--results-dir)))
                        (with-temp-file md-file
                          (insert md-content))
                        ;; Add the extracted MD file as context silently
                        (when (fboundp 'gptel-add-file)
                          (let ((inhibit-message t))
                            (gptel-add-file md-file))))
                      
                      ;; Apply configured Backend & Model
                      (when fuji-gptel-backend
                        (let ((be (gptel-get-backend fuji-gptel-backend)))
                          (when be (setq-local gptel-backend be))))
                      (when fuji-gptel-model
                        (setq-local gptel-model fuji-gptel-model))

                      ;; Configure system directive
                      (setq-local gptel-directives 
                                  (cons '(fuji . "You are an academic assistant. Answer questions based on the provided document context. If you need more info from the paper using semantic search, use the 'query_graphlit' tool.")
                                        gptel-directives))
                      (setq-local gptel-default-directive 'fuji)
                      
                      ;; Register Graphlit as a gptel tool if available
                      (when (and (boundp 'gptel-tools) fuji-gptel-tool-graphlit)
                        (setq-local gptel-tools (list fuji-gptel-tool-graphlit)))
                      
                      (insert "\n* ") ;; Initial user prompt
                      (gptel-mode)
                      (fuji-mode 1)
                      (fuji--setup-buffer-header filename content-id)
                      (add-hook 'kill-buffer-hook #'fuji--cleanup-session nil t)
                      (fuji--log "[SUCCESS] Chat initialization complete. Ready!")
                      (goto-char (point-max))
                      ;; Auto-focus the chat window
                      (when-let* ((win (get-buffer-window chat-buffer)))
                        (select-window win))))))))))

      (pcase mode
        ('direct
         (fuji--log "[STEP 1/3] Reading plain text file directly (no extraction needed)...")
         ;; For plain text files, read content directly and save as markdown
         (let* ((text-content (with-temp-buffer
                                (insert-file-contents doc-file)
                                (buffer-string)))
                (md-file (expand-file-name (concat (file-name-base doc-file) ".md")
                                           results-dir)))
           (unless (file-directory-p results-dir)
             (make-directory results-dir t))
           (with-temp-file md-file
             (insert text-content))
           (fuji--log "[STEP 2/3] Text file loaded. Ingesting content...")
           (funcall extraction-callback md-file)))
        
        ('llm
         (fuji--log "[STEP 1/3] Starting extraction with %s (async)..." llm-tool)
         ;; Use configured LLM extractor via unified plugin API (PDF only)
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
             (progn
               (fuji--log "[STEP 1/3] Using fast text-only extraction (pdftotext)...")
               ;; Use pdftotext for PDF
               (let ((md-file (fuji--extract doc-file results-dir "pdftotext")))
                 (fuji--log "[STEP 2/3] Text extracted. Ingesting content...")
                 (funcall extraction-callback md-file)))
           (progn
             (fuji--log "[STEP 1/3] Extracting %s with Pandoc..." doc-type)
             ;; Use Pandoc for non-PDF formats
             (let ((md-file (fuji--extract doc-file results-dir "pandoc")))
               (fuji--log "[STEP 2/3] Extraction complete. Ingesting content...")
               (funcall extraction-callback md-file)))))
        
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

))))

(provide 'fuji)

;;; fuji.el ends here
