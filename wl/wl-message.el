;;; wl-message.el -- Message displaying modules for Wanderlust.

;; Copyright (C) 1998,1999,2000 Yuuichi Teranishi <teranisi@gohome.org>

;; Author: Yuuichi Teranishi <teranisi@gohome.org>
;; Keywords: mail, net news

;; This file is part of Wanderlust (Yet Another Message Interface on Emacsen).

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.
;;

;;; Commentary:
;; 

;;; Code:
;; 

(require 'wl-vars)
(require 'wl-highlight)
(require 'elmo)
(require 'elmo-mime) ; XXX should modify for tm.

(eval-when-compile
  (if wl-use-semi
      (progn
	(require 'wl-mime)
	(require 'mime-view))
    (require 'tm-wl))
  (defalias-maybe 'event-window 'ignore)
  (defalias-maybe 'posn-window 'ignore)
  (defalias-maybe 'event-start 'ignore)
  (defalias-maybe 'mime-open-entity 'ignore))

(defconst wl-message-buffer-prefetch-idle-time
  (if (featurep 'lisp-float-type) (/ (float 1) (float 5)) 1))
(defvar wl-message-buffer-prefetch-get-next-func
  'wl-summary-default-get-next-msg)

(defvar wl-message-buffer-prefetch-folder-type-list t)

(defvar wl-message-buffer-prefetch-debug
  t)
(defvar wl-message-buffer-prefetch-threshold
  30000)

(defvar wl-message-buffer nil) ; message buffer.

(defvar wl-message-buffer-cur-summary-buffer nil)
(defvar wl-message-buffer-cur-folder nil)
(defvar wl-message-buffer-cur-number nil)
(defvar wl-message-buffer-cur-flag nil)
(defvar wl-message-buffer-cur-summary-buffer nil)
(defvar wl-message-buffer-original-buffer nil) ; original buffer.

(make-variable-buffer-local 'wl-message-buffer-cur-folder)
(make-variable-buffer-local 'wl-message-buffer-cur-number)
(make-variable-buffer-local 'wl-message-buffer-cur-flag)
(make-variable-buffer-local 'wl-message-buffer-cur-summary-buffer)
(make-variable-buffer-local 'wl-message-buffer-original-buffer)

(defvar wl-fixed-window-configuration nil)

(defvar wl-message-buffer-cache-size 10) ; At least 1.

;;; Message buffer cache.

(defvar wl-message-buffer-cache nil
  "Message cache.  (old ... new) order alist.
With association ((\"folder\" message \"message-id\") . cache-buffer).")

(defmacro wl-message-buffer-cache-buffer-get (entry)
  (` (cdr (, entry))))

(defmacro wl-message-buffer-cache-folder-get (entry)
  (` (car (car (, entry)))))

(defmacro wl-message-buffer-cache-message-get (entry)
  (` (cdr (car (, entry)))))

(defmacro wl-message-buffer-cache-entry-make (key buf)
  (` (cons (, key) (, buf))))

(defmacro wl-message-buffer-cache-hit (key)
  "Return value assosiated with key."
  (` (wl-message-buffer-cache-buffer-get
      (assoc (, key) wl-message-buffer-cache))))

(defun wl-message-buffer-cache-sort (entry)
  "Move ENTRY to the top of `wl-message-buffer-cache'."
  (setq wl-message-buffer-cache
	(cons entry (delete entry wl-message-buffer-cache))))
;  (let* ((pointer (cons nil wl-message-buffer-cache))
;	 (top pointer))
;    (while (cdr pointer)
;      (if (equal (car (cdr pointer)) entry)
;	  (setcdr pointer (cdr (cdr pointer)))
;	(setq pointer (cdr pointer))))
;    (setcdr pointer (list entry))
;    (setq wl-message-buffer-cache (cdr top))))

(defconst wl-message-buffer-cache-name    " *WL:Message*")
(defconst wl-original-message-buffer-name " *Original*")

(defun wl-original-message-mode ()
  "A major mode for original message buffer."
  (setq major-mode 'wl-original-message-mode)
  (setq buffer-read-only t)
  (elmo-set-buffer-multibyte nil)
  (setq mode-name "Wanderlust original message"))

(defun wl-original-message-buffer-get (name)
  "Get original message buffer for NAME.
If original message buffer already exists, it is re-used."
  (let* ((name (concat wl-original-message-buffer-name name))
	 (buffer (get-buffer name)))
    (unless (and buffer (buffer-live-p buffer))
      (with-current-buffer (setq buffer (get-buffer-create name))
	(wl-original-message-mode)))
    buffer))

(defun wl-message-buffer-create ()
  "Create a new message buffer."
  (let* ((buffer (generate-new-buffer wl-message-buffer-cache-name))
	 (name (buffer-name buffer)))
    (with-current-buffer buffer
      (setq wl-message-buffer-original-buffer
	    (wl-original-message-buffer-get name)))
    buffer))

(defun wl-message-buffer-cache-add (key)
  "Add (KEY . buf) to the top of `wl-message-buffer-cache'.
Return its cache buffer."
  (let ((len (length wl-message-buffer-cache))
	(buf nil))
    (if (< len wl-message-buffer-cache-size)
	(setq buf (wl-message-buffer-create))
      (setq buf (wl-message-buffer-cache-buffer-get
		 (nth (1- len) wl-message-buffer-cache)))
      (setcdr (nthcdr (- len 2) wl-message-buffer-cache) nil))
    (setq wl-message-buffer-cache
	  (cons (wl-message-buffer-cache-entry-make key buf)
		wl-message-buffer-cache))
    buf))

(defun wl-message-buffer-cache-delete (&optional key)
  "Delete the most recent cache entry"
  (if key
      (setq wl-message-buffer-cache
	    (delq (assoc key wl-message-buffer-cache)
		  wl-message-buffer-cache))
    (let ((buf (wl-message-buffer-cache-buffer-get
		(car wl-message-buffer-cache))))
      (setq wl-message-buffer-cache
	    (nconc (cdr wl-message-buffer-cache)
		   (list (wl-message-buffer-cache-entry-make nil buf)))))))

(defun wl-message-buffer-cache-clean-up ()
  "A function to flush all decoded messages in cache list."
  (interactive)
  (if (and (eq major-mode 'wl-summary-mode)
	   wl-message-buffer
	   (get-buffer-window wl-message-buffer))
      (delete-window (get-buffer-window wl-message-buffer)))
  (wl-kill-buffers (regexp-quote wl-message-buffer-cache-name))
  (setq wl-message-buffer-cache nil))

;;; Message buffer handling from summary buffer.

(defun wl-message-buffer-window ()
  "Get message buffer window if any."
  (let* ((start-win (selected-window))
	 (cur-win start-win))
    (catch 'found
      (while (progn
	       (setq cur-win (next-window cur-win))
	       (with-current-buffer (window-buffer cur-win)
		 (if (or (eq major-mode 'wl-message-mode)
			 (eq major-mode 'mime-view-mode))
		     (throw 'found cur-win)))
	       (not (eq cur-win start-win)))))))

(defun wl-message-select-buffer (buffer)
  "Select BUFFER as a message buffer."
  (let ((window (get-buffer-window buffer))
	(sum (car wl-message-window-size))
	(mes (cdr wl-message-window-size))
	whi)
    (when (and window
	       (not (eq (save-excursion (set-buffer (window-buffer window))
					wl-message-buffer-cur-summary-buffer)
			(current-buffer))))
      (delete-window window)
      (run-hooks 'wl-message-window-deleted-hook)
      (setq window nil))
    (if window
	(select-window window)
      (when wl-fixed-window-configuration
        (delete-other-windows)
        (and wl-stay-folder-window
             (wl-summary-toggle-disp-folder)))
      ;; There's no buffer window. Search for message window and snatch it.
      (if (setq window (wl-message-buffer-window))
	  (select-window window)
	(setq whi (1- (window-height)))
	(if mes
	    (progn
	      (let ((total (+ sum mes)))
		(setq sum (max window-min-height (/ (* whi sum) total)))
		(setq mes (max window-min-height (/ (* whi mes) total))))
	      (if (< whi (+ sum mes))
		  (enlarge-window (- (+ sum mes) whi)))))
	(split-window (get-buffer-window (current-buffer)) sum)
	(other-window 1)))
    (switch-to-buffer buffer)))

(defun wl-message-narrow-to-page (&optional arg)
  "Narrow to page.
If ARG is specified, narrow to ARGth page."
  (interactive "P")
  (setq arg (if arg (prefix-numeric-value arg) 0))
  (save-excursion
    (condition-case ()
        (forward-page -1)               ; Beginning of current page.
      (beginning-of-buffer
       (goto-char (point-min))))
    (forward-char 1)  ; for compatibility with emacs-19.28 and emacs-19.29
    (widen)
    (cond
     ((> arg 0) (forward-page arg))
     ((< arg 0) (forward-page (1- arg))))
    (forward-page)
    (if wl-break-pages
	(narrow-to-region (point)
			  (progn
			    (forward-page -1)
			    (if (and (eolp) (not (bobp)))
				(forward-line))
			    (point))))))

(defun wl-message-prev-page (&optional lines)
  "Scroll down current message by LINES.
Returns non-nil if top of message."
  (interactive)
  (if (buffer-live-p wl-message-buffer)
      (let ((cur-buf (current-buffer))
	    top)
	(wl-message-select-buffer wl-message-buffer)
	(move-to-window-line 0)
	(if (and wl-break-pages
		 (bobp)
		 (not (save-restriction (widen) (bobp))))
	    (progn
	      (wl-message-narrow-to-page -1)
	      (goto-char (point-max))
	      (recenter))
	  (if (not (bobp))
	      (condition-case nil
		  (scroll-down lines)
		(error))
	    (setq top t)))
	(select-window (get-buffer-window cur-buf))
	top)))

(defun wl-message-next-page (&optional lines)
  "Scroll up current message by LINES.
Returns non-nil if bottom of message."
  (interactive)
  (if (buffer-live-p wl-message-buffer)
      (let ((cur-buf (current-buffer))
	    bottom)
	(wl-message-select-buffer wl-message-buffer)
	(move-to-window-line -1)
	(if (save-excursion
	      (end-of-line)
	      (and (pos-visible-in-window-p)
		   (eobp)))
	    (if (or (null wl-break-pages)
		    (save-excursion
		      (save-restriction
			(widen) (forward-line) (eobp))))
		(setq bottom t)
	      (wl-message-narrow-to-page 1)
	      (setq bottom nil))
	  (condition-case ()
	      (static-if (boundp 'window-pixel-scroll-increment)
		  ;; XEmacs 21.2.20 and later.
		  (let (window-pixel-scroll-increment)
		    (scroll-up lines))
		(scroll-up lines))	      
	    (end-of-buffer
	     (goto-char (point-max))))
	  (setq bottom nil))
	(select-window (get-buffer-window cur-buf))
	bottom)))


(defun wl-message-follow-current-entity (buffer)
  "Follow to current message."
  (wl-draft-reply (wl-message-get-original-buffer)
		  nil wl-message-buffer-cur-summary-buffer) ; reply to all
  (let ((mail-reply-buffer buffer))
    (wl-draft-yank-from-mail-reply-buffer nil)))

;; 

(defun wl-message-mode ()
  "A major mode for message displaying."
  (interactive)
  (setq major-mode 'wl-message-mode)
  (setq buffer-read-only t)
  (setq mode-name "Message"))

(defun wl-message-exit ()
  "Move to summary buffer."
  (interactive)
  (let (summary-buf summary-win)
    (if (setq summary-buf wl-message-buffer-cur-summary-buffer)
	(if (setq summary-win (get-buffer-window summary-buf))
	    (select-window summary-win)
	  (switch-to-buffer summary-buf)
	  (wl-message-select-buffer wl-message-buffer)
	  (select-window (get-buffer-window summary-buf))))
    (run-hooks 'wl-message-exit-hook)))

(defun wl-message-toggle-disp-summary ()
  (interactive)
  (let ((summary-buf (get-buffer wl-message-buffer-cur-summary-buffer))
	summary-win)
    (if (and summary-buf
	     (buffer-live-p summary-buf))
	(if (setq summary-win (get-buffer-window summary-buf))
	    (delete-window summary-win)
	  (switch-to-buffer summary-buf)
	  (wl-message-select-buffer wl-message-buffer))
      (wl-summary-goto-folder-subr wl-message-buffer-cur-folder 'no-sync
				   nil nil t)
  					; no summary-buf
      (let ((sum-buf (current-buffer)))
	(wl-message-select-buffer wl-message-buffer)
	(setq wl-message-buffer-cur-summary-buffer sum-buf)))))

(defun wl-message-get-original-buffer ()
  "Get original buffer for current message buffer."
  wl-message-buffer-original-buffer)

(defun wl-message-redisplay (folder number flag &optional force-reload)
  (let* ((default-mime-charset wl-mime-charset)
	 (buffer-read-only nil)
	 (summary-buf (current-buffer))
	 message-buf
	 strategy entity
	 cache-used
	 header-end real-fld-num summary-win)
    (setq buffer-read-only nil)
    (setq cache-used (wl-message-buffer-display
		      folder number flag force-reload))
    (setq wl-message-buffer (car cache-used))
    (setq message-buf wl-message-buffer)
    (wl-message-select-buffer wl-message-buffer)

    (set-buffer message-buf)
    (setq buffer-read-only nil)
    (setq wl-message-buffer-cur-summary-buffer summary-buf)
    (setq wl-message-buffer-cur-folder (elmo-folder-name-internal folder))
    (setq wl-message-buffer-cur-number number)
    (wl-message-overload-functions)
    (setq mode-line-buffer-identification
	  (format "Wanderlust: << %s / %s >>"
		  (if (memq 'modeline wl-use-folder-petname)
		      (wl-folder-get-petname (elmo-folder-name-internal
					      folder))
		    (elmo-folder-name-internal folder)) number))
    ;; highlight body
;    (when wl-highlight-body-too
;      (wl-highlight-body))
    (condition-case ()
	(wl-message-narrow-to-page)
      (error nil)); ignore errors.
    (setq cache-used (cdr cache-used))
    (goto-char (point-min))
    (unwind-protect
	(save-excursion
	  (run-hooks 'wl-message-redisplay-hook))
      ;; go back to summary mode
      (set-buffer-modified-p nil)
      (setq buffer-read-only t)
      (set-buffer summary-buf)
      (setq summary-win (get-buffer-window summary-buf))
      (if (window-live-p summary-win)
	  (select-window summary-win)))
    cache-used))

;; Use message buffer cache.
(defun wl-message-buffer-display (folder number flag
					 &optional force-reload unread)
  (let* ((msg-id (elmo-message-field folder number 'message-id))
	 (fname (elmo-folder-name-internal folder))
	 (hit (wl-message-buffer-cache-hit (list fname number msg-id)))
	 (read nil)
	 cache-used)
    (when (and hit (not (buffer-live-p hit)))
      (wl-message-buffer-cache-delete (list fname number msg-id))
      (setq hit nil))
    (if hit
	(progn
	  ;; move hit to the top.
	  (wl-message-buffer-cache-sort
	   (wl-message-buffer-cache-entry-make (list fname number msg-id) hit))
	  ;; buffer cache is used.
	  (setq cache-used t)
	  (with-current-buffer hit
	    (unless (eq wl-message-buffer-cur-flag flag)
	      (setq read t))))
      ;; delete tail and add new to the top.
      (setq hit (wl-message-buffer-cache-add (list fname number msg-id)))
      (setq read t))
    (if (or force-reload read)
	(condition-case err
	    (save-excursion
	      (set-buffer hit)
	      (setq
	       cache-used
	       (wl-message-display-internal folder number flag
					    force-reload unread))
	      (setq wl-message-buffer-cur-flag flag))
	  (quit
	   (wl-message-buffer-cache-delete)
	   (error "Display message %s/%s is quitted" fname number))
	  (error
	   (wl-message-buffer-cache-delete)
	   (signal (car err) (cdr err))
	   nil))) ;; will not be used
    (cons hit cache-used)))

(defun wl-message-display-internal (folder number flag
					   &optional force-reload unread)
  (let ((elmo-message-ignored-field-list
	 (if (eq flag 'all-header)
	     nil
	   wl-message-ignored-field-list))
	(elmo-message-visible-field-list wl-message-visible-field-list)
	(elmo-message-sorted-field-list wl-message-sort-field-list)
	(elmo-fetch-threshold wl-fetch-confirm-threshold))
    (prog1 
	(if (eq flag 'as-is)
	    (let (wl-highlight-x-face-func)
	      (elmo-mime-display-as-is folder number
				       (current-buffer)
				       (wl-message-get-original-buffer)
				       'wl-original-message-mode
				       force-reload
				       unread))
	  (elmo-mime-message-display folder number
				     (current-buffer)
				     (wl-message-get-original-buffer)
				     'wl-original-message-mode
				     force-reload
				     unread))
      (setq buffer-read-only t))))

(defsubst wl-message-buffer-prefetch-p (folder &optional number)
  (cond 
   ((eq wl-message-buffer-prefetch-folder-type-list t)
    t)
   ((and number wl-message-buffer-prefetch-folder-type-list)
    (memq (elmo-folder-type-internal
	   (elmo-message-folder folder number))
	  wl-message-buffer-prefetch-folder-type-list))
   (wl-message-buffer-prefetch-folder-type-list
    (let ((list wl-message-buffer-prefetch-folder-type-list)
	  type)
      (catch 'done
	(while (setq type (pop list))
	  (if (elmo-folder-contains-type folder type)
	      (throw 'done t))))))
   ((consp wl-message-buffer-prefetch-folder-type-list)
    (wl-string-match-member (elmo-folder-name-internal folder)
			    wl-message-buffer-prefetch-folder-type-list))
   (t wl-message-buffer-prefetch-folder-type-list)))

(defun wl-message-buffer-prefetch-next (folder number &optional
					       summary charset)
  (if (wl-message-buffer-prefetch-p folder)
      (with-current-buffer (or summary (get-buffer wl-summary-buffer-name))
	(let* ((next (funcall wl-message-buffer-prefetch-get-next-func
			      number)))
	  (when (and next (wl-message-buffer-prefetch-p folder next))
	    (if (not (fboundp 'run-with-idle-timer))
		(when (sit-for wl-message-buffer-prefetch-idle-time)
		  (wl-message-buffer-prefetch folder next summary charset))
	      (run-with-idle-timer
	       wl-message-buffer-prefetch-idle-time
	       nil
	       'wl-message-buffer-prefetch folder next summary charset)
	      (sit-for 0)))))))

(defun wl-message-buffer-prefetch (folder number summary charset)
  (when (buffer-live-p summary)
    (save-excursion
      (set-buffer summary)
      (when (string= (elmo-folder-name-internal folder)
		     (wl-summary-buffer-folder-name))
	(let ((message-id (elmo-message-field folder number 'message-id))
	      (wl-mime-charset      charset)
	      (default-mime-charset charset)
	      result time1 time2 sec micro)
	  (if (not (wl-message-buffer-cache-hit (list folder
						      number message-id)))
	      (let* ((size (elmo-message-field folder number 'size)))
		(when (or (elmo-message-file-p folder number)
			  (not 
			   (and (integerp size)
				wl-message-buffer-prefetch-threshold
				(>= size
				    wl-message-buffer-prefetch-threshold))))
		  ;;(not (elmo-file-cache-exists-p message-id)))))
		  (when wl-message-buffer-prefetch-debug
		    (setq time1 (current-time))
		    (message "Prefetching %d..." number))
		  (setq result (wl-message-buffer-display folder number
							  'mime nil 'unread))
		  (when wl-message-buffer-prefetch-debug
		    (setq time2 (current-time))
		    (setq sec  (- (nth 1 time2)(nth 1 time1)))
		    (setq micro (- (nth 2 time2)(nth 2 time1)))
		    (setq micro (+ micro (* 1000000 sec)))
		    (message "Prefetching %d...done(%f msec)."
			     number
			     (/ micro 1000.0)))))))))))

(defvar wl-message-button-map (make-sparse-keymap))

(defun wl-message-add-button (from to function &optional data)
  "Create a button between FROM and TO with callback FUNCTION and DATA."
  (add-text-properties
   from to
   (nconc (list 'wl-message-button-callback function)
	  (if data
	      (list 'wl-message-button-data data))))
  (let ((ov (make-overlay from to)))
    (overlay-put ov 'mouse-face 'highlight)
    (overlay-put ov 'local-map wl-message-button-map)
    (overlay-put ov 'evaporate t)))

(defun wl-message-button-dispatcher (event)
  "Select the button under point."
  (interactive "@e")
  (mouse-set-point event)
  (let ((callback (get-text-property (point) 'wl-message-button-callback))
	(data (get-text-property (point) 'wl-message-button-data)))
    (if callback
	(funcall callback data)
      (wl-message-button-dispatcher-internal event))))

(defun wl-message-button-refer-article (data)
  "Read article specified by Message-ID DATA at point."
  (switch-to-buffer-other-window
   wl-message-buffer-cur-summary-buffer)
  (if (wl-summary-jump-to-msg-by-message-id data)
      (wl-summary-redisplay)))

(defun wl-message-refer-article-or-url (e)
  "Read article specified by message-id around point.
If failed, attempt to execute button-dispatcher."
  (interactive "e")
  (let ((window (get-buffer-window (current-buffer)))
	mouse-window point beg end msg-id)
    (unwind-protect
	(progn
	  (mouse-set-point e)
	  (setq mouse-window (get-buffer-window (current-buffer)))
	  (setq point (point))
	  (setq beg (save-excursion (beginning-of-line) (point)))
	  (setq end (save-excursion (end-of-line) (point)))
	  (search-forward ">" end t)      ;Move point to end of "<....>".
	  (if (and (re-search-backward "\\(<[^<> \t\n]+@[^<> \t\n]+>\\)"
				       beg t)
		   (not (string-match "mailto:"
				      (setq msg-id (wl-match-buffer 1)))))
	      (progn
		(goto-char point)
		(switch-to-buffer-other-window
		 wl-message-buffer-cur-summary-buffer)
		(if (wl-summary-jump-to-msg-by-message-id msg-id)
		    (wl-summary-redisplay)))
	    (wl-message-button-dispatcher-internal e)))
      (if (eq mouse-window (get-buffer-window (current-buffer)))
	  (select-window window)))))

(defun wl-message-uu-substring (buf outbuf &optional first last)
  (save-excursion
    (set-buffer buf)
    (search-forward "\n\n")
    (let ((sp (point))
	  ep filename case-fold-search)
      (catch 'done
	(if first
	    (progn
	      (if (re-search-forward "^begin[ \t]+[0-9]+[ \t]+\\([^ ].*\\)" nil t)
		  (setq filename (buffer-substring (match-beginning 1)(match-end 1)))
		(throw 'done nil)))
	  (re-search-forward "^M.*$" nil t)) ; uuencoded string
	(beginning-of-line)
	(setq sp (point))
	(goto-char (point-max))
	(if last
	    (re-search-backward "^end" sp t)
	  (re-search-backward "^M.*$" sp t)) ; uuencoded string
	(forward-line 1)
	(setq ep (point))
	(set-buffer outbuf)
	(goto-char (point-max))
	(insert-buffer-substring buf sp ep)
	(set-buffer buf)
	filename))))

(require 'product)
(product-provide (provide 'wl-message) (require 'wl-version))

;;; wl-message.el ends here
