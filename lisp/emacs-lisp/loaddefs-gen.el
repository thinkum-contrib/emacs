;;; loaddefs-gen.el --- generate loaddefs.el files  -*- lexical-binding: t -*-

;; Copyright (C) 2022 Free Software Foundation, Inc.

;; Keywords: maint
;; Package: emacs

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This package generates the main lisp/loaddefs.el file, as well as
;; all the other loaddefs files, like calendar/diary-loaddefs.el, etc.

;; The main entry point is `loaddefs-gen--generate' (normally called
;; from batch-loaddefs-gen via lisp/Makefile).
;;
;; The "other" loaddefs files are specified either via a file-local
;; setting of `generated-autoload-file', or by specifying
;;
;;   ;;;###foo-autoload
;;
;; This makes the autoload go to foo-loaddefs.el in the current directory.
;; Normal ;;;###autoload specs go to the main loaddefs file.

;; This file currently contains a bunch of things marked FIXME that
;; are only present to create identical output from the older files.
;; These should be removed.

;;; Code:

(require 'radix-tree)
(require 'lisp-mnt)

(defvar autoload-compute-prefixes t
  "If non-nil, autoload will add code to register the prefixes used in a file.
Standard prefixes won't be registered anyway.  I.e. if a file \"foo.el\" defines
variables or functions that use \"foo-\" as prefix, that will not be registered.
But all other prefixes will be included.")
(put 'autoload-compute-prefixes 'safe-local-variable #'booleanp)


(defvar autoload-ignored-definitions
  '("define-obsolete-function-alias"
    "define-obsolete-variable-alias"
    "define-category" "define-key"
    "defgroup" "defface" "defadvice"
    "def-edebug-spec"
    ;; Hmm... this is getting ugly:
    "define-widget"
    "define-erc-module"
    "define-erc-response-handler"
    "defun-rcirc-command")
  "List of strings naming definitions to ignore for prefixes.
More specifically those definitions will not be considered for the
`register-definition-prefixes' call.")

(defun loaddefs-gen--file-load-name (file outfile)
  "Compute the name that will be used to load FILE.
OUTFILE should be the name of the global loaddefs.el file, which
is expected to be at the root directory of the files we are
scanning for autoloads and will be in the `load-path'."
  (let* ((name (file-relative-name file (file-name-directory outfile)))
         (names '())
         (dir (file-name-directory outfile)))
    ;; If `name' has directory components, only keep the
    ;; last few that are really needed.
    (while name
      (setq name (directory-file-name name))
      (push (file-name-nondirectory name) names)
      (setq name (file-name-directory name)))
    (while (not name)
      (cond
       ((null (cdr names)) (setq name (car names)))
       ((file-exists-p (expand-file-name "subdirs.el" dir))
        ;; FIXME: here we only check the existence of subdirs.el,
        ;; without checking its content.  This makes it generate wrong load
        ;; names for cases like lisp/term which is not added to load-path.
        (setq dir (expand-file-name (pop names) dir)))
       (t (setq name (mapconcat #'identity names "/")))))
    (if (string-match "\\.elc?\\(\\.\\|\\'\\)" name)
        (substring name 0 (match-beginning 0))
      name)))

(defun loaddefs-gen--make-autoload (form file &optional expansion)
  "Turn FORM into an autoload or defvar for source file FILE.
Returns nil if FORM is not a special autoload form (i.e. a function definition
or macro definition or a defcustom).
If EXPANSION is non-nil, we're processing the macro expansion of an
expression, in which case we want to handle forms differently."
  (let ((car (car-safe form)) expand)
    (cond
     ((and expansion (eq car 'defalias))
      (pcase-let*
          ((`(,_ ,_ ,arg . ,rest) form)
           ;; `type' is non-nil if it defines a macro.
           ;; `fun' is the function part of `arg' (defaults to `arg').
           ((or (and (or `(cons 'macro ,fun) `'(macro . ,fun)) (let type t))
                (and (let fun arg) (let type nil)))
            arg)
           ;; `lam' is the lambda expression in `fun' (or nil if not
           ;; recognized).
           (lam (if (memq (car-safe fun) '(quote function)) (cadr fun)))
           ;; `args' is the list of arguments (or t if not recognized).
           ;; `body' is the body of `lam' (or t if not recognized).
           ((or `(lambda ,args . ,body)
                (and (let args t) (let body t)))
            lam)
           ;; Get the `doc' from `body' or `rest'.
           (doc (cond ((stringp (car-safe body)) (car body))
                      ((stringp (car-safe rest)) (car rest))))
           ;; Look for an interactive spec.
           (interactive (pcase body
                          ((or `((interactive . ,iargs) . ,_)
                               `(,_ (interactive . ,iargs) . ,_))
                           ;; List of modes or just t.
                           (if (nthcdr 1 iargs)
                               (list 'quote (nthcdr 1 iargs))
                             t)))))
        ;; Add the usage form at the end where describe-function-1
        ;; can recover it.
        (when (consp args) (setq doc (help-add-fundoc-usage doc args)))
        ;; (message "autoload of %S" (nth 1 form))
        `(autoload ,(nth 1 form) ,file ,doc ,interactive ,type)))

     ((and expansion (memq car '(progn prog1)))
      (let ((end (memq :autoload-end form)))
	(when end             ;Cut-off anything after the :autoload-end marker.
          (setq form (copy-sequence form))
          (setcdr (memq :autoload-end form) nil))
        (let ((exps (delq nil (mapcar (lambda (form)
                                        (loaddefs-gen--make-autoload
                                         form file expansion))
                                      (cdr form)))))
          (when exps (cons 'progn exps)))))

     ;; For complex cases, try again on the macro-expansion.
     ((and (memq car '(easy-mmode-define-global-mode define-global-minor-mode
                       define-globalized-minor-mode defun defmacro
		       easy-mmode-define-minor-mode define-minor-mode
                       define-inline cl-defun cl-defmacro cl-defgeneric
                       cl-defstruct pcase-defmacro))
           (macrop car)
	   (setq expand (let ((load-true-file-name file)
                              (load-file-name file))
                          (macroexpand form)))
	   (memq (car expand) '(progn prog1 defalias)))
      ;; Recurse on the expansion.
      (loaddefs-gen--make-autoload expand file 'expansion))

     ;; For special function-like operators, use the `autoload' function.
     ((memq car '(define-skeleton define-derived-mode
                   define-compilation-mode define-generic-mode
		   easy-mmode-define-global-mode define-global-minor-mode
		   define-globalized-minor-mode
		   easy-mmode-define-minor-mode define-minor-mode
		   cl-defun defun* cl-defmacro defmacro*
                   define-overloadable-function))
      (let* ((macrop (memq car '(defmacro cl-defmacro defmacro*)))
	     (name (nth 1 form))
	     (args (pcase car
                     ((or 'defun 'defmacro
                          'defun* 'defmacro* 'cl-defun 'cl-defmacro
                          'define-overloadable-function)
                      (nth 2 form))
                     ('define-skeleton '(&optional str arg))
                     ((or 'define-generic-mode 'define-derived-mode
                          'define-compilation-mode)
                      nil)
                     (_ t)))
	     (body (nthcdr (or (function-get car 'doc-string-elt) 3) form))
	     (doc (if (stringp (car body)) (pop body))))
        ;; Add the usage form at the end where describe-function-1
        ;; can recover it.
	(when (listp args) (setq doc (help-add-fundoc-usage doc args)))
        ;; `define-generic-mode' quotes the name, so take care of that
        `(autoload ,(if (listp name) name (list 'quote name))
           ,file ,doc
           ,(or (and (memq car '(define-skeleton define-derived-mode
                                  define-generic-mode
                                  easy-mmode-define-global-mode
                                  define-global-minor-mode
                                  define-globalized-minor-mode
                                  easy-mmode-define-minor-mode
                                  define-minor-mode))
                     t)
                (and (eq (car-safe (car body)) 'interactive)
                     ;; List of modes or just t.
                     (or (if (nthcdr 1 (car body))
                             (list 'quote (nthcdr 1 (car body)))
                           t))))
           ,(if macrop ''macro nil))))

     ;; For defclass forms, use `eieio-defclass-autoload'.
     ((eq car 'defclass)
      (let ((name (nth 1 form))
	    (superclasses (nth 2 form))
	    (doc (nth 4 form)))
	(list 'eieio-defclass-autoload (list 'quote name)
	      (list 'quote superclasses) file doc)))

     ;; Convert defcustom to less space-consuming data.
     ((eq car 'defcustom)
      (let* ((varname (car-safe (cdr-safe form)))
	     (props (nthcdr 4 form))
	     (initializer (plist-get props :initialize))
	     (init (car-safe (cdr-safe (cdr-safe form))))
	     (doc (car-safe (cdr-safe (cdr-safe (cdr-safe form)))))
	     ;; (rest (cdr-safe (cdr-safe (cdr-safe (cdr-safe form)))))
	     )
	`(progn
	   ,(if (not (member initializer '(nil 'custom-initialize-default
	                                   #'custom-initialize-default
	                                   'custom-initialize-reset
	                                   #'custom-initialize-reset)))
	        form
	      `(defvar ,varname ,init ,doc))
	   ;; When we include the complete `form', this `custom-autoload'
           ;; is not indispensable, but it still helps in case the `defcustom'
           ;; doesn't specify its group explicitly, and probably in a few other
           ;; corner cases.
	   (custom-autoload ',varname ,file
                            ,(condition-case nil
                                 (null (plist-get props :set))
                               (error nil)))
           ;; Propagate the :safe property to the loaddefs file.
           ,@(when-let ((safe (plist-get props :safe)))
               `((put ',varname 'safe-local-variable ,safe))))))

     ((eq car 'defgroup)
      ;; In Emacs this is normally handled separately by cus-dep.el, but for
      ;; third party packages, it can be convenient to explicitly autoload
      ;; a group.
      (let ((groupname (nth 1 form)))
        `(let ((loads (get ',groupname 'custom-loads)))
           (if (member ',file loads) nil
             (put ',groupname 'custom-loads (cons ',file loads))))))

     ;; When processing a macro expansion, any expression
     ;; before a :autoload-end should be included.  These are typically (put
     ;; 'fun 'prop val) and things like that.
     ((and expansion (consp form)) form)

     ;; nil here indicates that this is not a special autoload form.
     (t nil))))

(defun loaddefs-gen--make-prefixes (defs file)
  ;; Remove the defs that obey the rule that file foo.el (or
  ;; foo-mode.el) uses "foo-" as prefix.  Then compute a small set of
  ;; prefixes that cover all the remaining definitions.
  (let* ((tree (let ((tree radix-tree-empty))
                 (dolist (def defs)
                   (setq tree (radix-tree-insert tree def t)))
                 tree))
         (prefixes nil))
    ;; Get the root prefixes, that we should include in any case.
    (radix-tree-iter-subtrees
     tree (lambda (prefix subtree)
            (push (cons prefix subtree) prefixes)))
    ;; In some cases, the root prefixes are too short, e.g. if you define
    ;; "cc-helper" and "c-mode", you'll get "c" in the root prefixes.
    (dolist (pair (prog1 prefixes (setq prefixes nil)))
      (let ((s (car pair)))
        (if (or (and (> (length s) 2)   ; Long enough!
                     ;; But don't use "def" from deffoo-pkg-thing.
                     (not (string= "def" s)))
                (string-match ".[[:punct:]]\\'" s) ;A real (tho short) prefix?
                (radix-tree-lookup (cdr pair) "")) ;Nothing to expand!
            (push pair prefixes)                   ;Keep it as is.
          (radix-tree-iter-subtrees
           (cdr pair) (lambda (prefix subtree)
                        (push (cons (concat s prefix) subtree) prefixes))))))
    (when prefixes
      (let ((strings
             (mapcar
              (lambda (x)
                (let ((prefix (car x)))
                  (if (or (> (length prefix) 2) ;Long enough!
                          (and (eq (length prefix) 2)
                               (string-match "[[:punct:]]" prefix)))
                      prefix
                    ;; Some packages really don't follow the rules.
                    ;; Drop the most egregious cases such as the
                    ;; one-letter prefixes.
                    (let ((dropped ()))
                      (radix-tree-iter-mappings
                       (cdr x) (lambda (s _)
                                 (push (concat prefix s) dropped)))
                      (message "%s:0: Warning: Not registering prefix \"%s\".  Affects: %S"
                               file prefix dropped)
                      nil))))
              prefixes)))
        `(register-definition-prefixes ,file ',(sort (delq nil strings)
						     'string<))))))


(defun loaddefs-gen--parse-file (file main-outfile &optional package-only)
  "Examing FILE for ;;;###autoload statements.
MAIN-OUTFILE is the main loaddefs file these statements are
destined for, but this can be overriden by the buffer-local
setting of `generated-autoload-file' in FILE, and
by ;;;###foo-autoload statements.

If PACKAGE-ONLY, only return the package info."
  (let ((defs nil)
        (load-name (loaddefs-gen--file-load-name file main-outfile))
        (compute-prefixes t)
        local-outfile package-defs
        inhibit-autoloads)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-max))
      ;; We "open-code" this version of `hack-local-variables',
      ;; because it's really slow in bootstrap-emacs.
      (when (search-backward ";; Local Variables:" (- (point-max) 1000) t)
        (save-excursion
          (when (re-search-forward "generated-autoload-file: *" nil t)
            ;; Buffer-local file that should be interpreted relative to
            ;; the .el file.
            (setq local-outfile (expand-file-name (read (current-buffer))
                                                  (file-name-directory file)))))
        (save-excursion
          (when (re-search-forward "generated-autoload-load-name: *" nil t)
            (setq load-name (read (current-buffer)))))
        (when (re-search-forward "no-update-autoloads: *" nil t)
          (setq inhibit-autoloads (read (current-buffer))))
        (when (re-search-forward "autoload-compute-prefixes: *" nil t)
          (setq compute-prefixes (read (current-buffer)))))

      ;; We always return the package version (even for pre-dumped
      ;; files).
      (let ((version (lm-header "version"))
            package)
        (when (and version
                   (setq version (ignore-errors (version-to-list version)))
                   (setq package (or (lm-header "package")
                                     (file-name-sans-extension
                                      (file-name-nondirectory file)))))
          ;; FIXME: Push directly to defs.
          (setq package-defs
                `(push (purecopy ',(cons (intern package) version))
                       package--builtin-versions))))

      ;; Obey the `no-update-autoloads' file local variable.
      (when (and (not inhibit-autoloads)
                 (not package-only))
        (goto-char (point-min))
        ;; The cookie might be like ;;;###tramp-autoload...
        (while (re-search-forward lisp-mode-autoload-regexp nil t)
          ;; ... and if we have one of these names, then alter outfile.
          (let* ((aname (match-string 2))
                 (to-file (if aname
                              (expand-file-name
                               (concat aname "-loaddefs.el")
                               (file-name-directory file))
                            (or local-outfile main-outfile))))
            (if (eolp)
                ;; We have a form following.
                (let* ((form (prog1
                                 (read (current-buffer))
                               (unless (bolp)
                                 (forward-line 1))))
                       (autoload (or (loaddefs-gen--make-autoload form load-name)
                                     form)))
                  ;; We get back either an autoload form, or a tree
                  ;; structure of `(progn ...)' things, so unravel that.
                  (let ((forms (if (eq (car autoload) 'progn)
                                   (cdr autoload)
                                 (list autoload))))
                    (while forms
                      (let ((elem (pop forms)))
                        (if (eq (car elem) 'progn)
                            ;; More recursion; add it to the start.
                            (setq forms (nconc (cdr elem) forms))
                          ;; We have something to add to the defs; do it.
                          (push (list to-file file
                                      (loaddefs-gen--prettify-autoload elem))
                                defs))))))
              ;; Just put the rest of the line into the loaddefs.
              ;; FIXME: We skip the first space if there's more
              ;; whitespace after.
              (when (looking-at-p " [\t ]")
                (forward-char 1))
              (push (list to-file file
                          (buffer-substring (point) (line-end-position)))
                    defs))))

        (when (and autoload-compute-prefixes
                   compute-prefixes)
          (when-let ((form (loaddefs-gen--compute-prefixes load-name)))
            ;; This output needs to always go in the main loaddefs.el,
            ;; regardless of `generated-autoload-file'.

            ;; FIXME: Not necessary.
            (setq form (loaddefs-gen--prettify-autoload form))

            ;; FIXME: For legacy reasons, many specs go elsewhere.
            (cond ((and (string-match "/cedet/" file) local-outfile)
                   (push (list local-outfile file form) defs))
                  ((string-match "/cedet/\\(semantic\\|srecode\\)/"
                                 file)
                   (push (list (concat (substring file 0 (match-end 0))
                                       "loaddefs.el")
                               file form)
                         defs))
                  (local-outfile
                   (push (list local-outfile file form) defs))
                  (t
                   (push (list main-outfile file form) defs)))))))

    (if package-defs
        (nconc defs (list (list (or local-outfile main-outfile) file
                                package-defs)))
      defs)))

(defun loaddefs-gen--compute-prefixes (load-name)
  (goto-char (point-min))
  (let ((prefs nil))
    ;; Avoid (defvar <foo>) by requiring a trailing space.
    (while (re-search-forward
            "^(\\(def[^ ]+\\) ['(]*\\([^' ()\"\n]+\\)[\n \t]" nil t)
      (unless (member (match-string 1) autoload-ignored-definitions)
        (let ((name (match-string-no-properties 2)))
          (when (save-excursion
                  (goto-char (match-beginning 0))
                  (or (bobp)
                      (progn
                        (forward-line -1)
                        (not (looking-at ";;;###autoload")))))
            (push name prefs)))))
    (loaddefs-gen--make-prefixes prefs load-name)))

(defun loaddefs-gen--prettify-autoload (autoload)
  ;; FIXME: All this is just to emulate the current look -- it should
  ;; probably all go.
  (with-temp-buffer
    (prin1 autoload (current-buffer) '(t (escape-newlines . t)
                                         (escape-control-characters . t)))
    (goto-char (point-min))
    (when (memq (car autoload)
                '( defun autoload defvar defconst
                   defvar-local defsubst defcustom defmacro
                   cl-defsubst))
      (forward-char 1)
      (ignore-errors
        (forward-sexp 3)
        (skip-chars-forward " "))
      (when (looking-at-p "\"")
        (let* ((start (point))
               (doc (read (current-buffer))))
          (delete-region start (point))
          (prin1 doc (current-buffer) t)
          (goto-char start))
        (save-excursion
          (forward-char 1)
          (insert "\\\n"))
        (narrow-to-region (point)
                          (progn
                            (forward-sexp 1)
                            (point)))
        (goto-char (point-min))
        (while (search-forward "\n(" nil t)
          (replace-match "\n\\(" t t))
        (widen)))
    (goto-char (point-min))
    (insert "\n")
    (buffer-string)))

(defun loaddefs-gen--rubric (file &optional type feature)
  "Return a string giving the appropriate autoload rubric for FILE.
TYPE (default \"autoloads\") is a string stating the type of
information contained in FILE.  TYPE \"package\" acts like the default,
but adds an extra line to the output to modify `load-path'.

If FEATURE is non-nil, FILE will provide a feature.  FEATURE may
be a string naming the feature, otherwise it will be based on
FILE's name."
  (let ((basename (file-name-nondirectory file))
	(lp (if (equal type "package") (setq type "autoloads"))))
    (concat ";;; " basename
            " --- automatically extracted " (or type "autoloads")
            "  -*- lexical-binding: t -*-\n"
            (when (string-match "/lisp/loaddefs\\.el\\'" file)
              ";; This file will be copied to ldefs-boot.el and checked in periodically.\n")
	    ";;\n"
	    ";;; Code:\n\n"
	    (if lp
		"(add-to-list 'load-path (directory-file-name
                         (or (file-name-directory #$) (car load-path))))\n\n")
	    "\n"
	    ;; This is used outside of autoload.el, eg cus-dep, finder.
	    (if feature
		(format "(provide '%s)\n"
			(if (stringp feature) feature
			  (file-name-sans-extension basename))))
	    ";; Local Variables:\n"
	    ";; version-control: never\n"
            ";; no-byte-compile: t\n" ;; #$ is byte-compiled into nil.
	    ";; no-update-autoloads: t\n"
	    ";; coding: utf-8-emacs-unix\n"
	    ";; End:\n"
	    ";;; " basename
	    " ends here\n")))

(defun loaddefs-gen--insert-section-header (outbuf autoloads load-name file time)
  "Insert into buffer OUTBUF the section-header line for FILE.
The header line lists the file name, its \"load name\", its autoloads,
and the time the FILE was last updated (the time is inserted only
if `autoload-timestamps' is non-nil, otherwise a fixed fake time is inserted)."
  ;; (cl-assert ;Make sure we don't insert it in the middle of another section.
  ;;  (save-excursion
  ;;    (or (not (re-search-backward
  ;;              (concat "\\("
  ;;                      (regexp-quote generate-autoload-section-header)
  ;;                      "\\)\\|\\("
  ;;                      (regexp-quote generate-autoload-section-trailer)
  ;;                      "\\)")
  ;;              nil t))
  ;;        (match-end 2))))
  (insert "\f\n;;;### ")
  (prin1 `(autoloads ,autoloads ,load-name ,file ,time)
	 outbuf)
  (terpri outbuf)
  ;; Break that line at spaces, to avoid very long lines.
  ;; Make each sub-line into a comment.
  (with-current-buffer outbuf
    (save-excursion
      (forward-line -1)
      (while (not (eolp))
	(move-to-column 64)
	(skip-chars-forward "^ \n")
	(or (eolp)
	    (insert "\n" ";;;;;; "))))))

(defun loaddefs-gen--generate (dir output-file &optional excluded-files)
  "Generate loaddefs files for Lisp files in the directories DIRS.
DIR can be either a single directory or a list of
directories.

The autoloads will be written to OUTPUT-FILE.  If any Lisp file
binds `generated-autoload-file' as a file-local variable, write
its autoloads into the specified file instead.

The function does NOT recursively descend into subdirectories of the
directory or directories specified."
  (let* ((files-re (let ((tmp nil))
		     (dolist (suf (get-load-suffixes))
                       ;; We don't use module-file-suffix below because
                       ;; we don't want to depend on whether Emacs was
                       ;; built with or without modules support, nor
                       ;; what is the suffix for the underlying OS.
		       (unless (string-match "\\.\\(elc\\|so\\|dll\\)" suf)
                         (push suf tmp)))
                     (concat "\\`[^=.].*" (regexp-opt tmp t) "\\'")))
	 (files (apply #'nconc
		       (mapcar (lambda (d)
				 (directory-files (expand-file-name d)
                                                  t files-re))
			       (if (consp dir) dir (list dir)))))
         (defs nil))

    ;; Collect all the autoload data.
    (let ((progress (make-progress-reporter
                     (byte-compile-info
                      (concat "Scraping files for autoloads"))
                     0 (length files) nil 10))
          (file-count 0))
      (dolist (file files)
        (progress-reporter-update progress (setq file-count (1+ file-count)))
        ;; Do not insert autoload entries for excluded files.
        (setq defs (nconc
		    (loaddefs-gen--parse-file
                     file output-file
                     (member (expand-file-name file) excluded-files))
                    defs)))
      (progress-reporter-done progress))

    ;; Generate the loaddef files.  First group per output file.
    (dolist (fdefs (seq-group-by #'car defs))
      (with-temp-buffer
        (insert (loaddefs-gen--rubric (car fdefs) nil t))
        (search-backward "\f")
        ;; The group by source file (and sort alphabetically).
        (dolist (section (sort (seq-group-by #'cadr (cdr fdefs))
                               (lambda (e1 e2)
                                 (string<
                                  (file-name-sans-extension
                                   (file-name-nondirectory (car e1)))
                                  (file-name-sans-extension
                                   (file-name-nondirectory (car e2)))))))
          (pop section)
          (let ((relfile (file-relative-name
                          (cadar section)
                          (file-name-directory (car fdefs)))))
            (loaddefs-gen--insert-section-header
             (current-buffer) nil
             (file-name-sans-extension
              (file-name-nondirectory relfile))
             relfile '(0 0 0 0))
            (insert ";;; Generated autoloads from " relfile "\n")
            (dolist (def (reverse section))
              (setq def (caddr def))
              (if (stringp def)
                  (princ def (current-buffer))
                (prin1 def (current-buffer) t))
              (unless (bolp)
                (insert "\n")))
            (insert "\n;;;***\n")))
        ;; FIXME: Remove.
        (goto-char (point-min))
        (while (re-search-forward
                "^;;; Generated autoloads.*\n\\(\n\\)(push" nil t)
          (goto-char (match-end 1))
          (delete-char -1))
        (write-region (point-min) (point-max) (car fdefs) nil 'silent)
        (byte-compile-info (file-relative-name (car fdefs) lisp-directory)
                           t "GEN")))))

(defun loaddefs-gen--excluded-files ()
  ;; Exclude those files that are preloaded on ALL platforms.
  ;; These are the ones in loadup.el where "(load" is at the start
  ;; of the line (crude, but it works).
  (let ((default-directory (file-name-directory lisp-directory))
        (excludes nil)
	file)
    (with-temp-buffer
      (insert-file-contents "loadup.el")
      (while (re-search-forward "^(load \"\\([^\"]+\\)\"" nil t)
	(setq file (match-string 1))
	(or (string-match "\\.el\\'" file)
	    (setq file (format "%s.el" file)))
	(or (string-match "\\`site-" file)
	    (push (expand-file-name file) excludes))))
    ;; Don't scan ldefs-boot.el, either.
    (cons (expand-file-name "ldefs-boot.el") excludes)))

;;;###autoload
(defun batch-loaddefs-gen ()
  "Generate lisp/loaddefs.el autoloads in batch mode."
  ;; For use during the Emacs build process only.
  (let ((args command-line-args-left))
    (setq command-line-args-left nil)
    (loaddefs-gen--generate
     args (expand-file-name "loaddefs.el" lisp-directory)
     (loaddefs-gen--excluded-files))))

(provide 'loaddefs-gen)

;;; loaddefs-gen.el ends here
