# (defn start []
#   (c/start)

#   (while (not (c/should-close?))
#     (c/render))

#   (c/end))

# (defn render []
#   )

(defn start []
  (print "Starting")
  )

(print "Compiled")
