;;; org-now.el --- Conveniently show current tasks in a sidebar  -*- lexical-binding: t; -*-

;; Author: Adam Porter <adam@alphapapa.net>
;; URL: http://github.com/alphapapa/org-now
;; Version: 0.1-pre
;; Package-Requires: ((emacs "26.1") (dash))
;; Keywords: org

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This package provides commands to conveniently show Org headings in a sidebar
;; window while you're working on them.  A heading in one of your Org files is
;; defined as the "now" heading, and other headings are refiled to it with one
;; command, and back to their original location with another.

;; The sidebar window is an indirect buffer created with
;; `org-tree-to-indirect-buffer', so you can work in it as you would a normal
;; buffer.  Being a special Emacs side window, it's persistent, resisting being
;; closed by accident by window management commands.

;; Note that this package adds Org UUIDs to entries in property drawers when
;; they are refiled, to ensure they are tracked properly while they're being
;; moved.

;;;; Installation

;;;;; MELPA

;; If you installed from MELPA, you're done.

;;;;; Manual

;; Install these required packages:

;; + dash

;; Then put this file in your load-path, and put this in your init
;; file:

;; (require 'org-now)

;;;; Usage

;; 1.  Run the command `org-now' to show the sidebar.  You'll be prompted to
;;     configure the `org-now-location' setting to point to a heading in one of your
;;     Org files where you want to temporarily refile "now" tasks.
;; 2.  Refile tasks to the "now" buffer with the command `org-now-refile-to-now.'
;; 3.  Move tasks back to their original location with the command
;;     `org-now-refile-to-previous-location.'

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Code:

;;;; Requirements

(require 'org)

(require 'dash)

;;;; Customization

(defgroup org-now nil
  "Settings for `org-now'."
  :link '(url-link "http://github.com/alphapapa/org-now")
  :group 'org)

(defcustom org-now-location nil
  "Location of the \"Now\" entry.
A valid Org outline path list, starting with filename.  Each
subsequent string should be a heading in the outline hierarchy."
  ;; MAYBE: This could also be a UUID, but that might cause Org to spend time
  ;; opening buffers looking for it.
  :type '(repeat string))

(defcustom org-now-window-side 'right
  "Which side to show the sidebar on."
  :type '(choice (const :tag "Left" left)
                 (const :tag "Right" right)))

(defcustom org-now-default-cycle-level 2
  "Org heading level to expand to in side buffer by default."
  :type 'integer)

;;;; Variables

(defvar org-now-buffer nil
  "The \"now\" buffer.")

;;;; Functions

;;;;; Commands

;;;###autoload
(defun org-now ()
  "Display \"now\" buffer."
  (interactive)
  (display-buffer-in-side-window
   (org-now--buffer)
   (list (cons 'side org-now-window-side)
         (cons 'slot 0)
         (cons 'window-parameters (list (cons 'no-delete-other-windows t))))))

;;;###autoload
(defun org-now-refile-to-now ()
  "Refile current entry to the `org-now' entry."
  (interactive)
  (unless org-now-location
    (customize-variable 'org-now-location)
    (user-error "Please configure `org-now-location'"))
  (when-let* ((target-marker (org-find-olp org-now-location))
              (rfloc (list nil (car org-now-location) nil target-marker))
              (previous-location (or (save-excursion
                                       (when (org-up-heading-safe)
                                         (org-id-get nil 'create)))
                                     (prin1-to-string (cons (buffer-file-name)
                                                            (org-get-outline-path 'with-self)))))
              ;; Reverse note order so the heading will be refiled at the top of the node.  When it's
              ;; refiled at the bottom, existing indirect buffers will not show it.
              (org-reverse-note-order t))
    (org-set-property "refiled_from" previous-location)
    (org-refile nil nil rfloc)
    (unless (get-buffer-window (org-now--buffer) (selected-frame))
      ;; If the buffer is not already open and visible, call `org-now', but only
      ;; after refiling the entry, so that if it's the only child of the "now"
      ;; heading, the new, indirect buffer will contain it.
      (org-now))
    (with-current-buffer org-now-buffer
      ;; Re-cycle display levels in side buffer.
      (org-global-cycle org-now-default-cycle-level))))

;;;###autoload
(defun org-now-refile-to-previous-location ()
  "Refile current entry to its previous location.
Requires the entry to have a \"refiled_from\" property whose
value is a `read'able outline path list or an Org UUID.  The
property is removed after refiling."
  (interactive)
  (-if-let* ((payload-id (org-id-get nil 'create))
             (refiled-from (org-entry-get (point) "refiled_from"))
             ((target-file . target-pos) (cond ((string-prefix-p "(" refiled-from)
                                                (--> (org-find-olp (read refiled-from))
                                                     (cons (car it) it)))
                                               ((org-id-find refiled-from)))))
      ;; Be extra careful and ensure we don't try to refile to an invalid location.
      (when (and target-file target-pos
                 (org-refile nil nil (list nil target-file nil target-pos)))
        ;; Refile complete: remove refiled_from property
        (with-current-buffer (find-buffer-visiting target-file)
          ;; Copied from `org-find-property'.  Unlike it, we don't go to
          ;; `point-min', because the entry will be after point.
          (save-excursion
            (let ((case-fold-search t))
              (cl-loop while (re-search-forward (org-re-property "ID" nil nil payload-id) nil t)
                       when (org-at-property-p)
                       ;; TODO: Delete drawer if it's empty, using `org-remove-empty-drawer-at'.
                       do (org-delete-property "refiled_from")
                       and return t)))))
    (user-error "Heading has no previous location")))

;;;;; Support

(defun org-now--buffer ()
  "Return the \"now\" buffer, creating it if necessary."
  (or (when (and org-now-buffer
                 (buffer-live-p org-now-buffer))
        org-now-buffer)
      (save-window-excursion
        (org-with-point-at (org-find-olp org-now-location)
          (org-tree-to-indirect-buffer)
          (toggle-truncate-lines 1)
          (org-global-cycle 2)
          (rename-buffer "*org-now*")
          (setq org-now-buffer (current-buffer))))))

;;;; Footer

(provide 'org-now)

;;; org-now.el ends here