(defun fuji--query-graphlit (prompt success-callback error-callback)
  "Send PROMPT to Graphlit for RAG via MCP.
Calls SUCCESS-CALLBACK with answer on success, or ERROR-CALLBACK on failure."
  (let* ((orig-buffer (current-buffer))
         (conn (fuji--get-mcp-connection))
         (paper-name (or (bound-and-true-p fuji--filename) "this paper")))
    (message "Fuji: Querying Graphlit MCP... (Server: %s)" fuji-mcp-server-name)
    (if (not conn)
        (progn
          (message "Fuji ERROR: No MCP connection found for %s" fuji-mcp-server-name)
          (funcall error-callback "MCP server not connected"))
      (fuji--log "Querying Graphlit RAG (Content: %s, Conversation: %s) with prompt: %S" 
                 (or (bound-and-true-p fuji--content-id) "Global")
                 (or fuji--conversation-id "New")
                 prompt)
      (condition-case outer-err
          (mcp-async-call-tool conn "promptConversation"
                               `((prompt . ,prompt)
                                 ,@(when-let* ((cid (bound-and-true-p fuji--content-id)))
                                     `((contentIds . [,cid])))
                                 ,@(when fuji--conversation-id
                                     `((conversationId . ,fuji--conversation-id))))
                               (lambda (result)
                                 (fuji--log "MCP response received. Rendering...")
                                 (when (buffer-live-p orig-buffer)
                                   (with-current-buffer orig-buffer
                                     (let* ((parsed (fuji--mcp-parse-result result))
                                            (answer (and parsed 
                                                         (or (cdr (assoc 'answer parsed))
                                                             (cdr (assoc 'message parsed)))))
                                            (conv-id (and parsed (cdr (assoc 'id parsed)))))
                                       (if answer
                                           (progn
                                             (message "Fuji: Answer extracted, calling success callback.")
                                             ;; Save conversation ID for continuity
                                             (when conv-id
                                               (setq fuji--conversation-id conv-id))
                                             (funcall success-callback answer))
                                         (let ((err-msg (format "MCP tool returned success but no answer found in result.")))
                                           (fuji--log "[FAILURE] %s" err-msg)
                                           (message "Fuji: %s Raw: %S" err-msg result)
                                           (funcall error-callback err-msg)))))))
                               (lambda (inner-err)
                                 (message "Fuji: MCP error lambda triggered: %S" inner-err)
                                 (when (buffer-live-p orig-buffer)
                                   (with-current-buffer orig-buffer
                                     (let ((err-msg (format "MCP tool call error: %s" (error-message-string inner-err))))
                                       (fuji--log "[FAILURE] %s" err-msg)
                                       (funcall error-callback err-msg))))))
        (error
         (message "Fuji: MCP call failed: %s" (error-message-string outer-err))
         (funcall error-callback (format "MCP error: %s" (error-message-string outer-err)))))))

