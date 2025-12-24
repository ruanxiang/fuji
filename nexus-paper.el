;;; nexus-paper.el --- AI-Powered Academic Reading Workflow for Emacs -*- lexical-binding: t; -*-

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

(defconst nexus-paper-progress-buffer "*Nexus Progress*")

(defun nexus-paper--log (format-string &rest args)
  "Log a message to the Nexus Progress buffer."
  (let ((msg (apply #'format format-string args))
        (timestamp (format-time-string "[%H:%M:%S] ")))
    (with-current-buffer (get-buffer-create nexus-paper-progress-buffer)
      (let ((inhibit-read-only t))
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
  "Arrange windows in a 3-column layout: PDF | Chat | Progress."
  (delete-other-windows)
  (let* ((width (window-total-width))
         (col-width (/ width 3)))
    ;; Middle column (Chat)
    (let ((chat-win (split-window-horizontally col-width)))
      (set-window-buffer nil pdf-buffer)
      (with-selected-window chat-win
        ;; Right column (Progress)
        (let ((prog-win (split-window-horizontally col-width)))
          (set-window-buffer nil chat-buffer)
          (set-window-buffer prog-win progress-buffer))))))

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
  (let* ((marker-path (read-file-name "Path to Marker (marker_single preferred): " 
                                    (file-name-directory (or nexus-paper-marker-executable ""))
                                    nexus-paper-marker-executable t))
         (bib-path (read-directory-name "Directory for BibTeX files: " 
                                       nexus-paper-bib-path nexus-paper-bib-path t))
         (vis-backend (completing-read "Vision Backend (gptel): " 
                                       '("openai" "gemini" "anthropic" "ollama") 
                                       nil nil (symbol-name (or nexus-paper-gptel-vision-backend 'nil))))
         (vis-model (read-string "Vision Model: " (or nexus-paper-gptel-vision-model "")))
         (org-id (read-string "Graphlit Organization ID: " 
                             (or (plist-get (condition-case nil (nexus-paper--get-auth "graphlit") (error nil)) :user) "")))
         (secret (read-passwd "Graphlit JWT Secret: "))
         (env-id (read-string "Graphlit Environment ID: " (or nexus-paper-graphlit-environment-id "")))
         (cache-dir (read-directory-name "Cache Directory: " (or nexus-paper-cache-directory "")))
         (proxy (read-string "HTTP Proxy (e.g. 127.0.0.1:7890, leave empty for none): " 
                            (or nexus-paper-http-proxy ""))))
    
    (customize-save-variable 'nexus-paper-marker-executable (expand-file-name marker-path))
    (customize-save-variable 'nexus-paper-bib-path (expand-file-name bib-path))
    (customize-save-variable 'nexus-paper-graphlit-environment-id env-id)
    (customize-save-variable 'nexus-paper-cache-directory (expand-file-name cache-dir))
    (unless (string= vis-backend "nil")
      (customize-save-variable 'nexus-paper-gptel-vision-backend (intern vis-backend)))
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
  "Get the current Graphlit MCP connection object."
  (gethash nexus-paper-mcp-server-name mcp-server-connections))

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
                   :GRAPHLIT_ENVIRONMENT_ID ,env-id)
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
  (with-current-buffer (get-buffer-create "*Nexus Health Check*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "Nexus-Paper Health Check (MCP Mode)\n" (make-string 30 ?=) "\n\n")
      
      ;; 1. Marker
      (insert "[Marker]\n")
      (if (and nexus-paper-marker-executable (file-executable-p nexus-paper-marker-executable))
          (insert "  - Executable: OK (" nexus-paper-marker-executable ")\n")
        (insert "  - Executable: FAILED (Check nexus-paper-marker-executable)\n"))
      
      ;; 2. Files
      (insert "\n[Files]\n")
      (if (and nexus-paper-bib-path (file-directory-p nexus-paper-bib-path))
          (insert "  - Bib Directory: OK (" nexus-paper-bib-path ")\n")
        (insert "  - Bib Directory: FAILED (Check nexus-paper-bib-path)\n"))
      
      ;; 3. MCP Server
      (insert "\n[MCP Status]\n")
      (insert "  - Server Name: " nexus-paper-mcp-server-name "\n")
      (if (gethash nexus-paper-mcp-server-name mcp-server-connections)
          (insert "  - Connected: SUCCESS\n")
        (insert "  - Connected: FAILED (Run M-x nexus-paper-configure)\n"))
      
      ;; 4. Graphlit Cloud
      (insert "\n[Graphlit Cloud]\n")
      (if (and nexus-paper-graphlit-environment-id (not (string-empty-p nexus-paper-graphlit-environment-id)))
          (insert "  - Environment ID: OK (" nexus-paper-graphlit-environment-id ")\n")
        (insert "  - Environment ID: MISSING (Run M-x nexus-paper-configure)\n"))
      (condition-case nil
          (let ((auth (nexus-paper--get-auth "graphlit")))
            (if (and (plist-get auth :user) (plist-get auth :secret))
                (insert "  - Credentials: OK (Found in auth-source)\n")
              (insert "  - Credentials: MISSING Organization ID or Secret\n")))
        (error (insert "  - Credentials: NOT FOUND in auth-source (machine 'graphlit')\n")))
      
      ;; 4. Advice
      (insert "\n" (make-string 30 ?-) "\n")
      (insert "Tip: Run M-x nexus-paper-configure to modify settings.\n")
      (insert "Tip: Marker progress is shown in *Nexus Marker Output* during processing.\n"))
    (display-buffer (current-buffer))))

(defun nexus-paper--ensure-config ()
  "Ensure all required settings are configured."
  (nexus-paper-apply-proxy)
  (unless (and nexus-paper-marker-executable
               (file-executable-p nexus-paper-marker-executable)
               nexus-paper-bib-path
               (file-directory-p nexus-paper-bib-path))
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
      (nexus-paper--log "Starting Marker (%s) for %s..." 
                       (file-name-nondirectory (or marker-exe "marker"))
                       (file-name-nondirectory pdf-file))
      (let* ((out-buf (get-buffer-create "*Nexus Marker Output*"))
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
            (insert "Note: The FIRST run may take several minutes as it downloads AI models (~数GB).\n")
            (insert "Command: " (or marker-exe "marker") " " (mapconcat #'identity marker-args " ") "\n")
            (insert (make-string 40 ?-) "\n\n"))
          (display-buffer (current-buffer)))))))

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

(defun nexus-paper--mcp-parse-result (result)
  "Parse the JSON result string from an MCP tool RESULT.
RESULT is expected to be a plist like (:content [(:type \"text\" :text \"...\")])."
  (let* ((content-vecc (plist-get result :content))
         (first-item (and (> (length content-vecc) 0) (aref content-vecc 0)))
         (text-val (and first-item (plist-get first-item :text))))
    (if text-val
        (condition-case nil
            (json-read-from-string text-val)
          (error nil))
      nil)))

(defun nexus-paper--ingest-to-graphlit (text filename callback)
  "Ingest TEXT into Graphlit with FILENAME via MCP, then call CALLBACK with content ID."
  (nexus-paper--ensure-config)
  (nexus-paper--log "[STEP 2/3] Ingesting content via MCP tool 'ingestText'...")
  (let ((conn (nexus-paper--get-mcp-connection)))
    (if (not conn)
        (error "Nexus-Paper: MCP server not connected. Run M-x nexus-paper-configure")
      (condition-case err
          (mcp-async-call-tool conn "ingestText"
                               `((text . ,text)
                                 (name . ,filename)
                                 (type . "Markdown"))
                               (lambda (result)
                                 (let* ((parsed (nexus-paper--mcp-parse-result result))
                                        (content-id (and parsed (cdr (assoc 'id parsed)))))
                                   (if content-id
                                       (progn
                                         (nexus-paper--log "[SUCCESS] Ingestion completed. Content ID: %s" content-id)
                                         (funcall callback content-id))
                                     (let ((err-msg (format "MCP Ingestion failed to return ID: %s" result)))
                                       (nexus-paper--log "[FAILURE] %s" err-msg)
                                       (error "Nexus-Paper: %s" err-msg)))))
                               (lambda (err)
                                 (let ((err-msg (format "MCP tool call error: %s" (error-message-string err))))
                                   (nexus-paper--log "[FAILURE] %s" err-msg)
                                   (error "Nexus-Paper: %s" err-msg))))
        (error
         (let ((err-msg (format "MCP tool session error: %s" (error-message-string err))))
           (nexus-paper--log "[FAILURE] %s" err-msg)
           (error "Nexus-Paper: %s" err-msg)))))))

(defvar-local nexus-paper--content-id nil "Graphlit content ID for the current paper.")
(defvar-local nexus-paper--filename nil "Filename of the current paper.")
(defvar-local nexus-paper--conversation-id nil "Graphlit conversation ID for the current session.")
(defvar-local nexus-paper--results-dir nil "Directory containing Marker results.")

(defun nexus-paper--query-graphlit (prompt callback)
  "Send PROMPT to Graphlit for RAG via MCP and call CALLBACK with the answer."
  (let* ((conn (nexus-paper--get-mcp-connection))
         ;; Add paper name context to help RAG since contentIds might be ignored by MCP tool
         (paper-name (or (bound-and-true-p nexus-paper--filename) "this paper"))
         (paper-context (format "[Context: Discussion about \"%s\"] " paper-name))
         (full-prompt (concat paper-context prompt)))
    (if (not conn)
        (error "Nexus-Paper: MCP server not connected")
      (nexus-paper--log "Querying Graphlit RAG (Conversation: %s)..." 
                        (or nexus-paper--conversation-id "New"))
      (condition-case err
          (mcp-async-call-tool conn "promptConversation"
                               `((prompt . ,full-prompt)
                                 ,@(when nexus-paper--conversation-id
                                     `((conversationId . ,nexus-paper--conversation-id))))
                               (lambda (result)
                                 (let* ((parsed (nexus-paper--mcp-parse-result result))
                                        (answer (and parsed (cdr (assoc 'answer parsed))))
                                        (conv-id (and parsed (cdr (assoc 'id parsed)))))
                                   (if answer
                                       (progn
                                         ;; Save conversation ID for continuity
                                         (when conv-id
                                           (setq nexus-paper--conversation-id conv-id))
                                         (funcall callback answer))
                                     (let ((err-msg (format "MCP Query failed to return answer: %s" result)))
                                       (nexus-paper--log "[FAILURE] %s" err-msg)
                                       (error "Nexus-Paper: %s" err-msg)))))
                               (lambda (err)
                                 (let ((err-msg (format "MCP tool call error: %s" (error-message-string err))))
                                   (nexus-paper--log "[FAILURE] %s" err-msg)
                                   (error "Nexus-Paper: %s" err-msg))))
        (error
         (let ((err-msg (format "MCP tool session error: %s" (error-message-string err))))
           (nexus-paper--log "[FAILURE] %s" err-msg)
           (error "Nexus-Paper: %s" err-msg)))))))

;;; gptel Integration

(defun nexus-paper--detect-visual-query (prompt)
  "Return figure ID if PROMPT is a visual query, nil otherwise."
  (when (string-match "\\(figure\\|fig\\|table\\|chart\\|diagram\\)\\s-+\\([0-9]+\\)" (downcase prompt))
    (match-string 2 (downcase prompt))))

(defun nexus-paper-gptel-request (params callback)
  "Custom request function for gptel.
Intercepts PROMPT and routes to Graphlit or Vision model."
  (let* ((prompt (plist-get params :prompt))
         (figure-id (nexus-paper--detect-visual-query prompt)))
    (if figure-id
        (nexus-paper--handle-visual-query figure-id prompt callback)
      (nexus-paper--query-graphlit prompt callback))))

(defun nexus-paper--handle-visual-query (figure-id prompt callback)
  "Handle a visual query for FIGURE-ID."
  (message "Nexus-Paper: Handling visual query for Figure %s" figure-id)
  ;; 1. Query Graphlit for caption
  (nexus-paper--query-graphlit (format "What is the caption and context for Figure %s?" figure-id)
                               (lambda (caption)
                                 ;; 2. Find image
                                 (let ((image-file (expand-file-name (format "figure-%s.png" figure-id)
                                                                     (expand-file-name "assets" nexus-paper--results-dir))))
                                   (if (file-exists-p image-file)
                                       (progn
                                         (message "Nexus-Paper: Found image %s. Calling Vision API..." image-file)
                                         ;; 3. Call Vision API (using gptel or direct)
                                         ;; For now, let's assume we use a configured gptel-model for vision
                                         (nexus-paper--call-vision-api image-file caption prompt callback))
                                     (error "Figure image not found: %s" image-file))))))

(defun nexus-paper--call-vision-api (image-file caption prompt callback)
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
    
    ;; Use gptel-request with context if supported, 
    ;; but for now, we'll use a direct gptel-request call.
    ;; Note: Real multimodal support in gptel involves gptel-context--alist.
    (gptel-request 
     vision-prompt
     :callback (lambda (response _info) (funcall callback response))
     :context (list image-file)
     :backend backend
     :model model)))

(defun nexus-paper--cleanup-session ()
  "Prompt to delete Graphlit content on buffer kill."
  (when (and nexus-paper--content-id
             (y-or-n-p "Nexus-Paper: Delete paper content from Graphlit to save quota? "))
    (message "Nexus-Paper: Deleting content %s..." nexus-paper--content-id)
    (nexus-paper--delete-from-graphlit nexus-paper--content-id)))

(defun nexus-paper--delete-from-graphlit (content-id)
  "Delete CONTENT-ID from Graphlit via MCP."
  (nexus-paper--log "Deleting content %s via MCP tool 'deleteContent'..." content-id)
  (let ((conn (nexus-paper--get-mcp-connection)))
    (when conn
      (condition-case err
          (mcp-async-call-tool conn "deleteContent"
                               `((id . ,content-id))
                               (lambda (result)
                                 (let* ((parsed (nexus-paper--mcp-parse-result result))
                                        (id (and parsed (cdr (assoc 'id parsed)))))
                                   (nexus-paper--log "[SUCCESS] Content deleted: %s" id)))
                               (lambda (err)
                                 (nexus-paper--log "[FAILURE] Delete failed: %s" (error-message-string err))))
        (error
         (nexus-paper--log "[FAILURE] Delete session error: %s" (error-message-string err)))))))


(defun nexus-paper--setup-buffer-header (filename content-id)
  "Set up a header for the chat buffer for FILENAME."
  (let ((header (format "Nexus-Paper | File: %s | Graphlit ID: %s | Model: %s\n%s\n"
                        filename content-id gptel-model (make-string 60 ?-))))
    (save-excursion
      (goto-char (point-min))
      (insert header))))

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
        (erase-buffer)
        (insert "Nexus-Paper Progress: " filename "\n" (make-string 40 ?-) "\n\n")
        (setq-local cursor-type nil)
        (view-mode 1)))
    
    (with-current-buffer chat-buffer
      (let ((inhibit-read-only t))
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
                md-content filename
                (lambda (content-id)
                  (nexus-paper--log "[STEP 3/3] Ingestion complete (ID: %s). Finalizing chat..." content-id)
                  (with-current-buffer chat-buffer
                    (let ((inhibit-read-only t)) (erase-buffer))
                    (org-mode)
                    (gptel-mode)
                    (setq-local nexus-paper--content-id content-id)
                    (setq-local nexus-paper--filename filename)
                    (setq-local nexus-paper--results-dir results-dir)
                    (setq-local gptel-backend 
                                (gptel-make-generic "Nexus-Graphlit"
                                  :request-func 'nexus-paper-gptel-request
                                  :stream nil))
                    (setq-local gptel-model "Graphlit-RAG")
                    (nexus-paper--setup-buffer-header filename content-id)
                    (add-hook 'kill-buffer-hook #'nexus-paper--cleanup-session nil t)
                    (nexus-paper--log "[SUCCESS] Chat initialization complete. Ready!")
                    (goto-char (point-max)))))))))

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

(provide 'nexus-paper)
;;; nexus-paper.el ends here
