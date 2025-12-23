# Nexus-Paper Quick Start Guide

## 1. Prerequisites (Check Health)
First, ensure your environment is set up correctly: `M-x nexus-paper-check-health`.
- **Marker**: Must say "OK". If "MISSING", configure path via `nexus-paper-configure`.
- **Token Gen**: Must say "OK". If "FAILED", run `nexus-paper-configure` and provide your Secret.

## 2. Starting a Chat
Run the command:
`M-x rx/gptel-ref-chat`

## 3. Selecting a Paper
- A file selection dialog will appear.
- Browse to your PDF file and select it.
- **Tip**: You can now navigate into directories.

## 4. Processing (First Time Only)
- If this is the first time you've selected this PDF, Nexus-Paper will convert it using `marker`.
- **Status**: You will see "Processing PDF with Marker...".
- **Visual Feedback**: A buffer `*Nexus Marker Output*` will open showing the internal progress.
- **First Run Warning**: The first time you run this, Marker will download large AI models (several GB). This can take **5-10 minutes**. Please be patient and watch the download progress in the opened buffer.
- **Success**: You will see "Chat ready for [filename]" and a new buffer will open.
- **Failure**: Check the `*Nexus Marker Output*` buffer for errors.

## 5. Chatting
- A new buffer named `*Nexus-Ref-Chat: filename*` will open.
- This is a standard `gptel` buffer.
- Type your question (e.g., "Summarize this paper") and press `C-c RET` to send.
- The system will query Graphlit for relevant context from the paper and use GPT-4 Vision/Text models to answer.

## Maintenance
- **Clean Cache**: If you want to re-process a PDF, delete its folder in `~/.cache/nexus-paper/`.
- **Update Config**: `M-x nexus-paper-configure`.
