# 🗻 Fuji Usage Guide

This guide details the complete workflow for using **Fuji** (Fùjí, 负笈) as your Personal Digital Library and intelligent reading assistant.

---

## 🏗️ Structure: The 4 Pillars

Fuji's functionality is built around four core workflows:
1.  **Manage**: Organizing your library (Tags, BibTeX, Search).
2.  **Read**: Deep reading with AI assistance.
3.  **Cite**: Seamless citation insertion during writing.
4.  **Chat**: Interacting with your knowledge base.

---

## 1. Document Management 🗂️

The **Library Manager** is your command center. It provides a visual interface to manage all your documents.

### **Launching the Manager**
Run `M-x fuji-manage-content` to open the library view.

### **Keybindings (Library Mode)**

| Key | Command | Description |
| :--- | :--- | :--- |
| `a` / `+` | `fuji-library-add-file` | **Add File**: Import a PDF, DOCX, EPUB, or Image into the library. |
| `RET` | `fuji-library-open-session` | **Open**: Open the selected document for reading/chatting. |
| `d` | `fuji-library-mark-delete` | **Delete**: Mark file for deletion (execute with `x`). |
| `u` | `fuji-library-unmark` | **Unmark**: Unmark file. |
| `x` | `fuji-library-execute` | **Execute**: Permanently delete marked files. |
| `e` | `fuji-library-edit-title` | **Edit Title**: Rename how the file appears in Fuji (keeps original filename). |
| `t` / `m` | `fuji-library-edit-tags` | **Tags**: Add/Edit tags (comma-separated, e.g., `ai, transformers`). |
| `b` | `fuji-library-add-bibtex` | **BibTeX**: Bind a BibTeX entry (via DOI) to the document. |
| `s` | `fuji-library-search` | **Search**: Filter library by title or tags. |
| `/` / `S` | `fuji-library-clear-search` | **Clear Search**: Reset filters and show all files. |
| `@` | `fuji-search-by-tag` | **Tag Search**: Select tags to filter the view. |
| `W` | `fuji-library-chat-with-group`| **Group Chat**: Chat with *all* currently visible (filtered) documents. |
| `g` | `fuji-library-refresh` | **Refresh**: Reload the library view. |
| `q` | `quit-window` | **Quit**: Close the manager. |

### **Library-First Philosophy**
Fuji encourages keeping your files in its library (`~/.fuji/originals/`). When you open an external file with `fuji-read`, Fuji will ask to import it. Importing ensures:
1.  **Persistence**: Notes and chat history are saved forever.
2.  **Searchability**: The file becomes part of your global knowledge search.
3.  **BibTeX Sync**: You can attach metadata to it.

---

## 2. Intelligent Reading 🧠

The **Reading Interface** combines the document (left) and an AI Chat (right).

### **Starting a Session**
*   **From Manager**: Press `RET` on any file.
*   **From Anywhere**: Run `M-x fuji-read` (or binding `C-c f r` if tailored) and select a file.

### **Chat Features**
*   **Context Aware**: The AI knows the document content. Ask "Summarize Section 3" or "What is the main contribution?".
*   **Multimodal**: If the document contains images (or is an image), Fuji (via models like GPT-4o or Gemini 1.5 Pro) can "see" and explain them.
*   **Session History**: Your conversation is auto-saved. Closing Emacs does not lose your thought process.

### **Global Commands (Fuji Mode)**
These keys are available anywhere `fuji-mode` is active:

| Key | Command | Description |
| :--- | :--- | :--- |
| `C-c n b` | `fuji-add-bibtex-entry-from-doi` | **Add BibTeX**: Retrieve metadata via DOI and add to .bib file. |
| `C-c n i` | `fuji-insert-citation` | **Insert Citation**: Search library and insert citation (Org/LaTeX). |
| `C-c n m` | `fuji-session-set-model` | **Switch Model**: Change LLM (e.g., `gpt-4o` -> `claude-3-5-sonnet`). |
| `C-c n a` | `fuji-session-add-context`| **Add Context**: Inject another file/buffer into the *current* chat. |
| `C-c n q` | `fuji-quit` | **Quit**: Save and close the session. |

---

## 3. Unified Citation ✍️

Fuji revolutionizes academic writing by making citation finding strictly **content-based**.

### **The Command: `fuji-insert-citation`**
*   **Keybinding**: `C-c n i` (Global recommendation)
*   **Context**: Use this while writing in `org-mode` or `LaTeX`.

### **How it Works**
1.  **Trigger**: Press `C-c n i`.
2.  **Search**: Type *anything*—a concept, a keyword, or a phrase you remember from the paper.
    *   *Example*: "attention mechanism" or "resnets depth"
3.  **Fuzzy & Full-Text**: Fuji searches:
    *   **Metadata**: Titles, Authors (BibTeX).
    *   **Content**: The actual text of *every* PDF in your library (via `ripgrep`).
4.  **Insert**: Select the result, and Fuji inserts the correct citation key:
    *   Org: `[cite:@vaswani2017attention]`
    *   LaTeX: `\cite{vaswani2017attention}`

---

## 4. Knowledge Base Chat 💬

Your library is a living database.

### **Chat with Your Library**
1.  **Filter**: In `fuji-manage-content`, use `s` (search) or `@` (tag) to narrow down your view (e.g., just "Agents" papers).
2.  **Group Chat**: Press `W` (`fuji-library-chat-with-group`).
3.  **Interact**: A chat session opens with *all* visible documents as context.
    *   *Ask*: "Compare the evaluation metrics used in these 5 papers."
    *   *Ask*: "What is the common consensus on this topic?"
3.  **General Assistant**: It's not just for papers. Use it as a personalized ChatGPT/Gemini that knows your context.
    *   *Ask*: "How is the stock market doing today?" (The AI will use its general knowledge or web search).
    *   *Ask*: "Draft a blog post about my recent readings." (Combines your library with general writing skills).

---

## 🔧 Advanced Configuration

### **Pluggable Architecture**
Fuji allows you to swap backend components. See `fuji-configure.el` or `M-x customize-group fuji` to explore:
*   **Extractor**: Switch between `marker` (AI-based, expensive), `pdftotext` (fast, specific), or `pandoc`.
*   **RAG Backend**: Switch vector databases (e.g., `graphlit` or local).
*   **LLM Provider**: Any backend supported by `gptel`.

### **Troubleshooting**
*   **"Processing..." hangs**: Check the `*Fuji Marker Output*` buffer for errors.
*   **No Citations found**: Ensure you have run `fuji-add-bibtex-entry-from-doi` (`b` in Manager) for your papers so they have BibTeX keys.

---

*Happy Reading! 负笈远游，求知若渴.*
