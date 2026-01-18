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
(require 'cl-lib)

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
  (let* ((content (cond
                   ;; Case 1: Standard MCP Tool Result (plist with :content list)
                   ((and (listp result) (plist-get result :content))
                    (let ((c (plist-get result :content)))
                      (if (vectorp c) (aref c 0) (car c))))
                   ;; Case 2: Direct content object (rare)
                   ((listp result) result)
                   ;; Case 3: Raw
                   (t result)))
         (text-val (cond
                    ((plist-get content :text) (plist-get content :text))
                    ((and (hash-table-p content) (gethash "text" content)) (gethash "text" content))
                    ;; Fallback: try to interpret result itself if it's not a content object
                    ((stringp result) result)
                    (t nil))))
    
    (if (or (null text-val) (string-empty-p text-val) (string= text-val "null"))
        (progn
          ;; For async calls, an empty result is often expected immediately
          ;; Just return nil or a placeholder
          (fuji--log "Graphlit result text is empty (Async ack from %S)" result)
          nil)
      (condition-case err
          (let* ((json-object-type 'alist)
                 (parsed (json-read-from-string text-val)))
             ;; Check if it needs unwrapping "ingestContent"
            (if (assoc 'ingestContent parsed)
                (cdr (assoc 'ingestContent parsed))
              parsed))
        (error 
         (fuji--log "Graphlit JSON parse error: %S" text-val)
         ;; Return raw text as answer if JSON fails
         `((answer . ,text-val)))))))

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
    
    (message "Fuji: Ingesting '%s' to Graphlit... (len: %d chars, approx %.2f KB)" 
             filename (length text) (/ (string-bytes text) 1024.0))

    ;; Verify content integrity
    (condition-case err
        (let ((_ (json-encode text)))
          (message "Fuji: Content integrity verified."))
      (error
       (error "Fuji: Content validation failed: %s" (error-message-string err))))
    
    (let* ((ingest-name (format "%s-%d" filename (floor (float-time))))
           (start-time (float-time))
           (poll-timer nil)
           (poll-count 0)
           (max-polls 60) ; 5 mins (at 5s interval)
           
           (cleanup-fn (lambda ()
                         (when poll-timer (cancel-timer poll-timer))))

           (poll-fn 
            (lambda () 
              (setq poll-count (1+ poll-count))
              (condition-case err
                  (mcp-async-call-tool 
                   conn "queryContents"
                   ;; Graphlit filter syntax: filter content by name
                   `((filter . ((name . ,ingest-name))))
                                   (lambda (result)
                                     (let* ((raw-result (fuji--graphlit-parse-result result))
                                            ;; Normalize: Ensure we have a list of objects, not a single object
                                            (content-list (if (and (listp raw-result)
                                                                   (consp (car raw-result))
                                                                   (symbolp (caar raw-result)))
                                                              ;; It's a single alist ((key . val) ...), wrap it
                                                              (list raw-result)
                                                            raw-result))
                                            (found (cl-some (lambda (item)
                                                              (when (and (listp item)
                                                                         (string= (cdr (assoc 'name item)) ingest-name))
                                                                item))
                                                            content-list))
                                            (content-id (and found (cdr (assoc 'id found)))))
                       (if content-id
                           (progn
                             (message "Fuji: Async ingestion complete (ID: %s). Total time: %.1fs" 
                                      content-id (- (float-time) start-time))
                             (funcall cleanup-fn)
                             (funcall callback content-id))
                         ;; Not found yet, continue polling...
                         (if (> poll-count max-polls)
                             (progn
                               (message "Fuji: Ingestion timed out after %.0fs" (- (float-time) start-time))
                               (funcall cleanup-fn)
                               ;; Optional: call callback with nil or error?
                               ;; Current contract expects ID. Let's error.
                               (error "Graphlit ingestion timed out waiting for ID"))
                           (message "Fuji: Still processing... (%.0fs)" (- (float-time) start-time))))))
                   (lambda (err)
                     (message "Fuji: Polling error (will retry): %s" (error-message-string err))))
                (error 
                 (message "Fuji: Polling internal error: %s" (error-message-string err)))))))

      ;; Initial Ingestion Call
      (condition-case outer-err
          (mcp-async-call-tool 
           conn "ingestText"
           `((text . ,text)
             (name . ,ingest-name)
             (mimeType . "text/markdown")
             (isSynchronous . nil))
           (lambda (result)
             (let* ((parsed (fuji--graphlit-parse-result result))
                    (immediate-id (and parsed (cdr (assoc 'id parsed)))))
               (if immediate-id
                   (progn
                     (message "Fuji: Ingestion complete (Immediate ID: %s)" immediate-id)
                     (funcall callback immediate-id))
                 ;; No immediate ID -> Start Polling
                 (message "Fuji: Async ingestion initiated. Polling for completion...")
                 (setq poll-timer (run-with-timer 2 5 poll-fn)))))
           (lambda (err)
             (error "Graphlit ingestion request failed: %s" (error-message-string err))))
        (error
         (error "Graphlit MCP tool call failed: %s" (error-message-string outer-err)))))))

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
