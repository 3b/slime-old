
(defpackage :swank
  (:use :common-lisp)
  (:export #:start-server
           #:eval-string
	   #:interactive-eval
	   #:pprint-eval
           #:swank-compile-file 
	   #:swank-compile-string 
	   #:compiler-notes-for-emacs
	   #:compiler-notes-for-file
	   #:arglist-string 
	   #:completions
           #:find-fdefinition
	   #:apropos-list-for-emacs
	   #:swank-macroexpand-1
	   #:swank-macroexpand
	   #:swank-macroexpand-all
	   #:describe-symbol
	   #:describe-function
	   #:describe-setf-function 
	   #:describe-type
	   #:describe-class
	   #:disassemble-symbol
           #:sldb-loop
	   #:debugger-info-for-emacs
	   #:backtrace-for-emacs
	   #:frame-catch-tags
	   #:frame-locals
	   #:frame-code-location-for-emacs
	   #:eval-string-in-frame
	   #:invoke-nth-restart
	   #:sldb-abort
	   #:sldb-continue
	   #:throw-to-toplevel 
	   ))

(in-package :swank)

(defconstant server-port 4005
  "Default port for the swank TCP server.")

(defvar *swank-debug-p* t
  "When true extra debug printouts are enabled.")

;;; Setup and hooks.

(defun start-server (&optional (port server-port))
  (create-swank-server port :reuse-address t)
  (setf c:*record-xref-info* t)
  (ext:without-package-locks
   (setf c:*compiler-notification-function* 'handle-notification))
  (when *swank-debug-p*
    (format *debug-io* "~&Swank ready.~%")))

(defun set-fd-non-blocking (fd)
  (flet ((fcntl (fd cmd arg)
	   (multiple-value-bind (flags errno) (unix:unix-fcntl fd cmd arg)
	     (or flags 
		 (error "fcntl: ~A" (unix:get-unix-error-msg errno))))))
    (let ((flags (fcntl fd unix:F-GETFL 0)))
      (fcntl fd unix:F-SETFL (logior flags unix:O_NONBLOCK)))))

(set-fd-non-blocking (sys:fd-stream-fd sys:*stdin*))

;;; TCP Server.

(defvar *emacs-io* nil
  "Bound to a TCP stream to Emacs during request processing.")

(defun create-swank-server (port &key reuse-address)
  "Create a SWANK TCP server."
  (system:add-fd-handler
   (ext:create-inet-listener port :stream :reuse-address reuse-address)
   :input #'accept-connection))

(defun accept-connection (socket)
  "Accept a SWANK TCP connection on SOCKET."
  (setup-request-handler (ext:accept-tcp-connection socket)))

(defun setup-request-handler (socket)
  "Setup request handling for SOCKET."
  (let ((stream (sys:make-fd-stream socket
                                    :input t :output t
                                    :element-type 'unsigned-byte)))
    (system:add-fd-handler socket
                           :input (lambda (fd)
                                    (declare (ignore fd))
                                    (serve-request stream)))))

(defun serve-request (*emacs-io*)
  "Read and process a request from a SWANK client.
The request is read from the socket as a sexp and then evaluated."
  (let ((completed nil))
    (let ((condition (catch 'serve-request-catcher
		       (read-from-emacs)
		       (setq completed t))))
      (unless completed
	(when *swank-debug-p*
	  (format *debug-io* 
		  "~&;; Connection to Emacs lost.~%;; [~A]~%" condition))
	(sys:invalidate-descriptor (sys:fd-stream-fd *emacs-io*))
 	(close *emacs-io*)))))

(defun read-next-form ()
  (handler-case 
      (let* ((length (logior (ash (read-byte *emacs-io*) 16)
			     (ash (read-byte *emacs-io*) 8)
			     (read-byte *emacs-io*)))
	     (string (make-string length)))
	(sys:read-n-bytes *emacs-io* string 0 length)
	(read-form string))
    (condition (c)
      (throw 'serve-request-catcher c))))

(defvar *swank-io-package* 
  (let ((package (make-package "SWANK-IO-PACKAGE")))
    (import 'nil package)
    package))

(defun read-form (string) 
  (let ((*package* *swank-io-package*))
    (with-standard-io-syntax
      (read-from-string string))))

(defun read-from-emacs ()
  "Read and process a request from Emacs."
  (eval (read-next-form)))

(defun send-to-emacs (object)
  "Send OBJECT to Emacs."
  (let* ((string (prin1-to-string-for-emacs object))
         (length (length string)))
    (loop for position from 16 downto 0 by 8
          do (write-byte (ldb (byte 8 position) length) *emacs-io*))
    (write-string string *emacs-io*)
    (force-output *emacs-io*)))

(defun prin1-to-string-for-emacs (object)
  (let ((*print-case* :downcase)
	(*print-readably* t)
	(*print-pretty* nil)
	(*package* *swank-io-package*))
    (prin1-to-string object)))
  
;;; Functions for Emacs to call.

(defmacro defslimefun (fun &rest rest)
  `(progn
    (defun ,fun ,@rest)
    (export ',fun :swank)))


;;; Asynchronous eval

(defun guess-package-from-string (name)
  (or (and name
	   (or (find-package name) 
	       (find-package (string-upcase name))))
      *package*))

(defvar *swank-debugger-condition*)
(defvar *swank-debugger-hook*)

(defvar *buffer-package*)
(setf (documentation '*buffer-package* 'symbol)
      "Package corresponding to slime-buffer-package.  

EVAL-STRING binds *buffer-package*.  Strings originating from a slime
buffer are best read in this package.  See also READ-STRING.")

(defun read-string (string)
  "Read string in the *BUFFER-PACKAGE*"
  (let ((*package* *buffer-package*))
    (read-from-string string)))

(defun swank-debugger-hook (condition hook)
  (send-to-emacs '(:debugger-hook))
  (let ((*swank-debugger-condition* condition)
	(*swank-debugger-hook* hook))
    (read-from-emacs)))
  
(defslimefun eval-string (string buffer-package)
  (let ((*debugger-hook* #'swank-debugger-hook))
    (let (ok result)
      (unwind-protect
	   (let ((*buffer-package* (guess-package-from-string buffer-package)))
	     (setq result (eval (read-string string)))
	     (setq ok t))
	(send-to-emacs (if ok `(:ok ,result) '(:aborted)))))))

(defslimefun interactive-eval (string)
  (let ((values (multiple-value-list (eval (read-string string)))))
    (force-output)
    (format nil "~{~S~^, ~}" values)))

(defslimefun pprint-eval (string)
  (let ((value (eval (read-string string))))
    (let ((*print-pretty* t)
	  (*print-circle* t)
	  (*print-level* nil)
	  (*print-length* nil)
	  (ext:*gc-verbose* nil))
      (with-output-to-string (*standard-output*) 
	(pprint value)))))

;;;; Compilation Commands

;; (defun debugger-hook (condition old-hook)
;;   "Hook function to be invoked instead of the debugger.
;; See CL:*DEBUGGER-HOOK*."
;;   ;; FIXME: Debug from Emacs!
;;   (declare (ignore old-hook))
;;   (handler-case
;; 	 (progn (format *error-output*
;; 			"~@<SWANK: unhandled condition ~2I~_~A~:>~%"
;; 			condition)
;; 		(debug:backtrace 20 *error-output*)
;; 		(finish-output *error-output*))
;;     (condition ()
;; 	 nil)))

(defvar *compiler-notes* '()
  "List of compiler notes for the last compilation unit.")

(defun clear-compiler-notes ()  (setf *compiler-notes* '()))

(defvar *notes-database* (make-hash-table :test #'equal)
  "Database of recorded compiler notes/warnings/erros (keyed by filename).
Each value is a list of (LOCATION SEVERITY MESSAGE CONTEXT) lists.
  LOCATION is a position in the source code (integer or source path).
  SEVERITY is one of :ERROR, :WARNING, and :NOTE.
  MESSAGE is a string describing the note.
  CONTEXT is a string giving further details of where the error occured.")

(defun clear-note-database (filename)
  (remhash (canonicalize-filename filename) *notes-database*))

(defvar *buffername*)
(defvar *buffer-offset*)
  
(defun handle-notification (severity message context where-from position)
  "Hook function called by the compiler.
See C:*COMPILER-NOTIFICATION-FUNCTION*"
  (let* ((namestring (cond ((stringp where-from) where-from)
			   ;; we can be passed a stream from READER-ERROR
			   ((lisp::fd-stream-p where-from)
			    (lisp::fd-stream-file where-from))
			   (t where-from)))
	 (note (list 
		:position position
		:source-path (current-compiler-error-source-path)
		:filename namestring
		:severity severity
		:message message
		:context context
		:buffername (if (boundp '*buffername*) 
				*buffername*)
		:buffer-offset (if (boundp '*buffer-offset*) 
				   *buffer-offset*))))
    (push note *compiler-notes*)
    (when namestring
      (push note (gethash namestring *notes-database*)))))
	  
(defun current-compiler-error-source-path ()
  "Return the source-path for the current compiler error.
Returns NIL if this cannot be determined by examining internal
compiler state."
  (let ((context c::*compiler-error-context*))
    (cond ((c::node-p context)
           (reverse
            (c::source-path-original-source (c::node-source-path context))))
          ((c::compiler-error-context-p context)
           (reverse
            (c::compiler-error-context-original-source-path context))))))

(defun canonicalize-filename (filename)
  (namestring (unix:unix-resolve-links filename)))

(defslimefun compiler-notes-for-file (filename)
  "Return the compiler notes recorded for FILENAME.
\(See *NOTES-DATABASE* for a description of the return type.)"
  (gethash (canonicalize-filename filename) *notes-database*))

(defslimefun compiler-notes-for-emacs ()
  "Return the list of compiler notes for the last compilation unit."
  (reverse *compiler-notes*))

(defslimefun swank-compile-file (filename load)
  (clear-note-database filename)
  (clear-compiler-notes)
  (let ((*buffername* nil)
	(*buffer-offset* nil))
    (multiple-value-bind (pathname errorsp notesp)
	(compile-file filename :load load)
      (list (if pathname (namestring pathname)) errorsp notesp))))

(defslimefun swank-compile-string (string buffer start)
  (clear-compiler-notes)
  (let ((*package* *buffer-package*)
	(*buffername* buffer)
	(*buffer-offset* start))
    (with-input-from-string (stream string)
      (multiple-value-list
       (ext:compile-from-stream stream :source-info (cons buffer start))))))

;;;; ARGLIST-STRING -- interface
(defslimefun arglist-string (function)
  "Return a string describing the argument list for FUNCTION.
The result has the format \"(...)\"."
  (declare (type (or symbol function) function))
  (let ((arglist
         (if (not (or (fboundp function)
                      (functionp function)))
             "(-- <Unknown-Function>)"
             (let* ((fun (etypecase function
                           (symbol (or (macro-function function)
                                       (symbol-function function)))
                           ;;(function function)
			   ))
                    (df (di::function-debug-function fun))
                    (arglist (kernel:%function-arglist fun)))
               (cond ((eval:interpreted-function-p fun)
                      (eval:interpreted-function-arglist fun))
                     ((pcl::generic-function-p fun)
                      (pcl::gf-pretty-arglist fun))
                     (arglist arglist)
                     ;; this should work both for
                     ;; compiled-debug-function and for
                     ;; interpreted-debug-function
                     (df (di::debug-function-lambda-list df))
                     (t "(<arglist-unavailable>)"))))))
    (if (stringp arglist)
        arglist
        (prin1-to-string-for-emacs arglist))))

;;;; COMPLETIONS -- interface

(defun completions (prefix package-name &optional only-external-p)
  "Return a list of completions for a symbol's PREFIX and PACKAGE-NAME.
The result is a list of symbol-name strings. All symbols accessible in
the package are considered."
  (let ((completions nil)
        (package (find-package package-name)))
    (when package
      (do-symbols (symbol package)
        (when (and (or (not only-external-p) (symbol-external-p symbol))
                   (string-prefix-p prefix (symbol-name symbol)))
          (push (symbol-name symbol) completions))))
    completions))

(defun symbol-external-p (s)
  (multiple-value-bind (_ status)
      (find-symbol (symbol-name s) (symbol-package s))
    (declare (ignore _))
    (eq status :external)))

(defun string-prefix-p (s1 s2)
  "Return true iff the string S1 is a prefix of S2.
\(This includes the case where S1 is equal to S2.)"
  (and (<= (length s1) (length s2))
       (string= s1 s2 :end2 (length s1))))

;;;; Definitions

;;; FIND-FDEFINITION -- interface
;;;
(defslimefun find-fdefinition (symbol-name package-name)
  "Return the name of the file in which the function was defined, or NIL."
  (fdefinition-file (read-symbol/package symbol-name package-name)))

;;; Clone of HEMLOCK-INTERNALS::FUN-DEFINED-FROM-PATHNAME
(defun fdefinition-file (function)
  "Return the name of the file in which FUNCTION was defined."
  (declare (type (or symbol function) function))
  (typecase function
    (symbol
     (let ((def (or (macro-function function)
		    (and (fboundp function)
			 (fdefinition function)))))
       (when def (fdefinition-file def))))
    (kernel:byte-closure
     (fdefinition-file (kernel:byte-closure-function function)))
    (kernel:byte-function
     (code-definition-file (c::byte-function-component function)))
    (function
     (code-definition-file (kernel:function-code-header
			    (kernel:%function-self function))))
    (t nil)))

(defun code-definition-file (code)
  "Return the name of the file in which CODE was defined."
  (declare (type kernel:code-component code))
  (flet ((to-namestring (pathname)
           (handler-case (namestring (truename pathname))
             (file-error () nil))))
    (let ((info (kernel:%code-debug-info code)))
      (when info
        (let ((source (car (c::debug-info-source info))))
          (when (and source (eq (c::debug-source-from source) :file))
            (to-namestring (c::debug-source-name source))))))))

;;;; Utilities.

(defun read-symbol/package (symbol-name package-name)
  (let ((package (find-package package-name)))
    (unless package (error "No such package: ~S" package-name))
    (handler-case 
        (let ((*package* package))
          (read-from-string symbol-name))
      (reader-error () nil))))


(defun briefly-describe-symbol-for-emacs (symbol)
  "Return a plist of describing SYMBOL.
Return NIL if the symbol is unbound."
  (let ((result '()))
    (labels ((first-line (string) 
               (let ((pos (position #\newline string)))
                 (if (null pos) string (subseq string 0 pos))))
	     (doc (kind)
	       (let ((string (documentation symbol kind)))
		 (if string 
		     (first-line string)
		     :not-documented)))
	     (maybe-push (property value)
	       (when value
		 (setf result (list* property value result)))))
      (maybe-push
       :variable (multiple-value-bind (kind recorded-p)
		     (ext:info variable kind symbol)
		   (declare (ignore kind))
		   (if (or (boundp symbol) recorded-p)
		       (doc 'variable))))
      (maybe-push
       :function (if (fboundp symbol) 
		     (doc 'function)))
      (maybe-push
       :setf (if (or (ext:info setf inverse symbol)
		     (ext:info setf expander symbol))
		 (doc 'setf)))
      (maybe-push
       :type (if (ext:info type kind symbol)
		 (doc 'type)))
      (maybe-push
       :class (if (find-class symbol nil) 
		  (doc 'class)))
      (if result
	  (list* :designator (prin1-to-string symbol) result)))))

(defslimefun apropos-list-for-emacs  (name &optional external-only package)
  "Make an apropos search for Emacs.
The result is a list of property lists."
  (mapcan (listify #'briefly-describe-symbol-for-emacs)
          (sort (apropos-symbols name external-only package)
                #'belongs-before-in-apropos-p)))

(defun listify (f)
  "Return a function like F, but which returns any non-null value
wrapped in a list."
  (lambda (x)
    (let ((y (funcall f x)))
      (and y (list y)))))

(defun apropos-symbols (string &optional external-only package)
  "Return the symbols matching an apropos search."
  (let ((symbols '()))
    (ext:map-apropos (lambda (sym)
                       (unless (keywordp sym)
                         (push sym symbols)))
                     string package external-only)
    symbols))

(defun belongs-before-in-apropos-p (a b)
  "Return true if A belongs before B in an apropos listing.
Sorted alphabetically by package name and then symbol name, except
that symbols accessible in the current package go first."
  (flet ((accessible (s)
           (find-symbol (symbol-name s) *package*)))
    (let ((pa (symbol-package a))
          (pb (symbol-package b)))
      (cond ((or (eq pa pb)
                 (and (accessible a) (accessible b)))
             (string< (symbol-name a) (symbol-name b)))
            ((accessible a) t)
            ((accessible b) nil)
            (t
             (string< (package-name pa) (package-name pb)))))))

(defun apply-macro-expander (expander string)
  (let ((*print-pretty* t)
	(*print-length* 20)
	(*print-level* 20))
    (prin1-to-string (funcall expander (read-string string)))))

(defslimefun swank-macroexpand-1 (string)
  (apply-macro-expander #'macroexpand-1 string))

(defslimefun swank-macroexpand (string)
  (apply-macro-expander #'macroexpand string))

(defslimefun swank-macroexpand-all (string)
  (apply-macro-expander #'walker:macroexpand-all string))

(defun print-output-to-string (fn)
  (with-output-to-string (*standard-output*)
    (funcall fn)))

(defun print-desciption-to-string (object)
  (print-output-to-string (lambda () (describe object))))

(defslimefun describe-symbol (symbol-name)
  (print-desciption-to-string (read-string symbol-name)))

(defslimefun describe-function (symbol-name)
  (print-desciption-to-string (symbol-function (read-string symbol-name))))

(defslimefun describe-setf-function (symbol-name)
  (print-desciption-to-string
   (or (ext:info setf inverse (read-string symbol-name))
       (ext:info setf expander (read-string symbol-name)))))

(defslimefun describe-type (symbol-name)
  (print-desciption-to-string
   (kernel:values-specifier-type (read-string symbol-name))))

(defslimefun describe-class (symbol-name)
  (print-desciption-to-string (find-class (read-string symbol-name) nil)))
   
(defslimefun disassemble-symbol (symbol-name)
  (print-output-to-string (lambda () (disassemble (read-string symbol-name)))))


;;; Debugging stuff

(defvar *sldb-level* 0)
(defvar *sldb-stack-top*)
(defvar *sldb-restarts*)

(defslimefun sldb-loop ()
  (unix:unix-sigsetmask 0)
  (let* ((*sldb-level* (1+ *sldb-level*))
	 (*sldb-stack-top* (or debug:*stack-top-hint* (di:top-frame)))
	 (*sldb-restarts* (compute-restarts *swank-debugger-condition*))
	 (debug:*stack-top-hint* nil)
	 (*debugger-hook* nil)
	 (level *sldb-level*))
    (handler-bind ((di:debug-condition 
		    (lambda (condition)
		      (send-to-emacs `(:debug-condition
				       ,(princ-to-string condition)))
		      (throw 'sldb-loop-catcher nil))))
      (unwind-protect
	   (loop
	    (catch 'sldb-loop-catcher
	      (with-simple-restart (abort "Return to sldb level ~D." level)
		(send-to-emacs `(:sldb-prompt ,level))
		(read-from-emacs))))
	(send-to-emacs `(:sldb-abort ,level))))))

(defun format-restarts-for-emacs ()
  "Return a list of restarts for *swank-debugger-condition* in a
format suitable for Emacs."
  (loop for restart in *sldb-restarts*
	collect (list (princ-to-string (restart-name restart))
		      (princ-to-string restart))))

(defun format-condition-for-emacs ()
  (format nil "~A~%   [Condition of type ~S]"
	  (debug::safe-condition-message *swank-debugger-condition*)
          (type-of *swank-debugger-condition*)))

(defun nth-frame (index)
  (do ((frame *sldb-stack-top* (di:frame-down frame))
       (i index (1- i)))
      ((zerop i) frame)))

(defun nth-restart (index)
  (nth index *sldb-restarts*))

(defun format-frame-for-emacs (frame)
  (list (di:frame-number frame)
	(with-output-to-string (*standard-output*) 
	  (debug::print-frame-call frame :verbosity 1 :number t))))

(defun backtrace-length ()
  "Return the number of frames on the stack."
  (do ((frame *sldb-stack-top* (di:frame-down frame))
       (i 0 (1+ i)))
      ((not frame) i)))

(defun compute-backtrace (start end)
  "Return a list of frames starting with frame number START and
continuing to frame number END or if END is nil the last frame on the
stack."
  (let ((end (or end most-positive-fixnum)))
    (do ((frame *sldb-stack-top* (di:frame-down frame))
	 (i 0 (1+ i)))
	((= i start)
	 (loop for f = frame then (di:frame-down f)
	       for i from start below end
	       while f
	       collect f)))))

(defslimefun backtrace-for-emacs (start end)
  (mapcar #'format-frame-for-emacs (compute-backtrace start end)))

(defslimefun debugger-info-for-emacs (start end)
  (list (format-condition-for-emacs)
	(format-restarts-for-emacs)
	(backtrace-length)
	(backtrace-for-emacs start end)))

(defun code-location-source-path (code-location)
  (let* ((location (debug::maybe-block-start-location code-location))
	 (form-num (di:code-location-form-number location)))
    (let ((translations (debug::get-top-level-form location)))
      (unless (< form-num (length translations))
	(error "Source path no longer exists."))
      (reverse (cdr (svref translations form-num))))))

(defun code-location-file-position (code-location)
  (let* ((debug-source (di:code-location-debug-source code-location))
	 (filename (di:debug-source-name debug-source))
	 (path (code-location-source-path code-location)))
    (source-path-file-position path filename)))

(defun source-path-file-position (path filename)
  (let ((*read-suppress* t))
    (with-open-file (file filename)
      (dolist (n path)
	(dotimes (i n)
	  (read file))
	(read-delimited-list #\( file))
      (let ((start (file-position file)))
	(file-position file (1- start))
	(read file)
	(list start (file-position file))))))

(defun code-location-for-emacs (code-location)
  (let* ((debug-source (di:code-location-debug-source code-location))
	 (from (di:debug-source-from debug-source))
	 (name (di:debug-source-name debug-source)))
    (list
     :from from
     :filename (if (eq from :file)
		   (ext:unix-namestring (truename name)))
     :position (if (eq from :file)
		   (code-location-file-position code-location))
     :source-form
     (if (not (eq from :file))
	 (with-output-to-string (*standard-output*)
	   (debug::print-code-location-source-form code-location 100 t))))))

(defun safe-code-location-for-emacs (code-location)
  (handler-case (code-location-for-emacs code-location)
    (t (c) (list :error (debug::safe-condition-message c)))))

(defslimefun frame-code-location-for-emacs (index)
  (safe-code-location-for-emacs (di:frame-code-location (nth-frame index))))

(defslimefun eval-string-in-frame (string index)
  (prin1-to-string
   (di:eval-in-frame (nth-frame index) (read-string string))))

(defslimefun frame-locals (index)
  (let* ((frame (nth-frame index))
	 (location (di:frame-code-location frame))
	 (debug-function (di:frame-debug-function frame))
	 (debug-variables (di:ambiguous-debug-variables debug-function "")))
    (loop for v in debug-variables
	  collect (list
		   :symbol (di:debug-variable-symbol v)
		   :id (di:debug-variable-id v)
		   :validity (di:debug-variable-validity v location)
		   :value-string
		   (prin1-to-string (di:debug-variable-value v frame))))))

(defslimefun frame-catch-tags (index)
  (loop for (tag . code-location) in (di:frame-catches (nth-frame index))
	collect `(,tag . ,(safe-code-location-for-emacs code-location))))

(defslimefun invoke-nth-restart (index)
  (invoke-restart (nth-restart index)))

(defslimefun sldb-continue ()
  (continue *swank-debugger-condition*))

(defslimefun sldb-abort ()
  (invoke-restart (find 'abort *sldb-restarts* :key #'restart-name)))

(defslimefun throw-to-toplevel ()
  (throw 'lisp::top-level-catcher nil))

;;; Local Variables:
;;; eval: (font-lock-add-keywords 'lisp-mode '(("(\\(defslimefun\\)\\s +\\(\\(\\w\\|\\s_\\)+\\)"  (1 font-lock-keyword-face) (2 font-lock-function-name-face))))
;;; End:
