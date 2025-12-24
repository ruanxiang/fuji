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

## Performance Tuning

### Marker Processing
Marker processing can be slow on machines without a GPU. Nexus-Paper provides three modes to handle this:
1. **Auto (Run Marker)**: Full multimodal processing (extracts text, equations, and images). Recommended if you have a GPU or a powerful CPU.
2. **Skip (Text Only)**: Bypasses Marker and uses `pdftotext` for fast ingestion to Graphlit. Ideal for quick reading where figure analysis isn't required.
3. **Load Local Result**: Prompts you for a directory containing pre-generated Marker results.

### Recommended Workflow for Low-end Hardware
- **Pre-process in Bulk**: Run Marker on a machine with a GPU during idle time and save the results.
- **Load Locally**: Use the "Load Local Result" option in `rx/gptel-ref-chat` to instanty load those results on your low-end device.
- **Cache is King**: Nexus-Paper caches all Marker results. Once a paper is processed, switching between modes or restarting the session is near-instant.

## 5. Chatting
- A new buffer named `*Nexus-Ref-Chat: filename*` will open.
- This is a standard `gptel` buffer.
- Type your question (e.g., "Summarize this paper") and press `C-c RET` to send.
- The system will query Graphlit for relevant context from the paper and use GPT-4 Vision/Text models to answer.

## Maintenance
- **Clean Cache**: If you want to re-process a PDF, delete its folder in `~/.cache/nexus-paper/`.
- **Update Config**: `M-x nexus-paper-configure`.
