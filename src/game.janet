(defn start []
  (c/start)

  (while (not (c/should-close?))
    (c/render))
  # (print "We did it!")

  (c/end))
