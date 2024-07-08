;;; lsp-inline-completions.el --- inline code suggestions for lsp-mode -*- lexical-binding: t -*-

;; Copyright (C) 2024 Rodrigo Virote Kassick

;; This file is not part of GNU Emacs

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;; Author: Rodrigo Virote Kassick <kassick@gmail.com>
;; Version: 0.1
;; Package-Requires: (lsp-mode dash cl-lib)
;; Keywords: lsp-mode, generative-ai, code-assistant inline-completions completions code-suggestions
;; URL: https://github.com/kassick/lsp-inline-completions

;; Commentary:

;; LSP Inline Code Suggestions -- should work with any compatible server

;; Code:

(require 'lsp-mode)
(require 'cl-lib)
(require 'dash)


;; Specification here https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_inlineCompletion

;; lsp-mode as of now does not support this capability -- so we need to patch somethings up
(unless (assoc "textDocument/inlineCompletion" lsp-method-requirements)
  (push '("textDocument/inlineCompletion" :capability :inlineCompletionProvider) lsp-method-requirements))

(lsp-interface
 (InlineCompletionItem (:insertText) (:filterText :range :command))
 (InlineCompletionList (:items) nil)
 )

(defconst lsp--inline-completion-trigger-invoked 1 "Explicit invocation as per https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlineCompletionTriggerKind")
(defconst lsp--inline-completion-trigger-automatic 2 "Automatic invocation as per https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlineCompletionTriggerKind")

;; This keymap is a bit customized already ... maybe let it empty?
;;;###autoload
(defvar lsp-inline-completion-active-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<tab>") #'lsp-inline-completion-next)
    (define-key map (kbd "C-n") #'lsp-inline-completion-next)
    (define-key map (kbd "M-n") #'lsp-inline-completion-next)
    (define-key map (kbd "C-p") #'lsp-inline-completion-prev)
    (define-key map (kbd "M-p") #'lsp-inline-completion-prev)
    (define-key map (kbd "<return>") #'lsp-inline-completion-accept)
    (define-key map (kbd "C-l") #'lsp-inline-completion-accept)
    (define-key map (kbd "C-g") #'lsp-inline-completion-cancel)
    (define-key map (kbd "<escape>") #'lsp-inline-completion-cancel)
    (define-key map (kbd "C-c C-k") #'lsp-inline-completion-cancel)
    (define-key map [t] #'lsp-inline-completion-cancel)
    map)
  "Keymap active when showing inline code suggestions")

;;;###autoload
(defface lsp-inline-completion-overlay-face
  '((t :inherit shadow))
  "Face for the inline code suggestions overlay.")

;; Local Buffer State

(defvar-local lsp--inline-completions nil "The completions provided by the server")
(defvar-local lsp--inline-completion-current nil "The current suggestion to be displayed")
(defvar-local lsp--inline-completion-overlay nil "The overlay displaying code suggestions")

(defcustom lsp-before-inline-completion-hook nil
  "Hooks run before starting code suggestions"
  :type 'hook)

(defcustom lsp-after-inline-completion-hook nil
  "Hooks executed after asking for code suggestions."
  :type 'hook)

(defcustom lsp-inline-completion-accepted-hook nil
  "Hooks executed after accepting a code suggestion."
  :type 'hook)

(defsubst lsp--inline-completion-overlay-visible ()
  "Return whether the `overlay' is avaiable."
  (and (overlayp lsp--inline-completion-overlay)
       (overlay-buffer lsp--inline-completion-overlay)))

(defun lsp--inline-completion-get-overlay (beg end)
  "Build the suggestions overlay"
  (when (overlayp lsp--inline-completion-overlay)
    (lsp--inline-completion-clear-overlay))

  (setq lsp--inline-completion-overlay (make-overlay beg end nil nil t))
  (overlay-put lsp--inline-completion-overlay 'keymap lsp-inline-completion-active-map)
  (overlay-put lsp--inline-completion-overlay 'priority 9000)

  lsp--inline-completion-overlay)


(defun lsp--inline-completion-clear-overlay ()
  "Hide the suggestion overlay"
  (when (lsp--inline-completion-overlay-visible)
    (delete-overlay lsp--inline-completion-overlay))
  (setq lsp--inline-completion-overlay nil)
  )

(defun lsp--inline-completion-show ()
  "Makes the suggestion overlay visible"
  (lsp--inline-completion-clear-overlay)
  (let* ((tail (buffer-substring (point) (line-end-position)))
         (suggestion
          (elt lsp--inline-completions
               lsp--inline-completion-current))
         (insertText (lsp:inline-completion-item-insert-text suggestion))
         (text (cond
                ((lsp-markup-content? insertText) (lsp:markup-content-value insertText))
                (t insertText)))
         (ov (lsp--inline-completion-get-overlay (point) (+ (point)
                                                            (max 1 (length text)))))
         (display-key (if (eolp) 'after-string 'display)))
    (message "Completion %d/%s"
             (1+ lsp--inline-completion-current)
             (length lsp--inline-completions))
    (overlay-put ov display-key (concat
                                 (propertize text 'face 'lsp-inline-completion-overlay-face)
                                 tail))
    (overlay-put ov 'start (point))))

(defun lsp-inline-completion-accept ()
  "Accepts the current suggestion"
  (interactive)
  (unless (lsp--inline-completion-overlay-visible)
    (error "Not showing suggestions"))

  (lsp--inline-completion-clear-overlay)
  (-let* ((start-point (point))
          (suggestion (elt lsp--inline-completions lsp--inline-completion-current))
          ((&InlineCompletionItem? :insert-text :filter-text? :range? :command?) suggestion)
          ((kind . text) (cond
                          ((lsp-markup-content? insert-text)
                           (cons 'snippet (lsp:markup-content-value insert-text) ))
                          (t (cons 'text insert-text)))))

    ;; When range is provided, must replace the text of the range by the text
    ;; to insert
    (when range?
      (-let (((&RangeToPoint :start :end) range?))
        (when (/= start end)
          (delete-region start end))))

    ;; Insert suggestion
    (insert text)

    ;; Untested: snippet support
    (when (eq kind 'snippet)
      (lsp--expand-snippet (buffer-substring start-point (point))
                           start-point
                           (point)))

    ;; Post command
    (when command?
      (lsp--execute-command command?))

    ;; hooks
    (run-hook-with-args-until-failure 'lsp-inline-completion-accepted-hook text)))

(defun lsp-inline-completion-cancel ()
  "Close the suggestion overlay"
  (interactive)
  (unless (lsp--inline-completion-overlay-visible)
    (error "Not showing suggestions"))

  (lsp--inline-completion-clear-overlay))

(defun lsp-inline-completion-next ()
  (interactive)
  (unless (lsp--inline-completion-overlay-visible)
    (error "Not showing suggestions"))
  (setq lsp--inline-completion-current
        (mod (1+ lsp--inline-completion-current)
             (length lsp--inline-completions)))

  (lsp--inline-completion-show))

(defun lsp-inline-completion-prev ()
  (interactive)
  (unless (lsp--inline-completion-overlay-visible)
    (error "Not showing suggestions"))
  (setq lsp--inline-completion-current
        (mod (1- lsp--inline-completion-current)
             (length lsp--inline-completions)))

  (lsp--inline-completion-show))

;;;###autoload
(defun lsp-inline-completion (&optional implicit)
  (interactive)
  (unwind-protect
      (progn
        (run-hooks 'lsp-before-inline-completion-hook)

        (-when-let* ((trigger-kind (if implicit
                                       lsp--inline-completion-trigger-automatic
                                     lsp--inline-completion-trigger-invoked))
                     (args (plist-put (lsp--text-document-position-params)
                                      :context (ht ("triggerKind"  trigger-kind))))
                     (resp (lsp-request-while-no-input "textDocument/inlineCompletion" args))
                     ;; TODO: Maybe declare an interface for this command?
                     (items (cond
                             ((lsp-inline-completion-list? resp) (lsp:inline-completion-list-items resp))
                             (t resp))))
          (if (> (length items) 0)
              (progn
                (setq lsp--inline-completions items)
                (setq lsp--inline-completion-current 0)
                (lsp--inline-completion-show))

            (message "No Suggestions!"))))

    ;; Clean-up
    (run-hooks 'lsp-after-inline-completion-hook)))

(provide 'lsp-inline-completions)
