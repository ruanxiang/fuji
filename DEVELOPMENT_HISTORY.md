# Fuji Development History

This file tracks the development history across multiple Antigravity conversations.

## Project Information

- **Repository**: https://github.com/ruanxiang/misc_emacs_paperreading_workflow
- **Main Branch**: `main`
- **Latest Release**: v1.0.0-phase1 (2026-01-09)

## Development Sessions

### Session 1: Phase 0 - Plugin Architecture (Conversation: 42cb67a8)
**Date**: 2026-01-08  
**Status**: ✅ Complete, merged to main

**Achievements**:
- Implemented plugin architecture foundation
- Created PDF/DOCX extractor abstraction layer (`fuji-extractor.el`)
- Created RAG backend abstraction layer (`fuji-rag.el`)
- Implemented runtime plugin hot-swap functionality
- Added `fuji-set-extractor` and `fuji-set-rag-backend` commands
- Integrated buffer-local session variables for plugin overrides

**Key Files Created**:
- `fuji-extractor.el` - Extractor plugin abstraction
- `fuji-rag.el` - RAG backend abstraction
- Various plugin implementations (`fuji-extractor-*.el`, `fuji-rag-*.el`)

---

### Session 2 & 3: Phase 1 - Two-Tier Configuration (Conversation: 7e7ac597)
**Date**: 2026-01-09  
**Status**: ✅ Complete, released as v1.0.0-phase1

**Achievements**:
- Designed and implemented two-tier configuration system
- Created `fuji-configure.el` with Tier 1 (tool selection) and Tier 2 (tool-specific config)
- Implemented auto-detection for binary paths (pdftotext, marker, pandoc)
- Corrected configuration logic: both pdftotext AND LLM tools are configured
- Simplified UX with clear prompts
- Fixed gptel configuration to show all available backends and models
- Integrated with Phase 0 plugin dispatchers
- Added configuration validation (`fuji-validate-configuration`)

**Key Design Decisions**:
1. **Both tools configured** (AND relationship): pdftotext + LLM tool (marker)
2. **Offline is runtime option**, not configuration option
3. **Configuration persistence** via `customize-save-variable`
4. **Simplified prompts**: Only show currently available options (marker, graphlit)

**Key Files Created/Modified**:
- `fuji-configure.el` (new) - Configuration wizard
- `fuji.el` (modified) - Added Phase 1 defcustom variables
- `fuji-extractor.el` (modified) - Updated dispatcher
- `fuji-rag.el` (modified) - Updated dispatcher

**Git History**:
- 12 commits on `phase1` branch
- Tagged as `v1.0.0-phase1`
- Merged to `main` via fast-forward
- All changes pushed to origin

---

## Next Steps (Phase 2)

According to `TODO.org`, the next phase focuses on:

1. **Runtime Extraction Method Selection**
   - Implement user choice in `fuji-read`: pdftotext / LLM-based / offline
   - Dynamic offline directory specification

2. **Storage & Archiving System** (Calibre-style)
   - Automatic file archiving to `originals/`
   - Metadata tracking

3. **Multi-Format Expansion**
   - Pandoc integration for DOCX/EPUB/HTML

---

## Important Context for New Conversations

### Core Architecture
- **Plugin System**: Extractors and RAG backends are pluggable
- **Hot-Swap**: Runtime switching via `fuji-set-extractor`, `fuji-set-rag-backend`
- **Priority Order**: argument > session override > config default > auto-select

### Configuration System
- **Tier 1**: Tool selection (which tools to use)
- **Tier 2**: Tool-specific configuration (paths, credentials)
- **Both tools configured**: pdftotext (default) + LLM tool (high-quality option)
- **Runtime choice**: User selects which tool to use when opening files

### Key Files to Review
- `TODO.org` - Development roadmap
- `fuji.el` - Main file with defcustom variables
- `fuji-configure.el` - Configuration wizard
- `fuji-extractor.el` - Extractor abstraction
- `fuji-rag.el` - RAG backend abstraction

### Development Workflow
1. Make changes to `.el` files
2. Reload in Emacs: `(load-file "fuji-configure.el")`
3. Test with `M-x fuji-configure`
4. Commit and push changes

---

## Quick Start for New Conversations

When starting a new conversation about Fuji, mention:
1. Project location: `/home/ruan/Repositories/EmacsPaperreadingWorkflowAtGithub`
2. Current phase: Phase 1 complete, starting Phase 2
3. Reference this file: `DEVELOPMENT_HISTORY.md`

The AI will be able to read this file and understand the full context.
