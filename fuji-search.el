;;; fuji-search.el --- Search functionality for Fuji  -*- lexical-binding: t; -*-

;; Author: Ruan
;; Keywords: convenience, tools, research

;;; Commentary:
;; This module handles search functionality for the Fuji library.
;; It includes metadata search, tag search, and full-text content search.

;;; Code:

;; (require 'fuji) ;; Circular dependency if loaded from fuji.el, but needed for standalone. 
;; We assume fuji.el loads this file.
(require 'bibtex-completion nil t) ;; Optional dependency

;;; Customization

(defcustom fuji-rg-executable "rg"
  "Path to the ripgrep executable."
  :type 'string
  :group 'fuji)

(defcustom fuji-citation-format "cite:%s"
  "Format string for inserting citations. %s is replaced by the BibTeX key."
  :type 'string
  :group 'fuji)

;;; Tag Search

(defun fuji-search-by-tag ()
  "Search library by selecting tags with auto-completion.
Prompts for one or more tags (separated by comma) and initiating a search using the 't:Tag' syntax."
  (interactive)
  (let* ((all-tags (fuji--get-all-tags))
         (crm-separator "[ \t]*,[ \t]*")
         (selected-tags (completing-read-multiple 
                         "Select Tags to Search: "
                         all-tags
                         nil t))) ;; REQUIRE-MATCH = t (we only want existing tags)
    
    (when selected-tags
      ;; Construct query: "t:Tag1 t:Tag2"
      (let ((query (mapconcat (lambda (tag) (format "t:%s" tag))
                              selected-tags
                              " ")))
        (message "DEBUG: Running search with query: %s" query)
        ;; Call main search command
        (fuji-library-search query)))))

;;; Unified Content Search & Citation

(defun fuji--check-rg ()
  "Check if ripgrep is available."
  (zerop (call-process fuji-rg-executable nil nil nil "--version")))

(defun fuji--get-bibkey-for-id (id)
  "Retrieve BibTeX key for a given ID (filename base).
Checks metadata cache first, then tries to read #+FUJI_BIB_KEY from the file."
  (let* ((metadata (fuji--get-metadata-for-id id))
         ;; 1. Check Metadata Cache
         (key-from-meta (and metadata 
                             (or (alist-get 'bibkey metadata) 
                                 (alist-get 'bibliography_key metadata)))))
    (or key-from-meta
        ;; 2. Fallback: Parse File Header
        (let ((file (expand-file-name (format "%s.md" id) fuji-dir)))
          (when (file-exists-p file)
            (with-temp-buffer
              (insert-file-contents-literally file nil 0 1024) ;; Read first 1KB
              (save-excursion
                (goto-char (point-min))
                (when (re-search-forward "^#\\+FUJI_BIB_KEY: *\\(.*\\)$" nil t)
                  (match-string-no-properties 1)))))))))

(defun fuji--search-content-rg (query)
  "Search content in `fuji-dir` using `rg` for QUERY (fuzzy AND matching).
Returns a list of candidates: (DISPLAY-STRING . KEY)."
  (unless (fuji--check-rg)
    (error "Ripgrep (rg) is not installed or not found in PATH"))
  
  (let* ((default-directory fuji-dir)
         (results '())
         ;; REVISION: User wants fuzzy. We will replace spaces with `.*` to match "transformer ... google" 
         ;; on the SAME LINE. This is the most efficient `rg` behavior.
         (fuzzy-query (replace-regexp-in-string " +" ".*" query))
         
         (args (list "--no-heading" 
                     "--line-number" 
                     "--color=never" 
                     "--max-count=1"
                     "--max-columns=200"
                     "--smart-case"
                     fuzzy-query ;; Use the fuzzy line matcher
                     ".")))
    
    (with-temp-buffer
      (apply #'call-process fuji-rg-executable nil t nil args)
      (goto-char (point-min))
      (while (not (eobp))
        (let* ((line (buffer-substring-no-properties (point-at-bol) (point-at-eol)))
               (parts (split-string line ":" t))
               (filename (car parts))
               (content (mapconcat 'identity (cddr parts) ":")))
          
          (when (and filename (string-match "\\(.*\\)\\.md$" filename))
            (let* ((id (match-string 1 filename))
                   (bib-key (fuji--get-bibkey-for-id id)))
              
              (when bib-key
                (let* ((entry (and (fboundp 'bibtex-completion-get-entry)
                                   (bibtex-completion-get-entry bib-key)))
                       (title (if entry (bibtex-completion-get-value "title" entry) bib-key))
                       (author (if entry (bibtex-completion-get-value "author" entry) "?"))
                       ;; Simplify display: Just Title (Author), no suffix.
                       ;; We want it to look identical to standard BibTeX candidates so they merge nicely.
                       (display-str (format "%s (%s)" 
                                            title 
                                            author)))
                  (push (cons display-str bib-key) results)))))
        (forward-line 1)))
    (nreverse results))))

(defun fuji-insert-citation ()
  "Unified command to search papers and insert citation.
1. Searches BibTeX metadata (fuzzy title/author/tags).
2. Searches full-text content using `rg` (fuzzy line match).
3. FILTERED: Only shows candidates matching query (in content OR metadata)."
  (interactive)
  (let* ((bib-candidates (if (fboundp 'bibtex-completion-candidates)
                             (bibtex-completion-candidates)
                           '()))
         
         ;; STEP 1: Ask for query
         (query (read-string "Search Citation: "))
         
         ;; STEP 2: Content Search (Fuzzy Line Match)
         (content-matches (if (> (length query) 2)
                              (condition-case nil
                                  (fuji--search-content-rg query)
                                (error '()))
                            nil))

         ;; STEP 3: Filter Metadata Candidates
         ;; We filter `bib-candidates` manually (substring match, case insensitive)
         (filtered-bib-candidates 
          (if (> (length query) 0)
              (let* ((terms (split-string query " " t))
                     (case-fold-search t))
                (seq-filter
                 (lambda (cand)
                   ;; cand is either string or (DISPLAY . KEY)
                   (let ((str (if (consp cand) (car cand) cand)))
                     (seq-every-p (lambda (term) 
                                    (string-match-p (regexp-quote term) str))
                                  terms)))
                 bib-candidates))
            bib-candidates))
         
         ;; STEP 4: Merge
         ;; Content matches are ALREADY filtered by rg.
         ;; Append content matches to filtered bib candidates.
         ;; Note: There might be duplicates if a file matches content AND metadata.
         ;; We should ideally deduplicate based on Key.
         (all-candidates (delete-dups (append content-matches filtered-bib-candidates)))
         
         ;; STEP 5: Select
         (selection (completing-read (format "Select Paper ('%s'): " query) 
                                     all-candidates
                                     nil t ;; Require match
                                     nil ;; No initial input needed, list is already filtered.
                                     )))
    
    (when selection
      ;; EXTRACT KEY SAFELY
      (let* ((candidate-data (cdr (assoc selection all-candidates)))
             ;; Check if candidate-data is a pure string (Key) or a Cons Cell/List (Entry)
             ;; In bibtex-completion, it's often the KEY string. 
             ;; But user reported receiving a struct: ((=has-pdf= ...) (=key= ...))
             (key (cond
                   ((stringp candidate-data) candidate-data)
                   ((listp candidate-data)
                    ;; Try to find =key= or fallback to car if it looks like an alist
                    (or (cdr (assoc "=key=" candidate-data))
                        (cdr (assoc 'bibliography_key candidate-data)) ;; Fuji metadata style
                        (alist-get '=key= candidate-data) ;; common bibtex-completion internal
                        ;; Fallback: Maybe it IS the entry alist itself?
                        ;; In `bibtex-completion`, the candidate CDR is the full entry alist.
                        ;; The key is stored in the entry.
                        ;; If standard `bibtex-completion`, the key is often implicit or in =key=.
                        (message "DEBUG: Got list for key: %S" candidate-data)
                        (cdr (assoc "=key=" candidate-data))))
                   (t (format "%s" candidate-data)))))
        
        (if (and key (stringp key))
            (insert (format fuji-citation-format key))
          (message "Fuji: Could not extract valid key from selection."))))))

(provide 'fuji-search)
;;; fuji-search.el ends here
