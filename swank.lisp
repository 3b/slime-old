(declaim (optimize debug))

(defpackage :swank
  (:use :common-lisp)
  (:export #:start-server
           #:eval-string
	   #:ping
	   #:getpid
           #:features
	   #:interactive-eval
	   #:interactive-eval-region
	   #:pprint-eval
	   #:re-evaluate-defvar
	   #:set-package
	   #:set-default-directory
           #:swank-compile-file 
	   #:swank-compile-string 
	   #:compiler-notes-for-emacs
	   #:compiler-notes-for-file
	   #:arglist-string 
	   #:completions
           #:find-fdefinition
	   #:apropos-list-for-emacs
           #:who-calls
           #:who-references
           #:who-sets
           #:who-binds
           #:who-macroexpands
	   #:list-all-package-names
	   #:function-source-location-for-emacs
	   #:swank-macroexpand-1
	   #:swank-macroexpand
	   #:swank-macroexpand-all
	   #:describe-symbol
	   #:describe-function
	   #:describe-setf-function 
	   #:describe-type
	   #:describe-class
	   #:disassemble-symbol
	   #:load-file
	   #:toggle-trace-fdefinition
	   #:untrace-all
           #:sldb-loop
	   #:debugger-info-for-emacs
	   #:backtrace-for-emacs
	   #:frame-catch-tags
	   #:frame-locals
	   #:frame-source-location-for-emacs
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
  (when *swank-debug-p*
    (format *debug-io* "~&;; Swank ready.~%")))

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

(defstruct (slime-output-stream
	    (:include lisp::string-output-stream
		      (lisp::misc #'slime-out-misc)))
  (last-charpos 0 :type kernel:index))

(defun slime-out-misc (stream operation &optional arg1 arg2)
  (case operation
    (:force-output
     (unless (zerop (lisp::string-output-stream-index stream))
       (setf (slime-output-stream-last-charpos stream)
	     (slime-out-misc stream :charpos))
       (send-to-emacs `(:read-output ,(get-output-stream-string stream)))))
    (:file-position nil)
    (:charpos 
     (do ((index (1- (the fixnum (lisp::string-output-stream-index stream)))
		 (1- index))
	  (count 0 (1+ count))
	  (string (lisp::string-output-stream-string stream)))
	 ((< index 0) (+ count (slime-output-stream-last-charpos stream)))
       (declare (simple-string string)
		(fixnum index count))
       (if (char= (schar string index) #\newline)
	   (return count))))
    (t (lisp::string-out-misc stream operation arg1 arg2))))

(defvar *slime-output* nil
  "Bound to a slime-output-stream during request processing.")

(defun create-swank-server (port &key reuse-address (address "localhost"))
  "Create a SWANK TCP server."
  (let* ((hostent (ext:lookup-host-entry address))
         (address (car (ext:host-entry-addr-list hostent)))
         (ip (ext:htonl address)))
    (system:add-fd-handler
     (ext:create-inet-listener port :stream
                               :reuse-address reuse-address
                               :host ip)
     :input #'accept-connection)))

(defun accept-connection (socket)
  "Accept a SWANK TCP connection on SOCKET."
  (setup-request-handler (ext:accept-tcp-connection socket)))

(defun setup-request-handler (socket)
  "Setup request handling for SOCKET."
  (let ((stream (sys:make-fd-stream socket
                                    :input t :output t
                                    :element-type 'unsigned-byte))
	(output (make-slime-output-stream)))
    (system:add-fd-handler socket
                           :input (lambda (fd)
                                    (declare (ignore fd))
                                    (serve-request stream output)))))
(defun serve-request (*emacs-io* *slime-output*)
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
  (with-standard-io-syntax
    (let ((*package* *swank-io-package*))
      (read-from-string string))))

(defparameter *redirect-output* t)

(defun read-from-emacs ()
  "Read and process a request from Emacs."
  (let ((form (read-next-form)))
    (if *redirect-output*
	(let ((*standard-output* *slime-output*)
	      (*error-output* *slime-output*)
	      (*trace-output* *slime-output*)
	      (*debug-io*  *slime-output*)
	      (*query-io* *slime-output*))
	  (apply #'funcall form))
	(apply #'funcall form))))

(defun send-to-emacs (object)
  "Send OBJECT to Emacs."
  (let* ((string (prin1-to-string-for-emacs object))
         (length (1+ (length string))))
    (loop for position from 16 downto 0 by 8
          do (write-byte (ldb (byte 8 position) length) *emacs-io*))
    (write-string string *emacs-io*)
    (terpri *emacs-io*)
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

;;; Utilities.

(defvar *buffer-package*)
(setf (documentation '*buffer-package* 'symbol)
      "Package corresponding to slime-buffer-package.  

EVAL-STRING binds *buffer-package*.  Strings originating from a slime
buffer are best read in this package.  See also FROM-STRING and TO-STRING.")

(defun from-string (string)
  "Read string in the *BUFFER-PACKAGE*"
  (let ((*package* *buffer-package*))
    (read-from-string string)))

(defun to-string (string)
  "Write string in the *BUFFER-PACKAGE*"
  (let ((*package* *buffer-package*))
    (prin1-to-string string)))

(defun read-symbol/package (symbol-name package-name)
  (let ((package (find-package package-name)))
    (unless package (error "No such package: ~S" package-name))
    (handler-case 
        (let ((*package* package))
          (read-from-string symbol-name))
      (reader-error () nil))))

;;; Asynchronous eval

(defun guess-package-from-string (name)
  (or (and name
	   (or (find-package name) 
	       (find-package (string-upcase name))))
      *package*))

(defvar *swank-debugger-condition*)
(defvar *swank-debugger-hook*)

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
	     (assert (packagep *buffer-package*))
	     (setq result (eval (read-form string)))
	     (force-output)
	     (setq ok t))
	(send-to-emacs (if ok `(:ok ,result) '(:aborted)))))))

(defslimefun interactive-eval (string)
  (let ((*package* *buffer-package*))
    (let ((values (multiple-value-list (eval (read-from-string string)))))
      (force-output)
      (format nil "~{~S~^, ~}" values))))
  
(defslimefun interactive-eval-region (string)
  (let ((*package* *buffer-package*))
    (with-input-from-string (stream string)
      (loop for form = (read stream nil stream)
	    until (eq form stream)
	    for result = (multiple-value-list (eval form))
	    do (force-output)
	    finally (return (format nil "~{~S~^, ~}" result))))))

(defslimefun pprint-eval (string)
  (let ((*package* *buffer-package*))
    (let ((value (eval (read-from-string string))))
      (let ((*print-pretty* t)
	    (*print-circle* t)
	    (*print-level* nil)
	    (*print-length* nil)
	    (ext:*gc-verbose* nil))
	(with-output-to-string (stream)
	  (pprint value stream))))))

(defslimefun re-evaluate-defvar (form)
  (let ((*package* *buffer-package*))
    (let ((form (read-from-string form)))
      (destructuring-bind (dv name &optional value doc) form
	(declare (ignore value doc))
	(assert (eq dv 'defvar))
	(makunbound name)
	(prin1-to-string (eval form))))))

(defslimefun set-package (package)
  (setq *package* (guess-package-from-string package))
  (package-name *package*))

(defslimefun set-default-directory (directory)
  (setf (ext:default-directory) (namestring directory))
  ;; Setting *default-pathname-defaults* to an absolute directory
  ;; makes the behavior of MERGE-PATHNAMES a bit more intuitive.
  (setf *default-pathname-defaults* (pathname (ext:default-directory)))
  (namestring (ext:default-directory)))

;;;; Compilation Commands

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

(defvar *previous-compiler-condition* nil
  "Used to detect duplicates.")

(defun handle-notification-condition (condition)
  "Handle a condition caused by a compiler warning.
This traps all compiler conditions at a lower-level than using
C:*COMPILER-NOTIFICATION-FUNCTION*. The advantage is that we get to
craft our own error messages, which can omit a lot of redundant
information."
  (let ((context (c::find-error-context nil)))
    (when (and context (not (eq condition *previous-compiler-condition*)))
      (setq *previous-compiler-condition* condition)
      (let* ((file-name (c::compiler-error-context-file-name context))
             (file-pos (c::compiler-error-context-file-position context))
             (file (if (typep file-name 'pathname)
                       (unix-truename file-name)
                       file-name))
             (note
              (list
               :position file-pos
               :filename (and (stringp file) file)
               :source-path (current-compiler-error-source-path)
               :severity (etypecase condition
                           (c::compiler-error :error)
                           (c::style-warning :note)
                           (c::warning :warning))
               :message (brief-compiler-message-for-emacs condition context)
               :buffername (if (boundp '*buffername*) *buffername*)
               :buffer-offset (if (boundp '*buffer-offset*) *buffer-offset*))))
        (push note *compiler-notes*)
        (push note (gethash file *notes-database*))))))

(defun brief-compiler-message-for-emacs (condition error-context)
  "Briefly describe a compiler error for Emacs.
When Emacs presents the message it already has the source popped up
and the source form highlighted. This makes much of the information in
the error-context redundant."
  (declare (type c::compiler-error-context error-context))
  (let ((enclosing (c::compiler-error-context-enclosing-source error-context)))
    (if enclosing
        (format nil "--> ~{~<~%--> ~1:;~A~> ~}~%~A" enclosing condition)
        (format nil "~A" condition))))

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

(defslimefun features ()
  (mapcar #'symbol-name *features*))

(defun canonicalize-filename (filename)
  (namestring (unix:unix-resolve-links filename)))

(defslimefun compiler-notes-for-file (filename)
  "Return the compiler notes recorded for FILENAME.
\(See *NOTES-DATABASE* for a description of the return type.)"
  (gethash (canonicalize-filename filename) *notes-database*))

(defslimefun compiler-notes-for-emacs ()
  "Return the list of compiler notes for the last compilation unit."
  (reverse *compiler-notes*))

(defun measure-time-intervall (fn)
  "Call FN and return the first return value and the elapsed time.
The time is measured in microseconds."
  (multiple-value-bind (ok start-secs start-usecs) (unix:unix-gettimeofday)
    (assert ok)
    (let ((value (funcall fn)))
      (multiple-value-bind (ok end-secs end-usecs) (unix:unix-gettimeofday)
	(assert ok)
	(values value (+ (* (- end-secs start-secs) 1000000)
			 (- end-usecs start-usecs)))))))
	
(defmacro with-trapping-compilation-notes (() &body body)
  `(handler-bind ((c::compiler-error #'handle-notification-condition)
                  (c::style-warning #'handle-notification-condition)
                  (c::warning #'handle-notification-condition))
    ,@body))

(defun call-with-compilation-hooks (fn)
  (multiple-value-bind (result usecs)
      (with-trapping-compilation-notes ()
	 (clear-compiler-notes)
	 (measure-time-intervall fn))
    (list (to-string result)
	  (format nil "~,2F" (/ usecs 1000000.0)))))

(defslimefun swank-compile-file (filename load)
  (call-with-compilation-hooks
   (lambda ()
     (clear-note-database filename)
     (clear-xref-info filename)
     (let ((*buffername* nil)
	   (*buffer-offset* nil))
       (compile-file filename :load load)))))

(defslimefun swank-compile-string (string buffer start)
  (call-with-compilation-hooks
   (lambda ()
     (let ((*package* *buffer-package*)
	   (*buffername* buffer)
	   (*buffer-offset* start))
       (with-input-from-string (stream string)
	 (ext:compile-from-stream 
	  stream 
	  :source-info `(:emacs-buffer ,buffer 
			 :emacs-buffer-offset ,start)))))))

(defun clear-xref-info (namestring)
  "Clear XREF notes pertaining to FILENAME.
This is a workaround for a CMUCL bug: XREF records are cumulative."
  (let ((filename (parse-namestring namestring)))
    (when c:*record-xref-info*
      (dolist (db (list xref::*who-calls*
                        xref::*who-is-called*
                        xref::*who-macroexpands*
                        xref::*who-references*
                        xref::*who-binds*
                        xref::*who-sets*))
        (maphash (lambda (target contexts)
                   (setf (gethash target db)
                         (delete-if (lambda (ctx)
                                      (xref-context-derived-from-p ctx filename))
                                    contexts)))
                 db)))))

(defun xref-context-derived-from-p (context filename)
  (let ((xref-file (xref:xref-context-file context)))
    (and xref-file (pathname= filename xref-file))))
  
(defun pathname= (&rest pathnames)
  "True if PATHNAMES refer to the same file."
  (apply #'string= (mapcar #'unix-truename pathnames)))

(defun unix-truename (pathname)
  (ext:unix-namestring (truename pathname)))

(defslimefun arglist-string (fname)
  "Return a string describing the argument list for FNAME.
The result has the format \"(...)\"."
  (declare (type string fname))
  (multiple-value-bind (function condition)
      (ignore-errors (values (from-string fname)))
    (when condition
      (return-from arglist-string (format nil "(-- ~A)" condition)))
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
	  (to-string arglist)))))

(defslimefun who-calls (function-name)
  "Return the places where FUNCTION-NAME is called."
  (xref-results-for-emacs (xref:who-calls function-name)))

(defslimefun who-references (variable)
  "Return the places where the global variable VARIABLE is referenced."
  (xref-results-for-emacs (xref:who-references variable)))

(defslimefun who-binds (variable)
  "Return the places where the global variable VARIABLE is bound."
  (xref-results-for-emacs (xref:who-binds variable)))

(defslimefun who-sets (variable)
  "Return the places where the global variable VARIABLE is set."
  (xref-results-for-emacs (xref:who-sets variable)))

(defslimefun who-macroexpands (macro)
  "Return the places where MACRO is expanded."
  (xref-results-for-emacs (xref:who-macroexpands macro)))

(defun xref-results-for-emacs (contexts)
  "Prepare a list of xref contexts for Emacs.
The result is a list of file-referrers:
file-referrer ::= (FILENAME ({reference}+))
reference     ::= (FUNCTION-SPECIFIER SOURCE-PATH)"
  (let ((hash (make-hash-table :test 'equal))
        (files '()))
    (dolist (context contexts)
      (let* ((file (xref:xref-context-file context))
             (unix-path (if file (unix-truename file) "<unknown>")))
        (push context (gethash unix-path hash))
        (pushnew unix-path files :test #'string=)))
    (mapcar (lambda (unix-path)
              (let ((real-path (if (string= unix-path "<unknown>")
                                   nil
                                   unix-path)))
                (file-xrefs-for-emacs real-path (gethash unix-path hash))))
            (sort files #'string<))))

(defun file-xrefs-for-emacs (unix-filename contexts)
  "Return a summary of the references from a particular file.
The result is a list of the form (FILENAME ((REFERRER SOURCE-PATH) ...))"
  (list unix-filename
        (loop for context in (sort-contexts-by-source-path contexts)
              collect (list (let ((*print-pretty* nil))
                              (to-string (xref:xref-context-name context)))
                            (xref:xref-context-source-path context)))))

(defun sort-contexts-by-source-path (contexts)
  "Sort xref contexts by lexical position of source-paths.
It is assumed that all contexts belong to the same file."
  (sort contexts #'source-path< :key #'xref:xref-context-source-path))

(defun source-path< (path1 path2)
  "Return true if PATH1 is lexically before PATH2."
  (and (every #'< path1 path2)
       (< (length path1) (length path2))))

(defslimefun completions (string default-package-name)
  "Return a list of completions for a symbol designator STRING.  

The result is a list of strings.  If STRING is package qualified the
result list will also be qualified.  If string is non-qualified the
result strings are also not qualified and are considered relative to
DEFAULT-PACKAGE-NAME.  All symbols accessible in the package are
considered."
  (flet ((parse-designator (string)
	   (values (let ((pos (position #\: string :from-end t)))
		     (if pos (subseq string (1+ pos)) string))
		   (let ((pos (position #\: string)))
		     (if pos (subseq string 0 pos) nil))
		   (search "::" string))))
    (multiple-value-bind (name package-name internal) (parse-designator string)
      (let ((completions nil)
	    (package (find-package 
		      (string-upcase (cond ((equal package-name "") "KEYWORD")
					   (package-name)
					   (default-package-name))))))
	(when package
	  (do-symbols (symbol package)
	    (when (and (string-prefix-p name (symbol-name symbol))
		       (or internal
			   (not package-name)
			   (symbol-external-p symbol)))
	      (push symbol completions))))
	(let ((*print-case* (if (find-if #'upper-case-p string)
				:upcase :downcase))
	      (*package* package))
	  (mapcar (lambda (s)
		    (cond (internal (format nil "~A::~A" package-name s))
			  (package-name (format nil "~A:~A" package-name s))
			  (t (format nil "~A" s))))
		  completions))))))

(defun symbol-external-p (s)
  (multiple-value-bind (_ status)
      (find-symbol (symbol-name s) (symbol-package s))
    (declare (ignore _))
    (eq status :external)))
 
(defun string-prefix-p (s1 s2)
  "Return true iff the string S1 is a prefix of S2.
\(This includes the case where S1 is equal to S2.)"
  (and (<= (length s1) (length s2))
       (string-equal s1 s2 :end2 (length s1))))

(defslimefun list-all-package-names ()
  (let ((list '()))
    (maphash (lambda (name package)
	       (declare (ignore package)) 
	       (pushnew name list))
	     lisp::*package-names*)
    list))

;;;; Definitions

(defvar *debug-definition-finding* nil
  "When true don't handle errors while looking for definitions.
This is useful when debugging the definition-finding code.")

;;; FIND-FDEFINITION -- interface
;;;
(defslimefun find-fdefinition (symbol-name package-name)
  "Return the name of the file in which the function was defined, or NIL."
  (fdefinition-file (read-symbol/package symbol-name package-name)))

(defun function-debug-info (function)
  "Return the debug-info for FUNCTION."
  (declare (type (or symbol function) function))
  (typecase function
    (symbol 
     (let ((def (or (macro-function function)
		    (and (fboundp function)
			 (fdefinition function)))))
       (when def (function-debug-info def))))
    (kernel:byte-closure
     (function-debug-info (kernel:byte-closure-function function)))
    (kernel:byte-function
     (kernel:%code-debug-info (c::byte-function-component function)))
    (function
     (kernel:%code-debug-info (kernel:function-code-header
			       (kernel:%function-self function))))
    (t nil)))

(defun function-first-code-location (function)
  (and (function-has-debug-function-p function)
       (di:debug-function-start-location
        (di:function-debug-function function))))

(defun function-debug-function-name (function)
  (and (function-has-debug-function-p function)
       (di:debug-function-name (di:function-debug-function function))))

(defun function-has-debug-function-p (function)
  (di:function-debug-function function))

(defun function-debug-function-name= (function name)
  (equal (function-debug-function-name function) name))

(defun struct-accessor-p (function)
  (function-debug-function-name= function "DEFUN STRUCTURE-SLOT-ACCESSOR"))

(defun struct-accessor-class (function)
  (kernel:%closure-index-ref function 0)) 

(defun struct-setter-p (function)
  (function-debug-function-name= function "DEFUN STRUCTURE-SLOT-SETTER"))

(defun struct-setter-class (function) 
  (kernel:%closure-index-ref function 0))

(defun struct-predicate-p (function)
  (function-debug-function-name= function "DEFUN %DEFSTRUCT"))

(defun struct-predicate-class (function)
  (kernel:layout-class
   (c:value-cell-ref 
    (kernel:%closure-index-ref function 0))))

(defun struct-class-source-location (class)
  (let ((constructor (kernel::structure-class-constructor class)))
    (cond (constructor (function-source-location constructor))
	  (t (error "Cannot locate struct without constructor: ~A" class)))))

(defun function-source-location (function)
  "Try to find the canonical source location of FUNCTION."
  ;; First test if FUNCTION is a closure created by defstruct; if so
  ;; extract the struct-class from the closure and find the
  ;; constructor for the struct-class.  Defstruct creates a defun for
  ;; the default constructor and we use that as an approximation to
  ;; the source location of the defstruct.  Unfortunately, some
  ;; defstructs have no or non-default constructors, in that case we
  ;; are out of luck.
  ;;
  ;; For an ordinary function we return the source location of the
  ;; first code-location we find.
  (cond ((struct-accessor-p function)
	 (struct-class-source-location 
	  (struct-accessor-class function)))
	((struct-setter-p function)
	 (struct-class-source-location 
	  (struct-setter-class function)))
	((struct-predicate-p function)
	 (struct-class-source-location 
	  (struct-predicate-class function)))
	(t
         (let ((location (function-first-code-location function)))
           (when location
             (source-location-for-emacs location))))))

(defslimefun function-source-location-for-emacs (fname)
  "Return the source-location of FNAME's definition."
  (let* ((fname (from-string fname))
         (finder
          (lambda ()
            (cond ((and (symbolp fname) (macro-function fname))
                   (function-source-location (macro-function fname)))
                  ((fboundp fname)
                   (function-source-location (coerce fname 'function)))))))
    (if *debug-definition-finding*
        (funcall finder)
        (handler-case (funcall finder)
          (error (e) (list :error (format nil "Error: ~A" e)))))))

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

(defun briefly-describe-symbol-for-emacs (symbol)
  "Return a plist describing SYMBOL.
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
	  (list* :designator (to-string symbol) result)))))

(defslimefun apropos-list-for-emacs  (name &optional external-only package)
  "Make an apropos search for Emacs.
The result is a list of property lists."
  (mapcan (listify #'briefly-describe-symbol-for-emacs)
          (sort (apropos-symbols name external-only package)
                #'present-symbol-before-p)))

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

(defun present-symbol-before-p (a b)
  "Return true if A belongs before B in a printed summary of symbols.
Sorted alphabetically by package name and then symbol name, except
that symbols accessible in the current package go first."
  (flet ((accessible (s)
           (find-symbol (symbol-name s) *buffer-package*)))
    (let ((pa (symbol-package a))
          (pb (symbol-package b)))
      (cond ((or (eq pa pb)
                 (and (accessible a) (accessible b)))
             (string< (symbol-name a) (symbol-name b)))
            ((accessible a) t)
            ((accessible b) nil)
            (t
             (string< (package-name pa) (package-name pb)))))))

(defun print-output-to-string (fn)
  (with-output-to-string (*standard-output*)
    (funcall fn)))

(defun print-desciption-to-string (object)
  (print-output-to-string (lambda () (describe object))))

(defslimefun describe-symbol (symbol-name)
  (print-desciption-to-string (from-string symbol-name)))

(defslimefun describe-function (symbol-name)
  (print-desciption-to-string (symbol-function (from-string symbol-name))))

(defslimefun describe-setf-function (symbol-name)
  (print-desciption-to-string
   (or (ext:info setf inverse (from-string symbol-name))
       (ext:info setf expander (from-string symbol-name)))))

(defslimefun describe-type (symbol-name)
  (print-desciption-to-string
   (kernel:values-specifier-type (from-string symbol-name))))

(defslimefun describe-class (symbol-name)
  (print-desciption-to-string (find-class (from-string symbol-name) nil)))

;;; Macroexpansion

(defun apply-macro-expander (expander string)
  (let ((*print-pretty* t)
	(*print-length* 20)
	(*print-level* 20))
    (to-string (funcall expander (from-string string)))))

(defslimefun swank-macroexpand-1 (string)
  (apply-macro-expander #'macroexpand-1 string))

(defslimefun swank-macroexpand (string)
  (apply-macro-expander #'macroexpand string))

(defslimefun swank-macroexpand-all (string)
  (apply-macro-expander #'walker:macroexpand-all string))



;;;
(defun tracedp (fname)
  (gethash (debug::trace-fdefinition fname)
	   debug::*traced-functions*))

(defslimefun toggle-trace-fdefinition (fname-string)
  (let ((fname (from-string fname-string)))
    (cond ((tracedp fname)
	   (debug::untrace-1 fname)
	   (format nil "~S is now untraced." fname))
	  (t
	   (debug::trace-1 fname (debug::make-trace-info))
	   (format nil "~S is now traced." fname)))))

(defslimefun untrace-all ()
  (untrace))

(defslimefun disassemble-symbol (symbol-name)
  (print-output-to-string (lambda () (disassemble (from-string symbol-name)))))
   
(defslimefun load-file (filename)
  (load filename))


;;; Debugging

(defvar *sldb-level* 0)
(defvar *sldb-stack-top*)
(defvar *sldb-restarts*)

(defslimefun ping (level)
  (cond ((= level *sldb-level*)
	 *sldb-level*)
	(t
	 (throw-to-toplevel))))

(defslimefun getpid ()
  (unix:unix-getpid))

(defslimefun sldb-loop ()
  (unix:unix-sigsetmask 0)
  (let* ((*sldb-level* (1+ *sldb-level*))
	 (*sldb-stack-top* (or debug:*stack-top-hint* (di:top-frame)))
	 (*sldb-restarts* (compute-restarts *swank-debugger-condition*))
	 (debug:*stack-top-hint* nil)
	 (*debugger-hook* nil)
	 (level *sldb-level*)
	 (*package* *buffer-package*)
	 (*readtable* (or debug:*debug-readtable* *readtable*))
	 (*print-level* debug:*debug-print-level*)
	 (*print-length* debug:*debug-print-length*))
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
          (let ((*print-pretty* nil))
            (debug::print-frame-call frame :verbosity 1 :number t)))))

(defun backtrace-length ()
  "Return the number of frames on the stack."
  (do ((frame *sldb-stack-top* (di:frame-down frame))
       (i 0 (1+ i)))
      ((not frame) i)))

(defun compute-backtrace (start end)
  "Return a list of frames starting with frame number START and
continuing to frame number END or, if END is nil, the last frame on the
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
      (file-position file))))

(defun debug-source-info-from-emacs-buffer-p (debug-source)
  (let ((info (c::debug-source-info debug-source)))
    (and info 
	 (consp info)
	 (eq :emacs-buffer (car info)))))

(defun source-location-for-emacs (code-location)
  (let* ((debug-source (di:code-location-debug-source code-location))
	 (from (di:debug-source-from debug-source))
	 (name (di:debug-source-name debug-source)))
    (list
     :from from
     :filename (if (eq from :file)
		   (ext:unix-namestring (truename name)))
     :position (if (eq from :file)
		   (code-location-file-position code-location))
     :info (and (debug-source-info-from-emacs-buffer-p debug-source)
		(c::debug-source-info debug-source))
     :path (code-location-source-path code-location)
     :source-form
     (unless (or (eq from :file)
		 (debug-source-info-from-emacs-buffer-p debug-source))
	 (with-output-to-string (*standard-output*)
	   (debug::print-code-location-source-form code-location 100 t))))))

(defun safe-source-location-for-emacs (code-location)
  (handler-case (source-location-for-emacs code-location)
    (t (c) (list :error (debug::safe-condition-message c)))))

(defslimefun frame-source-location-for-emacs (index)
  (safe-source-location-for-emacs (di:frame-code-location (nth-frame index))))

(defslimefun eval-string-in-frame (string index)
  (to-string (di:eval-in-frame (nth-frame index) (from-string string))))

(defslimefun frame-locals (index)
  (let* ((frame (nth-frame index))
	 (location (di:frame-code-location frame))
	 (debug-function (di:frame-debug-function frame))
	 (debug-variables (di::debug-function-debug-variables debug-function)))
    (loop for v across debug-variables
	  collect (list
		   :symbol (di:debug-variable-symbol v)
		   :id (di:debug-variable-id v)
		   :validity (di:debug-variable-validity v location)
		   :value-string
		   (if (eq (di:debug-variable-validity v location)
			   :valid)
		       (to-string (di:debug-variable-value v frame))
		       "<not-available>")))))

(defslimefun frame-catch-tags (index)
  (loop for (tag . code-location) in (di:frame-catches (nth-frame index))
	collect `(,tag . ,(safe-source-location-for-emacs code-location))))

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
