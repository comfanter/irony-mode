;;; irony-iotask.el --- Abstraction for I/O-based tasks

;; Copyright (C) 2015  Guillaume Papin

;; Author: Guillaume Papin <guillaume.papin@epitech.eu>
;; Keywords: processes, convenience

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Purpose is to work with both processes and network streams.
;;
;; Unlike tq.el we want tasks to be composed of 0, 1-1, or n-n communications.
;; tq.el only supports 1-1.
;;
;; 0 is useful if a server command has been cached, it means there is no need
;; for communication. We may only know if a task is still cached when the
;; callback is called (maybe after some other asynchronous tasks, so the context
;; may have changed since the task was initially posted)
;;
;; n-n is useful if the number of request depends on the answer to a previous
;; request but we still want to be able to push new, different tasks

;;; Code:

(require 'cl-lib)


;;
;; Error conditions
;;

(define-error 'irony-iotask-error "I/O task error")
(define-error 'irony-iotask-filter-error "I/O task filter error")


;;
;; Structures
;;

(cl-defstruct (irony-iotask-result (:constructor irony-iotask-result-create))
  -tag ;; 'value or 'error, or nil when unset
  -value
  -error -error-data
  )

(defun irony-iotask-result-valid-p (result)
  (and (irony-iotask-result--tag result) t))

(defun irony-iotask-result-set-value (result value)
  (setf (irony-iotask-result--tag result) 'value)
  (setf (irony-iotask-result--value result) value))

(defun irony-iotask-result-set-error (result error &rest error-data)
  (setf (irony-iotask-result--tag result) 'error)
  (setf (irony-iotask-result--error result) error)
  (setf (irony-iotask-result--error-data result) error-data))

(define-error 'irony-iotask-result-get-error
  "Result not set before call to get")

(defun irony-iotask-result-get (result)
  (cl-case (irony-iotask-result--tag result)
    ('value (irony-iotask-result--value result))
    ('error (signal (irony-iotask-result--error result)
                    (irony-iotask-result--error-data result)))
    (t
     (signal 'irony-iotask-result-get-error (list result)))))

;; FIXME: quoting issues? I cannot write "#'(lambda ()...)" as property value
(defmacro irony-iotask-define-task (var docstring &rest properties)
  "A task is simply a property list.

Each of these function are called in the buffer they were
originally created (at schedule time).

Properties:

`start' (mandatory)
     Function to call to launch the task.

     Usually the function sends a string/command/message to the
     execution context. If the task do some caching it's possible
     that nothing is send, instead the execution context result
     should be set to indicate that the task is ready.

     Takes an execution-context as parameter (`irony-iotask-ectx')."
  (declare (indent 1)
           (doc-string 2))
  `(progn
     (defvar ,var nil ,docstring)
     ;; Use `setq' to reset the var every time the macro is called.
     ;; This is useful, for example when evaluating using C-M-x (`eval-defun').
     ;; Trick stolen from auto-complete's `ac-define-source'
     (setq ,var '(,@properties))))

(cl-defstruct (irony-iotask-ectx
               (:constructor irony-iotask-ectx--create))
  "The execution context used as arguments for tasks."
  -result
  -pdata
  -process
  -task
  -buffer
  -callback)

(defun irony-iotask-ectx-create (pdata task callback)
  (irony-iotask-ectx--create :-result (irony-iotask-result-create)
                             :-pdata pdata
                             :-process (irony-iotask-pdata--process pdata)
                             :-task task
                             :-buffer (current-buffer)
                             :-callback callback))

(defun irony-iotask-ectx-set-result (ectx value)
  (irony-iotask-result-set-value (irony-iotask-ectx--result ectx)
                                 value))

(defun irony-iotask-ectx-set-error (ectx error &rest error-data)
  (irony-iotask-result-set-error (irony-iotask-ectx--result ectx)
                                 error error-data))
(cl-defstruct (irony-iotask-pdata
               (:constructor irony-iotask-pdata-create))
  "Structure for storing the necessary mechanics for running
tasks on a process. pdata stands for \"process data\"."
  queue
  -process)

(defun irony-iotask-pdata-append-output (pdata output)
  ;; TODO: implement
  (error "not implemented"))

(defun irony-iotask-pdata-enqueue (pdata task)
  (setf (irony-iotask-pdata-queue pdata)
        (append (irony-iotask-pdata-queue pdata) (list task))))


;;
;; Implementation details, internal mechanic
;;

(defun irony-iotask-process-data (process)
  (process-get process 'irony-iotask-pdata))

(define-error 'irony-iotask-bad-task "Bad I/O task")
(defun irony-iotask-pdata-run-first (pdata)
  (let* ((ectx (car (irony-iotask-pdata-queue pdata)))
         (task (irony-iotask-ectx--task ectx))
         (task-buffer (irony-iotask-ectx--buffer ectx))
         (result (irony-iotask-ectx--result ectx))
         (start-fn (plist-get task :start)))
    (if start-fn
        (with-current-buffer task-buffer
          (funcall start-fn ectx))
      (irony-iotask-ectx-set-error ectx 'irony-iotask-bad-task
                                   "no :start function"
                                   task))
    ;; check if the result was set (e.g: due to caching or error)
    (when (irony-iotask-result-valid-p result)
      (with-current-buffer task-buffer
        (funcall (irony-iotask-ectx--callback ectx) result)))))

(defun irony-iotask-pdata-schedule (pdata task callback)
  (irony-iotask-pdata-enqueue pdata
                              (irony-iotask-ectx-create pdata task callback))
  ;; run task if none were running
  (when (= (length (irony-iotask-pdata-queue pdata)) 1)
    (irony-iotask-pdata-run-first pdata)))

;; removing the dependance to a process is useful for testing
(defun irony-iotask-filter (pdata output)
  ;; if no task this is an error, a spurious message is an error
  (unless (irony-iotask-pdata-queue pdata)
    (signal 'irony-iotask-filter-error (list "spurious buffer output" output)))
  (irony-iotask-pdata-append-output pdata output)
  (error "Not implemented"))

(defun irony-iotask-process-filter (process output)
  (irony-iotask-filter (irony-iotask-process-data process) output))

(defun irony-iotask-process-sentinel (process event)
  (unless (process-live-p process)
    ;; TODO: send an abort error to all tasks, this should make
    ;; `irony-iotask-run' to stop looping gracefully
    ))

(defun irony-iotask-check-process (process)
  (unless (process-live-p process)
    (signal 'irony-iotask-error (list "Process ain't running!")))
  (let ((pdata (irony-iotask-process-data process))
        (pfilter (process-filter process))
        (psentinel (process-sentinel process)))
    (unless (irony-iotask-pdata-p pdata)
      (signal 'irony-iotask-error
              (list (concat "invalid process data:"
                            " did you call `irony-iotask-setup-process'?"))))
    (unless (eq pfilter 'irony-iotask-process-filter)
      (signal 'irony-iotask-error
              (list "invalid process filter" pfilter)))
    (unless (eq psentinel 'irony-iotask-process-sentinel)
      (signal 'irony-iotask-error
              (list "invalid process sentinel" psentinel)))))


;;
;; Public API
;;

(defun irony-iotask-setup-process (process)
  "Call after creating the asynchronous process to let
irony-iotask setup the PROCESS filter and anything else that may
be needed."
  (set-process-filter process #'irony-iotask-process-filter)
  (set-process-sentinel process #'irony-iotask-process-sentinel)
  (process-put process 'irony-iotask-pdata (irony-iotask-pdata-create))
  (buffer-disable-undo (process-buffer process)))

(defun irony-iotask-schedule (process task callback)
  ;; check argument
  (irony-iotask-check-process process)
  (irony-iotask-pdata-schedule (irony-iotask-process-data process)
                               task
                               callback))

(defvar irony-iotask--run-result nil)
(defvar irony-iotask--run-count 0)
(defun irony-iotask-run (process task)
  "Blocking/waiting counterpart of `irony-iotask-schedule'.

Return the result (or signal the stored error) instead of passing
it to a callback.

Returns nil when quitting.

This function isn't reentrant, do not call it from another task."
  ;; the count is necessary if some previous run were interrupted, we will have
  ;; to wait for them and the new task
  (cl-incf irony-iotask--run-count)
  ;; schedule an asynchronous task that set result when done
  (condition-case err
      (irony-iotask-schedule process task
                             (lambda (result)
                               (setq irony-iotask--run-result result)
                               (cl-decf irony-iotask--run-count)))
    (error
     ;; restore count in case of schedule failure, as the callback will never
     ;; run to decrement it otherwise
     (cl-decf irony-iotask--run-count)
     ;; rethrow
     (signal (car err) (cdr err))))

  ;; wait for the task to complete
  ;; quitting is allowed, in this case the task will still run but
  ;; asynchronously, it won't block the user interface but the result will be
  ;; lost
  (if (with-local-quit
        (while (not (zerop irony-iotask--run-count))
          (accept-process-output process 0.05))
        t)
      ;; didn't quit, task was completed
      (irony-iotask-result-get irony-iotask--run-result))
  ;; C-g was used
  ;; TODO: reset any continuation here, we don't need to spend time running them
  ;; if the result isn't used
  )

(provide 'irony-iotask)
;;; irony-iotask.el ends here
