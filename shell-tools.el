;;; shell-tools --- 

;; Author: Noah Peart <noah.v.peart@gmail.com>
;; URL: https://github.com/nverno/shell-tools
;; Package-Requires: 
;; Copyright (C) 2016, Noah Peart, all rights reserved.
;; Created:  4 November 2016

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

;; [![Build Status](https://travis-ci.org/nverno/shell-tools.svg?branch=master)](https://travis-ci.org/nverno/shell-tools)

;;; Code:
(eval-when-compile
  (require 'cl-lib)
  (require 'nvp-macro)
  (require 'pcomplete)
  (defvar yas-snippet-dirs))
(autoload 'pcomplete--here "pcomplete")
(autoload 'pcomplete-entries "pcomplete")
(autoload 'expand-add-abbrevs "expand")

(defvar shell-tools--dir nil)
(when load-file-name
  (setq shell-tools--dir (file-name-directory load-file-name)))

;;--- Pcomplete ------------------------------------------------------

(defun pcomplete/shell-mode/git ()
  (pcomplete-here
   '("add" "bisect" "branch" "checkout" "clone" "commit" "diff" "fetch"
     "grep" "init" "log" "merge" "mv" "pull" "push" "rebase" "remote"
     "reset" "rm" "show" "status" "submodule" "tag"))
       
  ;; FIXME: branches? cant use readline on windows, not sure its
  ;; worth fixing
  (pcomplete-here
   (let ((last-cmd (nth (1- pcomplete-last) pcomplete-args)))
     (cond
      ((equal "checkout" last-cmd) " ")
      ;; (my--get-git-branches)
      ((equal "add" last-cmd)
       (pcomplete-entries))
      ((equal "merge" last-cmd) " ")
      ;; (my--get-git-branches t)
      ))))

;; setup clink so it starts whenever cmd.exe runs
(nvp-with-w32
  (defun shell-w32tools-clink-install ()
    (start-process "clink" "*nvp-install*" "cmd.exe"
                   "clink" "autorun" "install")))

;;--- Shells ---------------------------------------------------------

;; return some available shells
(defun shell-tools-get-shells ()
  (or
   (nvp-with-gnu
     '("sh" "bash" "fish" "zsh"))
   (nvp-with-w32
     (cl-loop
        for var in `(,(expand-file-name "usr/bin" (getenv "MSYS_HOME"))
                     ,(expand-file-name "bin" (getenv "CYGWIN_HOME")))
        nconc (mapcar (lambda (x) (expand-file-name x var))
                      '("sh.exe" "bash.exe" "fish.exe" "zsh.exe"))))))

;; switch to a different shell for compiling
(defvar-local shell-tools-shell "bash")
(defun shell-tools-switch-shell (shell)
  (interactive
   (list (if #'ido-completing-read
             (ido-completing-read "Shell: " (shell-tools-get-shells))
           (completing-read "Shell: " (shell-tools-get-shells)))))
  (setq shell-tools-shell shell))

;;; Interactive

(defun shell-tools-basic-compile ()
  (interactive)
  (let ((compile-command
         (concat (or shell-tools-shell "bash") " "
                 (if buffer-file-name buffer-file-name)))
        (compilation-read-command))
    (call-interactively 'compile)))

(nvp-newline shell-tools-newline-dwim nil
  :pairs (("{" "}") ("(" ")")))

;;--- Abbrevs --------------------------------------------------------

;; dont expand in strings or after [-:]
(defun shell-tools-abbrev-expand-p ()
  (not (or (memq last-input-event '(?- ?:))
           (nth 3 (syntax-ppss)))))

;; dont expand when prefixed by [-/_.]
(defvar shell-tools-abbrev-re "\\(\\_<[_:\\.A-Za-z0-9/-]+\\)")

;; read aliases from bash_aliases to alist ((alias . expansion) ... )
(defun shell-tools-read-aliases (file &optional merge os)
  (with-current-buffer (find-file-noselect file)
    (goto-char (point-min))
    (let (res sys win)
      (while (not (eobp))
        ;; basic check: assume it is if [[ $OS == ".+" ]]
        ;; only dealing with "Windows_NT", and doesn't
        ;; try to deal with nested ifs
        (if (looking-at
             ;; eval-when-compile
             (concat "if[^!]*\\(!\\)? *\$OS.*=="
                     "\\s-*[\"']?\\([A-Za-z_0-9]+\\)"))
            (pcase (match-string-no-properties 2)
              (`"Windows_NT"
               (setq sys (if (match-string 1) 'other 'windows)))
              (_
               (setq sys (if (match-string 1) 'windows 'other))))
          (when (search-forward "alias" (line-end-position) t)
            (and (looking-at "[ \t]*\\([^=]+\\)='\\([^']+\\)'")
                 (push (list (match-string-no-properties 1)
                             (match-string-no-properties 2))
                       (if (eq sys 'windows) win res)))))
        ;; reset OS
        (when (looking-at-p "fi")
          (setq sys nil))
        ;; next line
        (forward-line 1))
      (if merge
          ;; use all aliases regardless of system type
          (nconc res win)
        (if os
            (pcase os
              ('windows win)
              (_ res))
          res)))))

(define-abbrev-table 'shell-tools-abbrev-table '())

;; Make abbrevs from bash_aliases file
;; If MERGE, use all abbrevs regardless of any if [[ $OS == ... ]]
;; If OS == 'windows, use only abbrevs in
;;   if [[ $OS == "Windows_NT" ]] blocks
;; Otherwise, use all others
(defun shell-tools-make-abbrevs (file &optional merge os system)
  (interactive
   (let* ((file (read-file-name "Bash aliases: " "~" ".bash_aliases"))
          (merge (y-or-n-p "Merge system specific abbrevs?"))
          (os (and (not merge)
                   (y-or-n-p "Use only windows abbrevs?")
                   'windows))
          (system (y-or-n-p "Create system abbrevs?")))
     (list file merge os)))
  ;; construct abbrev table
  (define-abbrev-table 'shell-tools-abbrev-table
    (shell-tools-read-aliases file merge os)
    :parents (list shells-abbrev-table
                   prog-mode-abbrev-table)
    :enable-function 'shell-tools-abbrev-expand-p
    :regexp shell-tools-abbrev-re)
  (when system
    (mapatoms (lambda (abbrev)
                (abbrev-put abbrev :system t))
              shell-tools-abbrev-table))
  ;; Set new abbrev table as local abbrev table
  (setq-local local-abbrev-table shell-tools-abbrev-table))

;; FIXME: Add option to merge to tables

;; write shell abbrevs
;; temporarily rebind `abbrev--write' so we can write out
;; :system abbrevs as well
(defun shell-tools-write-abbrevs (file)
  (interactive
   (list (read-file-name "Write abbrevs to: " shell-tools--dir)))
  (let ((abbrev-table-name-list '(shell-tools-abbrev-table)))
    (cl-letf (((symbol-function 'abbrev--write)
               (lambda (sym)
                 (unless (null (symbol-value sym))
                   (insert "    (")
                   (prin1 (symbol-name sym))
                   (insert " ")
                   (prin1 (symbol-value sym))
                   (insert " ")
                   (prin1 (symbol-function sym))
                   (insert " :system t)\n")))))
      (write-abbrev-file file ))))

;;--- Setup ----------------------------------------------------------

(eval-after-load 'yasnippet
  '(let ((dir (expand-file-name "snippets" shell-tools--dir))
         (dirs (or (and (consp yas-snippet-dirs) yas-snippet-dirs)
                   (cons yas-snippet-dirs ()))))
     (unless (member dir dirs)
       (setq yas-snippet-dirs (delq nil (cons dir dirs))))
     (yas-load-directory dir)))

;; -------------------------------------------------------------------

(declare-function yas-load-directory "yasnippet")

(provide 'shell-tools)
;;; shell-tools.el ends here
