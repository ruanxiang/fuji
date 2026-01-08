# Phase 0: Plugin Foundation - Implementation Plan

## Goal

Create a plugin architecture that makes Fuji extensible and backend-agnostic by:

1. Defining unified APIs for PDF extraction and RAG backends
2. Implementing a plugin registry system
3. Refactoring existing code into plugins
4. Making the Library Manager RAG-backend agnostic

## User Review Required

> [!IMPORTANT]
> **Breaking Changes**: This refactoring will change internal APIs but should not affect user-facing commands like `M-x fuji-read` and `M-x fuji-manage-content`.

> [!WARNING]
> **Testing Required**: Extensive testing needed after refactoring to ensure all existing functionality still works.

---

## Proposed Changes

### Component 1: Extractor API

Define a unified interface for PDF extraction plugins.

#### [NEW] [fuji-extractor.el](file:///home/ruan/Repositories/EmacsPaperreadingWorkflowAtGithub/fuji-extractor.el)

```elisp
;;; API Definition
(cl-defstruct fuji-extractor
  "Base structure for PDF extractor plugins."
  name          ; String: "marker", "pdftotext", "pandoc"
  description   ; String: Human-readable description
  available-p   ; Function: () -> bool, check if extractor is available
  extract-fn    ; Function: (pdf-file output-dir) -> markdown-file
  priority)     ; Integer: Higher = preferred (for auto-selection)

;;; Unified API
(defun fuji--extract (pdf-file output-dir &optional extractor-name)
  "Extract PDF-FILE to OUTPUT-DIR using specified or auto-selected extractor.
Returns path to generated markdown file.")

;;; Plugin Registry
(defvar fuji--extractors (make-hash-table :test 'equal)
  "Registry of available extractor plugins.")

(defun fuji-register-extractor (extractor)
  "Register an EXTRACTOR plugin.")

(defun fuji-list-extractors ()
  "List all registered extractors.")
```

#### Extractor Plugins

**[NEW] fuji-extractor-marker.el** - Marker plugin

```elisp
(fuji-register-extractor
 (make-fuji-extractor
  :name "marker"
  :description "High-accuracy OCR with figure support"
  :available-p (lambda () (file-exists-p fuji-marker-executable))
  :extract-fn #'fuji--marker-extract
  :priority 100))
```

**[NEW] fuji-extractor-pdftotext.el** - pdftotext plugin  
**[NEW] fuji-extractor-pandoc.el** - Pandoc plugin

---

### Component 2: RAG Backend API

Define a unified interface for RAG backend plugins.

#### [NEW] [fuji-rag.el](file:///home/ruan/Repositories/EmacsPaperreadingWorkflowAtGithub/fuji-rag.el)

```elisp
;;; API Definition
(cl-defstruct fuji-rag-backend
  "Base structure for RAG backend plugins."
  name          ; String: "graphlit", "local-vector", "llamaindex"
  description   ; String: Human-readable description
  available-p   ; Function: () -> bool, check if backend is available
  
  ;; Core API methods
  ingest-fn     ; Function: (text filename metadata callback) -> content-id
  query-fn      ; Function: (query content-ids callback) -> results
  list-fn       ; Function: (callback) -> list of content items
  delete-fn     ; Function: (content-id callback) -> success
  get-metadata-fn) ; Function: (content-id) -> metadata alist

;;; Unified API
(defun fuji--rag-ingest (text filename metadata callback)
  "Ingest TEXT with FILENAME and METADATA, call CALLBACK with content-id.")

(defun fuji--rag-query (query content-ids callback)
  "Query CONTENT-IDS with QUERY, call CALLBACK with results.")

(defun fuji--rag-list (callback)
  "List all content, call CALLBACK with list of items.")

(defun fuji--rag-delete (content-id callback)
  "Delete CONTENT-ID, call CALLBACK with success status.")

(defun fuji--rag-get-metadata (content-id)
  "Get metadata for CONTENT-ID.")

;;; Plugin Registry
(defvar fuji--rag-backends (make-hash-table :test 'equal)
  "Registry of available RAG backend plugins.")

(defvar fuji-rag-backend "graphlit"
  "Currently active RAG backend name.")
```

#### RAG Backend Plugins

**[NEW] fuji-rag-graphlit.el** - Graphlit MCP plugin

```elisp
(fuji-register-rag-backend
 (make-fuji-rag-backend
  :name "graphlit"
  :description "Graphlit cloud RAG via MCP"
  :available-p (lambda () (gethash fuji-mcp-server-name mcp-server-connections))
  :ingest-fn #'fuji--graphlit-ingest
  :query-fn #'fuji--graphlit-query
  :list-fn #'fuji--graphlit-list
  :delete-fn #'fuji--graphlit-delete
  :get-metadata-fn #'fuji--graphlit-get-metadata))
```

**Future plugins**:

- `fuji-rag-local.el` - Local vector database
- `fuji-rag-llamaindex.el` - LlamaIndex integration

---

### Component 3: Refactor Existing Code

Wrap existing functionality as plugins.

#### [MODIFY] [fuji.el](file:///home/ruan/Repositories/EmacsPaperreadingWorkflowAtGithub/fuji.el)

**Changes**:

1. Add `(require 'fuji-extractor)` and `(require 'fuji-rag)`
2. Replace direct Marker calls with `fuji--extract`
3. Replace Graphlit MCP calls with `fuji--rag-*` APIs
4. Update `fuji-read` to use unified APIs

**Example refactoring**:

```elisp
;; Before:
(fuji--process-pdf-with-marker pdf-file callback)

;; After:
(fuji--extract pdf-file results-dir "marker")
```

#### [MODIFY] [fuji-library.el](file:///home/ruan/Repositories/EmacsPaperreadingWorkflowAtGithub/fuji.el) (lines 1154-1400)

**Refactor Library Manager to be RAG-agnostic**:

```elisp
;; Before:
(defun fuji--query-all-contents (callback)
  (mcp-async-call-tool conn "queryContents" ...))

;; After:
(defun fuji-library-refresh ()
  (fuji--rag-list
   (lambda (contents)
     (setq fuji--content-list contents)
     (fuji-library--populate-buffer))))

;; Before:
(defun fuji--delete-from-graphlit (content-id)
  (mcp-async-call-tool conn "deleteContent" ...))

;; After:
(defun fuji-library-delete-marked ()
  (fuji--rag-delete content-id callback))
```

---

### Component 4: Configuration

Add plugin selection to configuration.

#### [MODIFY] fuji-configure

Add options for:

```elisp
(defcustom fuji-preferred-extractor "marker"
  "Preferred PDF extractor plugin."
  :type '(choice (const "marker")
                 (const "pdftotext")
                 (const "pandoc")))

(defcustom fuji-rag-backend "graphlit"
  "Active RAG backend plugin."
  :type '(choice (const "graphlit")
                 (const "local-vector")))
```

---

## File Structure

```
fuji/
├── fuji.el                      # Main entry, loads plugins
├── fuji-core.el                 # Core utilities (if needed)
│
├── fuji-extractor.el            # Extractor API definition
├── fuji-extractor-marker.el     # Marker plugin
├── fuji-extractor-pdftotext.el  # pdftotext plugin
├── fuji-extractor-pandoc.el     # Pandoc plugin
│
├── fuji-rag.el                  # RAG API definition
├── fuji-rag-graphlit.el         # Graphlit MCP plugin
│
└── (existing files remain)
```

---

## Implementation Steps

### Step 1: Create API Definitions

1. Create `fuji-extractor.el` with API and registry
2. Create `fuji-rag.el` with API and registry
3. Test that files load without errors

### Step 2: Implement Graphlit Plugin

1. Create `fuji-rag-graphlit.el`
2. Move existing Graphlit code into plugin
3. Implement all 5 RAG API methods
4. Test with existing functionality

### Step 3: Implement Marker Plugin

1. Create `fuji-extractor-marker.el`
2. Move existing Marker code into plugin
3. Test PDF extraction

### Step 4: Refactor fuji-read

1. Update `fuji-read` to use `fuji--extract`
2. Update to use `fuji--rag-ingest`
3. Test end-to-end workflow

### Step 5: Refactor Library Manager

1. Replace `fuji--query-all-contents` with `fuji--rag-list`
2. Replace `fuji--delete-from-graphlit` with `fuji--rag-delete`
3. Test all library operations

### Step 6: Add Other Extractors

1. Implement `fuji-extractor-pdftotext.el`
2. Implement `fuji-extractor-pandoc.el`
3. Test extractor selection

---

## Verification Plan

### Unit Tests

- Test each API function with mock plugins
- Test plugin registration and lookup
- Test error handling

### Integration Tests

- Test complete PDF processing workflow
- Test library management operations
- Test switching between backends

### Manual Verification

1. Process a PDF with Marker
2. Process a PDF with pdftotext
3. Upload to Graphlit
4. Query via Library Manager
5. Delete content
6. Verify all operations work as before

---

## Success Criteria

- ✅ All existing functionality works unchanged
- ✅ New plugin APIs are clean and well-documented
- ✅ Easy to add new extractor plugins
- ✅ Easy to add new RAG backend plugins
- ✅ Library Manager is backend-agnostic
- ✅ No breaking changes to user commands

---

## Timeline Estimate

- **Step 1-2**: 2-3 hours (API definition + Graphlit plugin)
- **Step 3**: 1 hour (Marker plugin)
- **Step 4**: 1-2 hours (Refactor fuji-read)
- **Step 5**: 1-2 hours (Refactor Library Manager)
- **Step 6**: 1 hour (Other extractors)
- **Testing**: 2 hours

**Total**: ~8-11 hours

---

## Risks & Mitigation

**Risk**: Breaking existing functionality  
**Mitigation**: Keep old code commented out, extensive testing

**Risk**: Plugin API too rigid  
**Mitigation**: Start simple, iterate based on real plugin needs

**Risk**: Performance overhead from abstraction  
**Mitigation**: Keep dispatching lightweight, profile if needed
