;;; fuji-rag.el --- RAG Backend Plugin API -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Ruan Xiang

;; Author: Ruan Xiang
;; Keywords: rag, retrieval, plugins
;; Version: 0.8.0

;;; Commentary:

;; This file defines the unified API for RAG (Retrieval-Augmented Generation)
;; backend plugins. It provides:
;; - A base structure for RAG backend plugins
;; - A plugin registry system
;; - Unified RAG operations API (ingest, query, list, delete, get-metadata)
;; - Backend switching support

;;; Code:

(require 'cl-lib)

;;; API Definition

(cl-defstruct fuji-rag-backend
  "Base structure for RAG backend plugins.
Each RAG backend plugin should create an instance of this structure
and register it using `fuji-register-rag-backend'.

Slots:
- name: String identifier (e.g., \"graphlit\", \"local-vector\", \"llamaindex\")
- description: Human-readable description of the backend
- available-p: Function () -> bool, checks if backend is available/configured
- ingest-fn: Function (text filename metadata callback) -> content-id
             Ingest TEXT with FILENAME and METADATA, call CALLBACK with content-id
- query-fn: Function (query content-ids callback) -> results
            Query CONTENT-IDS with QUERY, call CALLBACK with results
- list-fn: Function (callback) -> list of content items
           List all content, call CALLBACK with list of items
- delete-fn: Function (content-id callback) -> success
             Delete CONTENT-ID, call CALLBACK with success status
- get-metadata-fn: Function (content-id) -> metadata alist
                   Get metadata for CONTENT-ID"
  name
  description
  available-p
  ingest-fn
  query-fn
  list-fn
  delete-fn
  get-metadata-fn)

;;; Plugin Registry

(defvar fuji--rag-backends (make-hash-table :test 'equal)
  "Registry of available RAG backend plugins.
Keys are backend names (strings), values are `fuji-rag-backend' structs.")

(defvar fuji-rag-backend "graphlit"
  "Currently active RAG backend name.
Valid values: \"graphlit\", \"local-vector\", etc.
Change this to switch between RAG backends.")

;;; Registry Functions

(defun fuji-register-rag-backend (backend)
  "Register a RAG BACKEND plugin in the global registry.
BACKEND should be a `fuji-rag-backend' struct."
  (unless (fuji-rag-backend-p backend)
    (error "Invalid RAG backend: must be a fuji-rag-backend struct"))
  (let ((name (fuji-rag-backend-name backend)))
    (puthash name backend fuji--rag-backends)
    (message "Fuji: Registered RAG backend plugin '%s'" name)))

(defun fuji-list-rag-backends ()
  "List all registered RAG backends.
Returns a list of backend names (strings)."
  (let ((names nil))
    (maphash (lambda (name _backend) (push name names)) fuji--rag-backends)
    names))

(defun fuji-get-rag-backend (name)
  "Get RAG backend plugin by NAME.
Returns the `fuji-rag-backend' struct or nil if not found."
  (gethash name fuji--rag-backends))

(defun fuji--available-rag-backends ()
  "Get list of available (configured) RAG backends.
Returns a list of backend names."
  (let ((available nil))
    (maphash
     (lambda (name backend)
       (when (and (fuji-rag-backend-available-p backend)
                  (funcall (fuji-rag-backend-available-p backend)))
         (push name available)))
     fuji--rag-backends)
    available))

(defun fuji--get-active-backend ()
  "Get the currently active RAG backend struct.
Priority order:
1. Buffer-local session override (fuji--session-rag-backend)
2. Global setting (fuji-rag-backend)
Returns the backend struct or signals an error if not available."
  (let* ((backend-name (or (and (boundp 'fuji--session-rag-backend) 
                                fuji--session-rag-backend)
                           fuji-rag-backend))
         (backend (fuji-get-rag-backend backend-name)))
    (unless backend
      (error "RAG backend '%s' not registered" backend-name))
    (unless (and (fuji-rag-backend-available-p backend)
                 (funcall (fuji-rag-backend-available-p backend)))
      (error "RAG backend '%s' not available or not configured" backend-name))
    backend))

;;; Unified RAG API

(defun fuji--rag-ingest (text filename metadata callback)
  "Ingest TEXT with FILENAME and METADATA using the active RAG backend.
Call CALLBACK with the content-id when ingestion completes.
METADATA should be an alist of key-value pairs."
  (let ((backend (fuji--get-active-backend)))
    (message "Fuji: Ingesting to %s..." (fuji-rag-backend-name backend))
    (funcall (fuji-rag-backend-ingest-fn backend)
             text filename metadata callback)))

(defun fuji--rag-query (query content-ids callback)
  "Query CONTENT-IDS with QUERY using the active RAG backend.
Call CALLBACK with the query results.
CONTENT-IDS can be a single ID or a list of IDs."
  (let ((backend (fuji--get-active-backend)))
    (funcall (fuji-rag-backend-query-fn backend)
             query content-ids callback)))

(defun fuji--rag-list (callback)
  "List all content in the active RAG backend.
Call CALLBACK with a list of content items.
Each item should be an alist with at least 'id and 'name keys."
  (let ((backend (fuji--get-active-backend)))
    (funcall (fuji-rag-backend-list-fn backend)
             callback)))

(defun fuji--rag-delete (content-id callback)
  "Delete CONTENT-ID from the active RAG backend.
Call CALLBACK with success status (t or nil)."
  (let ((backend (fuji--get-active-backend)))
    (message "Fuji: Deleting from %s..." (fuji-rag-backend-name backend))
    (funcall (fuji-rag-backend-delete-fn backend)
             content-id callback)))

(defun fuji--rag-get-metadata (content-id)
  "Get metadata for CONTENT-ID from the active RAG backend.
Returns an alist of metadata key-value pairs."
  (let ((backend (fuji--get-active-backend)))
    (funcall (fuji-rag-backend-get-metadata-fn backend)
             content-id)))

;;; Backend Switching

(defun fuji-set-rag-backend (backend-name)
  "Switch to a different RAG backend.
BACKEND-NAME should be a registered backend name (string)."
  (interactive
   (list (completing-read "Select RAG backend: "
                          (fuji-list-rag-backends)
                          nil t)))
  (let ((backend (fuji-get-rag-backend backend-name)))
    (unless backend
      (error "RAG backend '%s' not registered" backend-name))
    (unless (and (fuji-rag-backend-available-p backend)
                 (funcall (fuji-rag-backend-available-p backend)))
      (error "RAG backend '%s' not available or not configured" backend-name))
    (setq fuji-rag-backend backend-name)
    (message "Fuji: Switched to RAG backend '%s'" backend-name)))

;;; Interactive Commands

(defun fuji-show-rag-backends ()
  "Display information about registered RAG backends."
  (interactive)
  (let ((backends (fuji-list-rag-backends))
        (available (fuji--available-rag-backends)))
    (with-current-buffer (get-buffer-create "*Fuji RAG Backends*")
      (erase-buffer)
      (insert "=== Fuji RAG Backends ===\n\n")
      (insert (format "Active: %s\n\n" fuji-rag-backend))
      (insert "Registered Backends:\n")
      (dolist (name backends)
        (let* ((backend (fuji-get-rag-backend name))
               (avail (member name available))
               (active (string= name fuji-rag-backend)))
          (insert (format "  [%s] %s %s\n"
                          (if avail "✓" " ")
                          name
                          (if active "(active)" "")))
          (insert (format "      %s\n" (fuji-rag-backend-description backend)))))
      (goto-char (point-min))
      (display-buffer (current-buffer)))))

(provide 'fuji-rag)

;;; fuji-rag.el ends here
