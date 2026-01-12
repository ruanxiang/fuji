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
  
  (let* ((doc-file (fuji--select-document))
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
                  (fuji--add-metadata-entry content-id filename doc-file)
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
                        (select-window win))))))))

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
