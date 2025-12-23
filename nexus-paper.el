;;; nexus-paper.el --- AI-Powered Academic Reading Workflow for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025 ruanxiang
;; Author: ruanxiang
;; Version: 0.1
;; Package-Requires: ((emacs "29.1") (gptel "0.1") (org-ref "3.0"))
;; Keywords: hypermedia, docs, multimedia
;; URL: https://github.com/ruanxiang/Nexus-Paper

;; License: MIT

;;; Commentary:

;; Nexus-Paper is a high-fidelity, multimodal research assistant.
;; It orchestrates Marker for PDF parsing, Graphlit for RAG,
;; and gptel for interaction.

;;; Code:

(require 'cl-lib)
(require 'auth-source)
(require 'url)
(require 'json)

(defconst nexus-paper-graphlit-url "https://data-scus.graphlit.io/api/v1/graphql")

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
         (secret (read-passwd "Graphlit Secret Key: "))
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
    
    (setq nexus-paper--token nil)
    (nexus-paper-apply-proxy)
    (message "Nexus-Paper: Configuration updated and saved.")))

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
(defvar nexus-paper--token nil "Cached Graphlit JWT token.")

(defun nexus-paper--get-token (callback)
  "Get Graphlit JWT token by generating it locally and call CALLBACK with it."
  (if nexus-paper--token
      (funcall callback nexus-paper--token)
    (let* ((auth (nexus-paper--get-auth "graphlit"))
           (env-id nexus-paper-graphlit-environment-id)
           (org-id (plist-get auth :user))
           (secret (plist-get auth :secret))
           (script-path (expand-file-name "nexus-paper-gen-token.py" 
                                        (file-name-directory "/home/ruan/Repositories/EmacsPaperreadingWorkflowAtGithub/nexus-paper.el")))
           (python-exec (file-name-directory (expand-file-name nexus-paper-marker-executable)))
           ;; Try to use the same venv as marker
           (cmd (format "%s/python %s %s %s %s" 
                        python-exec script-path org-id env-id secret)))
      
      (unless (and env-id (not (string-empty-p env-id)))
        (error "Graphlit Environment ID is not set. Run M-x nexus-paper-configure"))
      
      (message "Nexus-Paper: Generating local JWT token...")
      (let ((token (string-trim (shell-command-to-string cmd))))
        (if (and token (not (string-prefix-p "Error" token)))
            (progn
              (setq nexus-paper--token token)
              (funcall callback token))
          (error "Nexus-Paper: Local token generation failed: %s" token))))))


(defun nexus-paper-check-health ()
  "Check the health of the Nexus-Paper environment."
  (interactive)
  (with-current-buffer (get-buffer-create "*Nexus Health Check*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "Nexus-Paper Health Check\n" (make-string 30 ?=) "\n\n")
      
      ;; 1. Marker
      (insert "[Marker]\n")
      (if (and nexus-paper-marker-executable (file-executable-p nexus-paper-marker-executable))
          (insert "  - Executable: OK (" nexus-paper-marker-executable ")\n")
        (insert "  - Executable: FAILED (Check nexus-paper-marker-executable)\n"))
      
      ;; 2. Bib Path
      (insert "\n[Files]\n")
      (if (and nexus-paper-bib-path (file-directory-p nexus-paper-bib-path))
          (insert "  - Bib Directory: OK (" nexus-paper-bib-path ")\n")
        (insert "  - Bib Directory: FAILED (Check nexus-paper-bib-path)\n"))
      
      ;; 3. Proxy
      (insert "\n[Network]\n")
      (if nexus-paper-http-proxy
          (insert "  - Proxy Setting: OK (" nexus-paper-http-proxy ")\n")
        (insert "  - Proxy Setting: NOT SET (Direct connection)\n"))
      (insert "  - url-proxy-services: " (prin1-to-string url-proxy-services) "\n")
      
      ;; 4. Real-time Connectivity Test
      (insert "  - Connectivity Test: Testing...")
      (condition-case err
          (nexus-paper--get-token
           (lambda (token)
             (save-excursion
               (with-current-buffer (get-buffer "*Nexus Health Check*")
                 (let ((inhibit-read-only t))
                   (goto-char (point-min))
                   (when (re-search-forward "Connectivity Test: Testing..." nil t)
                     (replace-match "Connectivity Test: SUCCESS (Local JWT Generation)")))))))
        (error
         (insert (format "FAILED (%s)\n    [!] Tip: Ensure 'pyjwt' is installed in your marker venv." 
                         (error-message-string err)))))
      (insert "\n")
      
      ;; 5. Graphlit Credentials
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
      (insert "Tip: Check *Nexus Marker Output* if parsing fails.\n"))
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
      
      (message "Nexus-Paper: Starting Marker (%s) for %s..." 
               (file-name-nondirectory (or marker-exe "marker"))
               (file-name-nondirectory pdf-file))
      (let ((process (apply #'start-process "nexus-marker" "*Nexus Marker Output*"
                            (or marker-exe "marker") marker-args)))
        (set-process-sentinel
         process
         (lambda (proc event)
           (when (memq (process-status proc) '(exit signal))
             (let ((exit-status (process-exit-status proc)))
               (if (zerop exit-status)
                   (let ((final-md (nexus-paper--find-marker-output cache-dir)))
                     (if final-md
                         (progn
                           (message "Nexus-Paper: Marker finished successfully.")
                           (funcall callback final-md))
                       (with-current-buffer (get-buffer-create "*Nexus Marker Output*")
                         (display-buffer (current-buffer))
                         (error "Nexus-Paper: Marker finished but no .md file found in %s" cache-dir))))
                 (with-current-buffer (get-buffer-create "*Nexus Marker Output*")
                   (display-buffer (current-buffer))
                   (error "Nexus-Paper: Marker failed (%d): %s. Check output for details." exit-status event))))))))))

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

(defun nexus-paper--ingest-to-graphlit (text filename callback)
  "Ingest TEXT into Graphlit with FILENAME, then call CALLBACK with content ID."
  (nexus-paper--get-token
   (lambda (token)
     (let* ((mutation "mutation IngestText($text: String!, $name: String!) {
  ingestText(text: $text, name: $name, isMarkdown: true) {
    id
  }
}")
            (variables (list :text text :name filename))
            (url-request-method "POST")
            (url-request-extra-headers `(("Content-Type" . "application/json")
                                         ("Authorization" . ,(concat "Bearer " token))))
            (url-request-data (json-encode (list :query mutation :variables variables))))
       (message "Nexus-Paper: Ingesting content to Graphlit...")
       (let ((url-retrieve-timeout 30)) ; 30 seconds for ingestion
         (url-retrieve nexus-paper-graphlit-url
                       (lambda (status)
                         (let ((err (plist-get status :error)))
                           (if err
                               (error "Nexus-Paper: Ingestion failed (network): %s" (cdr err))
                             (goto-char (point-min))
                             (if (not (re-search-forward "HTTP/.* 200" nil t))
                                 (error "Nexus-Paper: Ingestion failed (HTTP error). Check *Messages* for raw response.")
                               (goto-char (point-min))
                               (if (re-search-forward "^$" nil t)
                                   (let* ((json-object-type 'plist)
                                          (resp (condition-case err-json
                                                    (json-read)
                                                  (error 
                                                   (message "Nexus-Paper: JSON Parse Error: %s" (error-message-string err-json))
                                                   (message "Nexus-Paper: Raw Response: %s" (buffer-string))
                                                   nil)))
                                          (content-id (when resp (plist-get (plist-get (plist-get resp :data) :ingestText) :id))))
                                     (if content-id
                                         (funcall callback content-id)
                                       (error "Nexus-Paper: Ingestion failed: %s" (if resp (json-encode resp) "Invalid JSON"))))
                                 (error "Nexus-Paper: Ingestion failed (no body)"))))))))))

(defvar-local nexus-paper--content-id nil "Graphlit content ID for the current paper.")
(defvar-local nexus-paper--results-dir nil "Directory containing Marker results.")

(defun nexus-paper--query-graphlit (prompt callback)
  "Send PROMPT to Graphlit for RAG and call CALLBACK with the answer."
  (nexus-paper--get-token
   (lambda (token)
     (let* ((query "query Prompt($prompt: String!, $contentIds: [ID!]) {
  prompt(prompt: $prompt, contentIds: $contentIds) {
    answer
  }
}")
            (variables (list :prompt prompt :contentIds (list nexus-paper--content-id)))
            (url-request-method "POST")
            (url-request-extra-headers `(("Content-Type" . "application/json")
                                         ("Authorization" . ,(concat "Bearer " token))))
            (url-request-data (json-encode (list :query query :variables variables))))
       (message "Nexus-Paper: Querying Graphlit RAG...")
       (let ((url-retrieve-timeout 20)) ; 20 seconds for query
         (url-retrieve nexus-paper-graphlit-url
                       (lambda (status)
                         (let ((err (plist-get status :error)))
                           (if err
                               (error "Nexus-Paper: Query failed (network): %s" (cdr err))
                             (goto-char (point-min))
                             (if (not (re-search-forward "HTTP/.* 200" nil t))
                                 (error "Nexus-Paper: Query failed (HTTP error). Check *Messages* for raw response.")
                               (goto-char (point-min))
                               (if (re-search-forward "^$" nil t)
                                   (let* ((json-object-type 'plist)
                                          (resp (condition-case err-json
                                                    (json-read)
                                                  (error 
                                                   (message "Nexus-Paper: JSON Parse Error: %s" (error-message-string err-json))
                                                   (message "Nexus-Paper: Raw Response: %s" (buffer-string))
                                                   nil)))
                                          (answer (when resp (plist-get (plist-get (plist-get resp :data) :prompt) :answer))))
                                     (if answer
                                         (funcall callback answer)
                                       (error "Nexus-Paper: Query failed: %s" (if resp (json-encode resp) "Invalid JSON"))))
                                 (error "Nexus-Paper: Query failed (no body)"))))))))))

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
  "Delete CONTENT-ID from Graphlit."
  (nexus-paper--get-token
   (lambda (token)
     (let* ((mutation "mutation DeleteContent($id: ID!) {
  deleteContent(id: $id) {
    id
  }
}")
            (variables (list :id content-id))
            (url-request-method "POST")
            (url-request-extra-headers `(("Content-Type" . "application/json")
                                         ("Authorization" . ,(concat "Bearer " token))))
            (url-request-data (json-encode (list :query mutation :variables variables))))
       (url-retrieve nexus-paper-graphlit-url
                     (lambda (status)
                       (let ((err (plist-get status :error)))
                         (if err
                             (message "Nexus-Paper: Delete failed (network): %s" (cdr err))
                           (goto-char (point-min))
                           (if (re-search-forward "^$" nil t)
                               (let* ((json-object-type 'plist)
                                      (resp (condition-case nil
                                                (json-read)
                                              (error nil))))
                                 (if (plist-get (plist-get resp :data) :deleteContent)
                                     (message "Nexus-Paper: Content deleted from Graphlit.")
                                   (message "Nexus-Paper: Delete failed: %s" (json-encode resp))))
                             (message "Nexus-Paper: Delete failed (no body)"))))))))))

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
  
  (let ((pdf-file (nexus-paper--select-pdf)))
    (nexus-paper--process-pdf-with-marker
     pdf-file
     (lambda (md-file)
       (let* ((results-dir (file-name-directory md-file))
              (filename (file-name-nondirectory pdf-file))
              (md-content (with-temp-buffer
                            (insert-file-contents md-file)
                            (buffer-string))))
         (message "Nexus-Paper: Ingesting to Graphlit...")
         (nexus-paper--ingest-to-graphlit
          md-content filename
          (lambda (content-id)
            (message "Nexus-Paper: Ingested (ID: %s). Initializing chat..." content-id)
            (let ((chat-buffer (get-buffer-create (format "*Nexus-Chat: %s*" filename))))
              (with-current-buffer chat-buffer
                (gptel-mode)
                (setq-local nexus-paper--content-id content-id)
                (setq-local nexus-paper--results-dir results-dir)
                ;; Setup gptel locally for this buffer
                (setq-local gptel-backend 
                            (gptel-make-generic "Nexus-Graphlit"
                              :request-func 'nexus-paper-gptel-request
                              :stream nil))
                (setq-local gptel-model "Graphlit-RAG")
                
                (nexus-paper--setup-buffer-header filename content-id)
                
                ;; Add cleanup hook
                (add-hook 'kill-buffer-hook #'nexus-paper--cleanup-session nil t)
                
                (display-buffer chat-buffer)
                (goto-char (point-max))
                (message "Nexus-Paper: Chat ready for %s" filename))))))))))

(provide 'nexus-paper)
;;; nexus-paper.el ends here
)))))
