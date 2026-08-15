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

(defun format-root (disk)
  (run (format nil "mkfs.ext4 ~A"
               (disk-config-root disk))))

(defun format-efi (disk)
  (run (format nil "mkfs.fat -F32 ~A"
               (disk-config-efi disk))))

(defun format-swap (disk)
  (run (format nil "mkswap ~A"
               (disk-config-swap disk))))

(defun mount-root (disk)
  (run (format nil "mount ~A /mnt"
               (disk-config-root disk))))

(defun mount-efi (disk)
  (run "mkdir -p /mnt/boot")
  (run (format nil "mount -t vfat -o fmask=177,dmask=077 ~A /mnt/boot"
               (disk-config-efi disk))))

(defun ask-partitions ()
  (format t "~&==> Disk configuration~%~%")

  (make-disk-config 
    :root (prompt "Root partition (e.g. /dev/sda2): ")
    :efi (prompt "EFI partition (e.g. /dev/sda1): ")))

(defun ask-swap (disk)
  (when (yes-p "Do you want to set up a swap partition? [y/N]: ")
    (setf (disk-config-swap disk)
          (prompt "Enter swap partition (e.g. /dev/sda3): "))))

(defun build-config ()
  (format t "~&==> System configuration (press Enter to accept defaults)~%~%")

  (make-system-config
    :hostname (prompt-default "Hostname" "archietype")
    :locale (prompt-default "Locale" "en_US.UTF-8")
    :keymap (prompt-default "Keymap" "us")))

(defun confirm-config (disk system)
  (format t "~&~%==> Final configuration~%~%")

  (format t "Disk:~%")
  (format t "  Root: ~A~%" (disk-config-root disk))

  (format t "  EFI:  ~A~%" (disk-config-efi disk))

  (when (disk-config-swap disk)
    (format t "  Swap: ~A~%" (disk-config-swap disk)))

  (format t "~%System:~%")
  (format t "  Hostname: ~A~%" (system-config-hostname system))
  (format t "  Locale:   ~A~%" (system-config-locale system))
  (format t "  Keymap:   ~A~%" (system-config-keymap system))

  (format t "~%")

  (yes-p "Continue? [Y/n]: "))
	
(defun ask-format-options (disk)
  (values
    (yes-p "Format root partition? [y/N]: ")
    (yes-p "Format EFI partition? [y/N]: ")
    (if (disk-config-swap disk)
      (yes-p "Format swap partition? [y/N]: ")
      nil)))

(defun enable-swap (disk)
  (let ((swap (disk-config-swap disk)))
    (when swap
      (run (format nil "swapon ~A" swap)))))

(defun install-base ()
  (run "pacstrap /mnt base linux"))

(defun generate-fstab ()
  (run "genfstab -U /mnt >> /mnt/etc/fstab"))

(defun configure-chroot (system)
  (with-open-file (s "/mnt/root/archietype-chroot.sh"
                     :direction :output
                     :if-exists :supersede)
    (sh-line s "#!/bin/sh")
    (sh-line s "set -eux")
    
    (setup-time s)
    (setup-localization s system)
    (setup-network s system)
    
    (sh-command s "echo 'Set root password:'")
    (sh-command s "passwd")

    (setup-bootloader s)
    
    (sh-command s "mkinitcpio -P"))

  (run "chmod +x /mnt/root/archietype-chroot.sh")
  (run "arch-chroot -S /mnt /root/archietype-chroot.sh"))

(defun setup-time (s)
  (sh-symlink s "/usr/share/zoneinfo/UTC" "/etc/localtime")
  (sh-command s "hwclock --systohc")
  (sh-enable-service s "systemd-timesyncd"))

(defun setup-localization (s system)
  (sh-line s "echo '~A UTF-8' >> /etc/locale.gen"
	  (system-config-locale system))
  (sh-command s "locale-gen")
  (sh-line s "echo 'LANG=~A' > /etc/locale.conf"
	  (system-config-locale system))
  (sh-line s "echo 'KEYMAP=~A' > /etc/vconsole.conf"
	  (system-config-keymap system)))

(defun setup-network (s system)
  (sh-line s "echo '~A' > /etc/hostname"
    (system-config-hostname system))
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
;;; Installer
;;; ----------------------------

(defun install ()
  (let (disk system)
    (loop
      (setf disk (ask-partitions)
            system (build-config))
            
      (ask-swap disk)
      
      (when (confirm-config disk system)
        (return)))
        
    (multiple-value-bind (format-root format-efi format-swap)
      (ask-format-options disk)
      
      (when format-root
        (format-root disk))

      (when format-efi
        (format-efi disk))
        
      (when (and (disk-config-swap disk)
                  format-swap)
        (format-swap disk))
        
        (mount-root disk)
        (mount-efi disk)
        
        (enable-swap disk)
        
        (install-base)
        (generate-fstab)
        (configure-chroot system))))

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
