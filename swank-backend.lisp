;;;; -*- Mode: lisp; indent-tabs-mode: nil; outline-regexp: ";;;;;*" -*-
;;;
;;; slime-impl.lisp --- Slime interface reference implementation.
;;;
;;; Copyright (C) 2003, James Bielman  <jamesjb@jamesjb.com>
;;; Released into the public domain.
;;;
;;;   $Id: swank-backend.lisp,v 1.2 2003/11/23 12:13:19 lgorrie Exp $
;;;

;; This is a skeletal implementation of the Slime internals interface.
;;
;; The idea is to create a de-facto standard interface that can be
;; used by editor <-> CL integration software, such as Slime.  Vendors
;; are encouraged to comment on this interface.

(defpackage :swank
  (:use :common-lisp)
  (:export #:start-server #:create-swank-server
           #:*sldb-pprint-frames*))


(in-package :swank)


;;;; Conditions and Error Handling

;; XXX need to specify restart behavior for errors/warnings?

(define-condition not-implemented-error (error)
  ())

(deftype severity () '(member :error :warning :style-warning :note))

;; Base condition type for compiler errors, warnings and notes.
(define-condition compiler-condition (condition)
  ((original-condition
    ;; The original condition thrown by the compiler if appropriate.
    ;; May be NIL if a compiler does not report using conditions.
    :initarg :original-condition
    :accessor original-condition)

   (severity
    :type severity
    :initarg :severity
    :accessor severity)

   (message
    :documentation "The error or warning message, must be a non-NIL string."
    :initarg :message
    :accessor message)

   (location
    :initarg :location
    :accessor location)))


;;;; Compilation

(defgeneric compile-string-for-emacs (string &key buffer position)
  (:documentation
   "Compile source from STRING.  During compilation, compiler
conditions must be trapped and resignalled as COMPILER-CONDITIONs.

If supplied, BUFFER and POSITION specify the source location in Emacs.

Additionally, if POSITION is supplied, it must be added to source
positions reported in compiler conditions."))

(defgeneric compile-file-for-emacs (filename load-p)
  (:documentation
   "Compile FILENAME signalling COMPILE-CONDITIONs.
If LOAD-P is true, load the file after compilation."))


;;;; Documentation

(defgeneric arglist-string (function-name)
  (:documentation
   "Return the argument for FUNCTION-NAME as a string.
The result should begin and end with parenthesis."))

(defgeneric macroexpand-all (form)
  (:documentation
   "Recursively expand all macros in FORM.
Return the resulting form."))

(defgeneric describe-symbol-for-emacs (symbol)
  (:documentation
   "Return a property list describing SYMBOL.

The property list has an entry for each interesting aspect of the
symbol. The recognised keys are:

  :VARIABLE :FUNCTION :SETF :TYPE :CLASS :MACRO :COMPILER-MACRO
  :ALIEN-TYPE :ALIEN-STRUCT :ALIEN-UNION :ALIEN-ENUM

The value of each property is the corresponding documentation string,
or :NOT-DOCUMENTED. It is legal to include keys not listed here.

Properties should be included if and only if they are applicable to
the symbol. For example, only (and all) fbound symbols should include
the :FUNCTION property.

Example:
\(describe-symbol-for-emacs 'vector)
  => (:CLASS :NOT-DOCUMENTED
      :TYPE :NOT-DOCUMENTED
      :FUNCTION \"Constructs a simple-vector from the given objects.\")"))


;;;; Debugging

(defgeneric call-with-debugging-environment (debugger-loop-fn)
  (:documentation
   "Call DEBUGGER-LOOP-FN in a suitable debugging environment.

This function is called recursively at each debug level to invoke the
debugger loop. The purpose is to setup any necessary environment for
other debugger callbacks that will be called within the debugger loop.

For example, this is a reasonable place to compute a backtrace, switch
to safe reader/printer settings, and so on."))

(define-condition sldb-condition (condition)
  ((original-condition
    :initarg :original-condition
    :accessor :original-condition))
  (:documentation
   "Wrapper for conditions that should not be debugged.

When a condition arises from the internals of the debugger, it is not
desirable to debug it -- we'd risk entering an endless loop trying to
debug the debugger! Instead, such conditions can be reported to the
user without (re)entering the debugger by wrapping them as
`sldb-condition's."))

(defgeneric debugger-info-for-emacs (start end)
  (:documentation
   "Return debugger state, with stack frames from START to END.
The result is a list:
  (condition-description ({restart}*) ({stack-frame}*)
where
  restart     ::= (name description)
  stack-frame ::= (number description)

condition-description---a string describing the condition that
triggered the debugger.

restart---a pair of strings: restart name, and description.

stack-frame---a number from zero (the top), and a printed
representation of the frame's call.

Below is an example return value. In this case the condition was a
division by zero (multi-line description), and only one frame is being
fetched (start=0, end=1).

 (\"Arithmetic error DIVISION-BY-ZERO signalled.
Operation was KERNEL::DIVISION, operands (1 0).
   [Condition of type DIVISION-BY-ZERO]\"
  ((\"ABORT\" \"Return to Slime toplevel.\")
   (\"ABORT\" \"Return to Top-Level.\"))
  ((0 \"0: (KERNEL::INTEGER-/-INTEGER 1 0)\")))"))


