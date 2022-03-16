;; Remove annoying UI elements
(menu-bar-mode -1)
(scroll-bar-mode -1)
(tool-bar-mode -1)

;; Make minibuffer history persist across sessions
(savehist-mode 1)

;; Be able to easily edit the minor mode stuff that shows up in the modeline
(use-package delight
  :ensure t
  :demand t)

;; Set up IDO nicely
(require 'ido)
(ido-mode t)
(require 'flx-ido)
(flx-ido-mode t)
(global-set-key (kbd "C-x C-d") #'ido-dired) ;; Map "C-x C-d" to do same as "C-x d" which is otherwise awkward.

;; Use IDO for yes-or-no-p and y-or-n-p
(use-package ido-yes-or-no
  :ensure t
  :init (ido-yes-or-no-mode t))

(display-time-mode 1)

(use-package which-key
  :ensure t
  :demand t
  :delight
  :config (which-key-mode))

;; Disable audible bell
(setq ring-bell-function 'ignore)


;; Turn on show-trailing-whitespace, but disable on some modes
(setq-default show-trailing-whitespace t)
(dolist (hook '(term-mode-hook))
  (add-hook hook '(lambda () (setq show-trailing-whitespace nil))))

;; Smoothen scrolling
(setq scroll-margin 1
      scroll-conservatively 0
      scroll-up-aggressively 0.01
      scroll-down-aggressively 0.01)
(setq-default scroll-up-aggressively 0.01
              scroll-down-aggressively 0.01)
;; (use-package smooth-scrolling ;; Doesn't seem to work well with F*
;;   :ensure t
;;   :config
;;   (setq smooth-scroll-margin 1))
;; (smooth-scrolling-mode 1)

;; Display a nicer startup message :D
(defun display-startup-echo-area-message ()
  (message "Let the hacking begin!"))

;; Make scratch buffer be a fundamental-mode buffer
;; and give a better message (empty :D)
(setq initial-major-mode 'fundamental-mode)
(setq initial-scratch-message "")

;; Do a pulse whenever jumping to a line
(require 'pulse)
(defun goto-line-and-pulse ()
  "Equivalent to goto-line interactively except that it also does
a pulse"
  (interactive)
  (let* ((line
          (read-number (format "Goto line: ")
                       (list (line-number-at-pos)))))
    (goto-line line)
    (pulse-momentary-highlight-one-line (point))))
(global-set-key (kbd "M-g M-g") 'goto-line-and-pulse)
(global-set-key (kbd "M-g g") 'goto-line-and-pulse)


;; Turn on line numbers for all buffers
(if (version<= "26.0.50" emacs-version)
    (global-display-line-numbers-mode) ;; use faster version when available
  (global-linum-mode))

;; Disable linum-mode for incompatible cases
;;
;; NOTE: olivetti-mode does not work well with linum, but we don't
;; need to disable display-line-numbers-mode for it, so I've removed
;; it from here.
(dolist (hook '(pdf-view-mode-hook image-mode-hook))
  (add-hook hook '(lambda ()
                    (linum-mode 0)
                    (when (version<= "26.0.50" emacs-version)
                      (display-line-numbers-mode 0)))))


;; Theme flipper
(setq
 theme-flipper-list '(misterioso solarized-light solarized-dark adwaita)
 theme-flipper-index 0)
(defun theme-flip ()
  (interactive)
  (setq theme-flipper-index (+ 1 theme-flipper-index))
  (when (>= theme-flipper-index (length theme-flipper-list))
    (setq theme-flipper-index 0))
  (let ((this-theme (nth-value theme-flipper-index theme-flipper-list)))
    (load-theme this-theme t t)
    (dolist (theme theme-flipper-list)
      (when (not (eq theme this-theme))
        (disable-theme theme)))
    (enable-theme this-theme)))
(global-set-key (kbd "C-<f12>") 'theme-flip)

;; Ensure that copying from another program and then running a kill
;; command in emacs doesn't cause things to disappear from the
;; clipboard
(setq save-interprogram-paste-before-kill t)

;; Make sure the mouse yanking pastes at point instead of at click
(setq mouse-yank-at-point t)

;; Be able to move between buffers more easily, using M-up, M-down,
;; M-left, M-right.
(require 'framemove)
(windmove-default-keybindings 'meta)
(setq framemove-hook-into-windmove t)

(use-package buffer-move
  :ensure t
  :bind
  ("<M-S-up>" . buf-move-up)
  ("<M-S-down>" . buf-move-down)
  ("<M-S-left>" . buf-move-left)
  ("<M-S-right>" . buf-move-right))


;; Always have column number mode on
(column-number-mode 1)

;; Add the doom modeline
;; If fonts don't work, use "M-x all-the-icons-install-fonts"
(use-package doom-modeline
  :ensure t
  :hook (after-init . doom-modeline-mode)
  :custom-face (doom-modeline-info ((t (:inherit bold))))
  :config
  (setq doom-modeline-buffer-file-name-style 'buffer-name)
  (setq doom-modeline-major-mode-icon nil)
  (setq doom-modeline-buffer-encoding nil)
  (setq doom-modeline-vcs-max-length 40))

;; Introduce C-M-= and C-M-- for changing the font size all across emacs.
(use-package default-text-scale
  :ensure t
  :demand t
  :config (default-text-scale-mode))

(provide 'f0xtr0t-gui)