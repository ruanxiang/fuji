;;; Nexus-paper.el --- AI-Powered Academic Reading Workflow for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025 ruanxiang
;; Author: ruanxiang
;; Version: 0.1
;; Package-Requires: ((emacs "29.1") (gptel "0.1") (org-ref "3.0") (mcp "0.1"))
;; Keywords: hypermedia, docs, multimedia
;; URL: https://github.com/ruanxiang/Nexus-Paper

;; License: MIT

;;; Commentary:

;; Nexus-Paper is a high-fidelity, multimodal research assistant.
;; It orchestrates Marker for PDF parsing, Graphlit for RAG,
;; and gptel for interaction.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url)
(require 'mcp)
(require 'gptel)
(require 'gptel-openai)
(require 'gptel-context nil t)

;; Phase 42: Global threshold to prevent "Argument list too long" (vfork)
;; This forces gptel to always use temporary files for curl payloads.
(setq gptel-curl-file-size-threshold 0)

(require 'auth-source)
(require 'subr-x)
(require 'ansi-color)

(defgroup nexus-paper nil
  "Customization group for Nexus-Paper."
  :group 'external)

;;;###autoload
(defcustom nexus-paper-marker-executable (or (executable-find "marker_single")
                                             (executable-find "marker"))
  "Path to the Marker executable. 
Note: For processing single files, 'marker_single' is preferred."
  :type '(choice (const :tag "Not Set" nil)
                 file)
  :group 'nexus-paper)

(defcustom nexus-paper-bib-path nil
  "Directory where BibTeX files are stored."
  :type '(choice (const :tag "Not Set" nil)
                 directory)
  :group 'nexus-paper)

(defcustom nexus-paper-gptel-vision-backend nil
  "The gptel backend to use for vision analysis.
If nil, use the default gptel-backend."
  :type '(choice (const :tag "Default" nil)
                 symbol)
  :group 'nexus-paper)

(defcustom nexus-paper-gptel-vision-model nil
  "The gptel model to use for vision analysis.
If nil, use the default model for the vision backend."
  :type '(choice (const :tag "Default" nil)
                 string)
  :group 'nexus-paper)

(defcustom nexus-paper-cache-directory (expand-file-name "nexus-paper-cache/" user-emacs-directory)
  "Directory to store parsed Markdown and images."
  :type 'directory
  :group 'nexus-paper)

;;;###autoload
(defcustom nexus-paper-graphlit-environment-id nil
  "Environment ID for Graphlit."
  :type 'string
  :group 'nexus-paper)

(defcustom nexus-paper-http-proxy nil
  "HTTP/HTTPS proxy to use for Nexus-Paper (e.g., \"127.0.0.1:7890\")."
  :type '(choice (const :tag "None" nil)
                 string)
  :group 'nexus-paper)

(defcustom nexus-paper-mcp-server-name "graphlit"
  "Name of the Graphlit MCP server registered in Emacs."
  :type 'string
  :group 'nexus-paper)

(defcustom nexus-paper-chat-mode 'hybrid
  "The chat mode for Nexus-Paper.
- `proxy': Standard RAG proxy mode (Graphlit is the backend).
- `hybrid': Local context injection mode (Standard gptel backend + Graphlit tool)."
  :type '(choice (const :tag "Hybrid (Recommended)" hybrid)
                 (const :tag "Proxy (Original)" proxy))
  :group 'nexus-paper)

(defcustom nexus-paper-gptel-backend nil
  "The default gptel backend name for chat sessions."
  :type '(choice (const :tag "Default (gptel-backend)" nil)
                 string)
  :group 'nexus-paper)

(defcustom nexus-paper-gptel-model nil
  "The default gptel model name for chat sessions."
  :type '(choice (const :tag "Default (gptel-model)" nil)
                 string)
  :group 'nexus-paper)

(defconst nexus-paper-progress-buffer "*Nexus Progress*")

(defvar-local nexus-paper--content-id nil "Graphlit content ID for current session.")
(defvar-local nexus-paper--filename nil "Filename of the paper being read.")
(defvar-local nexus-paper--results-dir nil "Cache directory for Marker results.")
(defvar-local nexus-paper--pdf-buffer nil "Buffer containing the source PDF.")
(defvar-local nexus-paper--prog-buffer nil "Buffer for progress logging.")
(defvar-local nexus-paper--context-buffer nil "Hidden buffer containing paper content for gptel context.")


(defun nexus-paper--log (format-string &rest args)
  "Log a message to the Nexus Progress buffer."
  (let* ((msg (apply #'format format-string args))
         (timestamp (format-time-string "[%H:%M:%S] ")))
    (with-current-buffer (get-buffer-create nexus-paper-progress-buffer)
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
    (message "Nexus-Paper: %s" msg)))

(defun nexus-paper--setup-3-buffer-layout (pdf-buffer chat-buffer progress-buffer)
  "Arrange windows: PDF and Chat side-by-side, Progress at the bottom (minibuffer-like)."
  (delete-other-windows)
  (let* ((prog-win (split-window-below -5))) ;; Create a 5-line window at the bottom
    (set-window-buffer prog-win progress-buffer)
    (set-window-dedicated-p prog-win t) ;; Make it dedicated
    (let ((chat-win (split-window-horizontally)))
      (set-window-buffer (selected-window) pdf-buffer)
      (set-window-buffer chat-win chat-buffer))))

(defun nexus-paper--save-auth-entry (org-id secret)
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
    (message "Nexus-Paper: Credentials saved to ~/.authinfo and cache cleared.")))

(defun nexus-paper-configure ()
  "Interactively configure or modify Nexus-Paper settings."
  (interactive)
  (let* ((auth (condition-case nil (nexus-paper--get-auth "graphlit") (error nil)))
         (backends (mapcar (lambda (b) (gptel-backend-name (cdr b))) gptel--known-backends))
         (marker-path (read-file-name "Path to Marker (marker_single preferred): " 
                                       (file-name-directory (or nexus-paper-marker-executable ""))
                                       nexus-paper-marker-executable t))
         (bib-path (read-directory-name "Directory for BibTeX files: " 
                                        nexus-paper-bib-path nexus-paper-bib-path t))
         
         ;; Chat Model Config
         (chat-backend-name (completing-read "Default Chat Backend: " backends nil t (or nexus-paper-gptel-backend "")))
         (chat-backend (gptel-get-backend chat-backend-name))
         (chat-model (completing-read "Default Chat Model: " (gptel-backend-models chat-backend) nil t (or nexus-paper-gptel-model "")))
         
         ;; Vision Model Config
         (vis-backend-name (completing-read "Vision Backend (Multimodal): " backends nil t 
                                            (or (and nexus-paper-gptel-vision-backend 
                                                     (symbolp nexus-paper-gptel-vision-backend)
                                                     (symbol-name nexus-paper-gptel-vision-backend))
                                                "")))
         (vis-backend (gptel-get-backend vis-backend-name))
         (vis-model (completing-read "Vision Model: " (gptel-backend-models vis-backend) nil t (or nexus-paper-gptel-vision-model "")))
         
         (org-id (read-string "Graphlit Organization ID: " (or (plist-get auth :user) "")))
         (secret (let ((s (read-passwd (format "Graphlit JWT Secret %s: " 
                                               (if (plist-get auth :secret) "(leave empty to keep current)" "")))))
                   (if (string-empty-p s) (plist-get auth :secret) s)))
         (env-id (read-string "Graphlit Environment ID: " (or nexus-paper-graphlit-environment-id "")))
         (cache-dir (read-directory-name "Cache Directory: " (or nexus-paper-cache-directory "")))
         (proxy (read-string "HTTP Proxy (e.g. 127.0.0.1:7890, leave empty for none): " 
                             (or nexus-paper-http-proxy ""))))
    
    (customize-save-variable 'nexus-paper-marker-executable (expand-file-name marker-path))
    (customize-save-variable 'nexus-paper-bib-path (expand-file-name bib-path))
    (customize-save-variable 'nexus-paper-graphlit-environment-id env-id)
    (customize-save-variable 'nexus-paper-cache-directory (expand-file-name cache-dir))
    
    (customize-save-variable 'nexus-paper-gptel-backend chat-backend-name)
    (customize-save-variable 'nexus-paper-gptel-model chat-model)
    
    (unless (string-empty-p vis-backend-name)
      (customize-save-variable 'nexus-paper-gptel-vision-backend (intern vis-backend-name)))
    (unless (string-empty-p vis-model)
      (customize-save-variable 'nexus-paper-gptel-vision-model vis-model))
    
    ;; Save credentials to ~/.authinfo
    (when (and (not (string-empty-p org-id)) (not (string-empty-p secret)))
      (nexus-paper--save-auth-entry org-id secret))

    (if (string-empty-p proxy)
        (customize-save-variable 'nexus-paper-http-proxy nil)
      (customize-save-variable 'nexus-paper-http-proxy proxy))
    
    (nexus-paper-apply-proxy)
    (nexus-paper--register-mcp-server)
    (message "Nexus-Paper: Configuration updated and MCP server registered.")))

(defun nexus-paper--get-mcp-connection ()
  "Get the current Graphlit MCP connection object, registering it if necessary."
  (let ((conn (gethash nexus-paper-mcp-server-name mcp-server-connections)))
    (unless conn
      (condition-case nil
          (progn
            (nexus-paper--register-mcp-server)
            (setq conn (gethash nexus-paper-mcp-server-name mcp-server-connections)))
        (error nil)))
    conn))

(defcustom nexus-paper-mcp-server-path
  (expand-file-name "node_modules/graphlit-mcp-server/dist/index.js"
                    (file-name-directory (or load-file-name buffer-file-name (locate-library "nexus-paper"))))
  "Path to the Graphlit MCP server executable."
  :type 'file
  :group 'nexus-paper)

(defun nexus-paper--register-mcp-server ()
  "Register the Graphlit MCP server using current credentials."
  (interactive)
  (let* ((auth (nexus-paper--get-auth "graphlit"))
         (org-id (plist-get auth :user))
         (secret (plist-get auth :secret))
         (env-id nexus-paper-graphlit-environment-id))
    (if (and org-id secret env-id)
        (progn
          (nexus-paper--log "Registering/Restarting MCP server: %s" nexus-paper-mcp-server-name)
          ;; Always stop first to ensure new credentials/env are applied
          (when (gethash nexus-paper-mcp-server-name mcp-server-connections)
            (mcp-stop-server nexus-paper-mcp-server-name))
          (mcp-connect-server nexus-paper-mcp-server-name
                              :command "node"
                              :args (list nexus-paper-mcp-server-path)
                              :env `(:GRAPHLIT_ORGANIZATION_ID ,org-id
                                     :GRAPHLIT_JWT_SECRET ,secret
                                     :GRAPHLIT_ENVIRONMENT_ID ,env-id
                                     ,@(when nexus-paper-http-proxy
                                         `(:HTTP_PROXY ,nexus-paper-http-proxy
                                           :HTTPS_PROXY ,nexus-paper-http-proxy)))
                              :syncp t))
      (nexus-paper--log "[WARNING] Missing credentials for MCP registration."))))

(defun nexus-paper-apply-proxy ()
  "Apply the configured proxy to Emacs `url-proxy-services`."
  (interactive)
  (if nexus-paper-http-proxy
      (setq url-proxy-services
            `(("http" . ,nexus-paper-http-proxy)
              ("https" . ,nexus-paper-http-proxy)
              ("no_proxy" . "^\\(localhost\\|127.0.0.1\\)")))
    (setq url-proxy-services nil))
  (message "Nexus-Paper: Proxy settings applied (%s)" (or nexus-paper-http-proxy "None")))
(defun nexus-paper-check-health ()
  "Check the health of the Nexus-Paper environment."
  (interactive)
  (let ((buf (get-buffer-create "*Nexus Health*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Nexus-Paper Health Check\n")
        (insert (make-string 30 ?=) "\n\n")
        
        ;; 1. Marker
        (insert "[Marker Settings]\n")
        (let ((marker-exe (or (bound-and-true-p nexus-paper-marker-executable) "marker")))
          (if (executable-find marker-exe)
              (insert (format "   [OK] Marker found: %s\n" (executable-find marker-exe)))
            (insert (format "   [FAIL] Marker NOT FOUND in PATH: %s\n" marker-exe))))
        
        ;; 2. Files
        (insert "\n[File Paths]\n")
        (if (and nexus-paper-bib-path (file-directory-p nexus-paper-bib-path))
            (insert (format "   [OK] Bib Directory: %s\n" nexus-paper-bib-path))
          (insert (format "   [FAIL] Bib Directory NOT FOUND: %s\n" nexus-paper-bib-path)))

        ;; 3. Credentials
        (insert "\n[Graphlit Credentials]\n")
        (let ((auth (nexus-paper--get-auth "graphlit")))
          (if auth
              (insert (format "   [OK] Found credentials for user: %s\n" (plist-get auth :user)))
            (insert "   [FAIL] No credentials found in ~/.netrc\n")))
        (if nexus-paper-graphlit-environment-id
            (insert (format "   [OK] Environment ID: %s\n" nexus-paper-graphlit-environment-id))
          (insert "   [FAIL] `nexus-paper-graphlit-environment-id` is not set.\n"))
        
        ;; 4. Proxy
        (insert "\n[Proxy Settings]\n")
        (insert (format "   Env HTTPS_PROXY: %s\n" (or (getenv "HTTPS_PROXY") "None")))
        (insert (format "   Env HTTP_PROXY:  %s\n" (or (getenv "HTTP_PROXY") "None")))
        (insert (format "   Emacs Proxy: %s\n" (or nexus-paper-http-proxy "None")))
        
        ;; 5. MCP Server
        (insert "\n[MCP Server Status]\n")
        (insert (format "   Path: %s\n" nexus-paper-mcp-server-path))
        (if (file-exists-p nexus-paper-mcp-server-path)
            (insert "   [OK] JS file exists.\n")
          (insert "   [FAIL] JS file NOT FOUND.\n"))
          
        (let ((conn (gethash nexus-paper-mcp-server-name mcp-server-connections)))
          (if conn
              (let ((proc (mcp-connection-process conn)))
                (if (and proc (process-live-p proc))
                    (insert (format "   [OK] Server '%s' is RUNNING (PID: %d)\n" 
                                    nexus-paper-mcp-server-name (process-id proc)))
                  (insert (format "   [FAIL] Server '%s' process is NOT LIVE.\n" nexus-paper-mcp-server-name))))
            (insert (format "   [OFFLINE] Server '%s' not registered.\n" nexus-paper-mcp-server-name))))
        
        (goto-char (point-min))
        (display-buffer (current-buffer))
        (message "Nexus-Paper: Health check complete.")))))

(defun nexus-paper--ensure-config ()
  "Ensure all required settings are configured."
  (nexus-paper-apply-proxy)
  (unless (and nexus-paper-marker-executable
               (file-executable-p nexus-paper-marker-executable)
               nexus-paper-bib-path
               (file-directory-p nexus-paper-bib-path)
               (nexus-paper--get-mcp-connection))
    (when (y-or-n-p "Nexus-Paper is not configured. Configure it now? ")
      (call-interactively #'nexus-paper-configure))))

(defun nexus-paper--get-auth (machine)
  "Retrieve auth-source info for MACHINE."
  (let ((auth (auth-source-search :host machine)))
    (if auth
        (let ((user (plist-get (car auth) :user))
              (secret (plist-get (car auth) :secret)))
          (list :user (if (functionp user) (funcall user) user)
                :secret (if (functionp secret) (funcall secret) secret)))
      (error "No credentials found for %s in auth-source" machine))))

(defun nexus-paper--get-pdf-text (pdf-file)
  "Extract text from PDF-FILE using `pdftotext` system utility."
  (let ((pdf-file (expand-file-name pdf-file)))
    (with-temp-buffer
      (call-process "pdftotext" nil t nil pdf-file "-")
      (buffer-string))))

(defun nexus-paper--use-local-marker-result (local-dir cache-dir)
  "Link files from LOCAL-DIR to CACHE-DIR."
  (unless (file-directory-p cache-dir)
    (make-directory cache-dir t))
  (let ((files (directory-files local-dir t directory-files-no-dot-files-regexp)))
    (dolist (file files)
      (let ((dest (expand-file-name (file-name-nondirectory file) cache-dir)))
        (if (fboundp 'make-symbolic-link)
            (make-symbolic-link file dest t)
          (copy-file file dest t))))))

(defun nexus-paper-verify-environment ()
  "Verify that the environment is correctly set up for Nexus-Paper."
  (interactive)
  (message "Nexus-Paper: Verifying environment...")
  (condition-case err
      (progn
        ;; 1. Check Marker
        (unless (file-executable-p nexus-paper-marker-executable)
          (error "Marker executable not found or not executable at: %s" nexus-paper-marker-executable))
        
        ;; 2. Check Graphlit Credentials
        (let ((auth (nexus-paper--get-auth "graphlit")))
          (unless (and (plist-get auth :user) (plist-get auth :secret))
            (error "Graphlit Organization ID or Secret missing in auth-source")))
        
        ;; 3. Check Bib Path
        (unless (file-directory-p nexus-paper-bib-path)
          (error "Bibliography directory not found: %s" nexus-paper-bib-path))

        ;; 4. Ensure Cache exists
        (unless (file-directory-p nexus-paper-cache-directory)
          (make-directory nexus-paper-cache-directory t))

        (message "Nexus-Paper: Environment verification SUCCESS!")
        t)
    (error
     (message "Nexus-Paper: Environment verification FAILED: %s" (error-message-string err))
     nil)))

(defun nexus-paper--get-cache-path (pdf-file)
  "Generate a cache path for PDF-FILE based on its hash."
  (let* ((hash (secure-hash 'sha256 pdf-file))
         (cache-dir (expand-file-name hash nexus-paper-cache-directory)))
    (unless (file-directory-p cache-dir)
      (make-directory cache-dir t))
    cache-dir))

(defun nexus-paper--find-marker-output (dir)
  "Find the first .md file in DIR or its subfolders."
  (let ((files (directory-files-recursively dir "\\.md$")))
    (when files
      (car files))))

(defun nexus-paper--process-pdf-with-marker (pdf-file callback)
  "Process PDF-FILE with Marker asynchronously, then call CALLBACK.
CALLBACK is called with the directory containing the results."
  (let* ((pdf-file (expand-file-name pdf-file)) ; Ensure absolute path
         (cache-dir (nexus-paper--get-cache-path pdf-file))
         (existing-md (nexus-paper--find-marker-output cache-dir))
         (marker-exe (if (and nexus-paper-marker-executable 
                              (string-match-p "marker_single$" nexus-paper-marker-executable))
                         nexus-paper-marker-executable
                       (let ((single-exe (expand-file-name "marker_single" 
                                                           (file-name-directory (or nexus-paper-marker-executable "")))))
                         (if (and (file-exists-p single-exe) (file-executable-p single-exe))
                             single-exe
                           nexus-paper-marker-executable))))
         ;; marker_single uses [OPTIONS] FPATH
         (marker-args (list "--output_dir" cache-dir pdf-file)))
    
    (if existing-md
        (progn
          (message "Nexus-Paper: Using cached Marker results for %s" (file-name-nondirectory pdf-file))
          (funcall callback existing-md))
      (progn
        (nexus-paper--log "Starting Marker (%s) for %s..." 
                          (file-name-nondirectory (or marker-exe "marker"))
                          (file-name-nondirectory pdf-file))
      (let* ((out-buf (get-buffer-create "*Nexus Marker Output*"))
             (_ (with-current-buffer out-buf
                  (unless enable-multibyte-characters
                    (set-buffer-multibyte t))))
             (process-environment (cons "PYTHONUNBUFFERED=1" process-environment))
             (process (make-process
                       :name "nexus-marker"
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
                                     (nexus-paper--log "Marker: %s" (string-trim (ansi-color-filter string))))))
                       :sentinel (lambda (proc event)
                                   (when (memq (process-status proc) '(exit signal))
                                     (let ((exit-status (process-exit-status proc)))
                                       (if (zerop exit-status)
                                           (let ((final-md (nexus-paper--find-marker-output cache-dir)))
                                             (if final-md
                                                 (progn
                                                   (nexus-paper--log "Marker finished successfully.")
                                                   (funcall callback final-md))
                                               (with-current-buffer (get-buffer-create "*Nexus Marker Output*")
                                                 (display-buffer (current-buffer))
                                                 (nexus-paper--log "Marker failed: No .md file found in %s" cache-dir)
                                                 (error "Nexus-Paper: Marker finished but no .md file found in %s" cache-dir))))
                                         (with-current-buffer (get-buffer-create "*Nexus Marker Output*")
                                           (display-buffer (current-buffer))
                                           (nexus-paper--log "Marker failed (%d): %s" exit-status event)
                                           (error "Nexus-Paper: Marker failed (%d): %s. Check output for details." exit-status event)))))))))
        (with-current-buffer out-buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert "Nexus-Paper: Processing PDF with Marker (PTY mode)...\n")
            (insert "Note: The FIRST run may take several minutes as it downloads AI models (several GB).\n")
            (insert "Command: " (or marker-exe "marker") " " (mapconcat #'identity marker-args " ") "\n")
            (insert (make-string 40 ?-) "\n\n"))
          (display-buffer (current-buffer))))))))

(defun nexus-paper--select-pdf ()
  "Select a PDF file. 
If the current buffer is a PDF, use it. Otherwise, prompt for a file,
favoring bib-search integration if available."
  (cond
   ;; 1. Current buffer is a PDF
   ((and buffer-file-name (string-match-p "\\.[pP][dD][fF]$" buffer-file-name))
    (let ((abs-path (expand-file-name buffer-file-name)))
      (message "Nexus-Paper: Using current PDF buffer: %s" (file-name-nondirectory abs-path))
      abs-path))
   
   ;; 2. Integration with ivy-bibtex (if the user wants to search by title)
   ((and (featurep 'ivy-bibtex)
         (y-or-n-p "Search bibliography for paper? "))
    (user-error "Please use `M-x ivy-bibtex` and pick 'Open PDF' or 'Nexus Chat' (if configured)"))

   ;; 3. Manual selection (fallback)
   (t
    (let ((file (read-file-name "Select PDF: " (or nexus-paper-bib-path default-directory) nil t)))
      (expand-file-name (substitute-in-file-name (expand-file-name file)))))))

(defun nexus-paper--normalize-string (s)
  "Ensure S is a multibyte string."
  (if (and s (stringp s))
      (if (multibyte-string-p s) s (decode-coding-string s 'utf-8))
    ""))

(defun nexus-paper--mcp-parse-result (result)
  "Parse the JSON result string from an MCP tool RESULT.
Handles various formats of RESULT (plists, hash-tables, symbols)."
  (message "Nexus-Paper: [DEBUG] Raw MCP result: %S" result)
  (let* ((content (or (plist-get result :content)
                      (and (hash-table-p result) (gethash "content" result))
                      (and (vectorp result) result)))
         (first-item (when (and content (> (length content) 0))
                       (aref content 0)))
         (text-val (nexus-paper--normalize-string
                    (or (plist-get first-item :text)
                        (and (hash-table-p first-item) (gethash "text" first-item))))))
    (message "Nexus-Paper: [DEBUG] Extracted text-val: %S" text-val)
    (if (or (string-empty-p text-val) (string= text-val "null"))
        (progn
          (message "Nexus-Paper: Result text is empty or null.")
          nil)
      (condition-case err
          (let* ((json-object-type 'alist)
                 (parsed (json-read-from-string text-val)))
            (message "Nexus-Paper: [DEBUG] Parsed JSON: %S" parsed)
            (if (or (assoc 'answer parsed) (assoc 'message parsed) (assoc 'id parsed))
                parsed
              ;; If it's valid JSON but doesn't have our keys, 
              ;; return the raw text-val as answer for safety
              `((answer . ,text-val) (id . ,(cdr (assoc 'id parsed))))))
        (error 
         (message "Nexus-Paper: [DEBUG] JSON parse error: %S" err)
         `((answer . ,text-val) (message . ,text-val)))))))

(defun nexus-paper--ingest-to-graphlit (text filename pdf-path callback)
  "Ingest TEXT for FILENAME from PDF-PATH to Graphlit via MCP.
Call CALLBACK with content-id on success."
  (nexus-paper--ensure-config)
  (nexus-paper--log "[STEP 2/3] Ingesting content via MCP tool 'ingestText'...")
  (let* ((conn (nexus-paper--get-mcp-connection))
         (text-len (length text)))
    (unless conn
      (error "Nexus-Paper: MCP connection not available"))
    (message "Nexus-Paper: Calling ingestText for %s (Text len: %d chars)..." filename text-len)
    (message "Nexus-Paper: [DEBUG] Initiating MCP ingestText call (Len: %d)..." text-len)
    (let ((timer (run-with-timer 60 nil
                                 (lambda ()
                                   (nexus-paper--log "[WARNING] Ingestion watchdog triggered: No response from MCP server after 60s.")
                                   (message "Nexus-Paper: [WARNING] Ingestion taking too long. Check MCP server status."))))
          (success-cb (lambda (result)
                        (when timer (cancel-timer timer))
                        (message "Nexus-Paper: [DEBUG] ingestText SUCCESS callback received.")
                        (let* ((parsed (nexus-paper--mcp-parse-result result))
                               (content-id (and parsed (cdr (assoc 'id parsed)))))
                          (if content-id
                              (progn
                                (nexus-paper--log "[SUCCESS] Ingestion completed. Content ID: %s" content-id)
                                ;; Save metadata to cache
                                (nexus-paper--add-metadata-entry content-id filename pdf-path)
                                (funcall callback content-id))
                            (let ((err-msg (format "MCP Ingestion failed to return ID: %s" result)))
                              (nexus-paper--log "[FAILURE] %s" err-msg)
                              (nexus-paper--log "[HINT] This usually means Graphlit credentials are invalid or expired.")
                              (nexus-paper--log "[HINT] Please run M-x nexus-paper-configure to update credentials.")
                              (message "Nexus-Paper: Graphlit returned empty response. Check credentials with M-x nexus-paper-configure")
                              (error "Nexus-Paper: %s" err-msg))))))
             (error-cb (lambda (err)
                         (when timer (cancel-timer timer))
                         (message "Nexus-Paper: [DEBUG] ingestText ERROR callback: %S" err)
                         (let ((err-msg (format "MCP tool call error: %s" (error-message-string err))))
                           (nexus-paper--log "[FAILURE] %s" err-msg)
                           (error "Nexus-Paper: %s" err-msg)))))
        (condition-case err
            (mcp-async-call-tool conn "ingestText"
                                 `((text . ,text)
                                   (name . ,filename)
                                   (type . "Markdown"))
                                 success-cb
                                 error-cb)
        (error
         (let ((err-msg (format "MCP tool session error: %s" (error-message-string err))))
           (nexus-paper--log "[FAILURE] %s" err-msg)
           (error "Nexus-Paper: %s" err-msg))))))

(defvar-local nexus-paper--content-id nil "Graphlit content ID for the current paper.")
(defvar-local nexus-paper--filename nil "Filename of the current paper.")
(defvar-local nexus-paper--conversation-id nil "Graphlit conversation ID for the current session.")
(defvar-local nexus-paper--results-dir nil "Directory containing Marker results.")
(defvar-local nexus-paper--pdf-buffer nil "PDF buffer for the current session.")
(defvar-local nexus-paper--prog-buffer nil "Progress buffer for the current session.")

(defun nexus-paper--query-graphlit (prompt success-callback error-callback)
  "Send PROMPT to Graphlit for RAG via MCP.
Calls SUCCESS-CALLBACK with answer on success, or ERROR-CALLBACK on failure."
  (let* ((orig-buffer (current-buffer))
         (conn (nexus-paper--get-mcp-connection))
         (paper-name (or (bound-and-true-p nexus-paper--filename) "this paper")))
    (message "Nexus-Paper: Querying Graphlit MCP... (Server: %s)" nexus-paper-mcp-server-name)
    (if (not conn)
        (progn
          (message "Nexus-Paper ERROR: No MCP connection found for %s" nexus-paper-mcp-server-name)
          (funcall error-callback "MCP server not connected"))
      (nexus-paper--log "Querying Graphlit RAG (Content: %s, Conversation: %s) with prompt: %S" 
                        (or (bound-and-true-p nexus-paper--content-id) "Global")
                        (or nexus-paper--conversation-id "New")
                        prompt)
      (condition-case err
          (mcp-async-call-tool conn "promptConversation"
                               `((prompt . ,prompt)
                                 ,@(when-let* ((cid (bound-and-true-p nexus-paper--content-id)))
                                     `((contentIds . [,cid])))
                                 ,@(when nexus-paper--conversation-id
                                     `((conversationId . ,nexus-paper--conversation-id))))
                                 (lambda (result)
                                 (message "Nexus-Paper: [DEBUG] MCP success lambda triggered.")
                                 (nexus-paper--log "MCP response received. Rendering...")
                                 (when (buffer-live-p orig-buffer)
                                   (with-current-buffer orig-buffer
                                     (let* ((parsed (nexus-paper--mcp-parse-result result))
                                            (answer (and parsed 
                                                         (or (cdr (assoc 'answer parsed))
                                                             (cdr (assoc 'message parsed)))))
                                            (conv-id (and parsed (cdr (assoc 'id parsed)))))
                                       (if answer
                                           (progn
                                             (message "Nexus-Paper: Answer extracted, calling success callback.")
                                             ;; Save conversation ID for continuity
                                             (when conv-id
                                               (setq nexus-paper--conversation-id conv-id))
                                             (funcall success-callback answer))
                                         (let ((err-msg (format "MCP tool returned success but no answer found in result.")))
                                           (nexus-paper--log "[FAILURE] %s" err-msg)
                                           (message "Nexus-Paper: %s Raw: %S" err-msg result)
                                               (funcall error-callback err-msg)))))))
                               (lambda (err)
                                 (message "Nexus-Paper: MCP error lambda triggered: %S" err)
                                 (when (buffer-live-p orig-buffer)
                                   (with-current-buffer orig-buffer
                                     (let ((err-msg (format "MCP tool call error: %s" (error-message-string err))))
                                       (nexus-paper--log "[FAILURE] %s" err-msg)
                                       (funcall error-callback err-msg))))))
        (error
         (let ((err-msg (format "MCP session logic error: %s" (error-message-string err))))
           (message "Nexus-Paper: %s" err-msg)
           (nexus-paper--log "[FAILURE] %s" err-msg)
           (funcall error-callback err-msg)))))))

;;; gptel Integration

(cl-defstruct (nexus-gptel-backend (:include gptel-backend)))

(require 'gptel-request nil t)

(defun nexus-paper--gptel-handle-wait-advice (orig-fun fsm)
  "Intercept gptel's `WAIT' state to use Graphlit MCP for `nexus-paper' backends."
  (let* ((info (gptel-fsm-info fsm))
         (backend (plist-get info :backend)))
    (if (and backend (fboundp 'nexus-gptel-backend-p) (nexus-gptel-backend-p backend))
        (progn
          (message "Nexus-Paper: Intercepting gptel request via WAIT advice.")
          (let ((data (or (plist-get info :data) (plist-get info :prompt))))
            (nexus-paper--gptel-request-handler backend data :fsm fsm)))
      (funcall orig-fun fsm))))

(advice-add 'gptel--handle-wait :around #'nexus-paper--gptel-handle-wait-advice)

(cl-defmethod gptel-parse-response ((_backend nexus-gptel-backend) response _info)
  "Extract text from RESPONSE. For Nexus, it's already a string."
  (if (stringp response) response ""))

(cl-defmethod gptel--parse-buffer ((_backend nexus-gptel-backend) &optional max-entries)
  "Parse current buffer backwards from point and return a list of prompts.
For Nexus, we follow the standard gptel pattern of scanning for 'gptel properties."
  (let ((prompts) (prev-pt (point)))
    (message "Nexus-Paper: [DEBUG] gptel--parse-buffer called at point %d in buffer %s" (point) (buffer-name))
    (if (or gptel-mode gptel-track-response)
        (while (and (or (not max-entries) (>= max-entries 0))
                    (/= prev-pt (point-min))
                    (goto-char (max (point-min) 
                                    (previous-single-property-change
                                     (point) 'gptel nil (point-min)))))
          (pcase (get-char-property (point) 'gptel)
            ('response
             (let ((content (string-trim (buffer-substring-no-properties (point) prev-pt))))
               (when (> (length content) 0)
                 (push (list :role "assistant" :content content) prompts))))
            ('nil
             (and max-entries (cl-decf max-entries))
             (let ((content (string-trim (buffer-substring-no-properties
                                           (point) prev-pt))))
               (when (> (length content) 0)
                 (push (list :role "user" :content content) prompts))))
            ('ignore))
          (setq prev-pt (point)))
      ;; Fallback: just use the whole buffer as one user prompt
      (let ((content (string-trim (buffer-substring-no-properties (point-min) (point-max)))))
        (when (> (length content) 0)
          (push (list :role "user" :content content) prompts))))
    (message "Nexus-Paper: [DEBUG] gptel--parse-buffer returning %d prompts" (length prompts))
    (dolist (p prompts)
      (message "Nexus-Paper: [DEBUG] Prompt role: %s, len: %d" (plist-get p :role) (length (plist-get p :content))))
    prompts))

(cl-defmethod gptel--request-data ((_backend nexus-gptel-backend) prompts)
  "Prepare the data for a Nexus request.
Since we intercept in the WAIT state, we just pass the prompts through."
  prompts)

(defun nexus-paper--gptel-request-handler (backend prompt &rest args)
  "Async request handler for Graphlit RAG backend.
PROMPT is the user query (string or list of plists). ARGS contains :fsm or direct plists."
  (message "Nexus-Paper: [DEBUG-START] Request Handler Entry")
  (let* ((fsm (plist-get args :fsm))
         (info (if fsm (gptel-fsm-info fsm) args))
         (sep (or (and (boundp 'gptel-model-separator) gptel-model-separator) 
                  "------------------------------------------------------------")))
    
    ;; Ensure default callback if missing
    (unless (plist-get info :callback)
      (message "Nexus-Paper: [DEBUG] Missing callback, injecting gptel--insert-response")
      (setq info (plist-put info :callback #'gptel--insert-response))
      (when fsm (setf (gptel-fsm-info fsm) info)))

    (let* ((callback (plist-get info :callback))
           (buffer (or (plist-get info :buffer) (current-buffer)))
           ;; Extract actual prompt from complex input
           (actual-prompt 
            (cond
             ((stringp prompt)
              (message "Nexus-Paper: [DEBUG] Processing STRING prompt (len: %d)" (length prompt))
              (if (string-match (concat "[^\0]*" (regexp-quote (string-trim sep)) "[[:space:]\n]*\\([^\0]*\\)") prompt)
                  (match-string 1 prompt)
                prompt))
             ((listp prompt)
              (message "Nexus-Paper: [DEBUG] Extracting from LIST prompt (len: %d)" (length prompt))
              (let* ((last-msg (car (last prompt)))
                     (raw-content (cond
                                   ((and (listp last-msg) (plist-get last-msg :content)) (plist-get last-msg :content))
                                   ((stringp last-msg) last-msg)
                                   (t ""))))
                (message "Nexus-Paper: [DEBUG] Raw content from list (len: %d)" (length raw-content))
                (if (string-match (concat "[^\0]*" (regexp-quote (string-trim sep)) "[[:space:]\n]*\\([^\0]*\\)") raw-content)
                    (match-string 1 raw-content)
                  raw-content)))
             (t 
              (message "Nexus-Paper: [DEBUG] Prompt branch fallthrough. Prompt: %S" prompt)
              ""))))
      
      (message "Nexus-Paper: [DEBUG] Actual Prompt (len: %d): %S" (length actual-prompt) actual-prompt)
      (nexus-paper--log "Nexus-Paper: gptel processing prompt (len: %d)" (length actual-prompt))

      (let ((figure-id (nexus-paper--detect-visual-query actual-prompt))
            (success-wrapper (lambda (response)
                               (message "Nexus-Paper: SUCCESS callback. Notifying gptel.")
                               (plist-put info :http-status "200")
                               (plist-put info :status "success")
                               (setq response (nexus-paper--normalize-string (or response "")))
                               
                               (with-current-buffer buffer
                                 (unless enable-multibyte-characters
                                   (set-buffer-multibyte t))
                                 (setq-local buffer-file-coding-system 'utf-8)
                                 (if callback 
                                     (condition-case err
                                         (progn
                                           (message "Nexus-Paper: [DEBUG] Pre-transition to TYPE. FSM: %S" fsm)
                                           ;; FSM Transition: Move to 'TYPE' state (uppercase in 0.9.x)
                                           (when (and fsm (fboundp 'gptel--fsm-transition))
                                             (message "Nexus-Paper: [DEBUG] Calling gptel--fsm-transition to TYPE")
                                             (gptel--fsm-transition fsm 'TYPE))
                                           
                                           (message "Nexus-Paper: [DEBUG] Calling callback: %S" callback)
                                           (funcall callback response info)
                                           (message "Nexus-Paper: [DEBUG] Callback returned successfully")
                                           
                                           (message "Nexus-Paper: [DEBUG] Pre-transition to DONE")
                                           ;; FSM Transition: Finalize to 'DONE' state
                                           (when (and fsm (fboundp 'gptel--fsm-transition))
                                             (gptel--fsm-transition fsm 'DONE)))
                                       (error
                                        (let ((err-str (error-message-string err)))
                                          (message "Nexus-Paper: [CRITICAL] Callback error: %S" err)
                                          (message "Nexus-Paper: [CRITICAL] Error detail: %s" err-str)
                                          (nexus-paper--log "Callback error: %S" err))))
                                   
                                   ;; Fallback
                                   (progn
                                     (message "Nexus-Paper WARNING: No callback provided, manually inserting.")
                                     (goto-char (point-max))
                                     (insert response)
                                     (when (and fsm (fboundp 'gptel--fsm-transition))
                                       (gptel--fsm-transition fsm 'DONE)))))))
            (error-wrapper (lambda (err-msg)
                             (message "Nexus-Paper: ERROR callback: %s" err-msg)
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
              (message "Nexus-Paper: Detected empty prompt, skipping Graphlit query.")
              (funcall success-wrapper "How can I help you with this paper?"))
          (if figure-id
              (nexus-paper--handle-visual-query figure-id actual-prompt success-wrapper error-wrapper)
            (nexus-paper--query-graphlit actual-prompt success-wrapper error-wrapper)))
        fsm))))

(defun nexus-paper--detect-visual-query (prompt)
  "Return figure ID if PROMPT is a visual query, nil otherwise."
  (when (and (stringp prompt)
             (string-match "\\(figure\\|fig\\|table\\|chart\\|diagram\\)\\s-+\\([0-9]+\\)" (downcase prompt)))
    (match-string 2 (downcase prompt))))

(defun nexus-paper--handle-visual-query (figure-id prompt success-callback error-callback)
  "Handle a visual query for FIGURE-ID.
Calls SUCCESS-CALLBACK on success, or ERROR-CALLBACK on failure."
  (message "Nexus-Paper: Handling visual query for Figure %s" figure-id)
  ;; 1. Query Graphlit for caption
  (nexus-paper--query-graphlit 
   (format "What is the caption and context for Figure %s?" figure-id)
   (lambda (caption)
     ;; 2. Find image
     (let ((image-file (expand-file-name (format "figure-%s.png" figure-id)
                                         (expand-file-name "assets" nexus-paper--results-dir))))
       (if (file-exists-p image-file)
           (progn
             (message "Nexus-Paper: Found image %s. Calling Vision API..." image-file)
             ;; 3. Call Vision API (using gptel or direct)
             (nexus-paper--call-vision-api image-file caption prompt success-callback error-callback))
         (let ((err (format "Figure image not found: %s" image-file)))
           (nexus-paper--log "[FAILURE] %s" err)
           (funcall error-callback err)))))
   error-callback))

(defun nexus-paper--call-vision-api (image-file caption prompt success-callback error-callback)
  "Call a multimodal model with IMAGE-FILE, CAPTION and PROMPT."
  (message "Nexus-Paper: Vision analysis for %s..." image-file)
  (let* ((vision-prompt (format "Below is Figure %s from a research paper. 
Caption: %s

User Question: %s

Please explain the figure based on the image and the provided context." 
                                (nexus-paper--detect-visual-query prompt)
                                caption prompt))
         (backend (or nexus-paper-gptel-vision-backend gptel-backend))
         (model (or nexus-paper-gptel-vision-model gptel-model)))
    
    (gptel-request 
            vision-prompt
      :callback (lambda (response info)
                  (if (plist-get info :error)
                      (funcall error-callback (plist-get info :error))
                    (funcall success-callback response)))
      :context (list image-file)
      :backend backend
      :model model)))

(defun nexus-paper--cleanup-session ()
  "Prompt to delete Graphlit content on buffer kill.
Also clears any global gptel context to ensure a clean exit."
  (let* ((filename nexus-paper--filename)
         (content-id nexus-paper--content-id)
         (ctx-buf nexus-paper--context-buffer))
    (nexus-paper--log "Session cleanup for: %s" filename)
    ;; 1. Remove all gptel context items
    (when (fboundp 'gptel-context-remove-all)
      (gptel-context-remove-all))
    ;; 2. Kill hidden context buffer if any
    (when (buffer-live-p ctx-buf)
      (kill-buffer ctx-buf))
    ;; 3. Prompt for Graphlit cleanup
    (when (and content-id
               (y-or-n-p "Nexus-Paper: Delete paper content from Graphlit to save quota? "))
      (message "Nexus-Paper: Deleting content %s..." content-id)
      (nexus-paper--delete-from-graphlit content-id))))

;;;###autoload
(defun rx/nexus-paper-quit ()
  "Unified command to quit the current Nexus-Paper session.
Prompts for content deletion and kills related buffers."
  (interactive)
  (let ((chat-buf (current-buffer))
        (pdf-buf nexus-paper--pdf-buffer)
        (prog-buf nexus-paper--prog-buffer))
    (unless (and nexus-paper--filename (string-match-p "\\*Nexus-Chat:" (buffer-name chat-buf)))
      (user-error "Nexus-Paper: Not in a Nexus-Chat buffer"))
    
    ;; 1. Run cleanup (asks about Graphlit deletion)
    (nexus-paper--cleanup-session)
    
    ;; 2. Remove the hook to prevent duplicate cleanup when killing buffer
    (remove-hook 'kill-buffer-hook #'nexus-paper--cleanup-session t)
    
    ;; 3. Kill buffers
    (when (buffer-live-p pdf-buf) (kill-buffer pdf-buf))
    (when (buffer-live-p prog-buf) (kill-buffer prog-buf))
    (kill-buffer chat-buf)
    
    (message "Nexus-Paper: Session ended and buffers cleaned up.")))

(defun nexus-paper--delete-from-graphlit (content-id)
  "Delete CONTENT-ID from Graphlit via MCP."
  (nexus-paper--log "Deleting content %s via MCP tool 'deleteContent'..." content-id)
  (let ((conn (gethash nexus-paper-mcp-server-name mcp-server-connections)))
    (when conn
      (condition-case err
          (mcp-async-call-tool conn "deleteContent"
                               `((id . ,content-id))
                               (lambda (result)
                                 (let* ((parsed (nexus-paper--mcp-parse-result result))
                                        (deleted-id (cdr (assoc 'id parsed)))
                                        (state (cdr (assoc 'state parsed))))
                                   (if (and deleted-id (string= state "DELETED"))
                                       (progn
                                         (nexus-paper--log "[SUCCESS] Content deleted: %s (state: %s)" deleted-id state)
                                         ;; Remove from metadata cache
                                         (nexus-paper--remove-metadata-entry content-id))
                                     (nexus-paper--log "[INFO] Delete operation completed (response: %s)" result))))
                               (lambda (err)
                                 (nexus-paper--log "[FAILURE] Delete failed: %s" (error-message-string err))))
        (error
         (nexus-paper--log "[FAILURE] Delete session error: %s" (error-message-string err)))))))


(defun nexus-paper--setup-buffer-header (filename content-id)
  "Set up a header for the chat buffer for FILENAME."
  (unless enable-multibyte-characters
    (set-buffer-multibyte t))
  (setq-local buffer-file-coding-system 'utf-8)
  (let ((header (format "Nexus-Paper | File: %s | Graphlit ID: %s | Model: %s\n%s\n"
                        filename content-id gptel-model (make-string 60 ?-))))
    (save-excursion
      (goto-char (point-min))
      (insert header))))

(defun nexus-paper-query-graphlit (query)
  "Search the research paper for specific details using Graphlit RAG.
This is used as a gptel tool in hybrid mode."
  (let* ((conn (nexus-paper--get-mcp-connection))
         (content-id nexus-paper--content-id))
    (unless content-id
      (error "Nexus-Paper: Content ID not found in current buffer"))
    (let ((result (mcp-call-tool conn "promptConversation"
                                `((prompt . ,query)
                                  (contentIds . [,content-id])))))
      (nexus-paper--mcp-parse-result result))))

(defvar nexus-paper-gptel-tool-graphlit
  (when (fboundp 'gptel-make-tool)
    (gptel-make-tool
     :name "query_graphlit"
     :function #'nexus-paper-query-graphlit
     :description "Search the research paper for specific details using RAG. Use this when the provided local context is insufficient or when you need to verify facts across the entire document."
     :args '((:name "query" :type string :description "The search query to look up in the paper database"))
     :category "research"))
  "The gptel tool for Graphlit RAG retrieval.")

;;;###autoload
(defun rx/gptel-ref-chat ()
  "Start a multimodal AI chat for a research paper.
Orchestrates PDF parsing via Marker and RAG via Graphlit."
  (interactive)
  (nexus-paper--ensure-config)
  (unless (nexus-paper-verify-environment)
    (error "Nexus-Paper: Environment not ready. Run M-x nexus-paper-configure"))
  
  (let* ((pdf-file (nexus-paper--select-pdf))
         (mode-map '(("Auto (Run Marker) - High accuracy, supports figures" . auto)
                     ("Skip (pdftotext) - Fast, text only, lower accuracy" . skip)
                     ("Load Local Result - Use pre-existing Marker output" . local)))
         (mode-label (completing-read "Marker Mode: " (mapcar #'car mode-map) nil t))
         (mode (cdr (assoc mode-label mode-map)))
         (filename (file-name-nondirectory pdf-file))
         (results-dir (nexus-paper--get-cache-path pdf-file))
         (pdf-buffer (find-file-noselect pdf-file))
         (chat-buffer (get-buffer-create (format "*Nexus-Chat: %s*" filename)))
         (prog-buffer (get-buffer-create nexus-paper-progress-buffer)))

    ;; Initial UI Setup
    (with-current-buffer prog-buffer
      (let ((inhibit-read-only t))
        (set-buffer-multibyte t)
        (erase-buffer)
        (insert "Nexus-Paper Progress: " filename "\n" (make-string 40 ?-) "\n\n")
        (setq-local cursor-type nil)
        (view-mode 1)))
    
    (with-current-buffer chat-buffer
      (let ((inhibit-read-only t))
        (set-buffer-multibyte t)
        (erase-buffer)
        (insert "# Waiting for document ingestion...\n\n")
        (insert "Progress is being tracked in the right buffer.")))

    (nexus-paper--setup-3-buffer-layout pdf-buffer chat-buffer prog-buffer)
    (nexus-paper--log "Workflow started in mode: %s" mode)

    (let ((marker-callback
           (lambda (md-file)
             (let* ((md-content (with-temp-buffer
                                  (insert-file-contents md-file)
                                  (buffer-string))))
               (nexus-paper--ingest-to-graphlit
                md-content filename pdf-file
                (lambda (content-id)
                  (nexus-paper--log "[STEP 3/3] Ingestion complete (ID: %s). Finalizing chat..." content-id)
                  (with-current-buffer chat-buffer
                    (let ((inhibit-read-only t)) 
                      (set-buffer-multibyte t)
                      (erase-buffer)
                      (org-mode)
                      
                      (setq-local nexus-paper--content-id content-id)
                      (setq-local nexus-paper--filename filename)
                      (setq-local nexus-paper--results-dir results-dir)
                      (setq-local nexus-paper--pdf-buffer pdf-buffer)
                      (setq-local nexus-paper--prog-buffer prog-buffer)
                      
                      (if (eq nexus-paper-chat-mode 'hybrid)
                          (progn
                             (let* ((md-file (expand-file-name (concat (file-name-base pdf-file) ".md")
                                                              nexus-paper--results-dir)))
                               (with-temp-file md-file
                                 (insert md-content))
                               ;; Add the extracted MD file as context silently
                               (when (fboundp 'gptel-add-file)
                                 (let ((inhibit-message t))
                                   (gptel-add-file md-file))))
                            
                            ;; Apply configured Backend & Model
                            (when nexus-paper-gptel-backend
                              (let ((be (gptel-get-backend nexus-paper-gptel-backend)))
                                (when be (setq-local gptel-backend be))))
                            (when nexus-paper-gptel-model
                              (setq-local gptel-model nexus-paper-gptel-model))

                            ;; 3. Configure system directive
                            (setq-local gptel-directives 
                                        (cons '(nexus-paper . "You are an academic assistant. Answer questions based on the provided document context. If you need more info from the paper using semantic search, use the 'query_graphlit' tool.")
                                              gptel-directives))
                            (setq-local gptel-default-directive 'nexus-paper)
                            
                            ;; 4. Register Graphlit as a gptel tool if available
                            (when (and (boundp 'gptel-tools) nexus-paper-gptel-tool-graphlit)
                              (setq-local gptel-tools (list nexus-paper-gptel-tool-graphlit))))
                        
                        ;; Proxy mode logic
                        (setq-local gptel-backend (make-nexus-gptel-backend
                                                   :name "Nexus-Graphlit"
                                                   :models '(Graphlit-RAG)))
                        (setq-local gptel-model 'Graphlit-RAG))
                      
                      (insert "\n* ") ;; Initial user prompt
                      (gptel-mode)
                      (nexus-paper-mode 1)
                      (nexus-paper--setup-buffer-header filename content-id)
                      (add-hook 'kill-buffer-hook #'nexus-paper--cleanup-session nil t)
                      (nexus-paper--log "[SUCCESS] Chat initialization complete. Ready!")
                      (goto-char (point-max))
                      ;; Auto-focus the chat window
                      (when-let* ((win (get-buffer-window chat-buffer)))
                        (select-window win))))))))))

      (pcase mode
        ('auto
         (nexus-paper--log "[STEP 1/3] Starting Marker processing...")
         (nexus-paper--process-pdf-with-marker pdf-file
                                               (lambda (md)
                                                 (nexus-paper--log "[STEP 2/3] Marker finished. Ingesting content...")
                                                 (funcall marker-callback md))))
        
        ('skip
         (nexus-paper--log "[STEP 1/3] Skipping Marker, extracting text directly...")
         (let ((md-file (expand-file-name "skipped_marker.md" results-dir)))
           (unless (file-directory-p results-dir) (make-directory results-dir t))
           (with-temp-file md-file
             (insert "# " filename "\n\n")
             (insert "> [!NOTE]\n")
             (insert "> Marker processing skipped. This is a text-only ingestion using pdftotext.\n\n")
             (insert (nexus-paper--get-pdf-text pdf-file)))
           (nexus-paper--log "[STEP 2/3] Text extracted. Ingesting content...")
           (funcall marker-callback md-file)))
        
        ('local
         (let ((local-dir (read-directory-name "Select directory with Marker results: " nil nil t)))
           (nexus-paper--log "[STEP 1/3] Loading local Marker results from: %s" local-dir)
           (nexus-paper--use-local-marker-result local-dir results-dir)
           (let ((md-file (nexus-paper--find-marker-output results-dir)))
             (if md-file
                 (progn
                   (nexus-paper--log "[STEP 2/3] Marker results loaded. Ingesting content...")
                   (funcall marker-callback md-file))
               (error "Nexus-Paper: No .md file found in the selected directory!")))))))))

;;; Interactive Configuration Interfaces

(defvar nexus-paper-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c n m") #'rx/nexus-paper-set-model)
    (define-key map (kbd "C-c n a") #'rx/nexus-paper-add-context)
    (define-key map (kbd "C-c n s") #'rx/nexus-paper-manage-mcp)
    (define-key map (kbd "C-c n q") #'rx/nexus-paper-quit)
    map)
  "Keymap for `nexus-paper-mode'.")

(define-minor-mode nexus-paper-mode
  "Minor mode for Nexus-Paper chat buffers."
  :lighter " Nexus"
  :keymap nexus-paper-mode-map)

(defun rx/nexus-paper-set-model ()
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
    (nexus-paper--log "Model updated to %s (%s)" model backend-name)
    (message "Nexus-Paper: Model set to %s" model)))

(defun rx/nexus-paper-add-context ()
  "Interactively add a file as context to the current Nexus session."
  (interactive)
  (let ((file (read-file-name "Add file to context: ")))
    (cond
     ((string-match-p "\\.\\(pdf\\|docx\\|pptx\\|xlsx\\|epub\\|mobi\\)$" (downcase file))
      (message "Nexus-Paper: [WARNING] gptel cannot process binary formats (PDF/DOCX) directly. Please extract to Markdown/Text first.")
      (when (y-or-n-p "Attempt to add anyway? ")
        (gptel-add-file file)
        (nexus-paper--log "Context added (Binary?): %s" (file-name-nondirectory file))))
     (t
      (gptel-add-file file)
      (nexus-paper--log "Context added: %s" (file-name-nondirectory file))
      (message "Nexus-Paper: File '%s' added to context." (file-name-nondirectory file))))))

(defun rx/nexus-paper-manage-mcp ()
  "Interactively manage (restart/register) the MCP server."
  (interactive)
  (if (y-or-n-p "Restart current Graphlit MCP server? ")
      (progn
        (nexus-paper--register-mcp-server)
        (message "Nexus-Paper: MCP server restarted."))
    (message "Nexus-Paper: MCP management cancelled.")))

;;; Graphlit Content Management UI

(defvar nexus-paper--content-list nil
  "List of content items from Graphlit.
Each item is an alist with keys: id, name, createdDate, fileSize, state.")

(defvar nexus-paper-library-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'nexus-paper-library-refresh)
    (define-key map (kbd "d") #'nexus-paper-library-mark-delete)
    (define-key map (kbd "u") #'nexus-paper-library-unmark)
    (define-key map (kbd "U") #'nexus-paper-library-unmark-all)
    (define-key map (kbd "x") #'nexus-paper-library-execute)
    (define-key map (kbd "RET") #'nexus-paper-library-view-details)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `nexus-paper-library-mode'.")

(define-derived-mode nexus-paper-library-mode tabulated-list-mode "Nexus-Library"
  "Major mode for managing Graphlit content.
\\{nexus-paper-library-mode-map}"
  (setq tabulated-list-format
        [("Title" 40 t)
         ("ID" 12 nil)
         ("Date" 12 t)
         ("Size" 10 t)
         ("Type" 20 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "Date" t))
  (tabulated-list-init-header))

(defun nexus-paper--query-all-contents (callback)
  "Query all content from Graphlit via MCP and call CALLBACK with results."
  (let ((conn (nexus-paper--get-mcp-connection)))
    (when conn
      (condition-case err
          (mcp-async-call-tool conn "queryContents"
                               '()  ; No arguments needed for listing all
                               (lambda (result)
                                 (message "Nexus-Paper: [DEBUG] queryContents raw result: %S" result)
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
                                   (message "Nexus-Paper: [DEBUG] Parsed %d content items" (length contents))
                                   (if contents
                                       (funcall callback contents)
                                     (message "Nexus-Paper: No content found in Graphlit")
                                     (funcall callback nil))))
                               (lambda (err)
                                 (message "Nexus-Paper: Failed to query contents: %s" 
                                          (error-message-string err))
                                 (funcall callback nil)))
        (error
         (message "Nexus-Paper: Query error: %s" (error-message-string err))
         (funcall callback nil))))))

;;; Metadata Cache for Content List

(defun nexus-paper--get-metadata-cache-file ()
  "Get the path to the metadata cache file."
  (let ((cache-dir (expand-file-name "~/.cache/nexus-paper")))
    (unless (file-directory-p cache-dir)
      (make-directory cache-dir t))
    (expand-file-name "graphlit-metadata.json" cache-dir)))

(defun nexus-paper--load-metadata-cache ()
  "Load metadata cache from file. Returns an alist of (content-id . metadata)."
  (let ((cache-file (nexus-paper--get-metadata-cache-file)))
    (if (file-exists-p cache-file)
        (condition-case err
            (with-temp-buffer
              (insert-file-contents cache-file)
              (let ((json-object-type 'alist))
                (json-read)))
          (error
           (message "Nexus-Paper: Failed to load metadata cache: %s" (error-message-string err))
           nil))
      nil)))

(defun nexus-paper--save-metadata-cache (cache)
  "Save metadata CACHE to file."
  (let ((cache-file (nexus-paper--get-metadata-cache-file)))
    (condition-case err
        (with-temp-file cache-file
          (insert (json-encode cache)))
      (error
       (message "Nexus-Paper: Failed to save metadata cache: %s" (error-message-string err))))))

(defun nexus-paper--add-metadata-entry (content-id filename file-path)
  "Add metadata entry for CONTENT-ID with FILENAME and FILE-PATH."
  (let* ((cache (or (nexus-paper--load-metadata-cache) '()))
         (file-size (and (file-exists-p file-path) (file-attribute-size (file-attributes file-path))))
         (metadata `((filename . ,filename)
                    (upload_date . ,(format-time-string "%Y-%m-%dT%H:%M:%S"))
                    (file_size . ,(or file-size 0))
                    (local_path . ,file-path))))
    ;; Add or update entry
    (setq cache (cons (cons content-id metadata)
                      (assoc-delete-all content-id cache)))
    (nexus-paper--save-metadata-cache cache)
    (message "Nexus-Paper: Saved metadata for %s" filename)))

(defun nexus-paper--get-metadata-for-id (content-id)
  "Get metadata for CONTENT-ID from cache. Returns alist or nil."
  (let ((cache (nexus-paper--load-metadata-cache)))
    (cdr (assoc content-id cache))))

(defun nexus-paper--remove-metadata-entry (content-id)
  "Remove metadata entry for CONTENT-ID from cache."
  (let* ((cache (or (nexus-paper--load-metadata-cache) '()))
         (updated-cache (assoc-delete-all content-id cache)))
    (nexus-paper--save-metadata-cache updated-cache)
    (message "Nexus-Paper: Removed metadata for %s" content-id)))


(defun nexus-paper--format-file-size (bytes)
  "Format BYTES as human-readable file size."
  (cond
   ((>= bytes 1073741824) (format "%.1f GB" (/ bytes 1073741824.0)))
   ((>= bytes 1048576) (format "%.1f MB" (/ bytes 1048576.0)))
   ((>= bytes 1024) (format "%.1f KB" (/ bytes 1024.0)))
   (t (format "%d B" bytes))))

(defun nexus-paper--format-date (iso-date)
  "Format ISO-DATE string to readable format."
  (if (stringp iso-date)
      (substring iso-date 0 10)  ; Extract YYYY-MM-DD
    "N/A"))

(defun nexus-paper-library-refresh ()
  "Refresh the Graphlit content list."
  (interactive)
  (message "Nexus-Paper: Querying Graphlit...")
  (let ((library-buf (get-buffer "*Nexus-Library*")))
    (nexus-paper--query-all-contents
     (lambda (contents)
       (setq nexus-paper--content-list contents)
       (when (buffer-live-p library-buf)
         (with-current-buffer library-buf
           (nexus-paper-library--populate-buffer)))
       (message "Nexus-Paper: Refreshed (%d items)" (length contents))))))

(defun nexus-paper-library--populate-buffer ()
  "Populate the library buffer with content list."
  (message "Nexus-Paper: [DEBUG] Populating buffer with %d items" (length nexus-paper--content-list))
  (let ((entries
         (mapcar
          (lambda (item)
            (let* ((id (cdr (assoc 'id item)))
                   (metadata (nexus-paper--get-metadata-for-id id))
                   ;; Use cached metadata if available
                   (name (if metadata
                            (cdr (assoc 'filename metadata))
                          (format "Content %s" (substring id 0 8))))
                   (date (if metadata
                            (let ((upload-date (cdr (assoc 'upload_date metadata))))
                              (if (stringp upload-date)
                                  (substring upload-date 0 10)  ; Extract YYYY-MM-DD
                                "N/A"))
                          "N/A"))
                   (size (if metadata
                            (nexus-paper--format-file-size (cdr (assoc 'file_size metadata)))
                          "N/A"))
                   (mime (or (cdr (assoc 'mimeType item)) "unknown"))
                   (id-short (substring id 0 (min 8 (length id)))))
              (list id (vector name id-short date size mime))))
          nexus-paper--content-list)))
    (message "Nexus-Paper: [DEBUG] Setting %d entries" (length entries))
    (setq tabulated-list-entries entries)
    (tabulated-list-init-header)
    (tabulated-list-print t)
    (message "Nexus-Paper: [DEBUG] Table printed")))

(defun nexus-paper-library-mark-delete ()
  "Mark the current entry for deletion."
  (interactive)
  (tabulated-list-put-tag "D" t))

(defun nexus-paper-library-unmark ()
  "Unmark the current entry."
  (interactive)
  (tabulated-list-put-tag " " t))

(defun nexus-paper-library-unmark-all ()
  "Unmark all entries."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (tabulated-list-put-tag " ")
      (forward-line 1)))
  (message "All marks cleared"))

(defun nexus-paper-library-execute ()
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
      (when (yes-or-no-p (format "Delete %d item(s) from Graphlit? " (length marked-ids)))
        (dolist (id marked-ids)
          (nexus-paper--delete-from-graphlit id))
        (message "Nexus-Paper: Deleting %d items..." (length marked-ids))
        ;; Refresh after a short delay to allow deletions to complete
        (run-with-timer 2 nil #'nexus-paper-library-refresh)))))

(defun nexus-paper-library-view-details ()
  "View detailed information about the current entry."
  (interactive)
  (let* ((id (tabulated-list-get-id))
         (item (cl-find id nexus-paper--content-list 
                        :key (lambda (x) (cdr (assoc 'id x)))
                        :test #'string=)))
    (if item
        (let ((details (format "Content Details\n%s\n\nID: %s\nName: %s\nCreated: %s\nSize: %s\nState: %s\nType: %s"
                               (make-string 60 ?=)
                               (cdr (assoc 'id item))
                               (cdr (assoc 'name item))
                               (cdr (assoc 'createdDate item))
                               (nexus-paper--format-file-size (or (cdr (assoc 'fileSize item)) 0))
                               (cdr (assoc 'state item))
                               (cdr (assoc '__typename item)))))
          (with-current-buffer (get-buffer-create "*Nexus-Content-Details*")
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert details)
              (goto-char (point-min))
              (view-mode))
            (display-buffer (current-buffer))))
      (message "No details available"))))

;;;###autoload
(defun nexus-paper-manage-content ()
  "Open the Graphlit content management interface."
  (interactive)
  (let ((buf (get-buffer-create "*Nexus-Library*")))
    (with-current-buffer buf
      (nexus-paper-library-mode)
      (nexus-paper-library-refresh))
    (switch-to-buffer buf)))

(provide 'nexus-paper)
;;; nexus-paper.el ends here
