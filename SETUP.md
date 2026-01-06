# Nexus-Paper Setup Guide

## Prerequisites

1. **Node.js**: Version 18+ required

   ```bash
   node --version  # Should be v18.0.0 or higher
   ```

2. **Emacs**: Version 29.1+ with `gptel` and `mcp.el` installed

## Installation Steps

### 1. Install Dependencies

```bash
cd /path/to/EmacsPaperreadingWorkflowAtGithub
npm install graphlit-mcp-server
```

### 2. Configure Graphlit Credentials

Run the interactive configuration:

```elisp
M-x fuji-configure
```

You'll be prompted for:

- **Graphlit Organization ID**: Your Graphlit org ID
- **Graphlit JWT Secret**: Your Graphlit JWT token
- **Graphlit Environment ID**: Your Graphlit environment ID

These credentials will be saved to `~/.authinfo`.

### 3. Configure Other Settings

During `M-x fuji-configure`, you'll also set:

- **Marker executable path**: Path to `marker_single` or `marker`
- **BibTeX directory**: Where your PDF papers are stored
- **Default Chat Backend**: Your preferred `gptel` backend (e.g., "ChatGPT", "Gemini")
- **Default Chat Model**: Your preferred model (e.g., "gpt-4o-mini", "gemini-2.0-flash-exp")
- **Vision Backend**: Backend for image analysis
- **Vision Model**: Model for multimodal queries
- **Cache Directory**: Where to store parsed papers
- **HTTP Proxy**: Optional proxy settings

### 4. Verify Installation

```elisp
M-x fuji-check-health
```

This will verify:

- Marker executable is found
- Graphlit credentials are configured
- MCP server can start
- All paths are valid

## Troubleshooting

### "Process graphlit not running: exited abnormally with code 1"

**Cause**: Missing `graphlit-mcp-server` npm package or invalid credentials.

**Solution**:

1. Install dependencies: `npm install graphlit-mcp-server`
2. Verify credentials: `M-x fuji-configure`
3. Check MCP server manually:

   ```bash
   node node_modules/graphlit-mcp-server/dist/index.js
   ```

### "Marker executable not found"

**Cause**: Marker is not installed or not in PATH.

**Solution**:

1. Install Marker: `pip install marker-pdf`
2. Update path in config: `M-x fuji-configure`

### "No credentials found in auth-source"

**Cause**: Graphlit credentials not configured.

**Solution**: Run `M-x fuji-configure` and enter your Graphlit credentials.

## Quick Start

1. Open a PDF: `M-x find-file /path/to/paper.pdf`
2. Start chat: `M-x rx/gptel-ref-chat`
3. Choose mode:
   - **Auto (Run Marker)**: High accuracy, supports figures
   - **Skip (pdftotext)**: Fast, text only
   - **Load Local Result**: Use existing Marker output

## Keybindings (in Chat Buffer)

- `C-c n m`: Switch model/backend
- `C-c n a`: Add file to context
- `C-c n s`: Restart MCP server
- `C-c n q`: Quit session
- `C-c RET`: Send message to LLM

## Getting Graphlit Credentials

1. Sign up at [Graphlit](https://www.graphlit.com/)
2. Create a new organization
3. Generate JWT credentials in the dashboard
4. Copy your Organization ID, JWT Secret, and Environment ID
