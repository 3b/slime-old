;;;; -*- Mode: lisp; outline-regexp: ";;;;;*"; indent-tabs-mode: nil -*-;;;
;;;
;;; swank.lisp --- the portable bits
;;;
;;; Created 2003, Daniel Barlow <dan@metacircles.com>
;;;
;;; This code has been placed in the Public Domain.  All warranties are 
;;; disclaimed.

;;; Currently the package is declared in swank-backend.lisp
#+nil
(defpackage :swank
  (:use :common-lisp)
  (:export #:start-server #:create-swank-server
           #:*sldb-pprint-frames*))

(in-package :swank)

(declaim (optimize (debug 2)))

(defvar *swank-io-package*
  (let ((package (make-package "SWANK-IO-PACKAGE" :use '())))
    (import '(nil t quote) package)
    package))

(defconstant +server-port+ 4005
  "Default port for the Swank TCP server.")

(defvar *swank-debug-p* t
  "When true, print extra debugging information.")

(defvar *sldb-pprint-frames* nil
  "*pretty-print* is bound to this value when sldb prints a frame.")

;;; public interface.  slimefuns are the things that emacs is allowed
;;; to call

(defmacro defslimefun (fun &rest rest)
  `(progn
    (defun ,fun ,@rest)
    (export ',fun :swank)))

(defmacro defslimefun-unimplemented (fun args)
  `(progn
    (defun ,fun ,args
      (declare (ignore ,@args))
      (error "Backend function ~A not implemented." ',fun))
    (export ',fun :swank)))

(declaim (ftype (function () nil) missing-arg))
(defun missing-arg ()
  (error "A required &KEY or &OPTIONAL argument was not supplied."))


;;;; Connections
;;;
;;; Connection structures represent the network connections between
;;; Emacs and Lisp. Each has a socket stream, a set of user I/O
;;; streams that redirect to Emacs, and optionally a second socket
;;; used solely to pipe user-output to Emacs (an optimization).
;;;

(defstruct (connection
             (:conc-name connection.)
             ;; (:print-function %print-connection)
             )
  ;; Raw I/O stream of socket connection.
  (socket-io        (missing-arg) :type stream :read-only t)
  ;; Optional dedicated output socket (backending `user-output' slot).
  ;; Has a slot so that it can be closed with the connection.
  (dedicated-output nil :type (or stream null))
  ;; Streams that can be used for user interaction, with requests
  ;; redirected to Emacs.
  (user-input       nil :type (or stream null))
  (user-output      nil :type (or stream null))
  (user-io          nil :type (or stream null))
  ;;
  (control-thread   nil :read-only t)
  (reader-thread    nil :read-only t)
  (read             (missing-arg) :type function)
  (send             (missing-arg) :type function)
  (serve-requests   (missing-arg) :type function)
  (cleanup          nil :type (or null function))
  )

#+(or)
(defun %print-connection (connection stream depth)
  (declare (ignore depth))
  (print-unreadable-object (connection stream :type t :identity t)))

(defvar *emacs-connection* nil
  "The connection to Emacs.
All threads communicate through this interface with Emacs.")

(defvar *swank-state-stack* '()
  "A list of symbols describing the current state.  Used for debugging
and to detect situations where interrupts can be ignored.")

(defslimefun state-stack ()
  "Return the value of *SWANK-STATE-STACK*."
  *swank-state-stack*)

;; Condition for SLIME protocol errors.
(define-condition slime-read-error (error) 
  ((condition :initarg :condition :reader slime-read-error.condition))
  (:report (lambda (condition stream)
             (format stream "~A" (slime-read-error.condition condition)))))

;;;; Helper macros

(defmacro with-io-redirection ((&rest ignore) &body body)
  "Execute BODY with I/O redirection to CONNECTION.
If *REDIRECT-IO* is true, all standard I/O streams are redirected."
  (declare (ignore ignore))
  `(if *redirect-io*
       (call-with-redirected-io *emacs-connection* (lambda () ,@body))
       (progn ,@body)))

(defmacro without-interrupts (&body body)
  `(call-without-interrupts (lambda () ,@body)))

(defmacro destructure-case (value &rest patterns)
  "Dispatch VALUE to one of PATTERNS.
A cross between `case' and `destructuring-bind'.
The pattern syntax is:
  ((HEAD . ARGS) . BODY)
The list of patterns is searched for a HEAD `eq' to the car of
VALUE. If one is found, the BODY is executed with ARGS bound to the
corresponding values in the CDR of VALUE."
  (let ((operator (gensym "op-"))
	(operands (gensym "rand-"))
	(tmp (gensym "tmp-")))
    `(let* ((,tmp ,value)
	    (,operator (car ,tmp))
	    (,operands (cdr ,tmp)))
      (case ,operator
        ,@(mapcar (lambda (clause)
                    (if (eq (car clause) t)
                        `(t ,@(cdr clause))
                        (destructuring-bind ((op &rest rands) &rest body) 
                            clause
                          `(,op (destructuring-bind ,rands ,operands
                                  . ,body)))))
                  patterns)
        ,@(if (eq (caar (last patterns)) t)
              '()
              `((t (error "destructure-case failed: ~S" ,tmp))))))))
  
;;;; TCP Server

(defparameter *redirect-io* t
  "When non-nil redirect Lisp standard I/O to Emacs.
Redirection is done while Lisp is processing a request for Emacs.")

(defvar *use-dedicated-output-stream* t)
(defvar *swank-in-background* nil)
(defvar *log-events* nil)

(defun start-server (port-file &optional (background *swank-in-background*))
  (setup-server 0 (lambda (port) (announce-server-port port-file port))
                background))
                     
(defun create-swank-server (&optional (port +server-port+)
                            (background *swank-in-background*)
                            (announce-fn #'simple-announce-function))
  (setup-server port announce-fn background))

(defparameter *loopback-interface* "127.0.0.1")

(defun setup-server (port announce-fn style)
  (declare (type function announce-fn))
  (let* ((socket (create-socket *loopback-interface* port))
         (port (local-port socket)))
    (funcall announce-fn port)
    (cond ((eq style :spawn)
           (spawn (lambda () (serve-connection socket :spawn)) :name "Swank"))
          (t (serve-connection socket style)))
    port))

(defun serve-connection (socket style)
  (let ((client (accept-connection socket)))
    (close-socket socket)
    (let ((connection (create-connection client style)))
      (init-emacs-connection connection)
      (serve-requests connection))))

(defun serve-requests (connection)
  "Read and process all requests on connections."
  (funcall (connection.serve-requests connection) connection))

(defun init-emacs-connection (connection)
  (setq *emacs-connection* connection)
  (emacs-connected))

(defun announce-server-port (file port)
  (with-open-file (s file
                     :direction :output
                     :if-exists :overwrite
                     :if-does-not-exist :create)
    (format s "~S~%" port))
  (simple-announce-function port))

(defun simple-announce-function (port)
  (when *swank-debug-p*
    (format *debug-io* "~&;; Swank started at port: ~D.~%" port)))

(defun open-streams (socket-io)
  "Return the 4 streams for IO redirection:
 DEDICATED-OUTPUT INPUT OUTPUT IO"
  (multiple-value-bind (output-fn dedicated-output) 
      (make-output-function socket-io)
    (let ((input-fn  (lambda () (read-user-input-from-emacs))))
      (multiple-value-bind (in out) (make-fn-streams input-fn output-fn)
        (let ((out (or dedicated-output out)))
          (let ((io (make-two-way-stream in out)))
            (values dedicated-output in out io)))))))

(defun make-output-function (socket-io)
  "Create function to send user output to Emacs.
This function may open a dedicated socket to send output. It
returns two values: the output function, and the dedicated
stream (or NIL if none was created)."
  (if *use-dedicated-output-stream*
      (let ((stream (open-dedicated-output-stream socket-io)))
        (values (lambda (string)
                  (write-string string stream)
                  (force-output stream))
                stream))
      (values (lambda (string) (send-output-to-emacs string socket-io))
              nil)))

(defun open-dedicated-output-stream (socket-io)
  "Open a dedicated output connection to the Emacs on SOCKET-IO.
Return an output stream suitable for writing program output.

This is an optimized way for Lisp to deliver output to Emacs."
  (let* ((socket (create-socket *loopback-interface* 0))
         (port (local-port socket)))
    (encode-message `(:open-dedicated-output-stream ,port) socket-io)
    (accept-connection socket)))

(defun handle-request ()
  "Read and process one request.  The processing is done in the extend
of the toplevel restart."
  (assert (null *swank-state-stack*))
  (let ((*swank-state-stack* '(:handle-request)))
    (catch 'slime-toplevel
      (with-simple-restart (abort "Return to SLIME toplevel.")
        (with-io-redirection ()
          (let ((*debugger-hook* #'swank-debugger-hook))
            (read-from-emacs)))))))

(defun changelog-date ()
  "Return the datestring of the latest ChangeLog entry.  The date is
determined at compile time."
  (macrolet ((date ()
               (let* ((here (or *compile-file-truename* *load-truename*))
		      (changelog (make-pathname 
				  :name "ChangeLog" 
				  :directory (pathname-directory here)
				  :host (pathname-host here)))
		      (date (with-open-file (file changelog :direction :input)
			      (string (read file)))))
		 `(quote ,date))))
    (date)))

(defun current-socket-io ()
  (connection.socket-io *emacs-connection*))

(defun close-connection (c &optional condition)
  (when condition
    (format *debug-io* "~&;; Connection to Emacs lost.~%;; [~A]~%" condition))
  (let ((cleanup (connection.cleanup c)))
    (when cleanup
      (funcall cleanup c)))
  (close (connection.socket-io c))
  (when (connection.dedicated-output c)
    (close (connection.dedicated-output c))))

(defmacro with-reader-error-handler ((connection) &body body)
  `(handler-case (progn ,@body)
    (slime-read-error (e) (close-connection ,connection e))))

(defun read-loop (control-thread input-stream)
  (with-reader-error-handler (*emacs-connection*)
    (loop (send control-thread (decode-message input-stream)))))

(defvar *active-threads* '())
(defvar *thread-counter* 0)

(defun add-thread (thread)
  (let ((id (mod (1+ *thread-counter*) most-positive-fixnum)))
    (setq *active-threads* (acons id thread *active-threads*)
          *thread-counter* id)
    id))

(defun drop&find (item list key test)
  "Return LIST where item is removed together with the removed
element."
  (declare (type function key test))
  (do ((stack '() (cons (car l) stack))
       (l list (cdr l)))
      ((null l) (values (nreverse stack) nil))
    (when (funcall test item (funcall key (car l)))
      (return (values (nreconc stack (cdr l))
                      (car l))))))

(defun drop-thread (thread)
  "Drop the first occurence of thread in *active-threads* and return its id."
  (multiple-value-bind (list pair) (drop&find thread *active-threads* 
                                              #'cdr #'eql)
    (setq *active-threads* list)
    (assert pair)
    (car pair)))

(defun lookup-thread (thread)
  (let ((probe (rassoc thread *active-threads*)))
    (cond (probe (car probe))
          (t (add-thread thread)))))

(defun lookup-thread-id (id &optional noerror)
  (let ((probe (assoc id *active-threads*)))
    (cond (probe (cdr probe))
          (noerror nil)
          (t (error "Thread id not found ~S" id)))))

(defun dispatch-loop (socket-io)
  (setq *active-threads* '())
  (setq *thread-counter* 0)
  (loop (with-simple-restart (abort "Retstart dispatch loop.")
	  (loop (dispatch-event (receive) socket-io)))))

(defun simple-break ()
  (with-simple-restart  (continue "Continue from interrupt.")
    (let ((*debugger-hook* #'swank-debugger-hook))
      (invoke-debugger 
       (make-condition 'simple-error 
                       :format-control "Interrupt from Emacs")))))

(defun interrupt-worker-thread (thread)
  (let ((thread (etypecase thread
                  ((member t) (cdr (car *active-threads*)))
                  (fixnum (lookup-thread-id thread)))))
    (interrupt-thread thread #'simple-break)))

(defun dispatch-event (event socket-io)
  (log-event "DISPATCHING: ~S~%" event)
  (destructure-case event
    ((:emacs-rex string package thread id)
     (let ((thread (etypecase thread
                     ((member t) (spawn #'handle-request :name "worker"))
                     (fixnum (lookup-thread-id thread)))))
       (send thread `(eval-string ,string ,package ,id))
       (add-thread thread)))
    ((:emacs-interrupt thread)
     (interrupt-worker-thread thread))
    (((:debug :debug-condition :debug-activate) thread &rest args)
     (encode-message `(,(car event) ,(add-thread thread) . ,args) socket-io))
    ((:debug-return thread level)
     (encode-message `(:debug-return ,(drop-thread thread) ,level) socket-io))
    ((:return thread &rest args)
     (drop-thread thread)
     (encode-message `(:return ,@args) socket-io))
    ((:read-string thread &rest args)
     (encode-message `(:read-string ,(add-thread thread) ,@args) socket-io))
    ((:read-aborted thread &rest args)
     (encode-message `(:read-aborted ,(drop-thread thread) ,@args) socket-io))
    ((:emacs-return-string thread tag string)
     (send (lookup-thread-id thread) `(take-input ,tag ,string)))
    (((:read-output :new-package :new-features :ed)
      &rest _)
     (declare (ignore _))
     (encode-message event socket-io))))

(defun create-connection (socket-io style)
  (multiple-value-bind (dedicated in out io) (open-streams socket-io)
    (ecase style
      (:spawn
       (let* ((control-thread (spawn (lambda () (dispatch-loop socket-io))
                                     :name "control-thread"))
              (reader-thread (spawn (lambda () 
                                      (read-loop control-thread socket-io))
                                    :name "reader-thread")))
         (make-connection :socket-io socket-io :dedicated-output dedicated
                          :user-input in :user-output out :user-io io
                          :control-thread control-thread
                          :reader-thread reader-thread
                          :read #'read-from-control-thread
                          :send #'send-to-control-thread
                          :serve-requests (lambda (c) c))))
      (:sigio
       (make-connection :socket-io socket-io :dedicated-output dedicated
                        :user-input in :user-output out :user-io io
                        :read #'read-from-socket-io
                        :send #'send-to-socket-io
                        :serve-requests #'install-sigio-handler
                        :cleanup #'deinstall-fd-handler))
      (:fd-handler
       (make-connection :socket-io socket-io :dedicated-output dedicated
                        :user-input in :user-output out :user-io io
                        :read #'read-from-socket-io
                        :send #'send-to-socket-io
                        :serve-requests #'install-fd-handler
                        :cleanup #'deinstall-fd-handler))
      ((nil)
       (make-connection :socket-io socket-io :dedicated-output dedicated
                        :user-input in :user-output out :user-io io
                        :read #'read-from-socket-io
                        :send #'send-to-socket-io
                        :serve-requests #'simple-serve-requests)))))

(defun process-available-input (stream fn)
  (loop while (and (open-stream-p stream) 
                   (listen stream))
        do (funcall fn)))

;;;;;; Signal driven IO

(defun install-sigio-handler (connection)
  (let ((client (connection.socket-io connection)))
    (flet ((handler ()   
             (cond ((null *swank-state-stack*)
                    (with-reader-error-handler (connection)
                      (process-available-input client #'handle-request)))
                   ((eq (car *swank-state-stack*) :read-next-form))
                   (t (process-available-input client #'read-from-emacs)))))
      (add-sigio-handler client #'handler)
      (handler))))

(defun deinstall-sigio-handler (connection)
  (remove-sigio-handlers (connection.socket-io connection)))

;;;;;; SERVE-EVENT based IO

(defun install-fd-handler (connection)
  (let ((client (connection.socket-io connection)))
    (flet ((handler ()   
             (cond ((null *swank-state-stack*)
                    (with-reader-error-handler (connection)
                      (process-available-input client #'handle-request)))
                   ((eq (car *swank-state-stack*) :read-next-form))
                   (t (process-available-input client #'read-from-emacs)))))
      (encode-message '(:use-sigint-for-interrupt) client)
      (setq *debugger-hook* 
            (lambda (c h)
              (with-reader-error-handler (connection)
		(block debugger
		  (catch 'slime-toplevel
		    (swank-debugger-hook c h)
		    (return-from debugger))
		  (abort)))))
      (add-fd-handler client #'handler)
      (handler))))

(defun deinstall-fd-handler (connection)
  (remove-fd-handlers (connection.socket-io connection)))

;;;;;; Simple sequential IO

(defun simple-serve-requests (connection)
  (let ((socket-io (connection.socket-io connection)))
    (encode-message '(:use-sigint-for-interrupt) socket-io)
    (with-reader-error-handler (connection)
      (loop (handle-request)))))

(defun read-from-socket-io ()
  (let ((event (decode-message (current-socket-io))))
    (log-event "DISPATCHING: ~S~%" event)
    (destructure-case event
      ((:emacs-rex string package thread id)
       (declare (ignore thread))
       `(eval-string ,string ,package ,id))
      ((:emacs-interrupt thread)
       (declare (ignore thread))
       '(simple-break))
      ((:emacs-return-string thread tag string)
       (declare (ignore thread))
       `(take-input ,tag ,string)))))

(defun send-to-socket-io (event) 
  (log-event "DISPATCHING: ~S~%" event)
  (flet ((send (o) (encode-message o (current-socket-io))))
    (destructure-case event
      (((:debug-activate :debug :debug-return :read-string :read-aborted) 
        thread &rest args)
       (declare (ignore thread))
       (send `(,(car event) 0 ,@args)))
      ((:return thread &rest args)
       (declare (ignore thread))
       (send `(:return ,@args)))
      (((:read-output :new-package :new-features :ed :debug-condition)
        &rest _)
       (declare (ignore _))
       (send event)))))


;;;; IO to Emacs
;;;
;;; The lower layer is a socket connection. Emacs sends us forms to
;;; evaluate, and we accept these by calling READ-FROM-EMACS. These
;;; evaluations can send messages back to Emacs as a side-effect by
;;; calling SEND-TO-EMACS.

(defun call-with-redirected-io (connection function)
  "Call FUNCTION with I/O streams redirected via CONNECTION."
  (declare (type function function))
  (let* ((io  (connection.user-io connection))
         (in  (connection.user-input connection))
         (out (connection.user-output connection))
         (*standard-output* out)
         (*error-output* out)
         (*trace-output* out)
         (*debug-io* io)
         (*query-io* io)
         (*standard-input* in)
         (*terminal-io* io))
    (funcall function)))

(defun log-event (format-string &rest args)
  "Write a message to *terminal-io* when *log-events* is non-nil.
Useful for low level debugging."
  (when *log-events*
    (apply #'format *terminal-io* format-string args)))

(defun read-from-emacs ()
  "Read and process a request from Emacs."
  (apply #'funcall (funcall (connection.read *emacs-connection*))))

(defun read-from-control-thread ()
  (receive))

(defun decode-message (stream)
  "Read an S-expression from STREAM using the SLIME protocol.
If a protocol error occurs then a SLIME-READ-ERROR is signalled."
  (let ((*swank-state-stack* (cons :read-next-form *swank-state-stack*)))
    (flet ((next-byte () (char-code (read-char stream t))))
      (handler-case
          (let* ((length (logior (ash (next-byte) 16)
                                 (ash (next-byte) 8)
                                 (next-byte)))
                 (string (make-string length))
                 (pos (read-sequence string stream)))
            (assert (= pos length) ()
                    "Short read: length=~D  pos=~D" length pos)
            (let ((form (read-form string)))
              (log-event "READ: ~A~%" string)
              form))
        (serious-condition (c)
          (error (make-condition 'slime-read-error :condition c)))))))

(defun read-form (string)
  (with-standard-io-syntax
    (let ((*package* *swank-io-package*))
      (read-from-string string))))

(defvar *slime-features* nil
  "The feature list that has been sent to Emacs.")

(defun sync-state-to-emacs ()
  "Update Emacs if any relevant Lisp state has changed."
  (unless (eq *slime-features* *features*)
    (setq *slime-features* *features*)
    (send-to-emacs (list :new-features (mapcar #'symbol-name *features*)))))

(defun send-to-emacs (object)
  "Send OBJECT to Emacs."
  (funcall (connection.send *emacs-connection*) object))

(defun send-oob-to-emacs (object)
  (send-to-emacs object))

(defun send-to-control-thread (object)
  (send (connection.control-thread *emacs-connection*) object))

(defun encode-message (message stream)
  (let* ((string (prin1-to-string-for-emacs message))
         (length (1+ (length string))))
    (log-event "WRITE: ~A~%" string)
    (without-interrupts
     (loop for position from 16 downto 0 by 8
           do (write-char (code-char (ldb (byte 8 position) length))
                          stream))
     (write-string string stream)
     (terpri stream)
     (force-output stream))))

(defun prin1-to-string-for-emacs (object)
  (with-standard-io-syntax
    (let ((*print-case* :downcase)
          (*print-readably* t)
          (*print-pretty* nil)
          (*package* *swank-io-package*))
      (prin1-to-string object))))

(defun force-user-output ()
  (force-output (connection.user-io *emacs-connection*))
  (force-output (connection.user-output *emacs-connection*)))

(defun clear-user-input  ()
  (clear-input (connection.user-input *emacs-connection*)))

(defun send-output-to-emacs (string socket-io)
  (encode-message `(:read-output ,string) socket-io))

(defvar *read-input-catch-tag* 0)

(defun read-user-input-from-emacs ()
  (let ((*read-input-catch-tag* (1+ *read-input-catch-tag*)))
    (force-output)
    (send-to-emacs `(:read-string ,(current-thread)
                     ,*read-input-catch-tag*))
    (let ((ok nil))
      (unwind-protect
           (prog1 (catch *read-input-catch-tag* 
                    (loop (read-from-emacs)))
             (setq ok t))
        (unless ok 
          (send-to-emacs `(:read-aborted ,(current-thread)
                           *read-input-catch-tag*)))))))

(defslimefun take-input (tag input)
  (throw tag input))

(defslimefun connection-info ()
  "Return a list of the form: 
\(VERSION PID IMPLEMENTATION-TYPE IMPLEMENTATION-NAME FEATURES)."
  (list (changelog-date)
        (getpid)
        (lisp-implementation-type)
        (lisp-implementation-type-name)
        (setq *slime-features* *features*)))


;;;; Reading and printing

(defvar *buffer-package*)
(setf (documentation '*buffer-package* 'symbol)
      "Package corresponding to slime-buffer-package.  

EVAL-STRING binds *buffer-package*.  Strings originating from a slime
buffer are best read in this package.  See also FROM-STRING and TO-STRING.")

(defun from-string (string)
  "Read string in the *BUFFER-PACKAGE*"
  (let ((*package* *buffer-package*))
    (read-from-string string)))

(defun symbol-from-string (string)
  "Read string in the *BUFFER-PACKAGE*"
  (let ((*package* *buffer-package*))
    (find-symbol (string-upcase string))))

(defun to-string (string)
  "Write string in the *BUFFER-PACKAGE*."
  (let ((*package* *buffer-package*))
    (prin1-to-string string)))

(defun guess-package-from-string (name &optional (default-package *package*))
  (or (and name
           (or (find-package name)
               (find-package (string-upcase name))))
      default-package))

(defun find-symbol-designator (string &optional
                                      (default-package *buffer-package*))
  "Return the symbol corresponding to the symbol designator STRING.
If string is not package qualified use DEFAULT-PACKAGE for the
resolution.  Return nil if no such symbol exists."
  (multiple-value-bind (name package-name internal-p)
      (tokenize-symbol-designator (case-convert string))
    (cond ((and package-name (not (find-package package-name)))
           (values nil nil))
          (t
           (let ((package (or (find-package package-name) default-package)))
             (multiple-value-bind (symbol access) (find-symbol name package)
               (cond ((and symbol package-name (not internal-p)
                           (not (eq access :external)))
                      (values nil nil))
                     (symbol (values symbol access)))))))))

(defun find-symbol-or-lose (string &optional 
                            (default-package *buffer-package*))
  "Like FIND-SYMBOL-DESIGNATOR but signal an error the symbols doesn't
exists."
  (multiple-value-bind (symbol package)
      (find-symbol-designator string default-package)
    (cond (package (values symbol package))
          (t (error "Unknown symbol: ~S [in ~A]" string default-package)))))

;;; We use a special pprint-dispatch table for printing the arglist.
;;; An argument is either a symbol or a list.  The name of the
;;; argument is PRINCed but the other components of an argument
;;; --default value or type-- are PPRINTed.  We do this to nicely
;;; cover cases like (&key (function #'cons) (quote 'quote)).  Too
;;; much code for such a minor feature?

(defvar *initial-pprint-dispatch-table* (copy-pprint-dispatch))

(defun print-cons-argument (stream object)
  (pprint-logical-block (stream object :prefix "(" :suffix ")")
    (princ (car object) stream)
    (write-char #\space stream)
    (let ((*print-pprint-dispatch* *initial-pprint-dispatch-table*))
      (pprint-fill stream (cdr object) nil))))

(defun print-symbol-argument (stream object)
  (let ((*print-pprint-dispatch* *initial-pprint-dispatch-table*))
    (princ object stream)))

(defvar *arglist-pprint-dispatch-table* 
  (let ((table (copy-pprint-dispatch)))
    (set-pprint-dispatch 'cons #'print-cons-argument 0 table)
    (set-pprint-dispatch 'symbol #'print-symbol-argument 0 table)
    table))

(defun format-arglist (function-name lambda-list-fn)
  "Use LAMBDA-LIST-FN to format the arglist for FUNCTION-NAME.
Call LAMBDA-LIST-FN with the symbol corresponding to FUNCTION-NAME."
  (declare (type function lambda-list-fn))
  (multiple-value-bind (arglist condition)
      (ignore-errors 
        (let ((symbol (find-symbol-or-lose function-name)))
          (values (funcall lambda-list-fn symbol))))
    (cond (condition (format nil "(-- ~A)" condition))
          (t (let ((*print-case* :downcase)
                   (*print-pprint-dispatch* *arglist-pprint-dispatch-table*)
                   (*print-level* nil)
                   (*print-length* nil))
               (with-output-to-string (stream)
                 (pprint-fill stream arglist)))))))


;;;; Debugger

;;; These variables are dynamically bound during debugging.

;; The condition being debugged.
(defvar *swank-debugger-condition* nil)

(defvar *sldb-level* 0
  "The current level of recursive debugging.")

(defvar *sldb-initial-frames* 20
  "The initial number of backtrace frames to send to Emacs.")

(defun swank-debugger-hook (condition hook)
  "Debugger entry point, called from *DEBUGGER-HOOK*.
Sends a message to Emacs declaring that the debugger has been entered,
then waits to handle further requests from Emacs. Eventually returns
after Emacs causes a restart to be invoked."
  (declare (ignore hook))
  (let ((*swank-debugger-condition* condition)
        (*package* (or (and (boundp '*buffer-package*)
                            (symbol-value '*buffer-package*))
                       *package*))
        (*sldb-level* (1+ *sldb-level*))
        (*swank-state-stack* (cons :swank-debugger-hook *swank-state-stack*)))
      (force-user-output)
      (call-with-debugging-environment
       (lambda () (sldb-loop *sldb-level*)))))

(defun sldb-loop (level)
  (unwind-protect
       (catch 'sldb-enter-default-debugger
         (send-to-emacs 
          (list* :debug (current-thread) *sldb-level* 
                 (debugger-info-for-emacs 0 *sldb-initial-frames*)))
         (loop (catch 'sldb-loop-catcher
                 (with-simple-restart (abort "Return to sldb level ~D." level)
                   (send-to-emacs (list :debug-activate (current-thread)
                                        *sldb-level*))
                   (handler-bind ((sldb-condition #'handle-sldb-condition))
                     (read-from-emacs))))))
    (send-to-emacs `(:debug-return ,(current-thread) ,level))))

(defun sldb-break-with-default-debugger ()
  (throw 'sldb-enter-default-debugger nil))

(defun handle-sldb-condition (condition)
  "Handle an internal debugger condition.
Rather than recursively debug the debugger (a dangerous idea!), these
conditions are simply reported."
  (let ((real-condition (original-condition condition)))
    (send-to-emacs `(:debug-condition ,(current-thread)
                     ,(princ-to-string real-condition))))
  (throw 'sldb-loop-catcher nil))

(defun safe-condition-message (condition)
  "Safely print condition to a string, handling any errors during
printing."
  (handler-case
      (princ-to-string condition)
    (error (cond)
      ;; Beware of recursive errors in printing, so only use the condition
      ;; if it is printable itself:
      (format nil "Unable to display error condition~@[: ~A~]"
	      (ignore-errors (princ-to-string cond))))))

(defun debugger-condition-for-emacs ()
  (list (safe-condition-message *swank-debugger-condition*)
        (format nil "   [Condition of type ~S]"
                (type-of *swank-debugger-condition*))))

(defun print-with-frame-label (n fn)
  "Bind some printer variables to properly indent the frame and call
FN with a string-stream for printing a frame of a bracktrace.  Return
the string."
  (declare (type function fn))
  (let* ((label (format nil "  ~D: " n))
         (string (with-output-to-string (stream) 
                   (let ((*print-pretty* *sldb-pprint-frames*)
                         (*print-circle* t))
                     (princ label stream) (funcall fn stream)))))
    (subseq string (length label))))

(defslimefun sldb-continue ()
  (continue))

(defslimefun invoke-nth-restart-for-emacs (sldb-level n)
  "Invoke the Nth available restart.
SLDB-LEVEL is the debug level when the request was made. If this
has changed, ignore the request."
  (when (= sldb-level *sldb-level*)
    (invoke-nth-restart n)))

(defslimefun eval-string-in-frame (string index)
  (to-string (eval-in-frame (from-string string) index)))


;;;; Evaluation

(defun eval-in-emacs (form)
  "Execute FORM in Emacs."
  (destructuring-bind (fn &rest args) form
    (send-to-emacs `(:%apply ,(string-downcase (string fn)) ,args))))

(defslimefun eval-string (string buffer-package id)
  (let ((*debugger-hook* #'swank-debugger-hook))
    (let (ok result)
      (unwind-protect
           (let ((*buffer-package* (guess-package-from-string buffer-package))
                 (*swank-state-stack* (cons :eval-string *swank-state-stack*)))
             (assert (packagep *buffer-package*))
             (setq result (eval (read-form string)))
             (force-output)
             (setq ok t))
        (sync-state-to-emacs)
        (force-user-output)
        (send-to-emacs `(:return ,(current-thread)
                         ,(if ok `(:ok ,result) '(:abort)) 
                         ,id))))))

(defslimefun oneway-eval-string (string buffer-package)
  "Evaluate STRING in BUFFER-PACKAGE, without sending a reply.
The debugger hook is inhibited during the evaluation."
  (let ((*buffer-package* (guess-package-from-string buffer-package))
        (*package* *buffer-package*)
        (*debugger-hook* nil))
    (eval (read-form string))))

(defun format-values-for-echo-area (values)
  (cond (values (format nil "~{~S~^, ~}" values))
        (t "; No value")))

(defslimefun interactive-eval (string)
  (let ((values (multiple-value-list
                 (let ((*package* *buffer-package*))
                   (eval (from-string string))))))
    (force-output)
    (format-values-for-echo-area values)))

(defun eval-region (string &optional package-update-p)
  "Evaluate STRING and return the result.
If PACKAGE-UPDATE-P is non-nil, and evaluation causes a package
change, then send Emacs an update."
  (let ((*package* *buffer-package*)
        - values)
    (unwind-protect
         (with-input-from-string (stream string)
           (loop for form = (read stream nil stream)
                 until (eq form stream)
                 do (progn
                      (setq - form)
                      (setq values (multiple-value-list (eval form)))
                      (force-output))
                 finally (return (values values -))))
      (when (and package-update-p (not (eq *package* *buffer-package*)))
        (send-to-emacs 
         (list :new-package (shortest-package-nickname *package*)))))))

(defun shortest-package-nickname (package)
  "Return the shortest nickname (or canonical name) of PACKAGE."
  (loop for name in (cons (package-name package) (package-nicknames package))
        for shortest = name then (if (< (length name) (length shortest))
                                     name
                                     shortest)
        finally (return shortest)))

(defslimefun interactive-eval-region (string)
  (let ((*package* *buffer-package*))
    (format-values-for-echo-area (eval-region string))))

(defslimefun re-evaluate-defvar (form)
  (let ((*package* *buffer-package*))
    (let ((form (read-from-string form)))
      (destructuring-bind (dv name &optional value doc) form
	(declare (ignore value doc))
	(assert (eq dv 'defvar))
	(makunbound name)
	(prin1-to-string (eval form))))))

(defvar *swank-pprint-circle* *print-circle*
  "*PRINT-CIRCLE* is bound to this volue when pretty printing slime output.")

(defvar *swank-pprint-escape* *print-escape*
  "*PRINT-ESCAPE* is bound to this volue when pretty printing slime output.")

(defvar *swank-pprint-level* *print-level*
  "*PRINT-LEVEL* is bound to this volue when pretty printing slime output.")

(defvar *swank-pprint-length* *print-length*
  "*PRINT-LENGTH* is bound to this volue when pretty printing slime output.")

(defun swank-pprint (list)
  "Bind some printer variables and pretty print each object in LIST."
  (let ((*print-pretty* t)
        (*print-circle* *swank-pprint-circle*)
        (*print-escape* *swank-pprint-escape*)
        (*print-level* *swank-pprint-level*)
        (*print-length* *swank-pprint-length*)
        (*package* *buffer-package*))
    (cond ((null list) "; No value")
          (t (with-output-to-string (*standard-output*)
               (dolist (o list)
                 (pprint o)
                 (terpri)))))))

(defslimefun pprint-eval (string)
  (let ((*package* *buffer-package*))
    (swank-pprint (multiple-value-list (eval (read-from-string string))))))

(defslimefun set-package (package)
  "Set *package* to PACKAGE and return its name and shortest nickname."
  (let ((p (setq *package* (guess-package-from-string package))))
    (list (package-name p) (shortest-package-nickname p))))

(defslimefun listener-eval (string)
  (clear-user-input)
  (multiple-value-bind (values last-form) (eval-region string t)
    (setq +++ ++  ++ +  + last-form
	  *** **  ** *  * (car values)
	  /// //  // /  / values)
    (cond ((null values) "; No value")
          (t
           (let ((*package* *buffer-package*))
             (format nil "~{~S~^~%~}" values))))))

(defslimefun ed-in-emacs (&optional what)
  "Edit WHAT in Emacs.
WHAT can be a filename (pathname or string) or function name (symbol)."
  (send-oob-to-emacs `(:ed ,(if (pathnamep what)
                                (canonicalize-filename what)
                                what))))


;;;; Compilation Commands.

(defvar *compiler-notes* '()
  "List of compiler notes for the last compilation unit.")

(defun clear-compiler-notes ()  
  (setf *compiler-notes* '()))

(defun canonicalize-filename (filename)
  (namestring (truename filename)))

(defslimefun compiler-notes-for-emacs ()
  "Return the list of compiler notes for the last compilation unit."
  (reverse *compiler-notes*))

(defun measure-time-interval (fn)
  "Call FN and return the first return value and the elapsed time.
The time is measured in microseconds."
  (declare (type function fn))
  (let ((before (get-internal-real-time)))
    (values
     (funcall fn)
     (* (- (get-internal-real-time) before)
        (/ 1000000 internal-time-units-per-second)))))

(defun record-note-for-condition (condition)
  "Record a note for a compiler-condition."
  (push (make-compiler-note condition) *compiler-notes*))

(defun make-compiler-note (condition)
  "Make a compiler note data structure from a compiler-condition."
  (declare (type compiler-condition condition))
  (list* :message (message condition)
         :severity (severity condition)
         :location (location condition)
         (let ((s (short-message condition)))
           (if s (list :short-message s)))))

(defun swank-compiler (function)
  (clear-compiler-notes)
  (multiple-value-bind (result usecs)
      (handler-bind ((compiler-condition #'record-note-for-condition))
        (measure-time-interval function))
    (list (to-string result)
	  (format nil "~,2F" (/ usecs 1000000.0)))))

(defslimefun swank-compile-file (filename load-p)
  "Compile FILENAME and, when LOAD-P, load the result.
Record compiler notes signalled as `compiler-condition's."
  (swank-compiler (lambda () (compile-file-for-emacs filename load-p))))

(defslimefun swank-compile-string (string buffer position)
  "Compile STRING (exerpted from BUFFER at POSITION).
Record compiler notes signalled as `compiler-condition's."
  (swank-compiler
   (lambda () 
     (compile-string-for-emacs string :buffer buffer :position position))))

(defslimefun swank-load-system (system)
  "Compile and load SYSTEM using ASDF.
Record compiler notes signalled as `compiler-condition's."
  (swank-compiler  (lambda ()  (compile-system-for-emacs system))))


;;;; Macroexpansion

(defun apply-macro-expander (expander string)
  (declare (type function expander))
  (swank-pprint (list (funcall expander (from-string string)))))

(defslimefun swank-macroexpand-1 (string)
  (apply-macro-expander #'macroexpand-1 string))

(defslimefun swank-macroexpand (string)
  (apply-macro-expander #'macroexpand string))

(defslimefun disassemble-symbol (symbol-name)
  (print-output-to-string (lambda () (disassemble (from-string symbol-name)))))

(defslimefun swank-macroexpand-all (string)
  (apply-macro-expander #'macroexpand-all string))


;;;; Completion

(defun case-convert (string)
  "Convert STRING according to the current readtable-case."
  (check-type string string)
  (ecase (readtable-case *readtable*)
    (:upcase (string-upcase string))
    (:downcase (string-downcase string))
    (:preserve string)
    (:invert (cond ((every #'lower-case-p string) (string-upcase string))
                   ((every #'upper-case-p string) (string-downcase string))
                   (t string)))))

(defun carefully-find-package (name default-package-name)
  "Find the package with name NAME, or DEFAULT-PACKAGE-NAME, or the
*buffer-package*.  NAME and DEFAULT-PACKAGE-NAME can be nil."
  (let ((n (cond ((equal name "") "KEYWORD")
                 (t (or name default-package-name)))))
    (if n 
        (find-package (case-convert n))
        *buffer-package*)))

(defslimefun completions (string default-package-name)
  "Return a list of completions for a symbol designator STRING.  

The result is the list (COMPLETION-SET
COMPLETED-PREFIX). COMPLETION-SET is the list of all matching
completions, and COMPLETED-PREFIX is the best (partial)
completion of the input string.

If STRING is package qualified the result list will also be
qualified.  If string is non-qualified the result strings are
also not qualified and are considered relative to
DEFAULT-PACKAGE-NAME.

The way symbols are matched depends on the symbol designator's
format. The cases are as follows:
  FOO      - Symbols with matching prefix and accessible in the buffer package.
  PKG:FOO  - Symbols with matching prefix and external in package PKG.
  PKG::FOO - Symbols with matching prefix and accessible in package PKG."
  (declare (type simple-base-string string))
  (multiple-value-bind (name package-name internal-p)
      (tokenize-symbol-designator string)
    (let ((package (carefully-find-package package-name default-package-name))
          (completions nil))
      (flet ((symbol-matches-p (symbol)
               (and (compound-prefix-match name (symbol-name symbol))
                    (or internal-p 
                        (null package-name)
                        (symbol-external-p symbol package)))))
        (when package 
          (do-symbols (symbol package)
            (when (symbol-matches-p symbol)
              (push symbol completions)))))
      (let ((*print-case* (if (find-if #'upper-case-p string)
                              :upcase :downcase)))
        (let ((completion-set
               (mapcar (lambda (s)
                         (cond (internal-p 
                                (format nil "~A::~A" package-name s))
                               (package-name 
                                (format nil "~A:~A" package-name s))
                               (t
                                (format nil "~A" s))))
                       ;; DO-SYMBOLS can consider the same symbol more than
                       ;; once, so remove duplicates.
                       (remove-duplicates (sort completions #'string<
                                                :key #'symbol-name)))))
          (list completion-set (longest-completion completion-set)))))))

(defun tokenize-symbol-designator (string)
  "Parse STRING as a symbol designator.
Return three values:
 SYMBOL-NAME
 PACKAGE-NAME, or nil if the designator does not include an explicit package.
 INTERNAL-P, if the symbol is qualified with `::'."
  (declare (type simple-base-string string))
  (values (let ((pos (position #\: string :from-end t)))
            (if pos (subseq string (1+ pos)) string))
          (let ((pos (position #\: string)))
            (if pos (subseq string 0 pos) nil))
          (search "::" string)))

(defun symbol-external-p (symbol &optional (package (symbol-package symbol)))
  "True if SYMBOL is external in PACKAGE.
If PACKAGE is not specified, the home package of SYMBOL is used."
  (multiple-value-bind (_ status)
      (find-symbol (symbol-name symbol) (or package (symbol-package symbol)))
    (declare (ignore _))
    (eq status :external)))
 

;;;;; Subword-word matching

(defun compound-prefix-match (prefix target)
  "Return true if PREFIX is a compound-prefix of TARGET.
Viewing each of PREFIX and TARGET as a series of substrings delimited
by hyphens, if each substring of PREFIX is a prefix of the
corresponding substring in TARGET then we call PREFIX a
compound-prefix of TARGET.

Examples:
\(compound-prefix-match \"foo\" \"foobar\") => t
\(compound-prefix-match \"m--b\" \"multiple-value-bind\") => t
\(compound-prefix-match \"m-v-c\" \"multiple-value-bind\") => NIL"
  (declare (type simple-base-string prefix target))
  (loop for ch across prefix
        with tpos = 0
        always (and (< tpos (length target))
                    (if (char= ch #\-)
                        (setf tpos (position #\- target :start tpos))
                        (char-equal ch (aref target tpos))))
        do (incf tpos)))


;;;;; Extending the input string by completion

(defun longest-completion (completions)
  "Return the longest prefix for all COMPLETIONS."
  (untokenize-completion
   (mapcar #'longest-common-prefix
           (transpose-lists (mapcar #'tokenize-completion completions)))))

(defun tokenize-completion (string)
  "Return all substrings of STRING delimited by #\-."
  (declare (type simple-base-string string))
  (loop with end
        for start = 0 then (1+ end)
        until (> start (length string))
        do (setq end (or (position #\- string :start start) (length string)))
        collect (subseq string start end)))

(defun untokenize-completion (tokens)
  (format nil "~{~A~^-~}" tokens))  

(defun longest-common-prefix (strings)
  "Return the longest string that is a common prefix of STRINGS."
  (if (null strings)
      ""
      (flet ((common-prefix (s1 s2)
               (let ((diff-pos (mismatch s1 s2)))
                 (if diff-pos (subseq s1 0 diff-pos) s1))))
        (reduce #'common-prefix strings))))

(defun transpose-lists (lists)
  "Turn a list-of-lists on its side.
If the rows are of unequal length, truncate uniformly to the shortest.

For example:
\(transpose-lists '((ONE TWO THREE) (1 2)))
  => ((ONE 1) (TWO 2))"
  ;; A cute function from PAIP p.574
  (if lists (apply #'mapcar #'list lists)))


;;;; Documentation

(defslimefun apropos-list-for-emacs  (name &optional external-only package)
  "Make an apropos search for Emacs.
The result is a list of property lists."
  (mapcan (listify #'briefly-describe-symbol-for-emacs)
          (sort (apropos-symbols name
                                 external-only
                                 (if package
                                     (or (find-package (read-from-string package))
                                         (error "No such package: ~S" package))
                                     nil))
                #'present-symbol-before-p)))

(defun briefly-describe-symbol-for-emacs (symbol)
  "Return a property list describing SYMBOL.
Like `describe-symbol-for-emacs' but with at most one line per item."
  (flet ((first-line (string) 
           (declare (type simple-base-string string))
           (let ((pos (position #\newline string)))
             (if (null pos) string (subseq string 0 pos)))))
    (let ((desc (map-if #'stringp #'first-line 
                        (describe-symbol-for-emacs symbol))))
      (if desc 
          (list* :designator (to-string symbol) desc)))))

(defun map-if (test fn &rest lists)
  "Like (mapcar FN . LISTS) but only call FN on objects satisfying TEST.
Example:
\(map-if #'oddp #'- '(1 2 3 4 5)) => (-1 2 -3 4 -5)"
  (declare (type function test fn))
  (apply #'mapcar
         (lambda (x) (if (funcall test x) (funcall fn x) x))
         lists))

(defun listify (f)
  "Return a function like F, but which returns any non-null value
wrapped in a list."
  (declare (type function f))
  (lambda (x)
    (let ((y (funcall f x)))
      (and y (list y)))))

(defun present-symbol-before-p (a b)
  "Return true if A belongs before B in a printed summary of symbols.
Sorted alphabetically by package name and then symbol name, except
that symbols accessible in the current package go first."
  (flet ((accessible (s)
           (find-symbol (symbol-name s) *buffer-package*)))
    (cond ((and (accessible a) (accessible b))
           (string< (symbol-name a) (symbol-name b)))
          ((accessible a) t)
          ((accessible b) nil)
          (t
           (string< (package-name (symbol-package a))
                    (package-name (symbol-package b)))))))

(defun apropos-symbols (string &optional external-only package)
  (remove-if (lambda (sym)
               (or (keywordp sym) 
                   (and external-only
;;                        (not (equal (symbol-package sym) *buffer-package*))
                        (not (symbol-external-p sym)))))
             (apropos-list string package)))

(defun print-output-to-string (fn)
  (declare (type function fn))
  (with-output-to-string (*standard-output*)
    (let ((*debug-io* *standard-output*))
      (funcall fn))))

(defun print-description-to-string (object)
  (print-output-to-string (lambda () (describe object))))

(defslimefun describe-symbol (symbol-name)
  (multiple-value-bind (symbol foundp)
      (find-symbol-designator symbol-name)
    (cond (foundp (print-description-to-string symbol))
	  (t (format nil "Unknown symbol: ~S [in ~A]" 
		     symbol-name *buffer-package*)))))

(defslimefun describe-function (symbol-name)
  (print-description-to-string
   (symbol-function (find-symbol-designator symbol-name))))

(defslimefun documentation-symbol (symbol-name &optional default)
  (let ((*package* *buffer-package*))
    (let ((vdoc (documentation (symbol-from-string symbol-name) 'variable))
          (fdoc (documentation (symbol-from-string symbol-name) 'function)))
      (or (and (or vdoc fdoc)
               (concatenate 'string
                            fdoc
                            (and vdoc fdoc '(#\Newline #\Newline))
                            vdoc))
          default))))


;;;;

(defslimefun list-all-package-names ()
  (mapcar #'package-name (list-all-packages)))

;; Use eval for the sake of portability... 
(defun tracedp (fspec)
  (member fspec (eval '(trace))))

(defslimefun toggle-trace-fdefinition (fname-string)
  (let ((fname (from-string fname-string)))
    (cond ((tracedp fname)
	   (eval `(untrace ,fname))
	   (format nil "~S is now untraced." fname))
	  (t
           (eval `(trace ,fname))
	   (format nil "~S is now traced." fname)))))

(defslimefun untrace-all ()
  (untrace))

(defslimefun undefine-function (fname-string)
  (let ((fname (from-string fname-string)))
    (format nil "~S" (fmakunbound fname))))

(defslimefun load-file (filename)
  (to-string (load filename)))

(defslimefun throw-to-toplevel ()
  (throw 'slime-toplevel nil))


;;;; Profiling

(defun profiledp (fspec)
  (member fspec (profiled-functions)))

(defslimefun toggle-profile-fdefinition (fname-string)
  (let ((fname (from-string fname-string)))
    (cond ((profiledp fname)
	   (unprofile fname)
	   (format nil "~S is now unprofiled." fname))
	  (t
           (profile fname)
	   (format nil "~S is now profiled." fname)))))  


;;;; Source Locations

(defstruct (:location (:type list) :named
                      (:constructor make-location (buffer position)))
  buffer position)

(defstruct (:error (:type list) :named (:constructor)) message)
(defstruct (:file (:type list) :named (:constructor)) name)
(defstruct (:buffer (:type list) :named (:constructor)) name)
(defstruct (:position (:type list) :named (:constructor)) pos)

(defun alistify (list key test)
  "Partition the elements of LIST into an alist.  KEY extracts the key
from an element and TEST is used to compare keys."
  (declare (type function key))
  (let ((alist '()))
    (dolist (e list)
      (let* ((k (funcall key e))
	     (probe (assoc k alist :test test)))
	(if probe
	    (push e (cdr probe))
            (push (cons k (list e)) alist))))
    alist))
  
(defun location-position< (pos1 pos2)
  (cond ((and (position-p pos1) (position-p pos2))
         (< (position-pos pos1)
            (position-pos pos2)))
        (t nil)))

(defun partition (list predicate)
  (declare (type function predicate))
  (loop for e in list 
	if (funcall predicate e) collect e into yes
	else collect e into no
	finally (return (values yes no))))

(defun group-xrefs (xrefs)
  (flet ((xref-buffer (xref) (location-buffer (cdr xref)))
         (xref-position (xref) (location-position (cdr xref))))
    (multiple-value-bind (resolved errors) 
	(partition xrefs (lambda (x) (location-p (cdr x))))
      (let ((alist (alistify resolved #'xref-buffer #'equal)))
	(append 
	 (loop for (key . list) in alist
	       collect (cons (to-string key) 
			     (sort list #'location-position<
				   :key #'xref-position)))
	 (if errors
	     `(("Unresolved" . ,errors))))))))


;;;; Inspecting

(defvar *inspectee*)
(defvar *inspectee-parts*)
(defvar *inspector-stack* '())
(defvar *inspector-history* (make-array 10 :adjustable t :fill-pointer 0))
(declaim (type vector *inspector-history*))
(defvar *inspect-length* 30)

(defun reset-inspector ()
  (setq *inspectee* nil)
  (setq *inspectee-parts* nil)
  (setq *inspector-stack* nil)
  (setf (fill-pointer *inspector-history*) 0))

(defslimefun init-inspector (string)
  (reset-inspector)
  (inspect-object (eval (from-string string))))

(defun print-part-to-string (value)
  (let ((*print-pretty* nil)
        (*print-circle* t))
    (let ((string (to-string value))
	  (pos (position value *inspector-history*)))
      (if pos
	  (format nil "#~D=~A" pos string)
	  string))))

(defun inspect-object (object)
  (push (setq *inspectee* object) *inspector-stack*)
  (unless (find object *inspector-history*)
    (vector-push-extend object *inspector-history*))
  (multiple-value-bind (text parts) (inspected-parts object)
    (setq *inspectee-parts* parts)
    (list :text text
          :type (to-string (type-of object))
          :primitive-type (describe-primitive-type object)
          :parts (loop for (label . value) in parts
                       collect (cons label
                                     (print-part-to-string value))))))

(defun nth-part (index)
  (cdr (nth index *inspectee-parts*)))

(defslimefun inspect-nth-part (index)
  (inspect-object (nth-part index)))

(defslimefun inspector-pop ()
  "Drop the inspector stack and inspect the second element.  Return
nil if there's no second element."
  (cond ((cdr *inspector-stack*)
	 (pop *inspector-stack*)
	 (inspect-object (pop *inspector-stack*)))
	(t nil)))

(defslimefun inspector-next ()
  "Inspect the next element in the *inspector-history*."
  (let ((position (position *inspectee* *inspector-history*)))
    (cond ((= (1+ position) (length *inspector-history*))
	   nil)
	  (t (inspect-object (aref *inspector-history* (1+ position)))))))

(defslimefun quit-inspector ()
  (reset-inspector)
  nil)

(defslimefun describe-inspectee ()
  "Describe the currently inspected object."
  (print-description-to-string *inspectee*))

(defmethod inspected-parts ((object cons))
  (if (consp (cdr object))
      (inspected-parts-of-nontrivial-list object)
      (inspected-parts-of-simple-cons object)))

(defun inspected-parts-of-simple-cons (object)
  (values "The object is a CONS."
	  (list (cons (string 'car) (car object))
		(cons (string 'cdr) (cdr object)))))

(defun inspected-parts-of-nontrivial-list (object)
  (let ((length 0)
	(in-list object)
	(reversed-elements nil))
    (flet ((done (description-format)
	     (return-from inspected-parts-of-nontrivial-list
	       (values (format nil description-format length)
		       (nreverse reversed-elements)))))
      (loop
       (cond ((null in-list)
	      (done "The object is a proper list of length ~S.~%"))
	     ((>= length *inspect-length*)
	      (push (cons  (string 'rest) in-list) reversed-elements)
	      (done "The object is a long list (more than ~S elements).~%"))
	     ((consp in-list)
	      (push (cons (format nil "~D" length) (pop in-list))
		    reversed-elements)
	      (incf length))
	     (t
	      (push (cons (string 'rest) in-list) reversed-elements)
	      (done "The object is an improper list of length ~S.~%")))))))


;;;; Thread listing

(defvar *thread-list* ()
  "List of threads displayed in Emacs.  We don't care a about
synchronization issues (yet).  There can only be one thread listing at
a time.")

(defslimefun list-threads ()
  "Return a list ((NAME DESCRIPTION) ...) of all threads."
  (setq *thread-list* (all-threads))
  (loop for thread in  *thread-list* 
        collect (list (thread-name thread)
                      (thread-status thread))))

(defslimefun quit-thread-browser ()
  (setq *thread-list* nil))

(defun lookup-thread-by-id (id)
  (nth id (all-threads)))

(defun debug-thread (thread-id)
  (interrupt-thread (lookup-thread-by-id thread-id)
                    (let ((pack *package*))
                      (lambda ()
                        (catch 'slime-toplevel
                          (let ((*debugger-hook* (lambda (c h)
                                                   (declare (ignore h))
                                                   ;; cut 'n paste from swank-debugger-hook
                                                   (let ((*swank-debugger-condition* c)
                                                         (*buffer-package* pack)
                                                         (*package* pack)
                                                         (*sldb-level* (1+ *sldb-level*))
                                                         (*swank-state-stack* (cons :swank-debugger-hook *swank-state-stack*)))
                                                     (force-user-output)
                                                     (call-with-debugging-environment
                                                      (lambda () (sldb-loop *sldb-level*)))))))
                            (restart-case
                                (error (make-condition 'simple-error
                                                       :format-control "Interrupt from Emacs"))
                              (un-interrupt ()
                                :report "Abandon control of this thread."
                                nil))))))))

;;; Local Variables:
;;; eval: (font-lock-add-keywords 'lisp-mode '(("(\\(defslimefun\\)\\s +\\(\\(\\w\\|\\s_\\)+\\)"  (1 font-lock-keyword-face) (2 font-lock-function-name-face))))
;;; End:
