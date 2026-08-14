#!/usr/bin/env sbcl --script


;;; ----------------------------
;;; Core utilities
;;; ----------------------------

(defun die (format-string &rest args)
  (apply #'format *error-output* format-string args)
  (terpri *error-output*)
  (sb-ext:exit :code 1))

(defun run (shell-command)
  (format t "~&  ~A~%" shell-command)
  (let ((process (sb-ext:run-program
               "/bin/sh"
               (list "-c" shell-command)
               :input t
               :output *standard-output*
               :error *error-output*
               :search t)))
    (unless (zerop (sb-ext:process-exit-code process))
      (die "Command failed: ~A" shell-command))))

(defun prompt (text)
  (format t "~&~A" text)
  (force-output)
  (read-line))

(defun prompt-default (text default)
  (format t "~&~A [~A]: " text default)
  (force-output)
  (let* ((input (string-trim '(#\Space #\Tab) (read-line))))
    (if (string= input "") default input)))

(defun yes-p (text)
  (member (string-downcase (prompt text)) '("y" "yes") :test #'string=))

(defun require-config (config key)
  (let ((value (getf config key)))
    (unless value
      (die "Missing required config: ~A" key))
    value))

;;; ----------------------------
;;; Helpers
;;; ----------------------------

(defun sh-line (s format-string &rest args)
  (apply #'format s (concatenate 'string format-string "~%") args))

(defun sh-command (s format-string &rest args)
  (apply #'sh-line s format-string args))

(defun sh-symlink (s target link)
  (sh-line s "ln -sf ~A ~A" target link))

(defun sh-enable-service (s &rest services)
  (sh-line s "systemctl enable ~{~A~^ ~}" services))

(defun sh-write-file (s path &rest lines)
  (sh-line s "cat > ~A <<'EOF'" path)
  (dolist (line lines)
    (sh-line s "~A" line))
  (sh-line s "EOF"))

;;; ----------------------------
;;; Configuration structures
;;; ----------------------------

(defstruct disk-config
  root
  efi
  swap)

(defstruct system-config
  hostname
  locale
  keymap)

;;; ----------------------------
;;; Installer actions
;;; ----------------------------

(defun format-root (config)
  (run (format nil "mkfs.ext4 ~A"
               (require-config config :root))))

(defun format-efi (config)
  (run (format nil "mkfs.fat -F32 ~A"
               (require-config config :efi))))

(defun format-swap (config)
  (run (format nil "mkswap ~A"
               (require-config config :swap))))

(defun mount-root (config)
  (run (format nil "mount ~A /mnt"
               (require-config config :root))))

(defun mount-efi (config)
  (run "mkdir -p /mnt/boot")
  (run (format nil "mount -t vfat -o fmask=177,dmask=077 ~A /mnt/boot"
               (require-config config :efi))))

(defun ask-partitions (config)
  (format t "~&==> Disk configuration~%~%")

  (let ((root (prompt "Root partition (e.g. /dev/sda2): ")))
    (setf (getf config :root) root))

  (let ((efi (prompt "EFI partition (e.g. /dev/sda1): ")))
    (setf (getf config :efi) efi))
  config)

(defun ask-swap (config)
  (when (yes-p "Do you want to set up a swap partition? [y/N]: ")
    (setf (getf config :swap)
          (prompt "Enter swap partition (e.g. /dev/sda3): ")))
  config)

(defun build-config (config)
  (format t "~&==> System configuration (press Enter to accept defaults)~%~%")

  (setf (getf config :hostname)
        (prompt-default "Hostname" "archietype"))

  (setf (getf config :locale)
        (prompt-default "Locale" "en_US.UTF-8"))

  (setf (getf config :keymap)
        (prompt-default "Keymap" "us"))
  config)

(defun confirm-config (config)
  (format t "~&~%==> Final configuration~%~%")

  (format t "Disk:~%")
  (format t "  Root: ~A~%" (getf config :root))

  (format t "  EFI:  ~A~%" (getf config :efi))

  (when (getf config :swap)
    (format t "  Swap: ~A~%" (getf config :swap)))

  (format t "~%System:~%")
  (format t "  Hostname: ~A~%" (getf config :hostname))
  (format t "  Locale:   ~A~%" (getf config :locale))
  (format t "  Keymap:   ~A~%" (getf config :keymap))

  (format t "~%")

  (if (yes-p "Continue? [Y/n]: ")
      config
      (progn
        (format t "~&Restarting configuration.~%")
        (confirm-config
         (ask-swap
          (build-config
           (ask-partitions '())))))))
	
(defun ask-format-options (config)
  (setf (getf config :format-root)
        (yes-p "Format root partition? [y/N]: "))

  (setf (getf config :format-efi)
        (yes-p "Format EFI partition? [y/N]: "))

  (when (getf config :swap)
    (setf (getf config :format-swap)
          (yes-p "Format swap partition? [y/N]: ")))
  config)

(defun enable-swap (config)
  (let ((swap (getf config :swap)))
    (when swap
      (run (format nil "swapon ~A" swap)))))

(defun install-base ()
  (run "pacstrap /mnt base linux"))

(defun generate-fstab ()
  (run "genfstab -U /mnt >> /mnt/etc/fstab"))

(defun configure-chroot (config)
  (with-open-file (s "/mnt/root/archietype-chroot.sh"
                     :direction :output
                     :if-exists :supersede)
    (sh-line s "#!/bin/sh")
    (sh-line s "set -eux")
    
    (setup-time s)
    (setup-localization s config)
    (setup-network s config)
    
    (sh-command s "echo 'Set root password:'")
    (sh-command s "passwd")

    (setup-bootloader s)
    
    (sh-command s "mkinitcpio -P"))

  (run "chmod +x /mnt/root/archietype-chroot.sh")
  (run "arch-chroot -S /mnt /root/archietype-chroot.sh")
	config)

(defun setup-time (s)
  (sh-symlink s "/usr/share/zoneinfo/UTC" "/etc/localtime")
  (sh-command s "hwclock --systohc")
  (sh-enable-service s "systemd-timesyncd"))

(defun setup-localization (s config)
  (sh-line s "echo '~A UTF-8' >> /etc/locale.gen"
	  (getf config :locale))
  (sh-command s "locale-gen")
  (sh-line s "echo 'LANG=~A' > /etc/locale.conf"
	  (getf config :locale))
  (sh-line s "echo 'KEYMAP=~A' > /etc/vconsole.conf"
	  (getf config :keymap)))

(defun setup-network (s config)
  (format s "echo '~A' > /etc/hostname~%"
        (getf config :hostname))
  (sh-symlink s "/usr/lib/systemd/network/89-ethernet.network.example" "/etc/systemd/network/89-ethernet.network")
  (sh-enable-service s "systemd-networkd systemd-resolved"))

(defun setup-bootloader (s)
  (sh-command s "bootctl install")

  (sh-command s "ROOT_UUID=$(findmnt -no UUID /)")
  (sh-command s "printf '%s\\n' \"root=UUID=$ROOT_UUID rw\" > /etc/kernel/cmdline")
  
  (sh-write-file 
  s
  "/etc/mkinitcpio.d/linux.preset"
  "# mkinitcpio preset file for the 'linux' package"
  ""
  "ALL_kver=\"/boot/vmlinuz-linux\""
  ""
  "PRESETS=('default' 'fallback')"
  ""
  "default_uki=\"/boot/EFI/Linux/arch-linux.efi\""
  "default_options=\"--splash /usr/share/systemd/bootctl/splash-arch.bmp\""
  ""
  "fallback_uki=\"/boot/EFI/Linux/arch-linux-fallback.efi\""
  "fallback_options=\"-S autodetect\""))

;;; ----------------------------
;;; Step DSL
;;; ----------------------------

(shadow 'step)
(defmacro step (id (&key desc when) &body body)
  `(list :id ',id
         :name ,(or desc (symbol-name id))
         :when ,(if when
                    `(lambda (config) ,when)
                    `(lambda (config) t))
         :fn (lambda (config)
               ,@body)))

;;; ----------------------------
;;; Step predicates
;;; ----------------------------

(defun wants-format-root (config)
  (getf config :format-root))

(defun wants-format-efi (config)
  (getf config :format-efi))

(defun wants-format-swap (config)
  (and (getf config :swap)
       (getf config :format-swap)))

(defun has-swap (config)
  (getf config :swap))

;;; ----------------------------
;;; Step definitions
;;; ----------------------------

(defparameter *steps*
  (list

   (step config
     (:desc "Disk + system config")
     (setf config (ask-partitions config))
     (setf config (build-config config))
     (setf config (ask-swap config))
     (setf config (confirm-config config))
     (ask-format-options config))

   (step format-root
     (:desc "Format root"
      :when (wants-format-root config))
     (format-root config))

   (step format-efi
     (:desc "Format EFI"
      :when (wants-format-efi config))
     (format-efi config))

   (step format-swap
     (:desc "Format swap"
      :when (wants-format-swap config))
     (format-swap config))

   (step mount-root
     (:desc "Mount root")
     (mount-root config))

   (step mount-efi
     (:desc "Mount EFI")
     (mount-efi config))

   (step enable-swap
     (:desc "Enable swap"
      :when (has-swap config))
     (enable-swap config))

   (step install-base
     (:desc "Install base")
     (install-base))

   (step genfstab
     (:desc "Generate fstab")
     (generate-fstab))

   (step configure
     (:desc "Configure system")
     (configure-chroot config))))

;;; ----------------------------
;;; Step engine
;;; ----------------------------

;;; Core execution engine.
;;; Steps are executed sequentially, threading a config plist.
;;; On failure, the user may retry, skip, or abort.
(defun run-step (step config)
  (let ((name (getf step :name))
        (fn   (getf step :fn))
        (cond (getf step :when)))

    (format t "~&==> [~A] ~A~%"
        (getf step :id)
        name)

    (if (and cond (not (funcall cond config)))
        (progn
          (format t "Skipping (condition not met)~%")
          config)

        (loop
          (handler-case
              (let ((result (funcall fn config)))
				   (return (or result config)))

            (error (e)
              (format t "~&Error: ~A~%" e)
              (format t "[r]etry  [s]kip  [q]uit: ")
              (let ((choice (read-line)))
                (cond
                  ((string-equal choice "r") nil)
                  ((string-equal choice "s") (return config))
                  ((string-equal choice "q") (quit 1))
                  (t (format t "Invalid option.~%"))))))))))

(defun run-steps (steps config)
  (dolist (step steps config)
    (setf config (run-step step config))))

;;; ----------------------------
;;; Entry point
;;; ----------------------------

(defun main ()
  (format t "~&archietype - minimal base system~%~%")

  (let ((config '()))
    (setf config (run-steps *steps* config)))

  (format t "~&Installation complete.~%")
  (format t "You may reboot now.~%"))

(main)
