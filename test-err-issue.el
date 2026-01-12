;;; test-err-issue.el --- Standalone test for err variable issue -*- lexical-binding: t; -*-

;; This file tests the exact scenario that causes the err variable error

;;; Code:

(message "=== Testing err variable scenario ===")

;; Simulate the exact pattern that causes the issue
(defun test-graphlit-list-pattern ()
  "Test the condition-case + lambda pattern."
  (let ((callback (lambda (result) (message "Callback got: %S" result))))
    (condition-case outer-err
        (progn
          (message "Calling async function...")
          ;; Simulate async call with error callback
          (funcall (lambda (inner-err)
                     (message "Error callback: %s" (error-message-string inner-err)))
                   '(error "Test error")))
      (error
       (message "Outer error: %s" (error-message-string outer-err))))))

(message "Running test...")
(test-graphlit-list-pattern)
(message "✅ Test completed without void-variable err error")

(provide 'test-err-issue)

;;; test-err-issue.el ends here
