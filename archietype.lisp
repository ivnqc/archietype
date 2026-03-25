#!/usr/bin/env sbcl --script

(defun die (fmt &rest args)
  (apply #'format *error-output* fmt args)
  (terpri *error-output*)
  (quit 1))

(defun run (cmd)
  (format t "~&  ~A~%" cmd)
  (let ((code (sb-ext:run-program
               "/bin/sh"
               (list "-c" cmd)
               :input t
               :output *standard-output*
               :error *error-output*
               :search t)))
    (unless (zerop (sb-ext:process-exit-code code))
      (die "Command failed: ~A" cmd))))

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
;;; Steps
;;; ----------------------------

(defun format-root (config)
  (run (format nil "mkfs.ext4 ~A"
               (require-config config :root)))
	config)

(defun format-efi (config)
  (run (format nil "mkfs.fat -F32 ~A"
               (require-config config :efi)))
	config)

(defun format-swap (config)
  (run (format nil "mkswap ~A"
               (require-config config :swap)))
	config)

(defun mount-root (config)
  (run (format nil "mount ~A /mnt"
               (require-config config :root)))
	config)

(defun mount-efi (config)
  (run "mkdir -p /mnt/boot")
  (run (format nil "mount -o umask=007 ~A /mnt/boot"
               (require-config config :efi)))
	config)

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
      (run (format nil "swapon ~A" swap))))
  config)

(defun install-base (config)
  (declare (ignore config))
  (run "pacstrap /mnt base linux")
	config)

(defun generate-fstab (config)
  (declare (ignore config))
  (run "genfstab -U /mnt >> /mnt/etc/fstab")
	config)

(defun configure-chroot (config)
  (with-open-file (s "/mnt/root/archietype-chroot.sh"
                     :direction :output
                     :if-exists :supersede)
    (format s "#!/bin/sh~%")
    (format s "set -eux~%")
    
    (setup-time s)
    (setup-localization s config)
    (setup-network s config)
    
    (format s "mkinitcpio -P~%")
    (format s "echo 'Set root password:'~%")
    (format s "passwd~%")

    (setup-bootloader s config))

  (run "chmod +x /mnt/root/archietype-chroot.sh")
  (run "arch-chroot /mnt /root/archietype-chroot.sh")
  (run "rm /mnt/root/archietype-chroot.sh")
	config)

(defun setup-time (s)
  (format s "ln -sf /usr/share/zoneinfo/UTC /etc/localtime~%")
  (format s "hwclock --systohc~%")
  (format s "systemctl enable systemd-timesyncd~%"))

(defun setup-localization (s config)
  (format s "echo '~A UTF-8' >> /etc/locale.gen~%"
	  (getf config :locale))
  (format s "locale-gen~%")
  (format s "echo 'LANG=~A' > /etc/locale.conf~%"
	  (getf config :locale))
  (format s "echo 'KEYMAP=~A' > /etc/vconsole.conf~%"
	  (getf config :keymap)))

(defun setup-network (s config)
  (format s "echo '~A' > /etc/hostname~%"
        (getf config :hostname))
  (format s "ln -sf /usr/lib/systemd/network/89-ethernet.network.example /etc/systemd/network/89-ethernet.network~%")
  (format s "systemctl enable systemd-networkd systemd-resolved~%"))

(defun setup-bootloader (s config)
  (format s "bootctl install~%")
 
  (format s "echo 'default arch' > /boot/loader/loader.conf~%")
  (format s "echo 'timeout 3' >> /boot/loader/loader.conf~%")

  (format s "ROOT_UUID=$(findmnt -no UUID /)~%")

  (format s "cat <<EOF > /boot/loader/entries/arch.conf~%")
  (format s "title archietype~%")
  (format s "linux /vmlinuz-linux~%")
  (format s "initrd /initramfs-linux.img~%")
  (format s "options root=UUID=$ROOT_UUID rw~%")
  (format s "EOF~%"))

(shadow 'step)
(defmacro step (id (&key desc when) &body body)
  `(list :id ',id
         :name ,(or desc (symbol-name id))
         :when (lambda (config)
                 ,(if when
                      `(let ((config config)) ,when)
                      t))
         :fn (lambda (config)
               ,@body)))

(defun wants-format-root (config)
  (getf config :format-root))

(defun wants-format-efi (config)
  (getf config :format-efi))

(defun wants-format-swap (config)
  (and (getf config :swap)
       (getf config :format-swap)))

(defun has-swap (config)
  (getf config :swap))

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

   (step install-base ()
     (install-base config))

   (step genfstab
     (:desc "Generate fstab")
     (generate-fstab config))

   (step configure
     (:desc "Configure system")
     (configure-chroot config))))

;;; ----------------------------
;;; Main
;;; ----------------------------

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

(defun main ()
  (format t "~&archietype - minimal base system~%~%")

  (let ((config '()))
    (setf config (run-steps *steps* config)))

  (format t "~&Installation complete.~%")
  (format t "You may reboot now.~%"))

(main)
