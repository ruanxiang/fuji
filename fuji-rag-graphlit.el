;;; fuji-rag-graphlit.el --- Graphlit MCP RAG Backend Plugin -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Ruan Xiang

;; Author: Ruan Xiang
;; Keywords: rag, graphlit, mcp
;; Version: 0.8.0

;;; Commentary:

;; This file implements the Graphlit MCP RAG backend plugin for Fuji.
;; It wraps the existing Graphlit MCP functionality into the unified RAG API.

;;; Code:

(require 'fuji-rag)
(require 'mcp nil t)
(require 'json)

;;; Configuration

(defvar fuji-mcp-server-name "graphlit"
  "Name of the Graphlit MCP server connection.")

;;; Helper Functions

(defun fuji--graphlit-get-connection ()
  "Get the current Graphlit MCP connection object.
Returns nil if not connected."
  (gethash fuji-mcp-server-name mcp-server-connections))

(defun fuji--graphlit-normalize-string (s)
  "Ensure S is a multibyte string."
  (if (and s (stringp s))
      (if (multibyte-string-p s) s (decode-coding-string s 'utf-8))
    ""))

(defun fuji--graphlit-parse-result (result)
  "Parse the JSON result string from an MCP tool RESULT.
Handles various formats of RESULT (plists, hash-tables, symbols)."
  (let* ((content (or (plist-get result :content)
                      (and (hash-table-p result) (gethash "content" result))
                      (and (vectorp result) result)))
         (first-item (when (and content (> (length content) 0))
                       (aref content 0)))
         (text-val (fuji--graphlit-normalize-string
                    (or (plist-get first-item :text)
                        (and (hash-table-p first-item) (gethash "text" first-item))))))
    (if (or (string-empty-p text-val) (string= text-val "null"))
        (progn
          (message "Fuji: Graphlit result text is empty or null.")
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
         (message "Fuji: Graphlit JSON parse error: %S" text-val)
         `((answer . ,text-val) (message . ,text-val)))))))

;;; RAG Backend Implementation

(defun fuji--graphlit-available-p ()
  "Check if Graphlit backend is available and configured."
  (and (featurep 'mcp)
       (fuji--graphlit-get-connection)
       t))

(defun fuji--graphlit-ingest (text filename metadata callback)
  "Ingest TEXT with FILENAME and METADATA to Graphlit.
METADATA should be an alist. CALLBACK is called with content-id on success."
  (let ((conn (fuji--graphlit-get-connection)))
    (unless conn
      (error "Graphlit MCP connection not available"))
    
    (message "Fuji: Ingesting to Graphlit... (len: %d chars)" (length text))
    
    (let* ((timer nil)
           (success-cb (lambda (result)
                        (when timer (cancel-timer timer))
                        (let* ((parsed (fuji--graphlit-parse-result result))
                               (content-id (and parsed (cdr (assoc 'id parsed)))))
                          (if content-id
                              (progn
                                (message "Fuji: Graphlit ingestion complete (ID: %s)" content-id)
                                (funcall callback content-id))
                            (error "Graphlit ingestion failed to return ID: %s" result)))))
           (error-cb (lambda (inner-err)
                       (when timer (cancel-timer timer))
                       (error "Graphlit ingestion error: %s" (error-message-string inner-err)))))
      
      ;; Start watchdog timer
      (setq timer (run-with-timer 60 nil
                                  (lambda ()
                                    (message "Fuji: [WARNING] Graphlit ingestion timeout after 60s"))))
      
      (condition-case outer-err
          (mcp-async-call-tool conn "ingestText"
                               `((text . ,text)
                                 (name . ,filename)
                                 (type . "Markdown"))
                               success-cb
                               error-cb)
        (error
         (when timer (cancel-timer timer))
         (error "Graphlit MCP call error: %s" (error-message-string outer-err)))))))

(defun fuji--graphlit-query (query content-ids callback)
  "Query CONTENT-IDS with QUERY using Graphlit.
CONTENT-IDS can be a single ID or a list of IDs.
CALLBACK is called with the answer string."
  (let ((conn (fuji--graphlit-get-connection)))
    (unless conn
      (error "Graphlit MCP connection not available"))
    
    (message "Fuji: Querying Graphlit...")
    
    ;; Normalize content-ids to vector
    (let ((ids-vector (cond
                       ((null content-ids) [])
                       ((stringp content-ids) (vector content-ids))
                       ((listp content-ids) (vconcat content-ids))
                       ((vectorp content-ids) content-ids)
                       (t []))))
      
      (condition-case outer-err
          (mcp-async-call-tool conn "promptConversation"
                               `((prompt . ,query)
                                 ,@(when (> (length ids-vector) 0)
                                     `((contentIds . ,ids-vector))))
                               (lambda (result)
                                 (let* ((parsed (fuji--graphlit-parse-result result))
                                        (answer (and parsed 
                                                     (or (cdr (assoc 'answer parsed))
                                                         (cdr (assoc 'message parsed))))))
                                   (if answer
                                       (funcall callback answer)
                                     (error "Graphlit query returned no answer: %s" result))))
                               (lambda (inner-err)
                                 (error "Graphlit query error: %s" (error-message-string inner-err))))
        (error
         (error "Graphlit MCP call error: %s" (error-message-string outer-err)))))))

(defun fuji--graphlit-list (callback)
  "List all content in Graphlit.
CALLBACK is called with a list of content items (alists)."
  (let ((conn (fuji--graphlit-get-connection)))
    (unless conn
      (error "Graphlit MCP connection not available"))
    
    (message "Fuji: Listing Graphlit content...")
    
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
       (funcall callback nil)))))

(defun fuji--graphlit-delete (content-id callback)
  "Delete CONTENT-ID from Graphlit.
CALLBACK is called with t on success, nil on failure."
  (let ((conn (fuji--graphlit-get-connection)))
    (unless conn
      (error "Graphlit MCP connection not available"))
    
    (message "Fuji: Deleting from Graphlit (ID: %s)..." content-id)
    
    (condition-case outer-err
        (mcp-async-call-tool conn "deleteContent"
                             `((id . ,content-id))
                             (lambda (result)
                               (let* ((parsed (fuji--graphlit-parse-result result))
                                      (deleted-id (cdr (assoc 'id parsed)))
                                      (state (cdr (assoc 'state parsed))))
                                 (if (and deleted-id (string= state "DELETED"))
                                     (progn
                                       (message "Fuji: Content deleted successfully: %s" deleted-id)
                                       (funcall callback t))
                                   (message "Fuji: Delete operation completed (response: %s)" result)
                                   (funcall callback nil))))
                             (lambda (inner-err)
                               (message "Fuji: Delete failed: %s" (error-message-string inner-err))
                               (funcall callback nil)))
      (error
       (message "Fuji: Delete session error: %s" (error-message-string outer-err))
       (funcall callback nil)))))

(defun fuji--graphlit-get-metadata (content-id)
  "Get metadata for CONTENT-ID from Graphlit.
Returns an alist of metadata key-value pairs.
Note: Graphlit doesn't have a dedicated metadata API, so this returns minimal info."
  ;; Graphlit doesn't expose a direct metadata retrieval API
  ;; We return a minimal structure
  `((id . ,content-id)
    (backend . "graphlit")))

;;; Register Plugin

(fuji-register-rag-backend
 (make-fuji-rag-backend
  :name "graphlit"
  :description "Graphlit cloud RAG via MCP"
  :available-p #'fuji--graphlit-available-p
  :ingest-fn #'fuji--graphlit-ingest
  :query-fn #'fuji--graphlit-query
  :list-fn #'fuji--graphlit-list
  :delete-fn #'fuji--graphlit-delete
  :get-metadata-fn #'fuji--graphlit-get-metadata))

(provide 'fuji-rag-graphlit)

;;; fuji-rag-graphlit.el ends here
