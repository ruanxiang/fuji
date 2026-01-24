;;; fuji-search.el --- Search functionality for Fuji  -*- lexical-binding: t; -*-

;; Author: Ruan
;; Keywords: convenience, tools, research

;;; Commentary:
;; This module handles search functionality for the Fuji library.
;; It includes metadata search, tag search, and (eventually) full-text content search.

;;; Code:

(require 'fuji)

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

(provide 'fuji-search)
;;; fuji-search.el ends here
