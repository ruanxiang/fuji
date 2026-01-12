;;; fuji-dev-utils.el --- Development utilities for Fuji -*- lexical-binding: t; -*-

;; Utility functions for Fuji development

;;; Code:

(defun fuji-reload ()
  "Reload all Fuji modules during development.
This is the proper way to reload Fuji after making changes to source files."
  (interactive)
  (message "Reloading Fuji modules...")
  
  ;; Unload all Fuji features in reverse dependency order
  (dolist (feature '(fuji fuji-configure fuji-rag-graphlit fuji-rag fuji-extractor))
    (when (featurep feature)
      (unload-feature feature t)
      (message "  Unloaded: %s" feature)))
  
  ;; Reload main module (which will require dependencies)
  (require 'fuji)
  (message "✅ Fuji modules reloaded successfully!")
  (message "You can now use M-x fuji-configure or M-x fuji-read"))

(defun fuji-check-config ()
  "Check current Fuji configuration."
  (interactive)
  (message "=== Fuji Configuration ===")
  (message "Marker: %s" (if (and fuji-marker-executable 
                                  (file-executable-p fuji-marker-executable))
                            "✅ Configured"
                          "❌ Not configured"))
  (message "Bibliography: %s" (if (and fuji-bib-path 
                                        (file-directory-p fuji-bib-path))
                                   "✅ Configured"
                                 "❌ Not configured"))
  (message "Cache: %s" (if (and fuji-cache-directory 
                                 (file-directory-p fuji-cache-directory))
                            "✅ Configured"
                          "❌ Not configured"))
  (message "Originals: %s" (if (and fuji-originals-archive-dir 
                                     (file-directory-p fuji-originals-archive-dir))
                                "✅ Configured"
                              "❌ Not configured"))
  (message "Config file: %s" (if (file-exists-p fuji-local-config-file)
                                  "✅ Exists"
                                "❌ Not found")))

(provide 'fuji-dev-utils)

;;; fuji-dev-utils.el ends here
