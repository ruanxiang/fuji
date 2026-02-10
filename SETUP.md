# 🛠️ Installation & Setup Guide

Fuji is a hybrid system combining an **Emacs Package** with powerful **External AI Tools**. Setup involves three steps:
1.  **System Preparation**: Installing the "eyes" (PDF/text extractors).
2.  **Emacs Installation**: Loading the package.
3.  **Configuration**: Running the built-in wizard.

---

## 🏗️ 1. System Preparation

Fuji relies on state-of-the-art tools to read documents. You'll need key utilities installed on your OS.

### A. Core Requirements (Linux/macOS)
| Tool | Purpose | Installation Command |
| :--- | :--- | :--- |
| **Poppler** | Fast PDF text extraction (`pdftotext`) | `sudo apt install poppler-utils` (Linux)<br>`brew install poppler` (macOS) |
| **Pandoc** | Reading DOCX, EPUB, and HTML | `sudo apt install pandoc` (Linux)<br>`brew install pandoc` (macOS) |
| **Node.js** | Running MCP Servers (Graphlit) | Install via [version manager (nvm)](https://github.com/nvm-sh/nvm) or system package manager. |
| **Chrome** | Web URL Archiving | Ensure **Google Chrome** or **Chromium** is installed. |

### B. AI-Powered PDF Engine (Marker)
For high-accuracy reading (formulas, tables, layout), Fuji uses [Marker](https://github.com/VikParuchuri/marker).

1.  **Install PyTorch** (GPU recommended, but works on CPU):
    *   Follow [PyTorch Get Started](https://pytorch.org/get-started/locally/)
2.  **Install Marker**:
    ```bash
    pip install marker-pdf
    ```
3.  **Verify**: Run `marker_single --help` to ensure it's in your PATH.
    > **💡 Developer's Tip**: Real-time AI extraction can be slow.
    > *   **Daily Use**: We highly recommend `pdftotext` (default). It is lightweight, instant, and handles 90% of papers perfectly.
    > *   **Deep Reading**: Use `marker` only when you strictly need **Formula** or **Chart** precision.
    > *   **Offline Import**: If you have pre-extracted text (from offline batch jobs), Fuji allows you to import it directly when adding a file, skipping the wait entirely.

---

## 📦 2. Emacs Installation

### Option A: `straight.el` (Recommended)
Add this to your `init.el`:

```elisp
(use-package fuji
  :straight (:host github :repo "ruanxiang/fuji")
  :custom
  ;; Optional: Set this if you want a custom location, 
  ;; otherwise wizard sets it to ~/.emacs.d/fuji-cache/
  ;; (fuji-cache-directory "~/MyKnowledgeBase/.fuji")
  :config
  ;; Global Keybindings (Optional)
  (global-set-key (kbd "C-c n m") #'fuji-manage-content)
  (global-set-key (kbd "C-c n r") #'fuji-read)
  (global-set-key (kbd "C-c n i") #'fuji-insert-citation))
```

### Option B: Manual Installation
1.  Clone the repository:
    ```bash
    git clone https://github.com/ruanxiang/fuji.git ~/.emacs.d/site-lisp/fuji
    ```
2.  Add to `init.el`:
    ```elisp
    (add-to-list 'load-path "~/.emacs.d/site-lisp/fuji")
    (require 'fuji)
    ```

**Dependencies**: Ensure `gptel` and `mcp` are installed (Fuji usually auto-installs them via `straight`/`package.el`).

---

## 🪄 3. Configuration (The Wizard)

Fuji comes with an interactive wizard that scans your system and sets everything up.

1.  Restart Emacs.
2.  Run **`M-x fuji-configure`**.
3.  Follow the interactive prompts:
    *   **Tier 1 (Tool Selection)**: Select your drivers.
        *   *LLM Tool*: Select `marker` (recommended for deep reading) or others.
        *   *DOCX Tool*: Select `pandoc`.
        *   *RAG Backend*: Select `graphlit`.
    *   **Tier 2 (Paths & Data)**: The wizard will auto-detect paths.
        *   *Confirm Paths*: For `pdftotext`, `marker`, `pandoc`, and `chrome`.
        *   *Bibliography*: Point to your master `.bib` file (e.g., `~/Documents/refs.bib`).
        *   *Cache Location*: Choose where Fuji stores data (default: `~/.emacs.d/fuji-cache/`).
    *   **Tier 3 (AI Backends)**:
        *   *Graphlit*: Enter Org ID, Env ID, and Secret (if RAG is enabled).
        *   *GPTel*: Select your default **Chat Model** and **Vision Model** (for image analysis).
    *   **Network**: Enter an HTTP Proxy (e.g., `127.0.0.1:7890`) if you are behind a firewall/VPN.

Once finished, the wizard automatically saves a machine-specific config to `fuji-local-config.el` (which is git-ignored, keeping your secrets safe) and reloads it.

### ✅ Validate Setup
Run **`M-x fuji-validate-configuration`** at any time. It will check:
*   [x] Are all binaries executable?
*   [x] Are API keys loaded?
*   [x] Is the cache directory writable?

---

## 🗝️ API Keys (RAG & LLM)

To fully unlock Fuji's "Chat with Library" features, you need external services.

### 1. LLM (gptel)
Fuji uses `gptel` for chat. Ensure you have at least one backend configured in your Emacs config **OR** via the Wizard.

```elisp
;; Example Manual Config (if skipped in Wizard)
(setq-default gptel-model "gpt-4o")
(setq-default gptel-backend (gptel-make-openai "OpenAI" :key "sk-..."))
```

### 2. Graphlit (RAG)
If using [Graphlit](https://www.graphlit.com/) for semantic search:
1.  Get your **Organization ID**, **Environment ID**, and **JWT Secret**.
2.  Enter them during `M-x fuji-configure`.

> **ℹ️ Privacy & Performance**:
> *   **Text Only**: Fuji converts everything to text before upload. This makes uploads **fast** and bandwidth-friendly.
> *   **Local Threshold**: Files larger than **100KB** (text size) are **NOT uploaded** to Graphlit. They are kept entirely local and fed directly into the LLM context window. This ensures you never hit Free Tier limits with large books, while still being able to chat with them.

---

## 📂 Troubleshooting

**Q: `marker` is slow!**
A: Ensure you have PyTorch installed with CUDA (NVIDIA) or MPS (Mac) support. On CPU, it will be slower but still accurate.

**Q: Where is my data?**
A: Check `M-x describe-variable RET fuji-cache-directory`. By default, it's `~/.emacs.d/fuji-cache/`.

**Q: "Command not found" errors?**
A: Run `M-x fuji-validate-configuration`. It will tell you exactly which tool is missing from Emacs's `exec-path`.
