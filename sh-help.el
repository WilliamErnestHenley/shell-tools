;;; sh-help --- help-at-point for sh -*- lexical-binding: t; -*-

;; This is free and unencumbered software released into the public domain.

;; Author: Noah Peart <noah.v.peart@gmail.com>
;; URL: https://github.com/nverno/shell-tools
;; Package-Requires: 
;; Created:  5 December 2016

;; This file is not part of GNU Emacs.
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth
;; Floor, Boston, MA 02110-1301, USA.

;;; Commentary:

;; - Within '[' or '[[' => show help for switches
;; - On shell builtin   => bash -c 'help %s'
;; - Otherwise          => use man

;; TODO:
;; - ${} formatting
;; - special variables

;;; Code:
(eval-when-compile
  (require 'nvp-macro)
  (require 'cl-lib))
(require 'nvp-read) ;; parse 'man' stuff
(autoload 'sh-tools-function-name "sh-tools")
(autoload 'sh-tools-conditional-switch "sh-tools")
(autoload 'nvp-basic-temp-binding "nvp-basic")
(autoload 'pos-tip-show "pos-tip")

;; ignore ':', not symbolized to match strings
(defvar sh-help-bash-builtins
  (eval-when-compile
    (concat
     (nvp-re-opt
      '("." "[" "[[" "alias" "bg" "bind" "break" "builtin" "case" "cd"
        "command" "compgen" "complete" "continue" "declare" "dirs"
        "disown" "echo" "enable" "eval" "exec" "exit" "export" "fc" "fg"
        "getopts" "hash" "help" "history" "if" "jobs" "kill" "let"
        "local" "logout" "popd" "printf" "pushd" "pwd" "read" "readonly"
        "return" "set" "shift" "shopt" "source" "suspend" "test" "times"
        "trap" "type" "typeset" "ulimit" "umask" "unalias" "unset"
        "until" "wait" "while")
      'no-symbol)
     "\\'")))
  
;; -------------------------------------------------------------------
;;; Utilities

;; synopsis: bash -c 'help -s %s'
;; help:     bash -c 'help %s'
(defsubst sh-help-bash-builtin-sync (cmd &optional synopsis)
  (shell-command-to-string
   (concat "bash -c 'help " (and synopsis "-s ") cmd "'")))

(defsubst sh-help-bash-builtin (cmd &optional sync buffer)
  (let ((cmd (concat "bash -c 'help " cmd "'"))
        (buffer (or buffer "*sh-help*")))
    (if sync
        (call-process-shell-command cmd nil buffer)
      (start-process-shell-command "bash" buffer cmd))))

;; output to BUFFER, return process
;; man --names-only %s | col -b
(defsubst sh-help-man (cmd &optional sync buffer)
  (let ((cmd (concat "man --names-only "
                     (regexp-quote cmd) " | col -b")))
    (if sync
        (call-process-shell-command
         cmd nil (or buffer "*sh-help*"))
      (start-process-shell-command
       "man" (or buffer "*sh-help*") cmd))))

;; do BODY in buffer with man output
(defmacro sh-with-man-help (cmd &optional sync buffer &rest body)
  (declare (indent defun))
  `(let ((buffer (or ,buffer "*sh-help*")))
     ,(if sync
          `(with-current-buffer buffer
             (sh-help-man ,cmd 'sync (current-buffer)))
        `(set-process-sentinel
          (sh-help-man ,cmd nil buffer)
          #'(lambda (p _m)
              (when (zerop (process-exit-status p))
                (with-current-buffer buffer
                  ,@body)))))))

;; if bash builtin do BASH else MAN
(defmacro sh-with-bash/man (cmd bash &rest man)
  (declare (indent 2) (indent 1))
  `(if (string-match-p sh-help-bash-builtins ,cmd)
       ,bash
     ,@man))

;; process BODY in output of help for CMD. Help output is
;; either from 'bash help' for bash builtins or 'man'.
(defmacro sh-with-help (cmd &optional sync buffer &rest body)
  (declare (indent defun) (debug t))
  `(let ((buffer (get-buffer-create (or ,buffer "*sh-help*"))))
     (if ,sync
         (with-current-buffer buffer
             (apply (sh-with-bash/man ,cmd
                      'sh-help-bash-builtin
                      'sh-help-man)
                    ,cmd 'sync `(,buffer))
             ,@body)
       (set-process-sentinel
        (apply (sh-with-bash/man ,cmd 'sh-help-bash-builtin 'sh-help-man)
               ,cmd nil `(,buffer))
        #'(lambda (p _m)
            (when (zerop (process-exit-status p))
              (with-current-buffer buffer
                ,@body)))))))

;; -------------------------------------------------------------------
;;; Parse output

(defsubst sh-help--builtin-string ()
  (goto-char (point-min))
  ;; skip synopsis
  ;; (forward-line 1)
  (buffer-substring (point) (point-max)))

(defsubst sh-help--man-string (&optional section)
  (setq section (if section (concat "^" section) "^DESCRIPTION"))
  (nvp-read-man-string section))

;; parse 'man bash' conditional switches for '[[' and '['
(defsubst sh-help--cond-switches ()
  (nvp-read-man-switches "^CONDITIONAL EXP" "\\s-+-" "^[[:alpha:]]"))

;; -------------------------------------------------------------------
;;; Cache / Lookup

(defvar sh-help-cache (make-hash-table :test 'equal))
(defvar sh-help-conditional-cache (make-hash-table :test 'equal))

;; return help string for CMD synchronously, cache result
(defun sh-help--function-string (cmd &optional section recache)
  (or (and (not recache)
           (gethash cmd sh-help-cache))
      (sh-with-help cmd 'sync "*sh-help*"
        (prog1
            (let ((res (sh-with-bash/man cmd
                         (sh-help--builtin-string)
                         (sh-help--man-string section))))
              (puthash cmd res sh-help-cache)
              res)
          (erase-buffer)))))

;; return conditional help string
(defun sh-help--conditional-string (switch)
  (or (gethash switch sh-help-conditional-cache)
      (gethash "all" sh-help-conditional-cache)
      (progn
        (sh-help--cache-conditionals)
        (sh-help--conditional-string switch))))

;; make sh-help-conditional-cache
(defun sh-help--cache-conditionals ()
  (sh-with-help "bash" 'sync "*sh-help*"
    (let ((entries (sh-help--cond-switches)))
      (dolist (entry entries)
        ;; key by -%s if possible
        (if (string-match "^\\(-[[:alnum:]]+\\).*" (car entry))
            (puthash (match-string 1 (car entry))
                     (concat (car entry) "\n" (cdr entry))
                     sh-help-conditional-cache)
          ;; otherwise just use entry, for things like
          ;; "string = string" from man
          (puthash (car entry) (cdr entry)
                   sh-help-conditional-cache)))
      ;; make one big entry for everything
      (puthash
       "all" (mapconcat
              #'(lambda (entry) (concat (car entry) "\n" (cdr entry)))
              entries
              "\n")
       sh-help-conditional-cache))
    (erase-buffer)))

;; -------------------------------------------------------------------
;;; Help at point

(defsubst sh-help-more-help (cmd)
  (interactive)
  (sh-with-bash/man cmd
    (man "bash-builtins")
    (man cmd)))

;; show help in popup tooltip for CMD
;; show SECTION from 'man', prompting with prefix
(defun sh-help-command-at-point (cmd &optional prompt section recache)
  (interactive (list (thing-at-point 'symbol)))
  (when cmd
    (nvp-with-toggled-tip
      (or (sh-help--function-string
           cmd
           (if prompt
               (read-from-minibuffer "Man Section: " "DESCRIPTION")
             section)
           recache)
          (format "No help found for %s" cmd))
      :help-fn #'(lambda ()
                   (interactive)
                   (x-hide-tip)
                   (sh-help-more-help cmd)))))

;; display help for conditional expressions: '[[' '['
(defun sh-help-conditional (switch &optional ignore)
  (interactive
   (if (x-hide-tip)
       (list nil 'ignore)
     (list (completing-read "Switch: " sh-help-conditional-cache))))
  (when (not ignore)
    (nvp-with-toggled-tip
      (sh-help--conditional-string switch))))

;; popup help for thing at point
;; - with C-u, show help for thing directly at point
;; - with C-u C-u, prompt for 'man' section, display result in popup
;; and recache result
;; - default, determine current function (not thing-at-point)
;; and find help for that.  If in [[ ... ]] or [ ... ],
;; show help for current switch, eg. "-d", or all possible switches
;;;###autoload
(defun sh-help-at-point (arg)
  (interactive "P")
  (if (equal arg '(4))
      (call-interactively 'sh-help-command-at-point)
    (let ((cmd (sh-tools-function-name)))
      (cond
       ((member cmd '("[[" "["))
        ;; return help for current switch or all if not found
        (sh-help-conditional (sh-tools-conditional-switch)))
       (t
        ;; with C-u C-u prompt for 'man' section and recache
        (sh-help-command-at-point
         cmd (equal arg '(16)) nil 'recache))))))

(provide 'sh-help)
;;; sh-help.el ends here
