;;; fuji-bib.el --- BibTeX integration for Fuji -*- lexical-binding: t; -*-

;;; Commentary:
;; Handlers for BibTeX metadata integration using Org-Ref.

;;; Code:

(require 'bibtex)
(require 'cl-lib)

(defgroup fuji-bib nil
  "BibTeX integration settings for Fuji."
  :group 'fuji)

(defun fuji-add-bibtex-entry-from-doi (doi &optional pdf-file)
  "Add BibTeX entry for DOI to `fuji-bibtex-file'.
If PDF-FILE is provided, associate it with the entry.
Returns the BibTeX key if successful, nil otherwise."
  (interactive
   (let ((doi (read-string "DOI: "))
         (pdf (or (and (bound-and-true-p fuji--pdf-buffer)
                       (buffer-live-p fuji--pdf-buffer)
                       (buffer-file-name fuji--pdf-buffer))
                  (and buffer-file-name (string-match-p "\\.pdf$" buffer-file-name) buffer-file-name)
                  (and (bound-and-true-p fuji--original-path) fuji--original-path)
                  (and (bound-and-true-p fuji--content-id)
                       (fboundp 'fuji--get-metadata-for-id)
                       (cdr (assoc 'original_path (fuji--get-metadata-for-id fuji--content-id)))))))
     (list doi pdf)))

  (unless (and (bound-and-true-p fuji-bibtex-file)
               (file-exists-p fuji-bibtex-file))
    (user-error "Fuji: BibTeX file not configured. Run M-x fuji-configure"))
  
  (unless (featurep 'doi-utils)
    (user-error "Fuji: org-ref (doi-utils) is required for this feature"))

  ;; Ensure we have the full path for doi-utils
  (let* ((bibtex-file fuji-bibtex-file)
         (org-ref-default-bibliography (list fuji-bibtex-file))
         (bibtex-completion-bibliography (list fuji-bibtex-file)))

    (let* ((clean-doi (cond
                       ((string-match-p "^http" doi) doi) ;; Assuming URL is fine
                       ((string-match-p "^10\\." doi) doi) ;; Standard DOI
                       ((string-match-p "^arXiv:" doi)    ;; ArXiv ID
                        (format "10.48550/arXiv.%s" (substring doi 6)))
                       (t (replace-regexp-in-string "^doi:" "" (replace-regexp-in-string "^https?://doi.org/" "" doi)))))
           (url (concat "http://dx.doi.org/" clean-doi)))

      (condition-case err
          (let ((bibtex-string 
                 (condition-case doi-err
                     (doi-utils-doi-to-bibtex-string clean-doi)
                   (json-readtable-error 
                    (error "DOI lookup returned invalid JSON (likely HTML error page). URL: %s" url))
                   (error (signal (car doi-err) (cdr doi-err)))))
                (key nil)
                (final-entry-string nil))

            (unless bibtex-string
              (error "No BibTeX data returned for DOI"))

            ;; Debug Logging
            (message "DEBUG: Raw BibTeX received: %s" bibtex-string)

            ;; 1. Prepare Entry (Regex Only - Avoiding fragile BibTeX mode in temp buffer)
            (with-temp-buffer
              (insert bibtex-string)
              (goto-char (point-min))
              
              ;; Parse Key robustly: @type { KEY,
              ;; Relaxed Regex: Allow empty key (group 1 can be empty)
              (when (re-search-forward "@[a-zA-Z]+[ \t\n]*{[ \t\n]*\\([^,]*\\)," nil t)
                (setq key (string-trim (match-string 1))))

              ;; Handle Empty Key (automagically generate from DOI if missing)
              ;; Example: @article{, -> @article{10.1234_MyDoi,
              (when (or (not key) (string-empty-p key))
                 (message "DEBUG: Key is empty, generating from DOI: %s" clean-doi)
                 (let ((gen-key (replace-regexp-in-string "[/:]" "_" clean-doi))) 
                    ;; Go back and insert the new key
                    (goto-char (point-min))
                    (when (re-search-forward "@[a-zA-Z]+[ \t\n]*{[ \t\n]*\\(,\\)" nil t)
                        (replace-match (format "%s," gen-key) t t nil 1))
                    (setq key gen-key)))

              (unless (and key (not (string-empty-p key)))
                 (error "Could not extract or generate Key from BibTeX data"))

              ;; Inject File Field via String Manipulation
              (when (and pdf-file (not (string-empty-p pdf-file)))
                 (goto-char (point-max))
                 ;; Find last closing brace
                 (if (search-backward "}" nil t)
                     (progn
                       (replace-match "")
                       (insert (format ",\n  file = {%s}\n}" (expand-file-name pdf-file))))
                   (insert (format ",\n  file = {%s}\n}" (expand-file-name pdf-file)))))
              
              (setq final-entry-string (buffer-string)))

            ;; 2. Main Buffer Operation: Safe Duplicate Replacement (PURE TEXT IO)
            ;; We read to a temp buffer, modify, and write back. 
            ;; We do NOT visit the file, avoiding buffer/mode contamination.
            (with-temp-buffer
              (insert-file-contents fuji-bibtex-file)
              
              (message "DEBUG: Fuji-Bib: Processing entry '%s' (IO-Safe Mode)" key)

              ;; Delete via Regex + Manual Brace Counting
              (let ((case-fold-search t)
                    (key-regex (format "^[ \t]*@[a-zA-Z]+[ \t\n]*{[ \t\n]*%s[ \t\n]*," (regexp-quote key))))
                (goto-char (point-min))
                (while (re-search-forward key-regex nil t)
                    (message "DEBUG: Found duplicate %s, deleting..." key)
                    (beginning-of-line)
                    (let ((beg (point)))
                      ;; Try safe navigation over parsing
                      (condition-case nil
                          (forward-list 1) ;; Jump over valid @entry{...}
                        (error 
                         (message "DEBUG: forward-list failed, trying bibtex-end-of-entry")
                         (ignore-errors (bibtex-end-of-entry))))
                      (delete-region beg (point)))))

              ;; Append New
              (goto-char (point-max))
              (unless (bolp) (insert "\n"))
              (insert "\n" final-entry-string)
              
              ;; Write back to file without triggering hooks
              (write-region (point-min) (point-max) fuji-bibtex-file nil 'silent))

            ;; 3. Update UI (Outside context)
            ;; Wrap in ignore-errors because metadata refresh might trigger
            ;; fragile BibTeX parsing (dialect errors), but the file IS saved.
            (ignore-errors
              (when (derived-mode-p 'org-mode)
                 (when (fboundp 'fuji--set-bib-key-in-session)
                    (fuji--set-bib-key-in-session key))
                 (when (fboundp 'fuji--refresh-chat-metadata)
                    (fuji--refresh-chat-metadata))))

            (message "Fuji: Successfully added/updated DOI entry for '%s'" key)
            key)
        (error 
         (message "Fuji: Failed to add DOI: %s" (error-message-string err))
         nil)))))

(defun fuji--set-bib-key-in-session (key)
  "Add #+FUJI_BIB_KEY: KEY to the current session buffer header."
  (message "DEBUG: set-bib-key-in-session executing for key: %s in buffer: %s" key (current-buffer))
  (save-excursion
    (goto-char (point-min))
    ;; Check if existing key exists
    (if (re-search-forward "^#\\+FUJI_BIB_KEY:.*$" nil t)
        (progn
          (message "DEBUG: Found existing key, replacing.")
          (replace-match (format "#+FUJI_BIB_KEY: %s" key)))
      ;; Insert after TITLE or at top
      (if (re-search-forward "^#\\+TITLE:.*$" nil t)
          (progn
            (message "DEBUG: Found TITLE, inserting after.")
            (forward-line 1)
            (insert (format "#+FUJI_BIB_KEY: %s\n" key)))
        (message "DEBUG: No TITLE found, inserting at top.")
        (insert (format "#+FUJI_BIB_KEY: %s\n" key))))
    (message "DEBUG: set-bib-key-in-session modified buffer.")))

(defun fuji-remove-bibtex-entry (key)
  "Remove the BibTeX entry with KEY from `fuji-bibtex-file`.
Uses safe IO (insert-file-contents + write-region) to avoid mode conflicts."
  (when (and key (bound-and-true-p fuji-bibtex-file) (file-exists-p fuji-bibtex-file))
    (let ((found nil))
      (with-temp-buffer
        (insert-file-contents fuji-bibtex-file)
        (goto-char (point-min))
        (let ((case-fold-search t)
              (key-regex (format "^[ \t]*@[a-zA-Z]+[ \t\n]*{[ \t\n]*%s[ \t\n]*," (regexp-quote key))))
          (while (re-search-forward key-regex nil t)
            (setq found t)
            (beginning-of-line)
            (let ((beg (point)))
              (condition-case nil
                  (forward-list 1)
                (error (ignore-errors (bibtex-end-of-entry))))
              (delete-region beg (point)))))
        (when found
          (write-region (point-min) (point-max) fuji-bibtex-file nil 'silent)
          (message "Fuji: Deleted BibTeX entry '%s'" key)
          t)))))

(defun fuji-get-bibtex-entry-direct (key)
  "Directly parse BibTeX entry for KEY from `fuji-bibtex-file` using Regex.
Returns an alist of fields (keys as strings)."
  (when (and key (bound-and-true-p fuji-bibtex-file) (file-exists-p fuji-bibtex-file))
    (with-temp-buffer
      (insert-file-contents fuji-bibtex-file)
      (let ((case-fold-search t)
            (key-regex (format "^[ \t]*@[a-zA-Z]+[ \t\n]*{[ \t\n]*%s[ \t\n]*," (regexp-quote key)))
            (fields nil))
        (goto-char (point-min))
        (when (re-search-forward key-regex nil t)
          (let ((entry-start (match-beginning 0))
                (entry-end (save-excursion 
                             (goto-char (match-beginning 0))
                             (condition-case nil (forward-list 1) (error nil))
                             (point))))
            (when (> entry-end entry-start)
              (goto-char entry-start)
              ;; Simple naive parser for field = {value} or "value"
              ;; We limit search to entry bounds
              (while (re-search-forward "\\([a-zA-Z0-9-]+\\)[ \t]*=[ \t]*[\"{]\\([^\"}]*\\)[\"}]" entry-end t)
                (push (cons (match-string 1) (match-string 2)) fields)))))
        fields))))

(provide 'fuji-bib)
;;; fuji-bib.el ends here
