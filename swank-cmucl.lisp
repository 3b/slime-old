;;;; -*- indent-tabs-mode: nil; outline-regexp: ";;;;+" -*-

(declaim (optimize (debug 2)))

(in-package :swank-backend)

(in-package :lisp)

;; Fix for read-sequence in 18e
#+cmu18e
(progn
  (let ((s (find-symbol (string :*enable-package-locked-errors*) :lisp)))
    (when s
      (setf (symbol-value s) nil)))

  (defun read-into-simple-string (s stream start end)
    (declare (type simple-string s))
    (declare (type stream stream))
    (declare (type index start end))
    (unless (subtypep (stream-element-type stream) 'character)
      (error 'type-error
             :datum (read-char stream nil #\Null)
             :expected-type (stream-element-type stream)
             :format-control "Trying to read characters from a binary stream."))
    ;; Let's go as low level as it seems reasonable.
    (let* ((numbytes (- end start))
           (total-bytes 0))
      ;; read-n-bytes may return fewer bytes than requested, so we need
      ;; to keep trying.
      (loop while (plusp numbytes) do
            (let ((bytes-read (system:read-n-bytes stream s start numbytes nil)))
              (when (zerop bytes-read)
                (return-from read-into-simple-string total-bytes))
              (incf total-bytes bytes-read)
              (incf start bytes-read)
              (decf numbytes bytes-read)))
      total-bytes))

  (let ((s (find-symbol (string :*enable-package-locked-errors*) :lisp)))
    (when s
      (setf (symbol-value s) t)))

  )

(in-package :swank-backend)


;;;; TCP server.

(defimplementation preferred-communication-style ()
  :sigio)

(defimplementation create-socket (host port)
  (ext:create-inet-listener port :stream
                            :reuse-address t
                            :host (resolve-hostname host)))

(defimplementation local-port (socket)
  (nth-value 1 (ext::get-socket-host-and-port (socket-fd socket))))

(defimplementation close-socket (socket)
  (ext:close-socket (socket-fd socket)))

(defimplementation accept-connection (socket)
  #+MP (mp:process-wait-until-fd-usable socket :input)
  (make-socket-io-stream (ext:accept-tcp-connection socket)))

(defvar *sigio-handlers* '()
  "List of (key . (fn . args)) pairs to be called on SIGIO.")

(defun sigio-handler (signal code scp)
  (declare (ignore signal code scp))
  (mapc (lambda (handler) (funcall (cdr handler))) *sigio-handlers*))

(defun set-sigio-handler ()
  (sys:enable-interrupt unix:SIGIO (lambda (signal code scp)
				     (sigio-handler signal code scp))))

(defun fcntl (fd command arg)
  (multiple-value-bind (ok error) (unix:unix-fcntl fd command arg)
    (cond (ok)
          (t (error "fcntl: ~A" (unix:get-unix-error-msg error))))))

(defimplementation add-sigio-handler (socket fn)
  (set-sigio-handler)
  (let ((fd (socket-fd socket)))
    (format *debug-io* "; Adding input handler: ~S ~%" fd)
    (fcntl fd unix:f-setown (unix:unix-getpid))
    (fcntl fd unix:f-setfl unix:FASYNC)
    (push (cons fd fn) *sigio-handlers*)))

(defimplementation remove-sigio-handlers (socket)
  (let ((fd (socket-fd socket)))
    (setf *sigio-handlers* (delete fd *sigio-handlers* :key #'car))
    (sys:invalidate-descriptor fd))
  (close socket))

(defimplementation add-fd-handler (socket fn)
  (let ((fd (socket-fd socket)))
    (format *debug-io* "; Adding fd handler: ~S ~%" fd)
    (sys:add-fd-handler fd :input (lambda (_) 
                                    _
                                    (funcall fn)))))

(defimplementation remove-fd-handlers (socket)
  (sys:invalidate-descriptor (socket-fd socket)))

(defimplementation make-fn-streams (input-fn output-fn)
  (let* ((output (make-slime-output-stream output-fn))
         (input  (make-slime-input-stream input-fn output)))
    (values input output)))

;;;;; Socket helpers.

(defun socket-fd (socket)
  "Return the filedescriptor for the socket represented by SOCKET."
  (etypecase socket
    (fixnum socket)
    (sys:fd-stream (sys:fd-stream-fd socket))))

(defun resolve-hostname (hostname)
  "Return the IP address of HOSTNAME as an integer."
  (let* ((hostent (ext:lookup-host-entry hostname))
         (address (car (ext:host-entry-addr-list hostent))))
    (ext:htonl address)))

(defun make-socket-io-stream (fd)
  "Create a new input/output fd-stream for FD."
  (sys:make-fd-stream fd :input t :output t :element-type 'base-char))

(defun set-fd-non-blocking (fd)
  (flet ((fcntl (fd cmd arg)
           (multiple-value-bind (flags errno) (unix:unix-fcntl fd cmd arg)
             (or flags 
                 (error "fcntl: ~A" (unix:get-unix-error-msg errno))))))
    (let ((flags (fcntl fd unix:F-GETFL 0)))
      (fcntl fd unix:F-SETFL (logior flags unix:O_NONBLOCK)))))


;;;; Unix signals

(defmethod call-without-interrupts (fn)
  (sys:without-interrupts (funcall fn)))

(defimplementation getpid ()
  (unix:unix-getpid))

(defimplementation lisp-implementation-type-name ()
  "cmucl")


;;;; Stream handling

(defstruct (slime-output-stream
             (:include lisp::lisp-stream
                       (lisp::misc #'sos/misc)
                       (lisp::out #'sos/out)
                       (lisp::sout #'sos/sout))
             (:conc-name sos.)
             (:print-function %print-slime-output-stream)
             (:constructor make-slime-output-stream (output-fn)))
  (output-fn nil :type function)
  (buffer (make-string 512) :type string)
  (index 0 :type kernel:index)
  (column 0 :type kernel:index))

(defun %print-slime-output-stream (s stream d)
  (declare (ignore d))
  (print-unreadable-object (s stream :type t :identity t)))

(defun sos/out (stream char)
  (let ((buffer (sos.buffer stream))
	(index (sos.index stream)))
    (setf (schar buffer index) char)
    (setf (sos.index stream) (1+ index))
    (incf (sos.column stream))
    (when (char= #\newline char)
      (setf (sos.column stream) 0))
    (when (= index (1- (length buffer)))
      (force-output stream)))
  char)

(defun sos/sout (stream string start end)
  (loop for i from start below end 
	do (sos/out stream (aref string i))))

(defun sos/misc (stream operation &optional arg1 arg2)
  (declare (ignore arg1 arg2))
  (case operation
    ((:force-output :finish-output)
     (let ((end (sos.index stream)))
       (unless (zerop end)
         (funcall (sos.output-fn stream) (subseq (sos.buffer stream) 0 end))
         (setf (sos.index stream) 0))))
    (:charpos (sos.column stream))
    (:line-length 75)
    (:file-position nil)
    (:element-type 'base-char)
    (:get-command nil)
    (:close nil)
    (t (format *terminal-io* "~&~Astream: ~S~%" stream operation))))

(defstruct (slime-input-stream
             (:include string-stream
                       (lisp::in #'sis/in)
                       (lisp::misc #'sis/misc))
             (:conc-name sis.)
             (:print-function %print-slime-output-stream)
             (:constructor make-slime-input-stream (input-fn sos)))
  (input-fn nil :type function)
  ;; We know our sibling output stream, so that we can force it before
  ;; requesting input.
  (sos      nil :type slime-output-stream)
  (buffer   ""  :type string)
  (index    0   :type kernel:index))

(defun sis/in (stream eof-errorp eof-value)
  (declare (ignore eof-errorp eof-value))
  (let ((index (sis.index stream))
	(buffer (sis.buffer stream)))
    (when (= index (length buffer))
      (force-output (sis.sos stream))
      (setf buffer (funcall (sis.input-fn stream)))
      (setf (sis.buffer stream) buffer)
      (setf index 0))
    (prog1 (aref buffer index)
      (setf (sis.index stream) (1+ index)))))

(defun sis/misc (stream operation &optional arg1 arg2)
  (declare (ignore arg2))
  (ecase operation
    (:file-position nil)
    (:file-length nil)
    (:unread (setf (aref (sis.buffer stream) 
			 (decf (sis.index stream)))
		   arg1))
    (:clear-input 
     (setf (sis.index stream) 0
			(sis.buffer stream) ""))
    (:listen (< (sis.index stream) (length (sis.buffer stream))))
    (:charpos nil)
    (:line-length nil)
    (:get-command nil)
    (:element-type 'base-char)
    (:close nil)))


;;;; Compilation Commands

(defvar *previous-compiler-condition* nil
  "Used to detect duplicates.")

(defvar *previous-context* nil
  "Previous compiler error context.")

(defvar *buffer-name* nil)
(defvar *buffer-start-position* nil)
(defvar *buffer-substring* nil)


;;;;; Trapping notes

(defun handle-notification-condition (condition)
  "Handle a condition caused by a compiler warning.
This traps all compiler conditions at a lower-level than using
C:*COMPILER-NOTIFICATION-FUNCTION*. The advantage is that we get to
craft our own error messages, which can omit a lot of redundant
information."
  (unless (eq condition *previous-compiler-condition*)
    (let ((context (c::find-error-context nil)))
      (setq *previous-compiler-condition* condition)
      (setq *previous-context* context)
      (signal-compiler-condition condition context))))

(defun signal-compiler-condition (condition context)
  (signal (make-condition
           'compiler-condition
           :original-condition condition
           :severity (severity-for-emacs condition)
           :short-message (brief-compiler-message-for-emacs condition)
           :message (long-compiler-message-for-emacs condition context)
           :location (compiler-note-location context))))

(defun severity-for-emacs (condition)
  "Return the severity of CONDITION."
  (etypecase condition
    (c::compiler-error :error)
    (c::style-warning :note)
    (c::warning :warning)))

(defun brief-compiler-message-for-emacs (condition)
  "Briefly describe a compiler error for Emacs.
When Emacs presents the message it already has the source popped up
and the source form highlighted. This makes much of the information in
the error-context redundant."
  (princ-to-string condition))

(defun long-compiler-message-for-emacs (condition error-context)
  "Describe a compiler error for Emacs including context information."
  (declare (type (or c::compiler-error-context null) error-context))
  (multiple-value-bind (enclosing source)
      (if error-context
          (values (c::compiler-error-context-enclosing-source error-context)
                  (c::compiler-error-context-source error-context)))
    (format nil "~@[--> ~{~<~%--> ~1:;~A~> ~}~%~]~@[~{==>~%~A~^~%~}~]~A"
            enclosing source condition)))

(defun compiler-note-location (context)
  (cond (context
         (resolve-note-location
          *buffer-name*
          (c::compiler-error-context-file-name context)
          (c::compiler-error-context-file-position context)
          (reverse (c::compiler-error-context-original-source-path context))
          (c::compiler-error-context-original-source context)))
        (t
         (resolve-note-location *buffer-name* nil nil nil nil))))

(defgeneric resolve-note-location (buffer file-name file-position 
                                          source-path source))

(defmethod resolve-note-location ((b (eql nil)) (f pathname) pos path source)
  (make-location
   `(:file ,(unix-truename f))
   `(:position ,(1+ (source-path-file-position path f)))))

(defmethod resolve-note-location ((b string) (f (eql :stream)) pos path source)
  (make-location
   `(:buffer ,b)
   `(:position ,(+ *buffer-start-position*
                   (source-path-string-position path *buffer-substring*)))))

(defmethod resolve-note-location (b (f (eql :lisp)) pos path (source string))
  (make-location
   `(:source-form ,source)
   `(:position 1)))

(defmethod resolve-note-location (buffer
                                  (file (eql nil)) 
                                  (pos (eql nil)) 
                                  (path (eql nil))
                                  (source (eql nil)))
  (list :error "No error location available"))

(defimplementation call-with-compilation-hooks (function)
  (let ((*previous-compiler-condition* nil)
        (*previous-context* nil)
        (*print-readably* nil))
    (handler-bind ((c::compiler-error #'handle-notification-condition)
                   (c::style-warning  #'handle-notification-condition)
                   (c::warning        #'handle-notification-condition))
      (funcall function))))

(defimplementation swank-compile-file (filename load-p)
  (clear-xref-info filename)
  (with-compilation-hooks ()
    (let ((*buffer-name* nil))
      (compile-file filename :load load-p))))

(defimplementation swank-compile-string (string &key buffer position)
  (with-compilation-hooks ()
    (let ((*buffer-name* buffer)
          (*buffer-start-position* position)
          (*buffer-substring* string))
      (with-input-from-string (stream string)
        (ext:compile-from-stream 
         stream 
         :source-info `(:emacs-buffer ,buffer 
                        :emacs-buffer-offset ,position
                        :emacs-buffer-string ,string))))))


;;;; XREF

(defmacro defxref (name function)
  `(defimplementation ,name (name)
    (xref-results (,function name))))

(defxref who-calls      xref:who-calls)
(defxref who-references xref:who-references)
(defxref who-binds      xref:who-binds)
(defxref who-sets       xref:who-sets)

#+cmu19
(progn
  (defxref who-macroexpands xref:who-macroexpands)
  ;; XXX
  (defimplementation who-specializes (symbol)
    (let* ((methods (xref::who-specializes (find-class symbol)))
           (locations (mapcar #'method-location methods)))
      (mapcar #'list methods locations))))

(defun xref-results (contexts)
  (mapcar (lambda (xref)
            (list (xref:xref-context-name xref)
                  (resolve-xref-location xref)))
          contexts))

(defun resolve-xref-location (xref)
  (let ((name (xref:xref-context-name xref))
        (file (xref:xref-context-file xref))
        (source-path (xref:xref-context-source-path xref)))
    (cond ((and file source-path)
           (let ((position (source-path-file-position source-path file)))
             (make-location (list :file (unix-truename file))
                            (list :position (1+ position)))))
          (file
           (make-location (list :file (unix-truename file))
                          (list :function-name (string name))))
          (t
           `(:error ,(format nil "Unkown source location: ~S ~S ~S " 
                             name file source-path))))))

(defun clear-xref-info (namestring)
  "Clear XREF notes pertaining to NAMESTRING.
This is a workaround for a CMUCL bug: XREF records are cumulative."
  (when c:*record-xref-info*
    (let ((filename (truename namestring)))
      (dolist (db (list xref::*who-calls*
                        #+cmu19 xref::*who-is-called*
                        #+cmu19 xref::*who-macroexpands*
                        xref::*who-references*
                        xref::*who-binds*
                        xref::*who-sets*))
        (maphash (lambda (target contexts)
                   ;; XXX update during traversal?  
                   (setf (gethash target db)
                         (delete filename contexts 
                                 :key #'xref:xref-context-file
                                 :test #'equalp)))
                 db)))))

(defun unix-truename (pathname)
  (ext:unix-namestring (truename pathname)))


;;;; Find callers and callees

;;; Find callers and callees by looking at the constant pool of
;;; compiled code objects.  We assume every fdefn object in the
;;; constant pool corresponds to a call to that function.  A better
;;; strategy would be to use the disassembler to find actual
;;; call-sites.

(declaim (inline map-code-constants))
(defun map-code-constants (code fn)
  "Call FN for each constant in CODE's constant pool."
  (check-type code kernel:code-component)
  (loop for i from vm:code-constants-offset below (kernel:get-header-data code)
	do (funcall fn (kernel:code-header-ref code i))))

(defun function-callees (function)
  "Return FUNCTION's callees as a list of functions."
  (let ((callees '()))
    (map-code-constants 
     (vm::find-code-object function)
     (lambda (obj)
       (when (kernel:fdefn-p obj)
	 (push (kernel:fdefn-function obj) callees))))
    callees))

(declaim (ext:maybe-inline map-allocated-code-components))
(defun map-allocated-code-components (spaces fn)
  "Call FN for each allocated code component in one of SPACES.  FN
receives the object as argument.  SPACES should be a list of the
symbols :dynamic, :static, or :read-only."
  (dolist (space spaces)
    (declare (inline vm::map-allocated-objects))
    (vm::map-allocated-objects
     (lambda (obj header size)
       (declare (type fixnum size) (ignore size))
       (when (= vm:code-header-type header)
	 (funcall fn obj)))
     space)))

(declaim (ext:maybe-inline map-caller-code-components))
(defun map-caller-code-components (function spaces fn)
  "Call FN for each code component with a fdefn for FUNCTION in its
constant pool."
  (let ((function (coerce function 'function)))
    (declare (inline map-allocated-code-components))
    (map-allocated-code-components
     spaces 
     (lambda (obj)
       (map-code-constants 
	obj 
	(lambda (constant)
	  (when (and (kernel:fdefn-p constant)
		     (eq (kernel:fdefn-function constant)
			 function))
	    (funcall fn obj))))))))

(defun function-callers (function &optional (spaces '(:read-only :static 
						      :dynamic)))
  "Return FUNCTION's callers.  The result is a list of code-objects."
  (let ((referrers '()))
    (declare (inline map-caller-code-components))
    (ext:gc :full t)
    (map-caller-code-components function spaces 
                                (lambda (code) (push code referrers)))
    referrers))

(defun debug-info-definitions (debug-info)
  "Return the defintions for a debug-info.  This should only be used
for code-object without entry points, i.e., byte compiled
code (are theree others?)"
  ;; This mess has only been tested with #'ext::skip-whitespace, a
  ;; byte-compiled caller of #'read-char .
  (check-type debug-info (and (not c::compiled-debug-info) c::debug-info))
  (let ((name (c::debug-info-name debug-info))
        (source (c::debug-info-source debug-info)))
    (destructuring-bind (first) source 
      (ecase (c::debug-source-from first)
        (:file 
         (list (list name
                     (make-location 
                      (list :file (unix-truename (c::debug-source-name first)))
                      (list :function-name name)))))))))

(defun code-component-entry-points (code)
  "Return a list ((NAME LOCATION) ...) of function definitons for
the code omponent CODE."
  (delete-duplicates
   (loop for e = (kernel:%code-entry-points code)
         then (kernel::%function-next e)
         while e
         collect (list (kernel:%function-name e)
                       (function-location e)))
   :test #'equal))

(defimplementation list-callers (symbol)
  "Return a list ((NAME LOCATION) ...) of callers."
  (let ((components (function-callers symbol))
        (xrefs '()))
    (dolist (code components)
      (let* ((entry (kernel:%code-entry-points code))
             (defs (if entry
                       (code-component-entry-points code)
                       ;; byte compiled stuff
                       (debug-info-definitions 
                        (kernel:%code-debug-info code)))))
        (setq xrefs (nconc defs xrefs))))
    xrefs))

(defimplementation list-callees (symbol)
  (let ((fns (function-callees symbol)))
    (mapcar (lambda (fn)
              (list (kernel:%function-name fn)
                    (function-location fn)))
            fns)))


;;;; Definitions

(defvar *debug-definition-finding* nil
  "When true don't handle errors while looking for definitions.
This is useful when debugging the definition-finding code.")

(defmacro safe-definition-finding (&body body)
  "Execute BODY ignoring errors.  Return the source location returned
by BODY or if an error occurs a description of the error.  The second
return value is the condition or nil."  
  `(flet ((body () ,@body))
    (if *debug-definition-finding*
        (body)
        (handler-case (values (progn ,@body) nil)
          (error (c) (values (list :error (princ-to-string c)) c))))))
    
(defun function-first-code-location (function)
  (and (function-has-debug-function-p function)
       (di:debug-function-start-location
        (di:function-debug-function function))))

(defun function-has-debug-function-p (function)
  (di:function-debug-function function))

(defun function-code-object= (closure function)
  (and (eq (vm::find-code-object closure)
	   (vm::find-code-object function))
       (not (eq closure function))))

(defun genericp (fn)
  (typep fn 'generic-function))

(defun struct-closure-p (function)
  (or (function-code-object= function #'kernel::structure-slot-accessor)
      (function-code-object= function #'kernel::structure-slot-setter)
      (function-code-object= function #'kernel::%defstruct)))

(defun struct-closure-dd (function)
  (assert (= (kernel:get-type function) vm:closure-header-type))
  (flet ((find-layout (function)
	   (sys:find-if-in-closure 
	    (lambda (x) 
	      (let ((value (if (di::indirect-value-cell-p x)
			       (c:value-cell-ref x) 
			       x)))
		(when (kernel::layout-p value)
		  (return-from find-layout value))))
	    function)))
    (kernel:layout-info (find-layout function))))
	    
(defun dd-location (dd)
  (let ((constructor (or (kernel:dd-default-constructor dd)
                         (car (kernel::dd-constructors dd)))))
    (when (or (not constructor) (and (consp constructor)
                                     (not (car constructor))))
      (error "Cannot locate struct without constructor: ~S" 
             (kernel::dd-name dd)))
    (function-location 
     (coerce (if (consp constructor) (car constructor) constructor)
             'function))))

(defun function-location (function)
  "Return the source location for FUNCTION."
  ;; First test if FUNCTION is a closure created by defstruct; if so
  ;; extract the defstruct-description (dd) from the closure and find
  ;; the constructor for the struct.  Defstruct creates a defun for
  ;; the default constructor and we use that as an approximation to
  ;; the source location of the defstruct.
  ;;
  ;; For an ordinary function we return the source location of the
  ;; first code-location we find.
  (cond ((struct-closure-p function)
         (safe-definition-finding
          (dd-location (struct-closure-dd function))))
        ((genericp function)
         (gf-location function))
        (t
         (multiple-value-bind (code-location error)
             (safe-definition-finding (function-first-code-location function))
           (cond (error (list :error (princ-to-string error)))
                 (t (code-location-source-location code-location)))))))

(defun method-location (method)
  (function-location (or (pcl::method-fast-function method)
                         (pcl:method-function method))))

(defun method-dspec (method)
  (let* ((gf (pcl:method-generic-function method))
         (name (pcl:generic-function-name gf))
         (specializers (pcl:method-specializers method)))
    `(method ,name ,(pcl::unparse-specializers specializers))))

(defun method-definition (method)
  (list (method-dspec method)
        (method-location method)))

(defun make-name-in-file-location (file string)
  (multiple-value-bind (filename c)
      (ignore-errors (unix-truename 
                      (merge-pathnames (make-pathname :type "lisp")
                                       file)))
    (cond (filename (make-location `(:file ,filename)
                                   `(:function-name ,string)))
          (t (list :error (princ-to-string c))))))

(defun gf-location (gf)
  (let ((def-source (pcl::definition-source gf))
        (name (string (nth-value 1 (ext:valid-function-name-p
                                    (pcl:generic-function-name gf))))))
    (etypecase def-source
      (pathname (make-name-in-file-location def-source name))
      (cons
       (destructuring-bind ((dg name) pathname) def-source
         (declare (ignore dg))
         (etypecase pathname
           (pathname (make-name-in-file-location pathname (string name)))
           (null `(:error ,(format nil "Cannot resolve: ~S" def-source)))))))))

(defun gf-method-definitions (gf)
  (mapcar #'method-definition (pcl::generic-function-methods gf)))

(defun function-definitions (symbol)
  "Return definitions in the \"function namespace\", i.e.,
regular functions, generic functions, methods and macros."
  (cond ((macro-function symbol)
         (list `((defmacro ,symbol)
                 ,(function-location (macro-function symbol)))))
        ((special-operator-p symbol)
         (list `((:special-operator ,symbol) 
                 (:error ,(format nil "Special operator: ~S" symbol)))))
        ((fboundp symbol)
         (let ((function (coerce symbol 'function)))
           (cond ((genericp function)
                  (cons (list `(defgeneric ,symbol)
                              (function-location function))
                        (gf-method-definitions function)))
                 (t (list (list `(function ,symbol)
                                (function-location function)))))))))

(defun maybe-make-definition (function kind symbol)
  (if function
      (list (list `(,kind ,symbol) (function-location function)))))

(defun type-definitions (symbol)
  (maybe-make-definition (ext:info :type :expander symbol) 'deftype symbol))

(defun find-dd (name)
  (let ((layout (ext:info :type :compiler-layout name)))
    (if layout 
        (kernel:layout-info layout))))

(defun struct-definitions (symbol)
  (let ((dd (find-dd symbol)))
    (if dd
        (list (list `(defstruct ,symbol) (dd-location dd))))))

(defun setf-definitions (symbol)
  (let ((function (or (let ((name `(setf ,symbol)))
                        (if (lisp::fdefinition-object name nil)
                            name))
                      (ext:info :setf :inverse symbol)
                      (ext:info :setf :expander symbol))))
    (if function
        (list (list `(setf ,symbol) 
                    (function-location (coerce function 'function)))))))

(defun compiler-macro-definitions (symbol)
  (maybe-make-definition (compiler-macro-function symbol)
                         'define-compiler-macro
                         symbol))

(defun source-transform-definitions (symbol)
  (maybe-make-definition (ext:info :function :source-transform symbol)
                         'c:def-source-transform
                         symbol))

(defun function-info-definitions (symbol)
  (let ((info (ext:info :function :info symbol)))
    (if info
        (append (loop for transform in (c::function-info-transforms info)
                      collect (list `(c:deftransform ,symbol 
                                      ,(c::type-specifier 
                                        (c::transform-type transform)))
                                    (function-location (c::transform-function 
                                                        transform))))
                (maybe-make-definition (c::function-info-derive-type info)
                                       'c::derive-type symbol)
                (maybe-make-definition (c::function-info-optimizer info)
                                       'c::optimizer symbol)
                (maybe-make-definition (c::function-info-ltn-annotate info)
                                       'c::ltn-annotate symbol)
                (maybe-make-definition (c::function-info-ir2-convert info)
                                       'c::ir2-convert symbol)
                (loop for template in (c::function-info-templates info)
                      collect (list `(c::vop ,(c::template-name template))
                                    (function-location 
                                     (c::vop-info-generator-function 
                                      template))))))))

(defun ir1-translator-definitions (symbol)
  (maybe-make-definition (ext:info :function :ir1-convert symbol)
                         'c:def-ir1-translator symbol))

(defimplementation find-definitions (symbol)
  (append (function-definitions symbol)
          (setf-definitions symbol)
          (struct-definitions symbol)
          (type-definitions symbol)
          (compiler-macro-definitions symbol)
          (source-transform-definitions symbol)
          (function-info-definitions symbol)
          (ir1-translator-definitions symbol)))

;;;; Documentation.

(defimplementation describe-symbol-for-emacs (symbol)
  (let ((result '()))
    (flet ((doc (kind)
             (or (documentation symbol kind) :not-documented))
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
       :generic-function 
       (if (and (fboundp symbol)
                (typep (fdefinition symbol) 'generic-function))
           (doc 'function)))
      (maybe-push
       :function (if (and (fboundp symbol)
                          (not (typep (fdefinition symbol) 'generic-function)))
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
      (maybe-push
       :alien-type (if (not (eq (ext:info alien-type kind symbol) :unknown))
		       (doc 'alien-type)))
      (maybe-push
       :alien-struct (if (ext:info alien-type struct symbol)
			 (doc nil)))
      (maybe-push
       :alien-union (if (ext:info alien-type union symbol)
			 (doc nil)))
      (maybe-push
       :alien-enum (if (ext:info alien-type enum symbol)
		       (doc nil)))
      result)))

(defimplementation describe-definition (symbol namespace)
  (ecase namespace
    (:variable
     (describe symbol))
    ((:function :generic-function)
     (describe (symbol-function symbol)))
    (:setf
     (describe (or (ext:info setf inverse symbol))
               (ext:info setf expander symbol)))
    (:type
     (describe (kernel:values-specifier-type symbol)))
    (:class
     (describe (find-class symbol)))
    (:alien-type
     (ecase (ext:info :alien-type :kind symbol)
       (:primitive
        (describe (let ((alien::*values-type-okay* t))
                    (funcall (ext:info :alien-type :translator symbol) 
                             (list symbol)))))
       ((:defined)
        (describe (ext:info :alien-type :definition symbol)))
       (:unknown
        (format nil "Unkown alien type: ~S" symbol))))
    (:alien-struct
     (describe (ext:info :alien-type :struct symbol)))
    (:alien-union
     (describe (ext:info :alien-type :union symbol)))
    (:alien-enum
     (describe (ext:info :alien-type :enum symbol)))))

(defimplementation arglist (symbol)
  (let* ((fun (or (macro-function symbol)
                  (symbol-function symbol)))
         (arglist
          (cond ((eval:interpreted-function-p fun)
                 (eval:interpreted-function-arglist fun))
                ((pcl::generic-function-p fun)
                 (pcl:generic-function-lambda-list fun))
                ((kernel:%function-arglist (kernel:%function-self fun)))
                ;; this should work both for
                ;; compiled-debug-function and for
                ;; interpreted-debug-function
                (t (let ((df (di::function-debug-function fun)))
                     (if df 
                         (di::debug-function-lambda-list df)
                         "(<arglist-unavailable>)"))))))
    (check-type arglist (or list string))
    arglist))


;;;; Miscellaneous.

(defimplementation macroexpand-all (form)
  (walker:macroexpand-all form))

;; (in-package :c)
;; 
;; (defun swank-backend::expand-ir1-top-level (form)
;;   "A scaled down version of the first pass of the compiler."
;;   (with-compilation-unit ()
;;     (let* ((*lexical-environment*
;;             (make-lexenv :default (make-null-environment)
;;                          :cookie *default-cookie*
;;                          :interface-cookie *default-interface-cookie*))
;;            (*source-info* (make-lisp-source-info form))
;;            (*block-compile* nil)
;;            (*block-compile-default* nil))
;;       (with-ir1-namespace
;;           (clear-stuff)
;;         (find-source-paths form 0)
;;         (ir1-top-level form '(0) t)))))
;; 
;; (in-package :swank-backend)
;; 
;; (defun print-ir1-converted-blocks (form)
;;   (with-output-to-string (*standard-output*)
;;     (c::print-all-blocks (expand-ir1-top-level (from-string form)))))
;; 
;; (defun print-compilation-trace (form)
;;   (with-output-to-string (*standard-output*)
;;     (with-input-from-string (s form)
;;       (ext:compile-from-stream s 
;;                                :verbose t
;;                                :progress t
;;                                :trace-stream *standard-output*))))

(defun set-default-directory (directory)
  (setf (ext:default-directory) (namestring directory))
  ;; Setting *default-pathname-defaults* to an absolute directory
  ;; makes the behavior of MERGE-PATHNAMES a bit more intuitive.
  (setf *default-pathname-defaults* (pathname (ext:default-directory)))
  (namestring (ext:default-directory)))

;;; source-path-{stream,file,string,etc}-position moved into 
;;; swank-source-path-parser

(defun code-location-stream-position (code-location stream)
  "Return the byte offset of CODE-LOCATION in STREAM.  Extract the
toplevel-form-number and form-number from CODE-LOCATION and use that
to find the position of the corresponding form."
  (let* ((location (debug::maybe-block-start-location code-location))
	 (tlf-offset (di:code-location-top-level-form-offset location))
	 (form-number (di:code-location-form-number location))
	 (*read-suppress* t))
    (dotimes (i tlf-offset) (read stream))
    (multiple-value-bind (tlf position-map) (read-and-record-source-map stream)
      (let* ((path-table (di:form-number-translations tlf 0))
             (source-path
              (if (<= (length path-table) form-number) ; source out of sync?
                  (list 0)              ; should probably signal a condition
                  (reverse (cdr (aref path-table form-number))))))
	(source-path-source-position source-path tlf position-map)))))
  
(defun code-location-string-offset (code-location string)
  (with-input-from-string (s string)
    (code-location-stream-position code-location s)))

(defun code-location-file-position (code-location filename)
  (with-open-file (s filename :direction :input)
    (code-location-stream-position code-location s)))

(defun debug-source-info-from-emacs-buffer-p (debug-source)
  (let ((info (c::debug-source-info debug-source)))
    (and info 
	 (consp info)
	 (eq :emacs-buffer (car info)))))

(defun source-location-from-code-location (code-location)
  "Return the source location for CODE-LOCATION."
  (let ((debug-fun (di:code-location-debug-function code-location)))
    (when (di::bogus-debug-function-p debug-fun)
      (error "Bogus debug function: ~A" debug-fun)))
  (let* ((debug-source (di:code-location-debug-source code-location))
         (from (di:debug-source-from debug-source))
         (name (di:debug-source-name debug-source)))
    (ecase from
      (:file 
       (make-location (list :file (unix-truename name))
                      (list :position (1+ (code-location-file-position
                                           code-location name)))))
      (:stream 
       (assert (debug-source-info-from-emacs-buffer-p debug-source))
       (let ((info (c::debug-source-info debug-source)))
         (make-location
          (list :buffer (getf info :emacs-buffer))
          (list :position (+ (getf info :emacs-buffer-offset) 
                             (code-location-string-offset 
                              code-location
                              (getf info :emacs-buffer-string)))))))
      (:lisp
       (make-location
        (list :source-form (with-output-to-string (*standard-output*)
                             (debug::print-code-location-source-form 
                              code-location 100 t)))
        (list :position 1))))))

(defun code-location-source-location (code-location)
  "Safe wrapper around `code-location-from-source-location'."
  (safe-definition-finding
   (source-location-from-code-location code-location)))


;;;; Debugging

(defvar *sldb-stack-top*)

(defimplementation call-with-debugging-environment (debugger-loop-fn)
  (unix:unix-sigsetmask 0)
  (let* ((*sldb-stack-top* (or debug:*stack-top-hint* (di:top-frame)))
	 (debug:*stack-top-hint* nil))
    (handler-bind ((di:debug-condition 
		    (lambda (condition)
                      (signal (make-condition
                               'sldb-condition
                               :original-condition condition)))))
      (funcall debugger-loop-fn))))

(defun nth-frame (index)
  (do ((frame *sldb-stack-top* (di:frame-down frame))
       (i index (1- i)))
      ((zerop i) frame)))

(defimplementation compute-backtrace (start end)
  (let ((end (or end most-positive-fixnum)))
    (loop for f = (nth-frame start) then (di:frame-down f)
	  for i from start below end
	  while f
	  collect f)))

(defimplementation print-frame (frame stream)
  (let ((*standard-output* stream))
    (debug::print-frame-call frame :verbosity 1 :number nil)))

(defimplementation frame-source-location-for-emacs (index)
  (code-location-source-location (di:frame-code-location (nth-frame index))))

(defimplementation eval-in-frame (form index)
  (di:eval-in-frame (nth-frame index) form))

(defimplementation frame-locals (index)
  (let* ((frame (nth-frame index))
	 (location (di:frame-code-location frame))
	 (debug-function (di:frame-debug-function frame))
	 (debug-variables (di::debug-function-debug-variables debug-function)))
    (loop for v across debug-variables collect 
          (list :name (di:debug-variable-symbol v)
                :id (di:debug-variable-id v)
                :value (ecase (di:debug-variable-validity v location)
                         (:valid 
                          (di:debug-variable-value v frame))
                         ((:invalid :unknown) 
                          ':not-available))))))

(defimplementation frame-catch-tags (index)
  (mapcar #'car (di:frame-catches (nth-frame index))))

(defun set-step-breakpoints (frame)
  (when (di:debug-block-elsewhere-p (di:code-location-debug-block
                                     (di:frame-code-location frame)))
    (error "Cannot step, in elsewhere code~%"))
  (let* ((code-location (di:frame-code-location frame))
         (debug::*bad-code-location-types* 
          (remove :call-site debug::*bad-code-location-types*))
         (next (debug::next-code-locations code-location)))
    (cond (next
           (let ((steppoints '()))
             (flet ((hook (frame breakpoint)
                      (let ((debug:*stack-top-hint* frame))
                        (mapc #'di:delete-breakpoint steppoints)
                        (let ((cl (di::breakpoint-what breakpoint)))
                          (break "Breakpoint: ~S ~S" 
                                 (di:code-location-kind cl)
                                 (di::compiled-code-location-pc cl))))))
               (dolist (code-location next)
                 (let ((bp (di:make-breakpoint #'hook code-location
                                               :kind :code-location)))
                   (di:activate-breakpoint bp)
                   (push bp steppoints))))))
         (t
          (flet ((hook (frame breakpoint values cookie)
                   (declare (ignore cookie))
                   (di:delete-breakpoint breakpoint)
                   (let ((debug:*stack-top-hint* frame))
                     (break "Function-end: ~A ~A" breakpoint values))))
            (let* ((debug-function (di:frame-debug-function frame))
                   (bp (di:make-breakpoint #'hook debug-function
                                           :kind :function-end)))
              (di:activate-breakpoint bp)))))))

;; (defslimefun sldb-step (frame)
;;   (cond ((find-restart 'continue *swank-debugger-condition*)
;;          (set-step-breakpoints (nth-frame frame))
;;          (continue *swank-debugger-condition*))
;;         (t
;;          (error "Cannot continue in from condition: ~A" 
;;                 *swank-debugger-condition*))))

(defun frame-cfp (frame)
  "Return the Control-Stack-Frame-Pointer for FRAME."
  (etypecase frame
    (di::compiled-frame (di::frame-pointer frame))
    ((or di::interpreted-frame null) -1)))

(defun frame-ip (frame)
  "Return the (absolute) instruction pointer and the relative pc of FRAME."
  (if (not frame)
      -1
      (let ((debug-fun (di::frame-debug-function frame)))
        (etypecase debug-fun
          (di::compiled-debug-function 
           (let* ((code-loc (di:frame-code-location frame))
                  (component (di::compiled-debug-function-component debug-fun))
                  (pc (di::compiled-code-location-pc code-loc))
                  (ip (sys:without-gcing
                       (sys:sap-int
                        (sys:sap+ (kernel:code-instructions component) pc)))))
             (values ip pc)))
          ((or di::bogus-debug-function di::interpreted-debug-function)
           -1)))))

(defun frame-registers (frame)
  "Return the lisp registers CSP, CFP, IP, OCFP, LRA for FRAME-NUMBER."
  (let* ((cfp (frame-cfp frame))
         (csp (frame-cfp (di::frame-up frame)))
         (ip (frame-ip frame))
         (ocfp (frame-cfp (di::frame-down frame)))
         (lra (frame-ip (di::frame-down frame))))
    (values csp cfp ip ocfp lra)))

(defun print-frame-registers (frame-number)
  (let ((frame (di::frame-real-frame (nth-frame frame-number))))
    (flet ((fixnum (p) (etypecase p
                         (integer p)
                         (sys:system-area-pointer (sys:sap-int p)))))
      (apply #'format t "~
CSP  =  ~X
CFP  =  ~X
IP   =  ~X
OCFP =  ~X
LRA  =  ~X~%" (mapcar #'fixnum 
                      (multiple-value-list (frame-registers frame)))))))


(defimplementation disassemble-frame (frame-number)
  "Return a string with the disassembly of frames code."
  (print-frame-registers frame-number)
  (terpri)
  (let* ((frame (di::frame-real-frame (nth-frame frame-number)))
         (debug-fun (di::frame-debug-function frame)))
    (etypecase debug-fun
      (di::compiled-debug-function
       (let* ((component (di::compiled-debug-function-component debug-fun))
              (fun (di:debug-function-function debug-fun)))
         (if fun
             (disassemble fun)
             (disassem:disassemble-code-component component))))
      (di::bogus-debug-function
       (format t "~%[Disassembling bogus frames not implemented]")))))

#+(or)
(defun print-binding-stack ()
  (flet ((bsp- (p) (sys:sap+ p (- (* vm:binding-size vm:word-bytes))))
         (frob (p offset) (kernel:make-lisp-obj (sys:sap-ref-32 p offset))))
    (do ((bsp (bsp- (kernel:binding-stack-pointer-sap)) (bsp- bsp))
         (start (sys:int-sap (lisp::binding-stack-start))))
        ((sys:sap= bsp start))
      (format t "~X:  ~S = ~S~%" 
              (sys:sap-int bsp)
              (frob bsp (* vm:binding-symbol-slot vm:word-bytes))
              (frob bsp (* vm:binding-value-slot vm:word-bytes))))))

;; (print-binding-stack)

#+(or)
(defun print-catch-blocks ()
  (do ((b (di::descriptor-sap lisp::*current-catch-block*)
          (sys:sap-ref-sap b (* vm:catch-block-previous-catch-slot
                                vm:word-bytes))))
      (nil)
    (let ((int (sys:sap-int b)))
      (when (zerop int) (return))
      (flet ((ref (offset) (sys:sap-ref-32 b (* offset vm:word-bytes))))
        (let ((uwp (ref vm:catch-block-current-uwp-slot))
              (cfp (ref vm:catch-block-current-cont-slot))
              (tag (ref vm:catch-block-tag-slot))
              )
      (format t "~X:  uwp = ~8X  cfp = ~8X  tag = ~X~%" 
              int uwp cfp (kernel:make-lisp-obj tag)))))))

;; (print-catch-blocks) 

#+(or)
(defun print-unwind-blocks ()
  (do ((b (di::descriptor-sap lisp::*current-unwind-protect-block*)
          (sys:sap-ref-sap b (* vm:unwind-block-current-uwp-slot
                                vm:word-bytes))))
      (nil)
    (let ((int (sys:sap-int b)))
      (when (zerop int) (return))
      (flet ((ref (offset) (sys:sap-ref-32 b (* offset vm:word-bytes))))
        (let ((cfp (ref vm:unwind-block-current-cont-slot)))
          (format t "~X:  cfp = ~X~%" int cfp))))))

;; (print-unwind-blocks)


;;;; Inspecting

(defconstant +lowtag-symbols+ 
  '(vm:even-fixnum-type
    vm:function-pointer-type
    vm:other-immediate-0-type
    vm:list-pointer-type
    vm:odd-fixnum-type
    vm:instance-pointer-type
    vm:other-immediate-1-type
    vm:other-pointer-type))

(defconstant +header-type-symbols+
  ;; Is there a convinient place for all those constants?
  (flet ((tail-comp (string tail)
	   (and (>= (length string) (length tail))
		(string= string tail :start1 (- (length string) 
						(length tail))))))
    (remove-if-not
     (lambda (x) (and (tail-comp (symbol-name x) "-TYPE")
		      (not (member x +lowtag-symbols+))
		      (boundp x)
		      (typep (symbol-value x) 'fixnum)))
     (append (apropos-list "-TYPE" "VM" t)
	     (apropos-list "-TYPE" "BIGNUM" t)))))

(defimplementation describe-primitive-type (object)
  (with-output-to-string (*standard-output*)
    (let* ((lowtag (kernel:get-lowtag object))
	   (lowtag-symbol (find lowtag +lowtag-symbols+ :key #'symbol-value)))
      (format t "lowtag: ~A" lowtag-symbol)
      (when (member lowtag (list vm:other-pointer-type
                                 vm:function-pointer-type
                                 vm:other-immediate-0-type
                                 vm:other-immediate-1-type
                                 ))
        (let* ((type (kernel:get-type object))
               (type-symbol (find type +header-type-symbols+
                                  :key #'symbol-value)))
          (format t ", type: ~A" type-symbol))))))

(defimplementation inspected-parts (o)
  (cond ((di::indirect-value-cell-p o)
	 (inspected-parts-of-value-cell o))
	(t
	 (destructuring-bind (text labeledp . parts)
	     (inspect::describe-parts o)
	   (let ((parts (if labeledp 
			    (loop for (label . value) in parts
				  collect (cons (string label) value))
			    (loop for value in parts
				  for i from 0
				  collect (cons (format nil "~D" i) value)))))
	     (values text parts))))))

(defun inspected-parts-of-value-cell (o)
  (values (format nil "~A~% is a value cell." o)
	  (list (cons "Value" (c:value-cell-ref o)))))

(defmethod inspected-parts ((o function))
  (let ((header (kernel:get-type o)))
    (cond ((= header vm:function-header-type)
	   (values 
	    (format nil "~A~% is a function." o)
	    (list (cons "Self" (kernel:%function-self o))
		  (cons "Next" (kernel:%function-next o))
		  (cons "Name" (kernel:%function-name o))
		  (cons "Arglist" (kernel:%function-arglist o))
		  (cons "Type" (kernel:%function-type o))
		  (cons "Code Object" (kernel:function-code-header o)))))
	  ((= header vm:closure-header-type)
	   (values (format nil "~A~% is a closure." o)
		   (list* 
		    (cons "Function" (kernel:%closure-function o))
		    (loop for i from 0 below (- (kernel:get-closure-length o) 
						(1- vm:closure-info-offset))
			  collect (cons (format nil "~D" i)
					(kernel:%closure-index-ref o i))))))
	  (t (call-next-method o)))))

(defmethod inspected-parts ((o kernel:code-component))
  (values (format nil "~A~% is a code data-block." o)
	  `(("First entry point" . ,(kernel:%code-entry-points o))
	    ,@(loop for i from vm:code-constants-offset 
		    below (kernel:get-header-data o)
		    collect (cons (format nil "Constant#~D" i)
				  (kernel:code-header-ref o i)))
	    ("Debug info" . ,(kernel:%code-debug-info o))
	    ("Instructions"  . ,(kernel:code-instructions o)))))

(defmethod inspected-parts ((o kernel:fdefn))
  (values (format nil "~A~% is a fdefn object." o)
	  `(("Name" . ,(kernel:fdefn-name o))
	    ("Function" . ,(kernel:fdefn-function o)))))


;;;; Profiling
(defimplementation profile (fname)
  (eval `(profile:profile ,fname)))

(defimplementation unprofile (fname)
  (eval `(profile:unprofile ,fname)))

(defimplementation unprofile-all ()
  (eval '(profile:unprofile))
  "All functions unprofiled.")

(defimplementation profile-report ()
  (eval '(profile:report-time)))

(defimplementation profile-reset ()
  (eval '(profile:reset-time))
  "Reset profiling counters.")

(defimplementation profiled-functions ()
  profile:*timed-functions*)

(defimplementation profile-package (package callers methods)
  (profile:profile-all :package package
                       :callers-p callers
                       :methods methods))


;;;; Multiprocessing

#+MP
(progn
  (defimplementation startup-multiprocessing ()
    ;; Threads magic: this never returns! But top-level becomes
    ;; available again.
    (mp::startup-idle-and-top-level-loops))

  (defimplementation spawn (fn &key (name "Anonymous"))
    (mp:make-process fn :name name))

  (defimplementation thread-name (thread)
    (mp:process-name thread))

  (defimplementation thread-status (thread)
    (mp:process-whostate thread))

  (defimplementation current-thread ()
    mp:*current-process*)

  (defimplementation all-threads ()
    (copy-list mp:*all-processes*))

  (defimplementation interrupt-thread (thread fn)
    (mp:process-interrupt thread fn))

  (defimplementation kill-thread (thread)
    (mp:destroy-process thread))

  (defvar *mailbox-lock* (mp:make-lock "mailbox lock"))
  
  (defstruct (mailbox (:conc-name mailbox.)) 
    (mutex (mp:make-lock "process mailbox"))
    (queue '() :type list))

  (defun mailbox (thread)
    "Return THREAD's mailbox."
    (mp:with-lock-held (*mailbox-lock*)
      (or (getf (mp:process-property-list thread) 'mailbox)
          (setf (getf (mp:process-property-list thread) 'mailbox)
                (make-mailbox)))))
  
  (defimplementation send (thread message)
    (let* ((mbox (mailbox thread))
           (mutex (mailbox.mutex mbox)))
      (mp:with-lock-held (mutex)
        (setf (mailbox.queue mbox)
              (nconc (mailbox.queue mbox) (list message))))))
  
  (defimplementation receive ()
    (let* ((mbox (mailbox mp:*current-process*))
           (mutex (mailbox.mutex mbox)))
      (mp:process-wait "receive" #'mailbox.queue mbox)
      (mp:with-lock-held (mutex)
        (pop (mailbox.queue mbox)))))

  )
