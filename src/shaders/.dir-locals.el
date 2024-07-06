;;; Directory Local Variables            -*- no-byte-compile: t -*-
;;; For more information see (info "(emacs) Directory Variables")

((glsl-mode . ((after-save-hook . (lambda nil
                                    (call-process "zig" nil 0 nil "build" "shd"))))))

