;; -*- mode: emacs-lisp; mode: outline-minor; outline-regexp: ";;;;*"; tab-width: 8; indent-tabs-mode: t -*-
;; slime.el -- Superior Lisp Interaction Mode, Extended
;;; License
;;     Copyright (C) 2003  Eric Marsden, Luke Gorrie, Helmut Eller
;;
;;     This program is free software; you can redistribute it and/or
;;     modify it under the terms of the GNU General Public License as
;;     published by the Free Software Foundation; either version 2 of
;;     the License, or (at your option) any later version.
;;     
;;     This program is distributed in the hope that it will be useful,
;;     but WITHOUT ANY WARRANTY; without even the implied warranty of
;;     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;;     GNU General Public License for more details.
;;     
;;     You should have received a copy of the GNU General Public
;;     License along with this program; if not, write to the Free
;;     Software Foundation, Inc., 59 Temple Place - Suite 330, Boston,
;;     MA 02111-1307, USA.


;;; Commentary

;; This minor mode extends Lisp-Mode with CMUCL-specific features.
;; The features can be summarised thusly:
;;
;;   Separate control channel for communication with CMUCL, similar to
;;   Hemlock. This is used to implement other features, rather than
;;   talking to the Lisp listener "in-band".
;;
;;   Compiler notes and warnings are visually annotated in the source
;;   buffer. Commands are provided for inspecting and navigating
;;   between notes.
;;
;;   Comforts familiar from ILISP and Emacs Lisp: completion of
;;   symbols, automatic display of arglists in function calls,
;;   TAGS-like definition finding, Lisp evaluation, online
;;   documentation, etc.
;;
;;   Common Lisp debugger interface.
;;
;; The goal is to make Emacs support CMU Common Lisp as well as it
;; supports Emacs Lisp. The strategy is to take maximum advantage of
;; all CMUCL features and hooks, portability be damned to hades.
;;
;; Compatibility with other Common Lisps is not an immediate
;; goal. SBCL support would be highly desirable in the future.
;;
;; SLIME is compatible with GNU Emacs 20 and 21, and XEmacs 21.
;; Development copies may have temporary have portability bugs.


;;; Dependencies, major global variables and constants

(require 'inf-lisp)
(require 'cl)
(require 'hyperspec)
(when (featurep 'xemacs)
  (require 'overlay))
(unless (fboundp 'define-minor-mode)
  (require 'easy-mmode)
  (defalias 'define-minor-mode 'easy-mmode-define-minor-mode))

(defconst slime-swank-port 4005
  "TCP port number for the Lisp Swank server.")

(defvar slime-path
  (let ((path (locate-library "slime")))
    (and path (file-name-directory path)))
  "Directory containing the Slime package.
This is used to load the supporting Common Lisp library, Swank.
The default value is automatically computed from the location of the
Emacs Lisp package.")

(defvar slime-swank-connection-retries 10
  "Number of times to try connecting to the Swank server before aborting.")

(defvar slime-lisp-binary-extension ".x86f"
  "Filename extension for Lisp object files.")

(defvar slime-backend "swank"
  "The name of the Lisp file implementing the Swank server.")

(make-variable-buffer-local
 (defvar slime-buffer-package nil
   "The Lisp package associated with the current buffer.
Don't access this value directly in a program. Call the function with
the same name instead."))

(defvar slime-lisp-features nil
  "The symbol names in the *FEATURES* list of the Superior lisp.
This is needed to READ Common Lisp expressions adequately.")

(defvar slime-pid nil
  "The process id of the Lisp process.")


;;; Customize group

(defgroup slime nil
  "Interfaction with the Superior Lisp Environment."
  :prefix "slime-"
  :group 'applications)

(defface slime-error-face
  '((((class color) (background light))
     (:underline "red"))
    (((class color) (background dark))
     (:underline "red"))
    (t (:underline t)))
  "Face for errors from the compiler."
  :group 'slime)

(defface slime-warning-face
  '((((class color) (background light))
     (:underline "orange"))
    (((class color) (background dark))
     (:underline "coral"))
    (t (:underline t)))
  "Face for warnings from the compiler."
  :group 'slime)

(defface slime-note-face
  '((((class color) (background light))
     (:underline "brown"))
    (((class color) (background dark))
     (:underline "gold"))
    (t (:underline t)))
  "Face for notes from the compiler."
  :group 'slime)

(defface slime-highlight-face
  '((t
     (:inherit highlight)
     (:underline nil)))
  "Face for compiler notes while selected."
  :group 'slime)


;;; Minor mode 

(define-minor-mode slime-mode
  "\\<slime-mode-map>
SLIME: The Superior Lisp Interaction Mode, Extended (minor-mode).

Commands to compile the current buffer's source file and visually
highlight any resulting compiler notes and warnings:
\\[slime-compile-and-load-file]	- Compile and load the current buffer's file.
\\[slime-compile-file]	- Compile (but not load) the current buffer's file.
\\[slime-compile-defun]	- Compile the top-level form at point.

Commands for visiting compiler notes:
\\[slime-next-note]	- Goto the next form with a compiler note.
\\[slime-previous-note]	- Goto the previous form with a compiler note.
\\[slime-remove-notes]	- Remove compiler-note annotations in buffer.

Finding definitions:
\\[slime-edit-fdefinition]	- Edit the definition of the function called at point.
\\[slime-pop-find-definition-stack]	- Pop the definition stack to go back from a definition.

Programming aids:
\\[slime-complete-symbol]	- Complete the Lisp symbol at point. (Also M-TAB.)
\\[slime-macroexpand-1]	- Macroexpand once.
\\[slime-macroexpand-all]	- Macroexpand all.

Cross-referencing (see CMUCL manual):
\\[slime-who-calls]	- WHO-CALLS a function.
\\[slime-who-references]	- WHO-REFERENCES a global variable.
\\[slime-who-sets]	- WHO-SETS a global variable.
\\[slime-who-binds]	- WHO-BINDS a global variable.
\\[slime-who-macroexpands]	- WHO-MACROEXPANDS a macro.
C-M-.		- Goto the next reference source location. (Also C-c C-SPC)

Documentation commands:
\\[slime-describe-symbol]	- Describe symbol.
\\[slime-apropos]	- Apropos search.
\\[slime-disassemble-symbol]	- Disassemble a function.

Evaluation commands:
\\[slime-eval-defun]	- Evaluate top-level from containing point.
\\[slime-eval-last-expression]	- Evaluate sexp before point.
\\[slime-pprint-eval-last-expression]	- Evaluate sexp before point, pretty-print result.

\\{slime-mode-map}"
  nil
  nil
  '((" "        . slime-space)
    ("\M-p"     . slime-previous-note)
    ("\M-n"     . slime-next-note)
    ("\C-c\M-c" . slime-remove-notes)
    ("\C-c\C-k" . slime-compile-and-load-file)
    ("\C-c\M-k" . slime-compile-file)
    ("\C-c\C-c" . slime-compile-defun)
    ("\C-c\C-l" . slime-load-file)
    ;; Multiple bindings for completion, since M-TAB is often taken by
    ;; the window manager.
    ("\M-\C-i"  . slime-complete-symbol)
    ("\C-c\C-i" . slime-complete-symbol)
    ("\M-."     . slime-edit-fdefinition)
    ("\M-,"     . slime-pop-find-definition-stack)
    ("\C-x\C-e" . slime-eval-last-expression)
    ("\C-c\C-p" . slime-pprint-eval-last-expression)
    ("\M-\C-x"  . slime-eval-defun)
    ("\C-c:"    . slime-interactive-eval)
    ("\C-c\C-z" . slime-switch-to-output-buffer)
    ("\C-c\C-d" . slime-describe-symbol)
    ("\C-c\M-d" . slime-disassemble-symbol)
    ("\C-c\C-t" . slime-toggle-trace-fdefinition)
    ("\C-c\C-a" . slime-apropos)
    ("\C-c\M-a" . slime-apropos-all)
    ([(control c) (control m)] . slime-macroexpand-1)
    ([(control c) (meta m)]    . slime-macroexpand-all)
    ("\C-c\C-g" . slime-interrupt)
    ("\C-c\M-g" . slime-quit)
    ("\C-c\M-0" . slime-restore-window-configuration)
    ("\C-c\C-h" . hyperspec-lookup)
    ("\C-c\C-wc" . slime-who-calls)
    ("\C-c\C-wr" . slime-who-references)
    ("\C-c\C-wb" . slime-who-binds)
    ("\C-c\C-ws" . slime-who-sets)
    ("\C-c\C-wm" . slime-who-macroexpands)
    ;; Not sure which binding is best yet, so both for now.
    ([(control meta ?\.)] . slime-next-location)
    ("\C-c\C- "  . slime-next-location)
    ("\C-c~"     . slime-sync-package-and-default-directory)
    ))

;; Setup the mode-line to say when we're in slime-mode, and which CL
;; package we think the current buffer belongs to.
(add-to-list 'minor-mode-alist
             '(slime-mode
               (" Slime"
		((slime-buffer-package (":" slime-buffer-package) "")
		 slime-state-name))))


;;; Setup initial `slime-mode' hooks

(make-variable-buffer-local
 (defvar slime-pre-command-actions nil
   "List of functions to execute before the next Emacs command.
This list of flushed between commands."))

(defun slime-pre-command-hook ()
  "Execute all functions in `slime-pre-command-actions', then NIL it."
  (dolist (undo-fn slime-pre-command-actions)
    (ignore-errors (funcall undo-fn)))
  (setq slime-pre-command-actions nil))

(defun slime-post-command-hook ()
  (slime-process-available-input))

(defun slime-setup-command-hooks ()
  "Setup a buffer-local `pre-command-hook' to call `slime-pre-command-hook'."
  (make-local-variable 'pre-command-hook)
  (make-local-variable 'post-command-hook)
  (add-hook 'pre-command-hook 'slime-pre-command-hook)
  (add-hook 'post-command-hook 'slime-post-command-hook))

(add-hook 'slime-mode-hook 'slime-setup-command-hooks)
(add-hook 'slime-mode-hook 'slime-buffer-package)


;;; Common utility functions and macros

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
                       (destructuring-bind ((op &rest rands) &rest body) clause
                         `(,op (destructuring-bind ,rands ,operands
                                 . ,body)))))
		   patterns)
	 (t (error "destructure-case failed: %S" ,tmp))))))

(put 'destructure-case 'lisp-indent-function 1)

(defun slime-buffer-package (&optional dont-cache)
  "Return the Common Lisp package associated with the current buffer.
This is heuristically determined by a text search of the buffer.
The result is cached and returned on subsequent calls unless
DONT-CACHE is non-nil."
  (or (and (not dont-cache) slime-buffer-package)
      (and (setq slime-buffer-package (slime-find-buffer-package))
           (progn (force-mode-line-update) slime-buffer-package))
      "CL-USER"))

(defun slime-find-buffer-package ()
  "Figure out which Lisp package the current buffer is associated with."
  (save-excursion
    (when (let ((case-fold-search t))
	    (re-search-backward "^(\\(cl:\\|common-lisp:\\)?in-package\\>" 
				nil t))
      (goto-char (match-end 0))
      (skip-chars-forward " \n\t\f\r#:")
      (let ((pkg (read (current-buffer))))
	(cond ((stringp pkg)
	       pkg)
	      ((symbolp pkg)
	       (symbol-name pkg)))))))

(defun slime-display-buffer-other-window (buffer &optional not-this-window)
  "Display BUFFER in some other window.
Like `display-buffer', but ignores `same-window-buffer-names'."
  (let ((same-window-buffer-names nil))
    (display-buffer buffer not-this-window)))

(defun slime-display-message-or-view (msg bufname &optional select)
  "Like `display-buffer-or-message', but with `view-buffer-other-window'.
That is, if a buffer pops up it will be in view mode, and pressing q
will get rid of it.

Only uses the echo area for single-line messages - or more accurately,
messages without embedded newlines. They may still need to wrap or
truncate to fit on the screen."
  (if (string-match "\n.*[^\\s-]" msg)
      ;; Contains a newline with actual text after it, so display as a
      ;; buffer
      (with-current-buffer (get-buffer-create bufname)
	(setq buffer-read-only t)
	(let ((inhibit-read-only t))
	  (erase-buffer)
	  (insert msg)
	  (goto-char (point-min))
	  (let ((win (display-buffer (current-buffer))))
	    (slime-display-buffer-region (current-buffer) 
					 (point-min) (point-max))
	    (when select (select-window win)))))
    (when (get-buffer-window bufname) (delete-windows-on bufname))
    ;; Print only the part before the newline (if there is
    ;; one). Newlines in messages are displayed as "^J" in emacs20,
    ;; which is ugly
    (string-match "^[^\r\n]*" msg)
    (message (match-string 0 msg))))

;; defun slime-message
(if (or (featurep 'xemacs)
	(= emacs-major-version 20))
    ;; XEmacs truncates multi-line messages in the echo area.
    (defun slime-message (fmt &rest args)
      (slime-display-message-or-view (apply #'format fmt args) "*CMUCL Note*"))
  (defun slime-message (fmt &rest args)
    (apply 'message fmt args)))

(defun slime-defun-at-point ()
  "Return the text of the defun at point."
  (save-excursion
    (end-of-defun)
    (let ((end (point)))
      (beginning-of-defun)
      (buffer-substring-no-properties (point) end))))

(defun slime-symbol-at-point ()
  "Return the symbol at point, otherwise nil."
  (let ((string (thing-at-point 'symbol)))
    (if string (intern (substring-no-properties string)) nil)))

(defun slime-symbol-name-at-point ()
  "Return the name of the symbol at point, otherwise nil."
  (let ((sym (slime-symbol-at-point)))
    (and sym (symbol-name sym))))

(defun slime-sexp-at-point ()
  "Return the sexp at point, otherwise nil."
  (let ((string (thing-at-point 'sexp)))
    (if string (substring-no-properties string) nil)))

(defun slime-function-called-at-point/line ()
  "Return the name of the function being called at point, provided the
function call starts on the same line at the point itself."
  (and (ignore-errors
         (slime-same-line-p (save-excursion (backward-up-list 1) (point))
                            (point)))
       (slime-function-called-at-point)))

(defun slime-read-symbol-name (prompt)
  "Either read a symbol name or choose the one at point.
The user is prompted if a prefix argument is in effect or there is no
symbol at point."
  (or (and (not current-prefix-arg) (slime-symbol-name-at-point))
      (slime-completing-read-symbol-name prompt)))

(defun slime-read-symbol (prompt)
  "Either read a symbol or choose the one at point.
The user is prompted if a prefix argument is in effect or there is no
symbol at point."
  (intern (slime-read-symbol-name prompt)))

(defvar slime-saved-window-configuration nil
  "Window configuration before the last changes SLIME made.")

(defun slime-save-window-configuration ()
  "Save the current window configuration.
This should be called before modifying the user's window configuration.

`slime-restore-window-configuration' restores the saved configuration."
  (setq slime-saved-window-configuration (current-window-configuration)))

(defun slime-restore-window-configuration ()
  "Restore the most recently saved window configuration."
  (interactive)
  (when slime-saved-window-configuration
    (set-window-configuration slime-saved-window-configuration)
    (setq slime-saved-window-configuration nil)))

(defmacro slime-with-output-to-temp-buffer (&rest args)
  "Like `with-output-to-temp-buffer', but saves the window configuration."
  `(progn (slime-save-window-configuration)
          (with-output-to-temp-buffer ,@args)))

(put 'slime-with-output-to-temp-buffer 'lisp-indent-function 1)

(defun slime-function-called-at-point ()
  "Return a function around point or else called by the list containing point.
If that doesn't give a function, return nil."
  (ignore-errors
    (save-excursion
      (save-restriction
        (narrow-to-region (max (point-min) (- (point) 1000))
                          (point-max))
        ;; Move up to surrounding paren, then after the open.
        (backward-up-list 1)
        (when (or (ignore-errors
                    ;; "((foo" is probably not a function call
                    (save-excursion (backward-up-list 1)
                                    (looking-at "(\\s *(")))
                  ;; nor is "( foo"
                  (looking-at "([ \t]"))
          (error "Probably not a Lisp function call"))
        (forward-char 1)
        (let ((obj (read (current-buffer))))
          (and (symbolp obj) obj))))))

(defun slime-read-package-name (prompt &optional initial-value)
  (let ((completion-ignore-case t))
    (completing-read prompt (mapcar (lambda (x) (cons x x))
				    (slime-eval 
				     `(swank:list-all-package-names)))
		     nil nil initial-value)))


;;; CMUCL Setup: compiling and connecting to Swank

;; SLIME -- command
;;
(defun slime ()
  "Start an inferior^_superior Lisp and connect to its Swank server."
  (interactive)
  (call-interactively 'inferior-lisp)
  (slime-start-swank-server)
  (slime-connect "localhost" slime-swank-port))

;; SLIME-CONNECT -- command
;;
(defun slime-connect (host port &optional retries)
  "Connect to a running Swank server."
  (interactive (list (read-string "Host: " "localhost")
		     (let ((port
			    (read-string "Port: " 
					 (number-to-string slime-swank-port))))
		       (or (ignore-errors (string-to-number port)) port))))
  (setq retries (or retries slime-swank-connection-retries))
  (if (zerop retries)
      (error "Unable to contact Swank server.")
    (if (slime-net-connect host port)
        (progn (slime-init-dispatcher)
               (slime-fetch-features-list)
               (message "Connected to Swank on %s:%S. %s"
                        host port (slime-random-words-of-encouragement)))
      (message "Connecting to Swank (%S attempts remaining)." 
               retries)
      (sit-for 1)
      (slime-connect host port (1- retries)))))

(defun slime-start-swank-server ()
  "Start a Swank server on the inferior lisp."
  (slime-maybe-compile-swank)
  (comint-proc-query (inferior-lisp-proc)
                     (format "(load %S)\n"
                             (concat slime-path slime-backend)))
  (comint-proc-query (inferior-lisp-proc)
                     "(swank:start-server)\n"))

(defun slime-maybe-compile-swank ()
  (let ((source (concat slime-path slime-backend ".lisp"))
        (binary (concat slime-path slime-backend slime-lisp-binary-extension)))
    (flet ((compile-swank () (comint-proc-query 
			      (inferior-lisp-proc)
			      (format "(compile-file %S)\n" source))))
      (when (or (and (not (file-exists-p binary))
                     (y-or-n-p "\
The CMUCL support library (Swank) is not compiled. Compile now? "))
                (and (file-newer-than-file-p source binary)
                     (y-or-n-p "\
Your Swank binary is older than the source. Recompile now? ")))
        (compile-swank)))))

(defun slime-fetch-features-list ()
  "Fetch and remember the *FEATURES* of the inferior lisp."
  (interactive)
  (setq slime-lisp-features (slime-eval '(swank:features))))

(defvar slime-words-of-encouragement
  '("Let the hacking commence!"
    "Hacks and glory await!"
    "Hack and be merry!"
    "Your hacking starts... NOW!"
    "May the source be with you!")
  "Scientifically-proven optimal words of hackerish encouragement.")

(defun slime-random-words-of-encouragement ()
  "Return a string of hackerish encouragement."
  (nth (random (length slime-words-of-encouragement))
       slime-words-of-encouragement))


;;; Networking

(defvar slime-net-process nil
  "The process (socket) connected to CMUCL.")

(defun slime-net-connect (host port)
  "Establish a connection with CMUCL."
  (condition-case nil
      (progn
        (setq slime-net-process (open-network-stream "CMUCL" nil host port))
        (let ((buffer (slime-make-net-buffer "*cmucl-connection*")))
          (set-process-buffer slime-net-process buffer)
          (set-process-filter slime-net-process 'slime-net-filter)
          (set-process-sentinel slime-net-process 'slime-net-sentinel)
	  (set-process-coding-system slime-net-process 
				     'no-conversion 'no-conversion))
	slime-net-process)
    (file-error () nil)))
    
(defun slime-make-net-buffer (name)
  "Make a buffer suitable for a network process."
  (let ((buffer (generate-new-buffer name)))
    (with-current-buffer buffer
      (when (fboundp 'set-buffer-multibyte)
	(set-buffer-multibyte nil))
      (buffer-disable-undo))
    buffer))

(defun slime-net-output-funcall (fun &rest args)
  "Send a request for FUN to be applied to ARGS."
  (slime-net-send `(,fun ,@args)))

(defun slime-net-send (sexp)
  "Send a SEXP to CMUCL.
This is the lowest level of communication. The sexp will be READ and
EVAL'd by Lisp."
  (let* ((msg (format "%S\n" sexp))
	 (string (concat (slime-net-enc3 (length msg)) msg)))
    (process-send-string slime-net-process (string-make-unibyte string))))

(defun slime-net-sentinel (process message)
  (message "wire sentinel: %s" message)
  (ignore-errors (kill-buffer (process-buffer slime-net-process))))

(defun slime-net-filter (process string)
  "Accept output from the socket and input all complete messages."
  (with-current-buffer (process-buffer slime-net-process)
    (save-excursion
      (goto-char (point-max))
      (insert string))
    (slime-process-available-input)))

(defun slime-process-available-input ()
  "Process all complete messages that have arrived from Lisp."
  (with-current-buffer (process-buffer slime-net-process)
    (while (slime-net-have-input-p)
      (save-current-buffer
	(slime-dispatch-event (slime-net-read))))))

(defun slime-net-have-input-p ()
  "Return true if a complete message is available."
  (goto-char (point-min))
  (and (>= (buffer-size) 3)
       (>= (- (buffer-size) 3) (slime-net-read3))))

(defun slime-net-read ()
  "Read a message from the network buffer."
  (goto-char (point-min))
  (let* ((length (slime-net-read3))
         (start (+ 3 (point)))
         (end (+ start length)))
    (let ((string (buffer-substring start end)))
      (prog1 (read string)
        (delete-region (point-min) end)))))

(defun slime-net-read3 ()
  "Read a 24-bit big-endian integer from buffer."
  (save-excursion
    (logior (prog1 (ash (char-after) 16) (forward-char 1))
            (prog1 (ash (char-after) 8)  (forward-char 1))
            (char-after))))

(defun slime-net-enc3 (n)
  "Encode an integer into a 24-bit big-endian string."
  (string (logand (ash n -16) 255)
          (logand (ash n -8) 255)
          (logand n 255)))


;;; Evaluation mechanics

;; The SLIME protocol is implemented with a small state machine. That
;; means the program uses "state" data structures to remember where
;; it's up to -- whether it's idle, or waiting for an evaluation
;; request from Lisp, whether it's debugging, and so on.
;;
;; The state machine has a stack for putting states that are only
;; partially complete, i.e. it is a "push-down automaton" like they
;; use in parsers. This design works well because the SLIME protocol
;; can be described as a context-free grammar, loosely:
;;
;;   CONVERSATION ::= <EXCHANGE>*
;;   EXCHANGE     ::= request reply
;;                or  request <DEBUG> reply
;;   DEBUG        ::= enter-debugger <CONVERSATION> debug-return
;;
;; Or, in plain english, in the simplest case Emacs asks Lisp to
;; evaluate something and Lisp sends the result. But it's also
;; possible that Lisp signals a condition and enters the debugger
;; while computing the reply. In that case both sides enter a
;; debugging state, and can have arbitrary nested conversations until
;; a restart makes the debugger return.
;;
;; The state machine's stack represents the interesting parts of the
;; remote Lisp stack. Each Emacs state on the stack corresponds to a
;; particular Lisp stack frame. When that frame returns it sends a
;; message to Emacs delivering a result, which Emacs delivers to the
;; state and pops its stack. So the stacks are kept synchronized.
;;
;; The format of events is lists whose CAR is a symbol identifying the
;; type of event and whose CDR contains any extra arguments. We treat
;; events created by Emacs the same as events sent by Lisp, but by
;; convention use "emacs-" as a prefix on the names of events
;; originating locally in Emacs.
;;
;; There are also certain "out of band" messages which are handled by
;; a special function instead of reaching the state machine.


;;;;; Basic state machine aframework

(defvar slime-state-stack '()
  "Stack of machine states. The state at the top is the current state.")

(defvar slime-state-name "[??]"
  "The name of the current state, for display in the modeline.")

(defun slime-push-state (state)
  "Push into a new state, saving the current state on the stack.
This may be called by a state machine to cause a state change."
  (push state slime-state-stack)
  (slime-activate-state))

(defun slime-pop-state ()
  "Pop back to the previous state from the stack.
This may be called by a state machine to finish its current state."
  (pop slime-state-stack)
  (slime-activate-state))

(defun slime-current-state ()
  "The current state."
  (car slime-state-stack))

(defun slime-init-dispatcher ()
  "Initialize the stack machine."
  (setq slime-state-stack (list (slime-idle-state)))
  (setq slime-pid (slime-eval `(swank:getpid))))

(defun slime-activate-state ()
  "Activate the current state.
This delivers an (activate) event to the state function, and updates
the state name for the modeline."
  (let ((state (slime-current-state)))
    (setq slime-state-name
          (case (slime-state-name state)
            (slime-idle-state "")
            (slime-evaluating-state "[eval...]")
            (slime-debugging-state "[debug]")))
    (force-mode-line-update)
    (slime-dispatch-event '(activate))))

(defun slime-dispatch-event (event)
  "Dispatch an event to the current state.
Certain \"out of band\" events are handled specially instead of going
into the state machine."
  (or (slime-handle-oob event)
      (funcall (slime-state-function (slime-current-state)) event)))

(defun slime-handle-oob (event)
  "Handle out-of-band events.
Return true if the event is recognised and handled."
  (destructure-case event
    ((:read-output output)
     (slime-output-string output)
     t)
    (t nil)))

;; state datastructure
(defun slime-make-state (name function)
  "Make a state object called NAME that handles events with FUNCTION."
  (list 'slime-state name function))

(defun slime-state-name (state)
  "Return the name of STATE."
  (second state))

(defun slime-state-function (state)
  "Return STATE's event-handler function."
  (third state))


;;;;; Upper layer macros for defining states

(defmacro slime-defstate (name variables doc &rest events)
  "Define a state called NAME and comprised of VARIABLES.
DOC is a documentation string.
EVENTS is a set of event-handler patterns for matching events with
their actions. The pattern syntax is the same as `destructure-case'."
  `(defun ,name ,variables
     ,doc
     (slime-make-state ',name ,(slime-make-state-function variables events))))

(defun slime-make-state-function (arglist clauses)
  "Build the function that implements a state.
The state's variables are moved into lexical bindings."
  (let ((event-var (gensym "event-")))
    `(lexical-let ,(mapcar* #'list arglist arglist)
       (lambda (,event-var)
         (destructure-case ,event-var
           ,@clauses
           ;; Every state can handle the event (activate). By default
           ;; it does nothing.
           ,@(if (member* '(activate) clauses :key #'car :test #'equal)
                 '()
               '( ((activate) nil)) )
           (t (error "Can't handle event %S in state %S"
                     ,event-var
                     (slime-state-name (slime-current-state)))))))))


;;;;; The SLIME state machine definition

(defvar sldb-level 0
  "Current debug level, or 0 when not debugging.")

(slime-defstate slime-idle-state ()
  "Idle state. The only event allowed is to make a request."
  ((activate)
   (setq sldb-level 0))
  ((:emacs-evaluate form-string package-name continuation)
   (slime-output-evaluate-request form-string package-name)
   (slime-push-state (slime-evaluating-state continuation))))

(slime-defstate slime-evaluating-state (continuation)
  "Evaluting state.
We have asked Lisp to evaluate a form, and when the result arrives we
will pass it to CONTINUATION."
  ((:ok result)
   (slime-pop-state)
   (funcall continuation result))
  ((:aborted)
   (slime-pop-state)
   (message "Evaluation aborted."))
  ((:debug level condition restarts stack-depth frames)
   (slime-push-state
    (slime-debugging-state level condition restarts stack-depth frames)))
  ((:emacs-interrupt)
   (slime-send-sigint))
  ((:emacs-quit)
   ;; To discard the state would break our synchronization.
   ;; Instead, just cancel the continuation.
   (setq continuation (lambda (value) t))))

(slime-defstate slime-debugging-state (level condition restarts depth frames)
  "Debugging state.
Lisp entered the debugger while handling one of our requests. This
state interacts with it until it is coaxed into returning."
  ((activate)
   (when (/= level (prog1 sldb-level (setq sldb-level level)))
     (sldb-setup condition restarts depth frames)))
  ((:debug-return level)
   (unwind-protect
       (when (= level 1)
         (let ((sldb-buffer (get-buffer "*sldb*")))
           (when sldb-buffer
             (delete-windows-on sldb-buffer)
             (kill-buffer sldb-buffer))))
     (slime-pop-state)))
  ((:emacs-evaluate form-string package-name continuation)
   ;; recursive evaluation request
   (slime-output-evaluate-request form-string package-name)
   (slime-push-state (slime-evaluating-state continuation))))

(put 'slime-defstate 'lisp-indent-function 2)


;;;;; Utilities

(defun slime-output-evaluate-request (form-string package-name)
  "Send a request for LISP to read and evaluate FORM-STRING in PACKAGE-NAME."
  (slime-net-send `(swank:eval-string ,form-string ,package-name)))
                
(defun slime-check-connected ()
  (unless (and slime-net-process
               (eq (process-status slime-net-process) 'open))
    (error "Not connected. Use `M-x slime' to start a Lisp.")))

(defun slime-eval-string-async (string package continuation)
  (when (slime-busy-p)
    (error "Lisp is already busy evaluating a request."))
  (slime-dispatch-event `(:emacs-evaluate ,string ,package ,continuation)))

(defconst +slime-sigint+ 2)

(defun slime-send-sigint ()
  (signal-process slime-pid +slime-sigint+))


;;;;; Emacs Lisp programming interface

(defun slime-eval (sexp &optional package)
  "Evaluate EXPR on the superior Lisp and return the result."
  (slime-check-connected)
  (catch 'slime-result
    (let ((continuation (lambda (value) (throw 'slime-result value))))
      (slime-eval-async sexp package continuation)
      (loop (accept-process-output)))))

(defun slime-eval-async (sexp package cont)
  "Evaluate EXPR on the superior Lisp and call CONT with the result."
  (slime-check-connected)
  (slime-eval-string-async (prin1-to-string sexp) package cont))

(defun slime-sync ()
  "Block until any asynchronous command has completed."
  (while (slime-busy-p)
    (accept-process-output)))

(defun slime-busy-p ()
  "Return true if Lisp is busy processing a request."
  (eq (slime-state-name (slime-current-state)) 'slime-evaluating-state))

(defun slime-ping ()
  "Check that communication works."
  (interactive)
  (message (slime-eval "PONG")))


;;; Stream output

(defvar slime-last-output-start (make-marker)
  "Marker for the start of the output for the evaluation.")

(defun slime-output-buffer ()
  "Return the output buffer, create it if necessary."
  (or (get-buffer "*slime-messages*")
      (with-current-buffer (get-buffer-create "*slime-messages*")
	(slime-mode t)
	(current-buffer))))

(defun slime-output-buffer-position ()
  (with-current-buffer (slime-output-buffer) (point-max)))

(defun slime-insert-transcript-delimiter (string)
  (with-current-buffer (slime-output-buffer)
    (goto-char (point-max))
    (insert "\n;;;; " 
	    (subst-char-in-string ?\n ?\ 
				  (substring string 0 
					     (min 60 (length string))))
	    " ...\n")
    (set-marker slime-last-output-start (point) (current-buffer))))

(defun slime-show-last-output (&optional output-start)
  (let ((output-start (or output-start 
			  (marker-position slime-last-output-start))))
    (when (< output-start (slime-output-buffer-position))
      (slime-display-buffer-region 
       (slime-output-buffer)
       output-start (slime-output-buffer-position)
       1))))

(defun slime-output-string (string)
  (unless (zerop (length string))
    (with-current-buffer (slime-output-buffer)
      (goto-char (point-max))
      (insert string))))

(defun slime-switch-to-output-buffer ()
  "Select the output buffer, preferably in a different window."
  (interactive)
  (slime-save-window-configuration)
  (pop-to-buffer (slime-output-buffer) nil t))


;;; Compilation and the creation of compiler-note annotations

(defun slime-compile-and-load-file ()
  "Compile and load the buffer's file and highlight compiler notes.

Each source location that is the subject of a compiler note is
underlined and annotated with the relevant information. The commands
`slime-next-note' and `slime-previous-note' can be used to navigate
between compiler notes and to display their full details."
  (interactive)
  (slime-compile-file t))

(defun slime-compile-file (&optional load)
  "Compile current buffer's file and highlight resulting compiler notes.

See `slime-compile-and-load-file' for further details."
  (interactive)
  (unless (eq major-mode 'lisp-mode)
    (error "Only valid in lisp-mode"))
  (save-some-buffers)
  (slime-eval-async
   `(swank:swank-compile-file ,(buffer-file-name) ,(if load t nil))
   nil
   (slime-compilation-finished-continuation))
  (message "Compiling %s.." (buffer-file-name))
  ;;(with-current-buffer (slime-output-buffer)
  ;;  (display-buffer (slime-output-buffer) t)
  ;;  (set-window-start (get-buffer-window (current-buffer)) (point-max)))
  )

(defun slime-compile-defun ()
  (interactive)
  (slime-eval-async 
   `(swank:swank-compile-string ,(slime-defun-at-point) 
				,(buffer-name)
				,(save-excursion
                                   (end-of-defun)
				   (beginning-of-defun)
				   (point)))
   (slime-buffer-package)
   (slime-compilation-finished-continuation)))

(defun slime-show-note-counts (notes &optional secs)
  (loop for note in notes 
	for severity = (plist-get note :severity)
	count (eq :error severity) into errors
	count (eq :warning severity) into warnings
	count (eq :note severity) into notes
	finally 
	(message 
	 "Compilation finished: %s errors  %s warnings  %s notes%s"
	 errors warnings notes (if secs (format "  [%s secs]" secs) ""))))

(defun slime-compilation-finished (result buffer)
  (with-current-buffer buffer
    (multiple-value-bind (result secs) result
      (let ((notes (slime-compiler-notes)))
	(slime-show-note-counts notes secs)
	(slime-highlight-notes notes)))))

(defun slime-compilation-finished-continuation ()
  (lexical-let ((buffer (current-buffer)))
    (lambda (result) 
      (slime-compilation-finished result buffer))))

(defun slime-highlight-notes (notes)
  "Highlight compiler notes, warnings, and errors in the buffer."
  (interactive (list (slime-compiler-notes-for-file (buffer-file-name))))
  (save-excursion
    (slime-remove-old-overlays)
    (mapc #'slime-overlay-note notes)))

(defun slime-compiler-notes ()
  "Return all compiler notes, warnings, and errors."
  (slime-eval `(swank:compiler-notes-for-emacs)))

(defun slime-remove-old-overlays ()
  "Delete the existing Slime overlays in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (goto-char (next-overlay-change (point)))
      (dolist (o (overlays-at (point)))
        (when (overlay-get o 'slime)
          (delete-overlay o))))))


;;;; Adding a single compiler note

(defun slime-overlay-note (note)
  "Add a compiler note to the buffer as an overlay.
If an appropriate overlay for a compiler note in the same location
already exists then the new information is merged into it. Otherwise a
new overlay is created."
  (multiple-value-bind (start end) (slime-choose-overlay-region note)
    (goto-char start)
    (let ((severity (plist-get note :severity))
	  (message (plist-get note :message))
	  (appropriate-overlay (slime-note-at-point)))
      (if appropriate-overlay
	  (slime-merge-note-into-overlay appropriate-overlay severity message)
	(slime-create-note-overlay note start end severity message)))))

(defun slime-create-note-overlay (note start end severity message)
  "Create an overlay representing a compiler note.
The overlay has several properties:
  FACE       - to underline the relevant text.
  SEVERITY   - for future reference, :NOTE, :WARNING, or :ERROR.
  MOUSE-FACE - highlight the note when the mouse passes over.
  HELP-ECHO  - a string describing the note, both for future reference
               and for display as a tooltip (due to the special
               property name)."
  (let ((overlay (make-overlay start end)))
    (flet ((putp (name value) (overlay-put overlay name value)))
      (putp 'slime note)
      (putp 'priority (slime-sexp-depth start))
      (putp 'face (slime-severity-face severity))
      (putp 'severity severity)
      (unless (emacs-20-p)
	(putp 'mouse-face 'highlight))
      (putp 'help-echo message)
      overlay)))

(defun slime-sexp-depth (position)
  "Return the number of sexps containing POSITION."
  (let ((n 0))
    (save-excursion
      (goto-char position)
      (ignore-errors
        (while t
          (backward-up-list 1)
          (incf n))))
    n))

(defun slime-merge-note-into-overlay (overlay severity message)
  "Merge another compiler note into an existing overlay.
The help text describes both notes, and the highest of the severities
is kept."
  (flet ((putp (name value) (overlay-put overlay name value))
	 (getp (name)       (overlay-get overlay name)))
    (putp 'severity (slime-most-severe severity (getp 'severity)))
    (putp 'face (slime-severity-face (getp 'severity)))
    (putp 'help-echo (concat (getp 'help-echo) "\n" message))))

(defun slime-choose-overlay-region (note)
  "Choose the start and end points for an overlay over NOTE.
If the location's sexp is a list spanning multiple lines, then the
region around the first element is used."
  (slime-goto-location note)
  (let ((start (point)))
    (slime-forward-sexp)
    (if (slime-same-line-p start (point))
        (values start (point))
      (values (1+ start)
              (progn (goto-char (1+ start))
                     (forward-sexp 1)
                     (point))))))

(defun slime-same-line-p (start end)
  "Return true if buffer positions START and END are on the same line."
  (save-excursion (goto-char start)
                  (not (search-forward "\n" end t))))

(defun slime-severity-face (severity)
  "Return the name of the font-lock face representing SEVERITY."
  (ecase severity
    (:error   'slime-error-face)
    (:warning 'slime-warning-face)
    (:note    'slime-note-face)))

(defun slime-most-severe (sev1 sev2)
  "Return the most servere of two conditions.
Severity is ordered as :NOTE < :WARNING < :ERROR."
  (if (or (eq sev1 :error)              ; Well, not exactly Smullyan..
          (and (eq sev1 :warning)
               (not (eq sev2 :error))))
      sev1
    sev2))


(defun slime-visit-source-path (source-path)
  "Visit a full source path including the top-level form."
  (ignore-errors
    (goto-char (point-min))
    (slime-forward-sexp (car source-path))
    (slime-forward-source-path (cdr source-path))))

(defun slime-forward-source-path (source-path)
  (let ((origin (point)))
    (cond ((null source-path)
	   (or (ignore-errors (slime-forward-sexp) (backward-sexp) t)
	       (goto-char origin)))
	  (t 
	   (or (ignore-errors (down-list 1)
			      (slime-forward-sexp (car source-path))
			      (slime-forward-source-path (cdr source-path)))
	       (goto-char origin))))))

(defun slime-goto-location (note)
  "Move to the location fiven with the note NOTE.

NOTE's :position property contains the byte offset of the toplevel
form we are searching.  NOTE's :source-path property the path to the
subexpression.  NOTE's :function-name property indicates the name of
the function the note occurred in.

A source-path is a list of the form (1 2 3 4), which indicates a
position in a file in terms of sexp positions. The first number
identifies the top-level form that contains the position that we wish
to move to: the first top-level form has number 0. The second number
in the source-path identifies the containing sexp within that
top-level form, etc."
  (interactive)
  (cond ((plist-get note :function-name)
	 (ignore-errors
	   (goto-char (point-min))
	   (re-search-forward (format "^(def\\w+\\s +%s\\s +"
				      (plist-get note :function-name)))
	   (beginning-of-line)))
	((not (plist-get note :source-path))
	 ;; no source-path available. hmm... move the the first sexp
	 (cond ((plist-get note :buffername)
		(goto-char (plist-get note :buffer-offset)))
	       (t
		(goto-char (point-min))))
	 (forward-sexp)
	 (backward-sexp))
	((stringp (plist-get note :filename))
	 ;; Jump to the offset given with the :position property (and avoid
	 ;; most of the reader issues)
	 (goto-char (plist-get note ':position))
	 ;; Drop the the toplevel form from the source-path and go the
	 ;; expression.
	 (slime-forward-source-path (cdr (plist-get note ':source-path))))
	((stringp (plist-get note :buffername))
	 (assert (string= (buffer-name) (plist-get note :buffername)))
	 (goto-char (plist-get note :buffer-offset))
	 (slime-forward-source-path (cdr (plist-get note ':source-path))))
	(t
	 (error "Unsupported location type %s" note))))

(defun slime-forward-sexp (&optional count)
  "Like `forward-sexp', but understands reader-conditionals (#- and #+)."
  (dotimes (i (or count 1))
    (slime-forward-reader-conditional)
    (forward-sexp)))

(defun slime-forward-reader-conditional ()
  "Move past any reader conditionals (#+ or #-) at point."
  (while (progn (slime-beginning-of-next-sexp)
                (or (looking-at "\\s *#\\+")
                    (looking-at "\\s *#-")))
    (goto-char (match-end 0))
    (let* ((plus-conditional-p (eq (char-before) ?+))
           (result (slime-eval-feature-conditional (read (current-buffer)))))
      (unless (if plus-conditional-p result (not result))
        ;; skip this sexp
        (forward-sexp)))))
    
(defun slime-beginning-of-next-sexp ()
  "Move the point to the first character of the next sexp."
  (forward-sexp)
  (backward-sexp))

(defun slime-eval-feature-conditional (e)
  "Interpret a reader conditional expression."
  (if (symbolp e)
      (member* (symbol-name e) slime-lisp-features :test #'equalp)
    (funcall (ecase (car e)
               (and #'every)
               (or  #'some))
             #'slime-eval-feature-conditional
             (cdr e))))


;;;; Visiting and navigating the overlays of compiler notes

(defun slime-next-note ()
  "Go to and describe the next compiler note in the buffer."
  (interactive)
  (slime-find-next-note)
  (if (slime-note-at-point)
      (slime-show-note (slime-note-at-point))
    (message "No next note.")))

(defun slime-previous-note ()
  "Go to and describe the previous compiler note in the buffer."
  (interactive)
  (slime-find-previous-note)
  (if (slime-note-at-point)
      (slime-show-note (slime-note-at-point))
    (message "No previous note.")))

(defun slime-remove-notes ()
  "Remove compiler-note annotations from the current buffer."
  (interactive)
  (slime-remove-old-overlays))

(defun slime-show-note (overlay)
  "Present the details of a compiler note to the user."
  (slime-temporarily-highlight-note overlay)
  (slime-message "%s" (get-char-property (point) 'help-echo)))

(defun slime-temporarily-highlight-note (overlay)
  "Temporarily highlight a compiler note's overlay.
The highlighting is designed to both make the relevant source more
visible, and to highlight any further notes that are nested inside the
current one.

The highlighting is automatically undone before the next Emacs command."
  (lexical-let ((old-face (overlay-get overlay 'face))
                (overlay overlay))
    (push (lambda () (overlay-put overlay 'face old-face))
	  slime-pre-command-actions)
    (overlay-put overlay 'face 'slime-highlight-face)))


;;;; Overlay lookup operations

(defun slime-note-at-point ()
  "Return the overlay for a note starting at point, otherwise NIL."
  (find (point) (slime-note-overlays-at-point)
	:key 'overlay-start))

(defun slime-note-overlay-p (overlay)
  "Return true if OVERLAY represents a compiler note."
  (overlay-get overlay 'slime))

(defun slime-note-overlays-at-point ()
  "Return a list of all note overlays that are under the point."
  (remove-if-not 'slime-note-overlay-p (overlays-at (point))))

(defun slime-find-next-note ()
  "Go to the next position with the `slime-note' text property.
Retuns true if such a position is found."
  (slime-find-note 'next-single-char-property-change))

(defun slime-find-previous-note ()
  "Go to the next position with the `slime' text property.
Returns true if such a position is found."
  (slime-find-note 'previous-single-char-property-change))

(defun slime-find-note (next-candidate-fn)
  "Seek out the beginning of a note.
NEXT-CANDIDATE-FN is called to find each new position for consideration."
  (let ((origin (point)))
    (loop do (goto-char (funcall next-candidate-fn (point) 'slime))
	  until (or (slime-note-at-point)
		    (eobp)
		    (bobp)))
    (unless (slime-note-at-point)
      (goto-char origin))))


;;; Arglist Display

(defun slime-space ()
  "Insert a space and print some relevant information (function arglist).
Designed to be bound to the SPC key."
  (interactive)
  (insert " ")
  (unless (slime-busy-p)
    (when (slime-function-called-at-point/line)
      (slime-arglist (symbol-name (slime-function-called-at-point/line))))))

(defun slime-arglist (symbol-name)
  "Show the argument list for the nearest function call, if any."
  (interactive (list (slime-read-symbol "Arglist of: ")))
  (slime-eval-async 
   `(swank:arglist-string ',symbol-name)
   (slime-buffer-package)
   (lexical-let ((symbol-name symbol-name))
     (lambda (arglist)
       (message "(%s %s)" symbol-name (substring arglist 1 -1))))))


;;; Completion

(defun slime-complete-symbol ()
  "Complete the symbol at point.
If the symbol lacks an explicit package prefix, the current buffer's
package is used."
  ;; NB: It is only the name part of the symbol that we actually want
  ;; to complete -- the package prefix, if given, is just context.
  (interactive)
  (let* ((end (point))
         (beg (slime-symbol-start-pos))
         (prefix (buffer-substring-no-properties beg end))
         (completions (slime-completions prefix))
         (completions-alist (slime-bogus-completion-alist completions))
         (completion (try-completion prefix completions-alist nil)))
    (cond ((eq completion t))
          ((null completion)
           (message "Can't find completion for \"%s\"" prefix)
           (ding))
          ((not (string= prefix completion))
           (delete-region beg end)
           (insert completion))
          (t
           (message "Making completion list...")
           (let ((list (all-completions prefix completions-alist nil)))
             (slime-with-output-to-temp-buffer "*Completions*"
	       (display-completion-list list)))
           (message "Making completion list...done")))))

(defun slime-completing-read-internal (string default-package flag)
  ;; We misuse the predicate argument to pass the default-package.
  ;; That's needed because slime-completing-read-internal is called in
  ;; the minibuffer.
  (ecase flag
    ((nil) 
     (let* ((completions (slime-completions string default-package)))
       (try-completion string
		       (slime-bogus-completion-alist completions))))
    ((t)
     (slime-completions string default-package))
    ((lambda)
     (member string (slime-completions string default-package)))))

(defun slime-completing-read-symbol-name (prompt &optional initial-value)
  "Read the name of a CL symbol, with completion.  
The \"name\" may include a package prefix."
  (completing-read prompt 
		   'slime-completing-read-internal
		   (slime-buffer-package)
		   nil
		   initial-value))

(defvar slime-read-expression-map (make-sparse-keymap)
  "Minibuffer keymap used for reading CL expressions.")

(set-keymap-parent slime-read-expression-map minibuffer-local-map)

(define-key slime-read-expression-map "\t" 'slime-complete-symbol)
(define-key slime-read-expression-map "\M-\t" 'slime-complete-symbol)

(defvar slime-read-expression-history '()
  "History list of expressions read from the minibuffer.")
 
(defun slime-read-from-minibuffer (prompt &optional initial-value)
  "Read a string from the minibuffer, prompting with PROMPT.  
If INITIAL-VALUE is non-nil, it is inserted into the minibuffer before
reading input.  The result is a string (\"\" if no input was given)."
  (let ((minibuffer-setup-hook 
	 (cons (lexical-let ((package (slime-buffer-package)))
		 (lambda ()
		   (setq slime-buffer-package package)))
	       minibuffer-setup-hook)))
    (read-from-minibuffer prompt initial-value slime-read-expression-map
			  nil 'slime-read-expression-history)))

(defun slime-symbol-start-pos ()
  "Return the starting position of the symbol under point.
The result is unspecified if there isn't a symbol under the point."
  (save-excursion
    (backward-sexp 1)
    (skip-syntax-forward "'")
    (point)))

(defun slime-bogus-completion-alist (list)
  "Make an alist out of list.
The same elements go in the CAR, and nil in the CDR. To support the
apparently very stupid `try-completions' interface, that wants an
alist but ignores CDRs."
  (mapcar (lambda (x) (cons x nil)) list))

(defun slime-completions (prefix &optional default-package)
  (let ((prefix (etypecase prefix
		  (symbol (symbol-name prefix))
		  (string prefix))))
    (slime-eval `(swank:completions ,prefix 
				    ,(or default-package
					 (slime-find-buffer-package)
					 (slime-buffer-package))))))


(defun slime-cl-symbol-name (symbol)
  (let ((n (if (stringp symbol) symbol (symbol-name symbol))))
    (if (string-match ":\\([^:]*\\)$" n)
	(match-string 1 n)
      n)))

(defun slime-cl-symbol-package (symbol &optional default)
  (let ((n (if (stringp symbol) symbol (symbol-name symbol))))
    (if (string-match "^\\([^:]*\\):" n)
	(match-string 1 n)
      default)))

(defun slime-cl-symbol-external-ref-p (symbol)
  "Does SYMBOL refer to an external symbol?
FOO:BAR is an external reference.
FOO::BAR is not, and nor is BAR."
  (let ((name (if (stringp symbol) symbol (symbol-name symbol))))
    (and (string-match ":" name)
         (not (string-match "::" name)))))


;;; Edit definition

(defvar slime-find-definition-history-ring (make-ring 20)
  "History ring recording the definition-finding \"stack\".")

(defun slime-push-definition-stack (&optional marker)
  "Add MARKER to the edit-definition history stack.
If MARKER is nil, use the point."
  (ring-insert-at-beginning slime-find-definition-history-ring
                            (or marker (point-marker))))

(defun slime-pop-find-definition-stack ()
  "Pop the edit-definition stack and goto the location."
  (interactive)
  (unless (ring-empty-p slime-find-definition-history-ring)
    (let* ((marker (ring-remove slime-find-definition-history-ring))
	   (buffer (marker-buffer marker)))
      (if (buffer-live-p buffer)
	  (progn (switch-to-buffer buffer)
		 (goto-char (marker-position marker)))
        ;; If this buffer was deleted, recurse to try the next one
        (slime-pop-find-definition-stack)))))

(defun slime-edit-fdefinition (name)
  "Lookup the definition of the symbol at point.  
If there's no symbol at point, or a prefix argument is given, then the
function name is prompted."
  (interactive (list (slime-read-symbol-name "Function name: ")))
  (let ((origin (point-marker))
	(source-location
	 (slime-eval `(swank:function-source-location-for-emacs ,name)
		     (slime-buffer-package))))
    (cond ((null source-location)
           (message "No definition found: %s" name))
          ((eq (car source-location) :error)
           (message (cadr source-location)))
          (t
           (slime-goto-source-location source-location)
           (ring-insert-at-beginning slime-find-definition-history-ring origin)))))


;;; Interactive evaluation.

(defun slime-interactive-eval (string)
  (interactive (list (slime-read-from-minibuffer "Slime Eval: ")))
  (slime-insert-transcript-delimiter string)
  (slime-eval-async 
   `(swank:interactive-eval ,string)
   (slime-buffer-package t)
   (slime-show-evaluation-result-continuation)))

(defun slime-display-buffer-region (buffer start end &optional border)
  (slime-save-window-configuration)
  (let ((border (or border 0)))
    (with-current-buffer buffer
      (save-selected-window
	(save-excursion
	  (unless (get-buffer-window buffer)
	    (display-buffer buffer t))
	  (goto-char start)
	  (when (eolp) 
	    (forward-char))
	  (beginning-of-line)
	  (let ((win (get-buffer-window buffer)))
	    ;; set start before select to force update.
	    ;; (set-window-start sets a "modified" flag, but only if the
	    ;; window is not selected.)
	    (set-window-start win (point))
	    (let* ((lines (max (count-screen-lines (point) end) 1))
		   (new-height (1+ (min (/ (frame-height) 2)
					(+ border lines))))
		   (diff (- new-height (window-height win))))
	      (let ((window-min-height 1))
		(select-window win)
		(enlarge-window diff)))))))))

(defun slime-show-evaluation-result (output-start value)
  (message "=> %s" value)
  (slime-show-last-output output-start))

(defun slime-show-evaluation-result-continuation ()
  (lexical-let ((output-start (slime-output-buffer-position)))
    (lambda (value)
      (slime-show-evaluation-result output-start value))))
  
(defun slime-last-expression ()
  (buffer-substring-no-properties (save-excursion (backward-sexp) (point))
				  (point)))

(defun slime-eval-last-expression ()
  (interactive)
  (slime-interactive-eval (slime-last-expression)))

(defun slime-eval-defun ()
  (interactive)
  (slime-interactive-eval (slime-defun-at-point)))

(defun slime-eval-region (start end)
  (interactive "r")
  (slime-eval-async
   `(swank:interactive-eval-region ,(buffer-substring-no-properties start end))
   (slime-buffer-package)
   (slime-show-evaluation-result-continuation)))

(defun slime-eval-buffer ()
  (interactive)
  (slime-eval-region (point-min) (point-max)))

(defun slime-re-evaluate-defvar ()
  "Force the re-evaluaton of the defvar form before point.  

First make the variable unbound, then evaluate the entire form."
  (interactive)
  (slime-eval-async `(swank:re-evaluate-defvar ,(slime-last-expression))
		    (slime-buffer-package)
		    (slime-show-evaluation-result-continuation)))

(defun slime-pprint-eval-last-expression ()
  (interactive)
  (slime-eval-describe `(swank:pprint-eval ,(slime-last-expression))))

(defun slime-toggle-trace-fdefinition (fname-string)
  (interactive (list (slime-completing-read-symbol-name 
		      "(Un)trace: " (slime-symbol-name-at-point))))
  (message "%s" (slime-eval `(swank:toggle-trace-fdefinition ,fname-string)
			    (slime-buffer-package t))))

(defun slime-untrace-all ()
  (interactive)
  (slime-eval `(swank:untrace-all)))

(defun slime-disassemble-symbol (symbol-name)
  (interactive (list (slime-read-symbol-name "Disassemble: ")))
  (slime-eval-describe `(swank:disassemble-symbol ,symbol-name)))

(defun slime-load-file (filename)
  (interactive "fLoad file: ")
  (slime-eval-async 
   `(swank:load-file ,(expand-file-name filename)) nil 
   (slime-show-evaluation-result-continuation)))


;;; Documentation

(defun slime-show-description (string package)
  (slime-save-window-configuration)
  (save-current-buffer
    (let* ((slime-package-for-help-mode package)
	   (temp-buffer-show-hook 
	    (cons (lambda ()
		    (setq slime-buffer-package slime-package-for-help-mode)
		    (set-syntax-table lisp-mode-syntax-table)
		    (slime-mode t))
		  temp-buffer-show-hook)))
      (slime-with-output-to-temp-buffer "*Help*"
	(princ string)))))

(defun slime-eval-describe (form)
  (let ((package (slime-buffer-package)))
    (slime-eval-async 
     form package
     (lexical-let ((package package))
       (lambda (string) (slime-show-description string package))))))

(defun slime-describe-symbol (symbol-name)
  (interactive (list (slime-read-symbol-name "Describe symbol: ")))
  (when (not symbol-name)
    (error "No symbol given"))
  (slime-eval-describe `(swank:describe-symbol ,symbol-name)))

(defun slime-apropos (string &optional only-external-p package)
  (interactive
   (if current-prefix-arg
       (list (read-string "SLIME Apropos: ")
             (y-or-n-p "External symbols only? ")
             (let ((pkg (slime-read-package-name "Package: ")))
               (if (string= pkg "") nil pkg)))
     (list (read-string "SLIME Apropos: ") t nil)))
  (slime-eval-async
   `(swank:apropos-list-for-emacs ,string ,only-external-p ,package)
   (slime-buffer-package t)
   (lexical-let ((string string)
                 (package package))
     (lambda (r) (slime-show-apropos r string package)))))

(defun slime-apropos-all ()
  "Shortcut for (slime-apropos <pattern> nil nil)"
  (interactive)
  (slime-apropos (read-string "SLIME Apropos: ") nil nil))

(defun slime-show-apropos (plists string package)
  (if (null plists)
      (message "No apropos matches for %S" string)
    (save-current-buffer
      (slime-with-output-to-temp-buffer "*CMUCL Apropos*"
	(set-buffer standard-output)
	(apropos-mode)
	(set-syntax-table lisp-mode-syntax-table)
	(slime-mode t)
	(setq slime-buffer-package package)
	(set (make-local-variable 'truncate-lines) t)
	(slime-print-apropos plists)))))

(defun slime-princ-propertized (string props)
  (with-current-buffer standard-output
    (let ((start (point)))
      (princ string)
      (add-text-properties start (point) props))))

(autoload 'apropos-mode "apropos")
(defvar apropos-label-properties)

(defun slime-print-apropos (plists)
  (dolist (plist plists)
    (let ((designator (plist-get plist :designator)))
      (slime-princ-propertized designator 
			       (list 'face apropos-symbol-face
				     'item designator
				     'action 'slime-describe-symbol)))
    (terpri)
    (let ((apropos-label-properties 
	   (cond ((and (boundp 'apropos-label-properties) 
		       apropos-label-properties))
		 ((boundp 'apropos-label-face)
		  (typecase apropos-label-face
		    (symbol `(face ,(or apropos-label-face 'italic)
				   mouse-face highlight))
		    (list apropos-label-face))))))
      (loop for (prop namespace action) 
	    in '((:variable "Variable" swank:describe-symbol)
		 (:function "Function" swank:describe-function)
		 (:setf "Setf" swank:describe-setf-function)
		 (:type "Type" swank:describe-type)
		 (:class "Class" swank:describe-class))
	    do
	    (let ((value (plist-get plist prop))
		  (start (point)))
	      (when value
		(princ "  ") 
		(slime-princ-propertized namespace apropos-label-properties)
		(princ ": ")
		(princ (etypecase value
			 (string value)
			 ((member :not-documented) "(not documented)")))
		(put-text-property start (point) 'describer action)
		(put-text-property start (point) 'action 'slime-call-describer)
		(terpri)))))))

(defun slime-call-describer (item)
  (slime-eval-describe `(,(get-text-property (point) 'describer) ,item)))


;;; XREF: cross-referencing

(defvar slime-xref-summary nil
  "Summary of a cross reference list, for the mode line.")

(define-minor-mode slime-xref-mode
  "\\<slime-xref-mode-map>"
  nil
  nil
  '(("RET"  . slime-goto-xref)
    ("\C-m" . slime-goto-xref)
    ))

;; Setup the mode-line to say when we're in slime-mode, and which CL
;; package we think the current buffer belongs to.
(add-to-list 'minor-mode-alist '(slime-xref-mode slime-xref-summary))

(defun slime-who-calls (symbol)
  "Show all known callers of the function SYMBOL."
  (interactive (list (slime-read-symbol "Who calls: ")))
  (slime-xref 'calls symbol))

(defun slime-who-references (symbol)
  "Show all known referrers of the global variable SYMBOL."
  (interactive (list (slime-read-symbol "Who references: ")))
  (slime-xref 'references symbol))

(defun slime-who-binds (symbol)
  "Show all known binders of the global variable SYMBOL."
  (interactive (list (slime-read-symbol "Who binds: ")))
  (slime-xref 'binds symbol))

(defun slime-who-sets (symbol)
  "Show all known setters of the global variable SYMBOL."
  (interactive (list (slime-read-symbol "Who sets: ")))
  (slime-xref 'sets symbol))

(defun slime-who-macroexpands (symbol)
  "Show all known expanders of the macro SYMBOL."
  (interactive (list (slime-read-symbol "Who macroexpands: ")))
  (slime-xref 'macroexpands symbol))

(defun slime-xref (type symbol)
  "Make an XREF request to Lisp."
  (slime-eval-async
   `(,(intern (format "swank:who-%s" type)) ',symbol)
   (slime-buffer-package t)
   (lexical-let ((type type)
                 (symbol symbol)
                 (package (slime-buffer-package)))
     (lambda (result)
       (slime-show-xrefs result type symbol package)))))

(defun slime-show-xrefs (file-referrers type symbol package)
  "Show the results of an XREF query."
  (if (null file-referrers)
      (message "No references found.")
    (slime-save-window-configuration)
    (setq slime-next-location-function 'slime-goto-next-xref)
    (with-current-buffer (slime-xref-buffer t)
      (slime-init-xref-buffer package type symbol)
      (dolist (ref file-referrers)
        (apply #'slime-insert-xrefs ref))
      (setq buffer-read-only t)
      (goto-char (point-min))
      (save-selected-window
        (delete-windows-on (slime-xref-buffer))
        (slime-display-xref-buffer)))))

(defun slime-insert-xrefs (filename refs)
  "Insert the cross-references for a file.
Each cross-reference line contains these text properties:
 slime-xref:             a unique object
 slime-file:             filename of reference
 slime-xref-source-path: source-path of reference
 slime-xref-complete:    true iff both file and source-path are known."
  (unless (bobp) (insert "\n"))
  (insert (format "In %s:\n" (or filename "unidentified files")))
  (loop for (referrer source-path) in refs
        do (let ((complete (and filename source-path)))
             (slime-insert-propertized
              (list 'slime-xref (make-symbol "#:unique-ref")
                    'slime-xref-complete complete
                    'slime-xref-file filename
                    'slime-xref-source-path source-path
                    'face (if complete
                              'font-lock-function-name-face
                            'font-lock-comment-face))
              (format "%s\n" referrer)))))


;;;;; XREF results buffer and window management

(defun slime-xref-buffer (&optional create)
  "Return the XREF results buffer.
If CREATE is non-nil, create it if necessary."
  (if create
      (get-buffer-create "*CMUCL xref*")
    (or (get-buffer "*CMUCL xref*")
        (error "No XREF buffer"))))

(defun slime-init-xref-buffer (package ref-type symbol)
  "Initialize the current buffer for displaying XREF information."
  (slime-xref-mode t)
  (setq buffer-read-only nil)
  (erase-buffer)
  (set-syntax-table lisp-mode-syntax-table)
  (slime-mode t)
  (setq slime-buffer-package package)
  (set (make-local-variable 'truncate-lines) t)
  (setq slime-xref-summary
        (format " XREF[%s: %s]" ref-type symbol)))

(defun slime-display-xref-buffer ()
  "Display the XREF results buffer in a window and select it."
  (let* ((buffer (slime-xref-buffer))
         (window (get-buffer-window buffer)))
    (if (and window (window-live-p window))
        (select-window window)
      (select-window (display-buffer buffer t))
      (set-window-text-height (selected-window)
                              (min (count-lines (point-min) (point-max))
                                   (window-text-height))))))


;;;;; XREF navigation
(defun slime-goto-xref ()
  "Goto the cross-referenced location at point."
  (interactive)
  (let ((file (get-text-property (point) 'slime-xref-file))
        (path (get-text-property (point) 'slime-xref-source-path)))
    (unless (and file path)
      (error "No reference at point."))
    (find-file-other-window file)
    (goto-char (point-min))
    (slime-visit-source-path path)))

(defun slime-goto-next-xref ()
  "Goto the next cross-reference location."
  (save-selected-window
    (slime-display-xref-buffer)
    (loop do (goto-char (next-single-char-property-change (point) 'slime-xref))
          until (or (get-text-property (point) 'slime-xref-complete)
                    (eobp)))
    (if (not (eobp))
        (slime-goto-xref)
      (forward-line -1)
      (message "No more xrefs."))))

(defvar slime-next-location-function nil
  "Function to call for going to the next location.")

(defun slime-next-location ()
  "Go to the next location, depending on context.
When displaying XREF information, this goes to the next reference."
  (interactive)
  (when (null slime-next-location-function)
    (error "No context for finding locations."))
  (funcall slime-next-location-function))


;;; Macroexpansion

(defun slime-eval-macroexpand (expander)
  (let ((string (slime-sexp-at-point)))
    (slime-eval-describe `(,expander ,string))))

(defun slime-macroexpand-1 (&optional repeatedly)
  (interactive "P")
  (slime-eval-macroexpand
   (if repeatedly 'swank:swank-macroexpand 'swank:swank-macroexpand-1)))

(defun slime-macroexpand-all ()
  (interactive)
  (slime-eval-macroexpand 'swank:swank-macroexpand-all))


;;; Subprocess control

(defun slime-interrupt ()
  (interactive)
  (slime-dispatch-event '(:emacs-interrupt)))

(defun slime-quit ()
  (interactive)
  (slime-dispatch-event '(:emacs-quit)))

(defun slime-set-package (package)
  (interactive (list (slime-read-package-name "Package: " 
					      (slime-find-buffer-package))))
  (message "*package*: %s" (slime-eval `(swank:set-package package))))

(defun slime-set-default-directory (directory)
  (interactive (list (read-file-name "Directory: " nil default-directory t)))
  (message "default-directory: %s" 
	   (slime-eval `(swank:set-default-directory 
			 ,(expand-file-name directory)))))

(defun slime-sync-package-and-default-directory ()
  (interactive)
  (let ((package (slime-eval `(swank:set-package 
			       ,(slime-find-buffer-package))))
	(directory (slime-eval `(swank:set-default-directory 
				 ,(expand-file-name default-directory)))))
    (message "package: %s  default-directory: %s" package directory)))
	

;;; Debugger

(defvar sldb-condition)
(defvar sldb-restarts)
(defvar sldb-backtrace-length)
(defvar sldb-level-in-buffer)
(defvar sldb-backtrace-start-marker)
(defvar sldb-mode-map)

(defun slime-debugger-hook ()
  (slime-enter-sldb))

(defun slime-enter-sldb ()
  (slime-move-to-state (slime-state sldb-state (slime-current-state)))
  (incf sldb-level)
  (slime-net-send `(swank:sldb-loop)))

(defun sldb-setup (condition restarts stack-depth frames)
  (with-current-buffer (get-buffer-create "*sldb*")
    (setq buffer-read-only nil)
    (sldb-mode)
    (set (make-local-variable 'truncate-lines) t)
    (add-hook (make-local-variable 'kill-buffer-hook) 'sldb-delete-overlays)
    (setq sldb-condition condition)
    (setq sldb-restarts restarts)
    (setq sldb-backtrace-length stack-depth)
    (insert condition "\n" "\nRestarts:\n")
    (loop for (name string) in restarts
	  for number from 0 
	  do (progn
	       (slime-insert-propertized
		`(face bold 
		       restart-number ,number
		       sldb-default-action sldb-invoke-restart
		       mouse-face highlight)
		"  " (number-to-string number) ": ["  name "] " string)
	       (insert "\n")))
    (insert "\nBacktrace:\n")
    (setq sldb-backtrace-start-marker (point-marker))
    (sldb-insert-frames frames)
    (setq buffer-read-only t)
    (pop-to-buffer (current-buffer))))

(defun slime-insert-propertized (props &rest args)
  (let ((start (point)))
    (apply #'insert args)
    (add-text-properties start (point) props)))

(define-derived-mode sldb-mode fundamental-mode "sldb" 
  "Superior lisp debugger mode

\\{sldb-mode-map}"
  (erase-buffer)
  (set-syntax-table lisp-mode-syntax-table)
  (mapc #'make-local-variable '(sldb-condition 
				sldb-restarts
				sldb-backtrace-length
				sldb-level-in-buffer
				sldb-backtrace-start-marker))
  (setq sldb-level-in-buffer sldb-level)
  (setq mode-name (format "sldb[%d]" sldb-level)))

(defun sldb-insert-frames (frames)
  (save-excursion
    (loop for frame in frames
	  for (number string) = frame
	  do (slime-insert-propertized `(frame ,frame) string "\n"))
    (let ((number (sldb-previous-frame-number)))
      (cond ((= sldb-backtrace-length (1+ number)))
	    (t
	     (slime-insert-propertized 
	      '(sldb-default-action 
		sldb-fetch-more-frames
		point-entered sldb-fetch-more-frames)
	      "   --more--"))))))

(defun sldb-fetch-more-frames (&optional start end)
  (let ((inhibit-point-motion-hooks t))
    (let ((previous (sldb-previous-frame-number)))
      (let ((inhibit-read-only t))
	(beginning-of-line)
	(let ((start (point)))
	  (end-of-buffer)
	  (delete-region start (point)))
	(sldb-insert-frames 
	 (slime-eval `(swank:backtrace-for-emacs 
		       ,(1+ previous)
		       ,(+ previous 40))))))))

(defun sldb-default-action/mouse (event)
  (interactive "e")
  (destructuring-bind (mouse-1 (w pos (x . y) time)) event
    (save-excursion
      (goto-char pos)
      (let ((fn (get-text-property (point) 'sldb-default-action)))
	(if fn (funcall fn))))))

(defun sldb-default-action ()
  (interactive)
  (let ((fn (get-text-property (point) 'sldb-default-action)))
    (if fn (funcall fn))))

(defvar sldb-overlays '())

(defun sldb-delete-overlays ()
  (mapc #'delete-overlay sldb-overlays)
  (setq sldb-overlays '()))
  
(defun sldb-highlight-sexp (&optional start end)
  "Highlight the first sexp after point."
  (sldb-delete-overlays)
  (let ((start (or start (point)))
	(end (or end (save-excursion (forward-sexp) (point)))))
    (push (make-overlay start (1+ start)) sldb-overlays)
    (push (make-overlay (1- end) end) sldb-overlays)
    (dolist (overlay sldb-overlays)
      (overlay-put overlay 'face 'secondary-selection))))

(defun sldb-frame-number-at-point ()
  (let ((frame (get-text-property (point) 'frame)))
    (cond (frame (car frame))
	  (t (error "No frame at point")))))

(defun sldb-previous-frame-number ()
  (save-excursion
    (sldb-backward-frame)
    (sldb-frame-number-at-point)))

(defun slime-goto-source-location (source-location &optional other-window)
  (let ((error (plist-get source-location :error)))
    (when error
      (error "Cannot locate source: %s" error))
    (case (plist-get source-location :from)
      (:file
       (funcall (if other-window #'find-file-other-window #'find-file)
		(plist-get source-location :filename))
       (goto-char (plist-get source-location :position)))
      (:stream
       (let ((info (plist-get source-location :info)))
	 (cond ((and (consp info) (eq :emacs-buffer (car info)))
		(let ((buffer (plist-get info :emacs-buffer))
		      (offset (plist-get info :emacs-buffer-offset)))
		  (funcall (if other-window 
			       #'switch-to-buffer-other-window 
			     #'switch-to-buffer)
			   (get-buffer buffer))
		  (goto-char offset)
		  (slime-forward-source-path 
		   (cdr (plist-get source-location :path)))))
	       (t
		(error "Cannot locate source from stream: %s"
		       source-location)))))
      (t
       (slime-message "Source Form:\n%s" 
		      (plist-get source-location :source-form))))))
	   
(defun sldb-show-source ()
  (interactive)
  (sldb-delete-overlays)
  (let* ((number (sldb-frame-number-at-point))
	 (source-location (slime-eval
			   `(swank:frame-source-location-for-emacs ,number))))
    (save-selected-window
      (slime-goto-source-location source-location t)
      (sldb-highlight-sexp))))

(defun sldb-frame-details-visible-p ()
  (and (get-text-property (point) 'frame)
       (get-text-property (point) 'details-visible-p)))

(defun sldb-toggle-details (&optional on)
  (interactive)
  (sldb-frame-number-at-point)
  (let ((inhibit-read-only t))
    (if (or on (not (sldb-frame-details-visible-p)))
	(sldb-show-frame-details)
      (sldb-hide-frame-details))))

(defmacro* sldb-propertize-region (props &body body)
  (let ((start (gensym)))
    `(let ((,start (point)))
       (prog1 (progn ,@body)
	 (add-text-properties ,start (point) ,props)))))

(put 'sldb-propertize-region 'lisp-indent-function 1)

(defun sldb-frame-region ()
  (save-excursion
    (goto-char (next-single-property-change (point) 'frame nil (point-max)))
    (backward-char)
    (values (previous-single-property-change (point) 'frame)
	    (next-single-property-change (point) 'frame nil (point-max)))))

(defun sldb-show-frame-details ()
  (multiple-value-bind (start end) (sldb-frame-region)
    (save-excursion
      (let* ((props (text-properties-at (point)))
	     (frame (plist-get props 'frame))
	     (frame-number (car frame))
	     (standard-output (current-buffer)))
	(goto-char start)
	(delete-region start end)
	(sldb-propertize-region (plist-put props 'details-visible-p t)
	  (insert (second frame) "\n"
		  "   Locals:\n")
	  (sldb-princ-locals frame-number "       ")
	  (let ((catchers (sldb-catch-tags frame-number)))
	    (cond ((null catchers)
		   (princ "   [No catch-tags]\n"))
		  (t
		   (princ "   Catch-tags:\n")
		   (loop for (tag . location) in catchers
			 do (slime-insert-propertized  
			     '(catch-tag ,tag)
			     (format "      %S\n" tag))))))
	  (terpri)
	  (point)))))
  (apply #'sldb-maybe-recenter-region (sldb-frame-region)))

(defun sldb-maybe-recenter-region (start end)
  (sit-for 0 1)
  (cond ((and (< (window-start) start)
	      (< end (window-end))))
	(t
	 (let ((lines (count-lines start end)))
	   (cond ((< lines (window-height))
		  (recenter (max (- (window-height) lines 4) 0)))
		 (t (recenter 1)))))))

(defun sldb-hide-frame-details ()
  (save-excursion
    (multiple-value-bind (start end) (sldb-frame-region)
      (let* ((props (text-properties-at (point)))
	     (frame (plist-get props 'frame)))
	(goto-char start)
	(delete-region start end)
	(sldb-propertize-region (plist-put props 'details-visible-p nil)
	  (insert (second frame) "\n"))))))

(defun sldb-eval-in-frame (string)
  (interactive (list (slime-read-from-minibuffer "Eval in frame: ")))
  (let* ((number (sldb-frame-number-at-point)))
    (slime-eval-async `(swank:eval-string-in-frame ,string ,number)
		      nil
		      (lambda (reply) (slime-message "==> %s" reply)))))

(defun sldb-forward-frame ()
  (goto-char (next-single-char-property-change (point) 'frame)))

(defun sldb-backward-frame ()
  (goto-char (previous-single-char-property-change
	      (point) 'frame 
	      nil sldb-backtrace-start-marker)))

(defun sldb-down ()
  (interactive)
  (sldb-forward-frame))

(defun sldb-up ()
  (interactive)
  (sldb-backward-frame)
  (when (= (point) sldb-backtrace-start-marker)
    (recenter (1+ (count-lines (point-min) (point))))))

(defun sldb-sugar-move (move-fn)
  (let ((inhibit-read-only t))
    (when (sldb-frame-details-visible-p)
      (sldb-hide-frame-details))
    (funcall move-fn)
    (sldb-toggle-details t)
    (sldb-show-source)))
  
(defun sldb-details-up ()
  (interactive)
  (sldb-sugar-move 'sldb-up))

(defun sldb-details-down ()
  (interactive)
  (sldb-sugar-move 'sldb-down))

(defun sldb-frame-locals (frame)
  (slime-eval `(swank:frame-locals ,frame)))

(defun sldb-princ-locals (frame prefix)
  (dolist (l (sldb-frame-locals frame))
    (princ prefix)
    (princ (plist-get l :symbol))
    (let ((id (plist-get l :id)))
      (unless (zerop id) (princ "#") (princ id)))
    (princ " = ")
    (princ (plist-get l :value-string))
    (terpri)))

(defun sldb-list-locals ()
  (interactive)
  (let ((string (with-output-to-string
		  (sldb-princ-locals (sldb-frame-number-at-point) ""))))
    (slime-message "%s" string)))

(defun sldb-catch-tags (frame)
  (slime-eval `(swank:frame-catch-tags ,frame)))

(defun sldb-list-catch-tags ()
  (interactive)
  (slime-message "%S" (sldb-catch-tags (sldb-frame-number-at-point))))
  
(defun sldb-cleanup (buffer)
  (delete-windows-on buffer)
  (kill-buffer buffer))

(defun sldb-quit ()
  (interactive)
  (slime-eval-async '(swank:throw-to-toplevel) nil (lambda ())))

(defun sldb-continue ()
  (interactive)
  (slime-eval-async '(swank:sldb-continue)
		    nil
		    (lambda (foo)
		      (message "No restart named continue") 
		      (ding))))

(defun sldb-abort ()
  (interactive)
  (slime-eval-async '(swank:sldb-abort) nil (lambda ())))

(defun sldb-invoke-restart (&optional number)
  (interactive)
  (let ((restart (or number
                     (sldb-restart-at-point)
                     (error "No restart at point"))))
    (slime-eval-async `(swank:invoke-nth-restart ,restart) nil (lambda ()))))

(defun sldb-restart-at-point ()
  (get-text-property (point) 'restart-number))

(defmacro slime-define-keys (keymap &rest key-command)
  `(progn . ,(mapcar (lambda (k-c) `(define-key ,keymap . ,k-c))
		     key-command)))

(put 'slime-define-keys 'lisp-indent-function 1)

(slime-define-keys sldb-mode-map 
  ("v"    'sldb-show-source)
  ((kbd "RET") 'sldb-default-action)
  ([mouse-2]  'sldb-default-action/mouse)
  ("e"    'sldb-eval-in-frame)
  ("d"    'sldb-down)
  ("u"    'sldb-up)
  ("\M-n" 'sldb-details-down)
  ("\M-p" 'sldb-details-up)
  ("l"    'sldb-list-locals)
  ("t"    'sldb-toggle-details)
  ("c"    'sldb-continue)
  ("a"    'sldb-abort)
  ("r"    'sldb-invoke-restart)
  ("q"    'sldb-quit)
  
  ("\M-." 'slime-edit-fdefinition)
  ("\M-," 'slime-pop-find-definition-stack)
  )

;; Keys 0-9 are shortcuts to invoke particular restarts.
(defmacro define-sldb-invoke-restart-key (number key)
  (let ((fname (intern (format "sldb-invoke-restart-%S" number))))
    `(progn
       (defun ,fname ()
	 (interactive)
	 (sldb-invoke-restart ,number))
       (define-key sldb-mode-map ,key ',fname))))

(defmacro define-sldb-invoke-restart-keys (from to)
  `(progn
     ,@(loop for n from from to to
	     collect `(define-sldb-invoke-restart-key ,n 
			,(number-to-string n)))))

(define-sldb-invoke-restart-keys 0 9)
  

;;; Test suite

(defvar slime-tests '()
  "Names of test functions.")

(defvar slime-test-debug-on-error nil
  "*When non-nil debug errors in test cases.")

(defvar slime-test-verbose-p nil
  "*When non-nil do not display the results of individual checks.")

(defvar slime-total-tests nil
  "Total number of tests executed during a test run.")

(defvar slime-failed-tests nil
  "Total number of failed tests during a test run.")

(defun slime-run-tests ()
  (interactive)
  (slime-with-output-to-temp-buffer "*Tests*"
    (with-current-buffer standard-output
      (set (make-local-variable 'truncate-lines) t))
    (slime-execute-tests)))

(defun slime-execute-tests ()
  (save-window-excursion
    (let ((slime-total-tests 0)
          (slime-failed-tests 0))
      (loop for (name function inputs) in slime-tests
            do (dolist (input inputs)
                 (incf slime-total-tests)
                 (princ (format "%s: %S\n" name input))
                 (condition-case err
                     (apply function input)
                   (error (incf slime-failed-tests)
                          (slime-print-check-error err)))))
      (if (zerop slime-failed-tests)
          (message "All %S tests completed successfully." slime-total-tests)
        (message "Failed on %S of %S tests."
                 slime-failed-tests slime-total-tests)))))

(defun slime-batch-test ()
  "Run the test suite in batch-mode."
  (let ((standard-output t)
        (slime-test-debug-on-error nil))
    (slime)
    (slime-run-tests)))

(defmacro def-slime-test (name args doc inputs &rest body)
  "Define a test case.
NAME is a symbol naming the test.
ARGS is a lambda-list.
DOC is a docstring.
INPUTS is a list of argument lists, each tested separately.
BODY is the test case. The body can use `slime-check' to test
conditions (assertions)."
  (let ((fname (intern (format "slime-test-%s" name))))
    `(progn
       (defun ,fname ,args
         ,doc
         (slime-sync)
         ,@body)
       (setq slime-tests (append (remove* ',name slime-tests :key 'car)
                                 (list (list ',name ',fname ,inputs)))))))

(defmacro slime-check (test-name &rest body)
  `(if (progn ,@body)
       (slime-print-check-ok ',test-name)
     (incf slime-failed-tests)
     (slime-print-check-failed ',test-name)
     (when slime-test-debug-on-error
       (debug (format "Check failed: %S" ',test-name)))))

(defun slime-print-check-ok (test-name)
  (when slime-test-verbose-p
    (princ (format "        ok:     %s\n" test-name))))

(defun slime-print-check-failed (test-name)
  (slime-princ-propertized (format "        FAILED: %s\n" test-name)
                           '(face font-lock-warning-face)))

(defun slime-print-check-error (reason)
  (slime-princ-propertized (format "        ERROR:  %S\n" reason)
                           '(face font-lock-warning-face)))

;; Clear out old tests.
(setq slime-tests nil)

(def-slime-test find-definition
    (name expected-filename)
    "Find the definition of a function or macro."
    '((list "list.lisp")
      (loop "loop.lisp")
      (aref "array.lisp"))
  (let ((orig-buffer (current-buffer))
        (orig-pos (point)))
    (slime-edit-fdefinition (symbol-name name))
    ;; Postconditions
    (slime-check correct-file
      (string= (file-name-nondirectory (buffer-file-name))
               expected-filename))
    (slime-check looking-at-definition
      (looking-at (format "(\\(defun\\|defmacro\\)\\s *%s\\s " name)))
    (slime-pop-find-definition-stack)
    (slime-check return-from-definition
      (and (eq orig-buffer (current-buffer))
           (= orig-pos (point))))))

(def-slime-test complete-symbol
    (prefix expected-completions)
    "Find the completions of a symbol-name prefix."
    '(("cl:compile" ("cl:compile" "cl:compile-file" "cl:compile-file-pathname"
                     "cl:compiled-function" "cl:compiled-function-p"
                     "cl:compiler-macro" "cl:compiler-macro-function"))
      ("cl:foobar" nil)
      ("cl::compile-file" ("cl::compile-file" "cl::compile-file-pathname")))
  (let ((completions (slime-completions prefix)))
    (slime-check expected-completions
      (equal expected-completions (sort completions 'string<)))))

(def-slime-test arglist
    (symbol expected-arglist)
    "Lookup the argument list for SYMBOL.
Confirm that EXPECTED-ARGLIST is displayed."
    '(("list" "(list &rest args)")
      ("defun" "(defun &whole source name lambda-list &parse-body (body decls doc))")
      ("cl::defun" "(cl::defun &whole source name lambda-list &parse-body (body decls doc))"))
  (slime-arglist symbol)
  (slime-sync)
  (slime-check expected-arglist
    (string= expected-arglist (current-message))))

(def-slime-test compile-defun 
    (program subform)
    "Compile PROGRAM containing errors.
Confirm that SUBFORM is correclty located."
    '(("(defun :foo () (:bar))" (:bar))
      ("(defun :foo () 
         #\\space
         ;;Sdf              
         (:bar))"
       (:bar))
      ;; this fails
      ("(defun :foo () 
            #| |#
            (:bar))"
       (:bar))
      )
  (with-temp-buffer 
    (lisp-mode)
    (insert program)
    (slime-compile-defun)
    (slime-sync)
    (slime-previous-note)
    (slime-check error-location-correct
      (equal (read (current-buffer))
	     subform))))

(put 'def-slime-test 'lisp-indent-function 4)
(put 'slime-check 'lisp-indent-function 1)


;;; Portability library

(when (featurep 'xemacs)
  (require 'overlay)
  (defun next-single-char-property-change (&rest args)
    (or (apply 'next-single-property-change args)
        (point-max)))
  (defun previous-single-char-property-change (&rest args)
    (or (apply 'previous-single-property-change args)
        (point-min)))
  (unless (fboundp 'string-make-unibyte)
    (defalias 'string-make-unibyte #'identity))
  )

(eval-when (compile eval)
  (defmacro defun-if-undefined (name &rest rest)
    `(unless (fboundp ',name)
       (defun ,name ,@rest))))

(defun-if-undefined next-single-char-property-change
  (position prop &optional object limit)
  (let ((limit (typecase limit
		 (null nil)
		 (marker (marker-position limit))
		 (t limit))))
    (if (stringp object)
	(or (next-single-property-change position prop object limit)
	    limit 
	    (length object))
      (with-current-buffer (or object (current-buffer))
	(let ((initial-value (get-char-property position prop object))
	      (limit (or limit (point-max))))
	  (loop for pos = position then (next-char-property-change pos limit)
		if (>= pos limit) return limit
		if (not (eq initial-value 
			    (get-char-property pos prop object))) 
		return pos))))))

(defun-if-undefined previous-single-char-property-change 
  (position prop &optional object limit)
  (let ((limit (typecase limit
		 (null nil)
		 (marker (marker-position limit))
		 (t limit))))
    (if (stringp object)
	(or (previous-single-property-change position prop object limit)
	    limit 
	    (length object))
      (with-current-buffer (or object (current-buffer))
	(let ((initial-value (get-char-property (1- position) prop object))
	      (limit (or limit (point-min))))
	  (if (<= position limit)
	      limit
	    (loop for pos = position then 
		  (previous-char-property-change pos limit)
		  if (<= pos limit) return limit
		  if (not (eq initial-value 
			      (get-char-property (1- pos) prop object))) 
		  return pos)))))))

(defun-if-undefined substring-no-properties (string &optional start end)
  (let* ((start (or start 0))
	 (end (or end (length string)))
	 (string (substring string start end)))
    (set-text-properties start end nil string)
    string))

(defun-if-undefined set-window-text-height (window height)
  (let ((delta (- height (window-text-height window))))
    (unless (zerop delta)
      (let ((window-min-height 1))
	(if (and window (not (eq window (selected-window))))
	    (save-selected-window
	      (select-window window)
	      (enlarge-window delta))
	  (enlarge-window delta))))))

(defun-if-undefined window-text-height (&optional window)
  (1- (window-height window)))

(defun-if-undefined subst-char-in-string (fromchar tochar string 
						   &optional inplace)
  "Replace FROMCHAR with TOCHAR in STRING each time it occurs.
Unless optional argument INPLACE is non-nil, return a new string."
  (let ((i (length string))
	(newstr (if inplace string (copy-sequence string))))
    (while (> i 0)
      (setq i (1- i))
      (if (eq (aref newstr i) fromchar)
	  (aset newstr i tochar)))
    newstr))

(defun-if-undefined count-screen-lines 
  (&optional beg end count-final-newline window)
  (unless beg
    (setq beg (point-min)))
  (unless end
    (setq end (point-max)))
  (if (= beg end)
      0
    (save-excursion
      (save-restriction
        (widen)
        (narrow-to-region (min beg end)
                          (if (and (not count-final-newline)
                                   (= ?\n (char-before (max beg end))))
                              (1- (max beg end))
                            (max beg end)))
        (goto-char (point-min))
        (1+ (vertical-motion (buffer-size) window))))))

(defun emacs-20-p ()
  (and (not (featurep 'xemacs))
       (= emacs-major-version 20)))


;;; Finishing up

(run-hooks 'slime-load-hook)

(provide 'slime)

;;; slime.el ends here
