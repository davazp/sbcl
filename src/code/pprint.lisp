;;;; Common Lisp pretty printer

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!PRETTY")

;;;; pretty streams

;;; There are three different units for measuring character positions:
;;;  COLUMN - offset (if characters) from the start of the current line
;;;  INDEX  - index into the output buffer
;;;  POSN   - some position in the stream of characters cycling through
;;;           the output buffer
(deftype column ()
  '(and fixnum unsigned-byte))
;;; The INDEX type is picked up from the kernel package.
(deftype posn ()
  'fixnum)

(defconstant initial-buffer-size 128)

(defconstant default-line-length 80)

;; We're allowed to DXify the pretty-stream used by PPRINT-LOGICAL-BLOCK.
;;   "pprint-logical-block and the pretty printing stream it creates have
;;    dynamic extent. The consequences are undefined if, outside of this
;;    extent, output is attempted to the pretty printing stream it creates."
;; However doing that is slightly dangerous since there are a zillion ways
;; for users to get a hold of the stream and stash it somewhere.
;; Anyway, just a thought...
(declaim (maybe-inline make-pretty-stream))
(defstruct (pretty-stream (:include ansi-stream
                                    (out #'pretty-out)
                                    (sout #'pretty-sout)
                                    (misc #'pretty-misc))
                          (:constructor make-pretty-stream (target))
                          (:copier nil))
  ;; Where the output is going to finally go.
  (target (missing-arg) :type stream :read-only t)
  ;; Line length we should format to. Cached here so we don't have to keep
  ;; extracting it from the target stream.
  (line-length (or *print-right-margin*
                   (sb!impl::line-length target)
                   default-line-length)
               :type column
               :read-only t)
  ;; If non-nil, a function to call before performing OUT or SOUT
  (char-out-oneshot-hook nil :type (or null function))
  ;; A simple string holding all the text that has been output but not yet
  ;; printed.
  (buffer (make-string initial-buffer-size) :type (simple-array character (*)))
  ;; The index into BUFFER where more text should be put.
  (buffer-fill-pointer 0 :type index)
  ;; Whenever we output stuff from the buffer, we shift the remaining noise
  ;; over. This makes it difficult to keep references to locations in
  ;; the buffer. Therefore, we have to keep track of the total amount of
  ;; stuff that has been shifted out of the buffer.
  (buffer-offset 0 :type posn)
  ;; The column the first character in the buffer will appear in. Normally
  ;; zero, but if we end up with a very long line with no breaks in it we
  ;; might have to output part of it. Then this will no longer be zero.
  (buffer-start-column (or (sb!impl::charpos target) 0) :type column)
  ;; The line number we are currently on. Used for *PRINT-LINES*
  ;; abbreviations and to tell when sections have been split across
  ;; multiple lines.
  (line-number 0 :type index)
  ;; the value of *PRINT-LINES* captured at object creation time. We
  ;; use this, instead of the dynamic *PRINT-LINES*, to avoid
  ;; weirdness like
  ;;   (let ((*print-lines* 50))
  ;;     (pprint-logical-block ..
  ;;       (dotimes (i 10)
  ;;         (let ((*print-lines* 8))
  ;;           (print (aref possiblybigthings i) prettystream)))))
  ;; terminating the output of the entire logical blockafter 8 lines.
  (print-lines *print-lines* :type (or index null) :read-only t)
  ;; Stack of logical blocks in effect at the buffer start.
  (blocks (list (make-logical-block)) :type list)
  ;; Buffer holding the per-line prefix active at the buffer start.
  ;; Indentation is included in this. The length of this is stored
  ;; in the logical block stack.
  (prefix (make-string initial-buffer-size) :type (simple-array character (*)))
  ;; Buffer holding the total remaining suffix active at the buffer start.
  ;; The characters are right-justified in the buffer to make it easier
  ;; to output the buffer. The length is stored in the logical block
  ;; stack.
  (suffix (make-string initial-buffer-size) :type (simple-array character (*)))
  ;; Queue of pending operations. When empty, HEAD=TAIL=NIL. Otherwise,
  ;; TAIL holds the first (oldest) cons and HEAD holds the last (newest)
  ;; cons. Adding things to the queue is basically (setf (cdr head) (list
  ;; new)) and removing them is basically (pop tail) [except that care must
  ;; be taken to handle the empty queue case correctly.]
  (queue-tail nil :type list)
  (queue-head nil :type list)
  ;; Block-start queue entries in effect at the queue head.
  (pending-blocks nil :type list))
(def!method print-object ((pstream pretty-stream) stream)
  ;; FIXME: CMU CL had #+NIL'ed out this code and done a hand-written
  ;; FORMAT hack instead. Make sure that this code actually works instead
  ;; of falling into infinite regress or something.
  (print-unreadable-object (pstream stream :type t :identity t)))

#!-sb-fluid (declaim (inline index-posn posn-index posn-column))
(defun index-posn (index stream)
  (declare (type index index) (type pretty-stream stream)
           (values posn))
  (+ index (pretty-stream-buffer-offset stream)))
(defun posn-index (posn stream)
  (declare (type posn posn) (type pretty-stream stream)
           (values index))
  (- posn (pretty-stream-buffer-offset stream)))
(defun posn-column (posn stream)
  (declare (type posn posn) (type pretty-stream stream)
           (values posn))
  (index-column (posn-index posn stream) stream))

;;; Is it OK to do pretty printing on this stream at this time?
(defun print-pretty-on-stream-p (stream)
  (and (pretty-stream-p stream)
       *print-pretty*))

;;;; stream interface routines

(defun pretty-out (stream char)
  (declare (type pretty-stream stream)
           (type character char))
  (let ((f (pretty-stream-char-out-oneshot-hook stream)))
    (when f
      (setf (pretty-stream-char-out-oneshot-hook stream) nil)
      (funcall f stream char)))
  (cond ((char= char #\newline)
         (enqueue-newline stream :literal))
        (t
         (ensure-space-in-buffer stream 1)
         (let ((fill-pointer (pretty-stream-buffer-fill-pointer stream)))
           (setf (schar (pretty-stream-buffer stream) fill-pointer) char)
           (setf (pretty-stream-buffer-fill-pointer stream)
                 (1+ fill-pointer))))))

(defun pretty-sout (stream string start end)
  (declare (type pretty-stream stream)
           (type simple-string string)
           (type index start)
           (type (or index null) end))
  (let* ((end (or end (length string))))
    (unless (= start end)
      (sb!impl::string-dispatch (simple-base-string
                                 #!+sb-unicode
                                 (simple-array character (*)))
          string
        ;; For POSITION transform
        (declare (optimize (speed 2)))
        (let ((f (pretty-stream-char-out-oneshot-hook stream)))
          (when f
            (setf (pretty-stream-char-out-oneshot-hook stream) nil)
            (funcall f stream (aref string start))))
        (let ((newline (position #\newline string :start start :end end)))
          (cond
            (newline
             (pretty-sout stream string start newline)
             (enqueue-newline stream :literal)
             (pretty-sout stream string (1+ newline) end))
            (t
             (let ((chars (- end start)))
               (loop
                  (let* ((available (ensure-space-in-buffer stream chars))
                         (count (min available chars))
                         (fill-pointer (pretty-stream-buffer-fill-pointer
                                        stream))
                         (new-fill-ptr (+ fill-pointer count)))
                    (declare (fixnum available count))
                    (if (typep string 'simple-base-string)
                        ;; FIXME: Reimplementing REPLACE, since it
                        ;; can't be inlined and we don't have a
                        ;; generic "simple-array -> simple-array"
                        ;; transform for it.
                        (loop for i from fill-pointer below new-fill-ptr
                              for j from start
                              with target = (pretty-stream-buffer stream)
                              do (setf (aref target i)
                                       (aref string j)))
                        (replace (pretty-stream-buffer stream)
                                 string
                                 :start1 fill-pointer :end1 new-fill-ptr
                                 :start2 start))
                    (setf (pretty-stream-buffer-fill-pointer stream)
                          new-fill-ptr)
                    (decf chars count)
                    (when (zerop count)
                      (return))
                    (incf start count)))))))))))

(defun pretty-misc (stream op &optional arg1 arg2)
  (declare (ignore stream op arg1 arg2)))

;;;; logical blocks

(defstruct (logical-block (:copier nil))
  ;; The column this logical block started in.
  (start-column 0 :type column)
  ;; The column the current section started in.
  (section-column 0 :type column)
  ;; The length of the per-line prefix. We can't move the indentation
  ;; left of this.
  (per-line-prefix-end 0 :type index)
  ;; The overall length of the prefix, including any indentation.
  (prefix-length 0 :type index)
  ;; The overall length of the suffix.
  (suffix-length 0 :type index)
  ;; The line number
  (section-start-line 0 :type index))

(defun really-start-logical-block (stream column prefix suffix)
  (let* ((blocks (pretty-stream-blocks stream))
         (prev-block (car blocks))
         (per-line-end (logical-block-per-line-prefix-end prev-block))
         (prefix-length (logical-block-prefix-length prev-block))
         (suffix-length (logical-block-suffix-length prev-block))
         (block (make-logical-block
                 :start-column column
                 :section-column column
                 :per-line-prefix-end per-line-end
                 :prefix-length prefix-length
                 :suffix-length suffix-length
                 :section-start-line (pretty-stream-line-number stream))))
    (setf (pretty-stream-blocks stream) (cons block blocks))
    (set-indentation stream column)
    (when prefix
      (setf (logical-block-per-line-prefix-end block) column)
      (replace (pretty-stream-prefix stream) prefix
               :start1 (- column (length prefix)) :end1 column))
    (when suffix
      (let* ((total-suffix (pretty-stream-suffix stream))
             (total-suffix-len (length total-suffix))
             (additional (length suffix))
             (new-suffix-len (+ suffix-length additional)))
        (when (> new-suffix-len total-suffix-len)
          (let ((new-total-suffix-len
                 (max (* total-suffix-len 2)
                      (+ suffix-length
                         (floor (* additional 5) 4)))))
            (setf total-suffix
                  (replace (make-string new-total-suffix-len) total-suffix
                           :start1 (- new-total-suffix-len suffix-length)
                           :start2 (- total-suffix-len suffix-length)))
            (setf total-suffix-len new-total-suffix-len)
            (setf (pretty-stream-suffix stream) total-suffix)))
        (replace total-suffix suffix
                 :start1 (- total-suffix-len new-suffix-len)
                 :end1 (- total-suffix-len suffix-length))
        (setf (logical-block-suffix-length block) new-suffix-len))))
  nil)

(defun set-indentation (stream column)
  (let* ((prefix (pretty-stream-prefix stream))
         (prefix-len (length prefix))
         (block (car (pretty-stream-blocks stream)))
         (current (logical-block-prefix-length block))
         (minimum (logical-block-per-line-prefix-end block))
         (column (max minimum column)))
    (when (> column prefix-len)
      (setf prefix
            (replace (make-string (max (* prefix-len 2)
                                       (+ prefix-len
                                          (floor (* (- column prefix-len) 5)
                                                 4))))
                     prefix
                     :end1 current))
      (setf (pretty-stream-prefix stream) prefix))
    (when (> column current)
      (fill prefix #\space :start current :end column))
    (setf (logical-block-prefix-length block) column)))

(defun really-end-logical-block (stream)
  (let* ((old (pop (pretty-stream-blocks stream)))
         (old-indent (logical-block-prefix-length old))
         (new (car (pretty-stream-blocks stream)))
         (new-indent (logical-block-prefix-length new)))
    (when (> new-indent old-indent)
      (fill (pretty-stream-prefix stream) #\space
            :start old-indent :end new-indent)))
  nil)

;;;; the pending operation queue

(defstruct (queued-op (:constructor nil)
                      (:copier nil))
  (posn 0 :type posn))

(defmacro enqueue (stream type &rest args)
  (let ((constructor (symbolicate "MAKE-" type)))
    (once-only ((stream stream)
                (entry `(,constructor :posn
                                      (index-posn
                                       (pretty-stream-buffer-fill-pointer
                                        ,stream)
                                       ,stream)
                                      ,@args))
                (op `(list ,entry))
                (head `(pretty-stream-queue-head ,stream)))
      `(progn
         (if ,head
             (setf (cdr ,head) ,op)
             (setf (pretty-stream-queue-tail ,stream) ,op))
         (setf (pretty-stream-queue-head ,stream) ,op)
         ,entry))))

(defstruct (section-start (:include queued-op)
                          (:constructor nil)
                          (:copier nil))
  (depth 0 :type index)
  (section-end nil :type (or null newline block-end)))

(defstruct (newline (:include section-start)
                    (:copier nil))
  (kind (missing-arg)
        :type (member :linear :fill :miser :literal :mandatory)))

(defun enqueue-newline (stream kind)
  (let* ((depth (length (pretty-stream-pending-blocks stream)))
         (newline (enqueue stream newline :kind kind :depth depth)))
    (dolist (entry (pretty-stream-queue-tail stream))
      (when (and (not (eq newline entry))
                 (section-start-p entry)
                 (null (section-start-section-end entry))
                 (<= depth (section-start-depth entry)))
        (setf (section-start-section-end entry) newline))))
  (maybe-output stream (or (eq kind :literal) (eq kind :mandatory))))

(defstruct (indentation (:include queued-op)
                        (:copier nil))
  (kind (missing-arg) :type (member :block :current))
  (amount 0 :type fixnum))

(defun enqueue-indent (stream kind amount)
  (enqueue stream indentation :kind kind :amount amount))

(defstruct (block-start (:include section-start)
                        (:copier nil))
  (block-end nil :type (or null block-end))
  (prefix nil :type (or null simple-string))
  (suffix nil :type (or null simple-string)))

(defun start-logical-block (stream prefix per-line-p suffix)
  ;; (In the PPRINT-LOGICAL-BLOCK form which calls us,
  ;; :PREFIX and :PER-LINE-PREFIX have hairy defaulting behavior,
  ;; and might end up being NIL.)
  (declare (type (or null string) prefix))
  ;; (But the defaulting behavior of PPRINT-LOGICAL-BLOCK :SUFFIX is
  ;; trivial, so it should always be a string.)
  (declare (type string suffix))
  (when prefix
    (unless (typep prefix 'simple-string)
      (setq prefix (coerce prefix '(simple-array character (*)))))
    (pretty-sout stream prefix 0 (length prefix)))
  (unless (typep suffix 'simple-string)
    (setq suffix (coerce suffix '(simple-array character (*)))))
  (let* ((pending-blocks (pretty-stream-pending-blocks stream))
         (start (enqueue stream block-start
                         :prefix (and per-line-p prefix)
                         :suffix suffix
                         :depth (length pending-blocks))))
    (setf (pretty-stream-pending-blocks stream)
          (cons start pending-blocks))))

(defstruct (block-end (:include queued-op)
                      (:copier nil))
  (suffix nil :type (or null simple-string)))

(defun end-logical-block (stream)
  (let* ((start (pop (pretty-stream-pending-blocks stream)))
         (suffix (block-start-suffix start))
         (end (enqueue stream block-end :suffix suffix)))
    (when suffix
      (pretty-sout stream suffix 0 (length suffix)))
    (setf (block-start-block-end start) end)))

(defstruct (tab (:include queued-op)
                (:copier nil))
  (sectionp nil :type (member t nil))
  (relativep nil :type (member t nil))
  (colnum 0 :type column)
  (colinc 0 :type column))

(defun enqueue-tab (stream kind colnum colinc)
  (multiple-value-bind (sectionp relativep)
      (ecase kind
        (:line (values nil nil))
        (:line-relative (values nil t))
        (:section (values t nil))
        (:section-relative (values t t)))
    (enqueue stream tab :sectionp sectionp :relativep relativep
             :colnum colnum :colinc colinc)))

;;;; tab support

(defun compute-tab-size (tab section-start column)
  (let* ((origin (if (tab-sectionp tab) section-start 0))
         (colnum (tab-colnum tab))
         (colinc (tab-colinc tab))
         (position (- column origin)))
    (cond ((tab-relativep tab)
           (unless (<= colinc 1)
             (let ((newposn (+ position colnum)))
               (let ((rem (rem newposn colinc)))
                 (unless (zerop rem)
                   (incf colnum (- colinc rem))))))
           colnum)
          ((< position colnum)
           (- colnum position))
          ((zerop colinc) 0)
          (t
           (- colinc
              (rem (- position colnum) colinc))))))

(defun index-column (index stream)
  (let ((column (pretty-stream-buffer-start-column stream))
        (section-start (logical-block-section-column
                        (first (pretty-stream-blocks stream))))
        (end-posn (index-posn index stream)))
    (dolist (op (pretty-stream-queue-tail stream))
      (when (>= (queued-op-posn op) end-posn)
        (return))
      (typecase op
        (tab
         (incf column
               (compute-tab-size op
                                 section-start
                                 (+ column
                                    (posn-index (tab-posn op)
                                                    stream)))))
        ((or newline block-start)
         (setf section-start
               (+ column (posn-index (queued-op-posn op)
                                         stream))))))
    (+ column index)))

(defun expand-tabs (stream through)
  (let ((insertions nil)
        (additional 0)
        (column (pretty-stream-buffer-start-column stream))
        (section-start (logical-block-section-column
                        (first (pretty-stream-blocks stream)))))
    (dolist (op (pretty-stream-queue-tail stream))
      (typecase op
        (tab
         (let* ((index (posn-index (tab-posn op) stream))
                (tabsize (compute-tab-size op
                                           section-start
                                           (+ column index))))
           (unless (zerop tabsize)
             (push (cons index tabsize) insertions)
             (incf additional tabsize)
             (incf column tabsize))))
        ((or newline block-start)
         (setf section-start
               (+ column (posn-index (queued-op-posn op) stream)))))
      (when (eq op through)
        (return)))
    (when insertions
      (let* ((fill-ptr (pretty-stream-buffer-fill-pointer stream))
             (new-fill-ptr (+ fill-ptr additional))
             (buffer (pretty-stream-buffer stream))
             (new-buffer buffer)
             (length (length buffer))
             (end fill-ptr))
        (when (> new-fill-ptr length)
          (let ((new-length (max (* length 2)
                                 (+ fill-ptr
                                    (floor (* additional 5) 4)))))
            (setf new-buffer (make-string new-length))
            (setf (pretty-stream-buffer stream) new-buffer)))
        (setf (pretty-stream-buffer-fill-pointer stream) new-fill-ptr)
        (decf (pretty-stream-buffer-offset stream) additional)
        (dolist (insertion insertions)
          (let* ((srcpos (car insertion))
                 (amount (cdr insertion))
                 (dstpos (+ srcpos additional)))
            (replace new-buffer buffer :start1 dstpos :start2 srcpos :end2 end)
            (fill new-buffer #\space :start (- dstpos amount) :end dstpos)
            (decf additional amount)
            (setf end srcpos)))
        (unless (eq new-buffer buffer)
          (replace new-buffer buffer :end1 end :end2 end))))))

;;;; stuff to do the actual outputting

(defun ensure-space-in-buffer (stream want)
  (declare (type pretty-stream stream)
           (type index want))
  (let* ((buffer (pretty-stream-buffer stream))
         (length (length buffer))
         (fill-ptr (pretty-stream-buffer-fill-pointer stream))
         (available (- length fill-ptr)))
    (cond ((plusp available)
           available)
          ((> fill-ptr (pretty-stream-line-length stream))
           (unless (maybe-output stream nil)
             (output-partial-line stream))
           (ensure-space-in-buffer stream want))
          (t
           (let* ((new-length (max (* length 2)
                                   (+ length
                                      (floor (* want 5) 4))))
                  (new-buffer (make-string new-length)))
             (setf (pretty-stream-buffer stream) new-buffer)
             (replace new-buffer buffer :end1 fill-ptr)
             (- new-length fill-ptr))))))

(defun maybe-output (stream force-newlines-p)
  (declare (type pretty-stream stream))
  (let ((tail (pretty-stream-queue-tail stream))
        (output-anything nil))
    (loop
      (unless tail
        (setf (pretty-stream-queue-head stream) nil)
        (return))
      (let ((next (pop tail)))
        (etypecase next
          (newline
           (when (ecase (newline-kind next)
                   ((:literal :mandatory :linear) t)
                   (:miser (misering-p stream))
                   (:fill
                    (or (misering-p stream)
                        (> (pretty-stream-line-number stream)
                           (logical-block-section-start-line
                            (first (pretty-stream-blocks stream))))
                        (ecase (fits-on-line-p stream
                                               (newline-section-end next)
                                               force-newlines-p)
                          ((t) nil)
                          ((nil) t)
                          (:dont-know
                           (return))))))
             (setf output-anything t)
             (output-line stream next)))
          (indentation
           (unless (misering-p stream)
             (set-indentation stream
                              (+ (ecase (indentation-kind next)
                                   (:block
                                    (logical-block-start-column
                                     (car (pretty-stream-blocks stream))))
                                   (:current
                                    (posn-column
                                     (indentation-posn next)
                                     stream)))
                                 (indentation-amount next)))))
          (block-start
           (ecase (fits-on-line-p stream (block-start-section-end next)
                                  force-newlines-p)
             ((t)
              ;; Just nuke the whole logical block and make it look
              ;; like one nice long literal.
              (let ((end (block-start-block-end next)))
                (expand-tabs stream end)
                (setf tail (cdr (member end tail)))))
             ((nil)
              (really-start-logical-block
               stream
               (posn-column (block-start-posn next) stream)
               (block-start-prefix next)
               (block-start-suffix next)))
             (:dont-know
              (return))))
          (block-end
           (really-end-logical-block stream))
          (tab
           (expand-tabs stream next))))
      (setf (pretty-stream-queue-tail stream) tail))
    output-anything))

(defun misering-p (stream)
  (declare (type pretty-stream stream))
  (and *print-miser-width*
       (<= (- (pretty-stream-line-length stream)
              (logical-block-start-column (car (pretty-stream-blocks stream))))
           *print-miser-width*)))

(defun fits-on-line-p (stream until force-newlines-p)
  (let ((available (pretty-stream-line-length stream)))
    (when (and (not *print-readably*)
               (pretty-stream-print-lines stream)
               (= (pretty-stream-print-lines stream)
                  (pretty-stream-line-number stream)))
      (decf available 3) ; for the `` ..''
      (decf available (logical-block-suffix-length
                       (car (pretty-stream-blocks stream)))))
    (cond (until
           (<= (posn-column (queued-op-posn until) stream) available))
          (force-newlines-p nil)
          ((> (index-column (pretty-stream-buffer-fill-pointer stream) stream)
              available)
           nil)
          (t
           :dont-know))))

(defun output-line (stream until)
  (declare (type pretty-stream stream)
           (type newline until))
  (let* ((target (pretty-stream-target stream))
         (buffer (pretty-stream-buffer stream))
         (kind (newline-kind until))
         (literal-p (eq kind :literal))
         (amount-to-consume (posn-index (newline-posn until) stream))
         (amount-to-print
          (if literal-p
              amount-to-consume
              (let ((last-non-blank
                     (position #\space buffer :end amount-to-consume
                               :from-end t :test #'char/=)))
                (if last-non-blank
                    (1+ last-non-blank)
                    0)))))
    (write-string buffer target :end amount-to-print)
    (let ((line-number (pretty-stream-line-number stream)))
      (incf line-number)
      (when (and (not *print-readably*)
                 (pretty-stream-print-lines stream)
                 (>= line-number (pretty-stream-print-lines stream)))
        (write-string " .." target)
        (let ((suffix-length (logical-block-suffix-length
                              (car (pretty-stream-blocks stream)))))
          (unless (zerop suffix-length)
            (let* ((suffix (pretty-stream-suffix stream))
                   (len (length suffix)))
              (write-string suffix target
                            :start (- len suffix-length)
                            :end len))))
        (throw 'line-limit-abbreviation-happened t))
      (setf (pretty-stream-line-number stream) line-number)
      (write-char #\newline target)
      (setf (pretty-stream-buffer-start-column stream) 0)
      (let* ((fill-ptr (pretty-stream-buffer-fill-pointer stream))
             (block (first (pretty-stream-blocks stream)))
             (prefix-len
              (if literal-p
                  (logical-block-per-line-prefix-end block)
                  (logical-block-prefix-length block)))
             (shift (- amount-to-consume prefix-len))
             (new-fill-ptr (- fill-ptr shift))
             (new-buffer buffer)
             (buffer-length (length buffer)))
        (when (> new-fill-ptr buffer-length)
          (setf new-buffer
                (make-string (max (* buffer-length 2)
                                  (+ buffer-length
                                     (floor (* (- new-fill-ptr buffer-length)
                                               5)
                                            4)))))
          (setf (pretty-stream-buffer stream) new-buffer))
        (replace new-buffer buffer
                 :start1 prefix-len :start2 amount-to-consume :end2 fill-ptr)
        (replace new-buffer (pretty-stream-prefix stream)
                 :end1 prefix-len)
        (setf (pretty-stream-buffer-fill-pointer stream) new-fill-ptr)
        (incf (pretty-stream-buffer-offset stream) shift)
        (unless literal-p
          (setf (logical-block-section-column block) prefix-len)
          (setf (logical-block-section-start-line block) line-number))))))

(defun output-partial-line (stream)
  (let* ((fill-ptr (pretty-stream-buffer-fill-pointer stream))
         (tail (pretty-stream-queue-tail stream))
         (count
          (if tail
              (posn-index (queued-op-posn (car tail)) stream)
              fill-ptr))
         (new-fill-ptr (- fill-ptr count))
         (buffer (pretty-stream-buffer stream)))
    (when (zerop count)
      (error "Output-partial-line called when nothing can be output."))
    (write-string buffer (pretty-stream-target stream)
                  :start 0 :end count)
    (incf (pretty-stream-buffer-start-column stream) count)
    (replace buffer buffer :end1 new-fill-ptr :start2 count :end2 fill-ptr)
    (setf (pretty-stream-buffer-fill-pointer stream) new-fill-ptr)
    (incf (pretty-stream-buffer-offset stream) count)))

(defun force-pretty-output (stream)
  (maybe-output stream nil)
  (expand-tabs stream nil)
  (write-string (pretty-stream-buffer stream)
                (pretty-stream-target stream)
                :end (pretty-stream-buffer-fill-pointer stream)))

;;;; user interface to the pretty printer

(defun pprint-newline (kind &optional stream)
  #!+sb-doc
  "Output a conditional newline to STREAM (which defaults to
   *STANDARD-OUTPUT*) if it is a pretty-printing stream, and do
   nothing if not. KIND can be one of:
     :LINEAR - A line break is inserted if and only if the immediately
        containing section cannot be printed on one line.
     :MISER - Same as LINEAR, but only if ``miser-style'' is in effect.
        (See *PRINT-MISER-WIDTH*.)
     :FILL - A line break is inserted if and only if either:
       (a) the following section cannot be printed on the end of the
           current line,
       (b) the preceding section was not printed on a single line, or
       (c) the immediately containing section cannot be printed on one
           line and miser-style is in effect.
     :MANDATORY - A line break is always inserted.
   When a line break is inserted by any type of conditional newline, any
   blanks that immediately precede the conditional newline are omitted
   from the output and indentation is introduced at the beginning of the
   next line. (See PPRINT-INDENT.)"
  (declare (type (member :linear :miser :fill :mandatory) kind)
           (type stream-designator stream)
           (values null))
  (let ((stream (out-synonym-of stream)))
    (when (print-pretty-on-stream-p stream)
      (enqueue-newline stream kind)))
  nil)

(defun pprint-indent (relative-to n &optional stream)
  #!+sb-doc
  "Specify the indentation to use in the current logical block if
STREAM \(which defaults to *STANDARD-OUTPUT*) is a pretty-printing
stream and do nothing if not. (See PPRINT-LOGICAL-BLOCK.) N is the
indentation to use (in ems, the width of an ``m'') and RELATIVE-TO can
be either:

     :BLOCK - Indent relative to the column the current logical block
        started on.

     :CURRENT - Indent relative to the current column.

The new indentation value does not take effect until the following
line break."
  (declare (type (member :block :current) relative-to)
           (type real n)
           (type stream-designator stream)
           (values null))
  (let ((stream (out-synonym-of stream)))
    (when (print-pretty-on-stream-p stream)
      (enqueue-indent stream relative-to (truncate n))))
  nil)

(defun pprint-tab (kind colnum colinc &optional stream)
  #!+sb-doc
  "If STREAM (which defaults to *STANDARD-OUTPUT*) is a pretty-printing
   stream, perform tabbing based on KIND, otherwise do nothing. KIND can
   be one of:
     :LINE - Tab to column COLNUM. If already past COLNUM tab to the next
       multiple of COLINC.
     :SECTION - Same as :LINE, but count from the start of the current
       section, not the start of the line.
     :LINE-RELATIVE - Output COLNUM spaces, then tab to the next multiple of
       COLINC.
     :SECTION-RELATIVE - Same as :LINE-RELATIVE, but count from the start
       of the current section, not the start of the line."
  (declare (type (member :line :section :line-relative :section-relative) kind)
           (type unsigned-byte colnum colinc)
           (type stream-designator stream)
           (values null))
  (let ((stream (out-synonym-of stream)))
    (when (print-pretty-on-stream-p stream)
      (enqueue-tab stream kind colnum colinc)))
  nil)

(defun pprint-fill (stream list &optional (colon? t) atsign?)
  #!+sb-doc
  "Output LIST to STREAM putting :FILL conditional newlines between each
   element. If COLON? is NIL (defaults to T), then no parens are printed
   around the output. ATSIGN? is ignored (but allowed so that PPRINT-FILL
   can be used with the ~/.../ format directive."
  (declare (ignore atsign?))
  (pprint-logical-block (stream list
                                :prefix (if colon? "(" "")
                                :suffix (if colon? ")" ""))
    (pprint-exit-if-list-exhausted)
    (loop
      (output-object (pprint-pop) stream)
      (pprint-exit-if-list-exhausted)
      (write-char #\space stream)
      (pprint-newline :fill stream))))

(defun pprint-linear (stream list &optional (colon? t) atsign?)
  #!+sb-doc
  "Output LIST to STREAM putting :LINEAR conditional newlines between each
   element. If COLON? is NIL (defaults to T), then no parens are printed
   around the output. ATSIGN? is ignored (but allowed so that PPRINT-LINEAR
   can be used with the ~/.../ format directive."
  (declare (ignore atsign?))
  (pprint-logical-block (stream list
                                :prefix (if colon? "(" "")
                                :suffix (if colon? ")" ""))
    (pprint-exit-if-list-exhausted)
    (loop
      (output-object (pprint-pop) stream)
      (pprint-exit-if-list-exhausted)
      (write-char #\space stream)
      (pprint-newline :linear stream))))

(defun pprint-tabular (stream list &optional (colon? t) atsign? tabsize)
  #!+sb-doc
  "Output LIST to STREAM tabbing to the next column that is an even multiple
   of TABSIZE (which defaults to 16) between each element. :FILL style
   conditional newlines are also output between each element. If COLON? is
   NIL (defaults to T), then no parens are printed around the output.
   ATSIGN? is ignored (but allowed so that PPRINT-TABULAR can be used with
   the ~/.../ format directive."
  (declare (ignore atsign?))
  (pprint-logical-block (stream list
                                :prefix (if colon? "(" "")
                                :suffix (if colon? ")" ""))
    (pprint-exit-if-list-exhausted)
    (loop
      (output-object (pprint-pop) stream)
      (pprint-exit-if-list-exhausted)
      (write-char #\space stream)
      (pprint-tab :section-relative 0 (or tabsize 16) stream)
      (pprint-newline :fill stream))))

;;;; pprint-dispatch tables

(defvar *standard-pprint-dispatch-table*)
(defvar *initial-pprint-dispatch-table*)

(defstruct (pprint-dispatch-entry (:copier nil) (:predicate nil))
  ;; the type specifier for this entry
  (type (missing-arg) :type t :read-only t)
  ;; a function to test to see whether an object is of this type,
  ;; either (LAMBDA (OBJ) (TYPEP OBJECT TYPE)) or a builtin predicate.
  ;; We don't bother computing this for entries in the CONS
  ;; hash table, because we don't need it.
  (test-fn nil :type (or function null))
  ;; the priority for this guy
  (priority 0 :type real :read-only t)
  ;; T iff one of the original entries.
  (initial-p (eq *initial-pprint-dispatch-table* nil)
             :type (member t nil) :read-only t)
  ;; and the associated function
  (fun (missing-arg) :type callable :read-only t))
(def!method print-object ((entry pprint-dispatch-entry) stream)
  (print-unreadable-object (entry stream :type t)
    (format stream "type=~S, priority=~S~@[ [initial]~]"
            (pprint-dispatch-entry-type entry)
            (pprint-dispatch-entry-priority entry)
            (pprint-dispatch-entry-initial-p entry))))

;; Return T iff E1 is strictly less preferable than E2.
(defun entry< (e1 e2)
  (declare (type pprint-dispatch-entry e1 e2))
  (if (pprint-dispatch-entry-initial-p e1)
      (if (pprint-dispatch-entry-initial-p e2)
          (< (pprint-dispatch-entry-priority e1)
             (pprint-dispatch-entry-priority e2))
          t)
      (if (pprint-dispatch-entry-initial-p e2)
          nil
          (< (pprint-dispatch-entry-priority e1)
             (pprint-dispatch-entry-priority e2)))))

;; Return the predicate for CTYPE, equivalently TYPE-SPEC.
;; This used to involve rewriting into a sexpr if CONS was involved,
;; since it was not an official specifier. But now it is.
(defun compute-test-fn (ctype type-spec function)
  (declare (special sb!c::*backend-type-predicates*))
  ;; Avoid compiling code for an existing structure predicate
  (or (and (eq (info :type :kind type-spec) :instance)
           (let ((layout (info :type :compiler-layout type-spec)))
             (and layout
                  (let ((info (layout-info layout)))
                    (and info
                         (let ((pred (dd-predicate-name info)))
                           (and pred (fboundp pred)
                                (symbol-function pred))))))))
      ;; avoid compiling code for CONS, ARRAY, VECTOR, etc
      (awhen (assoc ctype sb!c::*backend-type-predicates* :test #'type=)
        (symbol-function (cdr it)))
      ;; OK, compile something
      (let ((name
             ;; Keep name as a string, because NAMED-LAMBDA with a symbol
             ;; affects the global environment, when all you want
             ;; is to give the lambda a human-readable label.
             (format nil "~A-P"
                     (cond ((symbolp type-spec) type-spec)
                           ((symbolp function) function)
                           ((%fun-name function))
                           (t
                            (write-to-string type-spec :pretty nil :escape nil
                                             :readably nil))))))
        (compile nil
                 `(named-lambda ,name (object) (typep object ',type-spec))))))

(defun copy-pprint-dispatch (&optional (table *print-pprint-dispatch*))
  (declare (type (or pprint-dispatch-table null) table))
  (let* ((orig (or table *initial-pprint-dispatch-table*))
         (new (make-pprint-dispatch-table
               :entries (copy-list (pprint-dispatch-table-entries orig)))))
    (replace/eql-hash-table (pprint-dispatch-table-cons-entries new)
                            (pprint-dispatch-table-cons-entries orig))
    new))

(defun pprint-dispatch (object &optional (table *print-pprint-dispatch*))
  (declare (type (or pprint-dispatch-table null) table))
  (let* ((table (or table *initial-pprint-dispatch-table*))
         (cons-entry
          (and (consp object)
               (gethash (car object)
                        (pprint-dispatch-table-cons-entries table))))
         (entry
          (dolist (entry (pprint-dispatch-table-entries table) cons-entry)
            (when (and cons-entry
                       (entry< entry cons-entry))
              (return cons-entry))
            (when (funcall (pprint-dispatch-entry-test-fn entry) object)
              (return entry)))))
    (if entry
        (values (pprint-dispatch-entry-fun entry) t)
        (values (lambda (stream object)
                  (output-ugly-object object stream))
                nil))))

(defun assert-not-standard-pprint-dispatch-table (pprint-dispatch operation)
  (when (eq pprint-dispatch *standard-pprint-dispatch-table*)
    (cerror "Frob it anyway!" 'standard-pprint-dispatch-table-modified-error
            :operation operation)))

;; Similar to (NOT CONTAINS-UNKNOWN-TYPE-P), but this is for when you
;; want to pre-verify that TYPEP won't outright croak, given that you're
;; going to call it really soon.
;; Granted, certain checks could pass or fail by short-circuiting,
;; such as (TYPEP 3 '(OR NUMBER (SATISFIES NO-SUCH-FUN))
;; but this has to be maximally conservative.
(defun testable-type-p (ctype)
  (typecase ctype
    (unknown-type nil) ; must precede HAIRY because an unknown is HAIRY
    (hairy-type
     (let ((spec (hairy-type-specifier ctype)))
       ;; Anything other than (SATISFIES ...) is testable
       ;; because there's no reason to suppose that it isn't.
       (or (neq (car spec) 'satisfies) (fboundp (cadr spec)))))
    (compound-type (every #'testable-type-p (compound-type-types ctype)))
    (negation-type (testable-type-p (negation-type-type ctype)))
    (cons-type (and (testable-type-p (cons-type-car-type ctype))
                    (testable-type-p (cons-type-cdr-type ctype))))
    (array-type (testable-type-p (array-type-element-type ctype)))
    (t t)))

(defun defer-type-checker (entry)
  (let ((saved-nonce sb!c::*type-cache-nonce*))
    (lambda (obj)
      (let ((nonce sb!c::*type-cache-nonce*))
        (if (eq nonce saved-nonce)
            nil
            (let ((ctype (specifier-type (pprint-dispatch-entry-type entry))))
              (setq saved-nonce nonce)
              (if (testable-type-p ctype)
                  (funcall (setf (pprint-dispatch-entry-test-fn entry)
                                 (compute-test-fn
                                  ctype
                                  (pprint-dispatch-entry-type entry)
                                  (pprint-dispatch-entry-fun entry)))
                           obj)
                  nil)))))))

;; The dispatch mechanism is not quite sophisticated enough to have a guard
;; condition on CONS entries. One place this would impact is that you could
;; write the full matcher for QUOTE as just a type-specifier. It can be done
;; now, but using the non-cons table entails linear scan.
;; A test-fn in the cons table would require storing multiple entries per
;; key though because any might fail. Conceivably you could have
;; (cons (eql foo) cons) and (cons (eql foo) bit-vector) as two FOO entries.
(defun set-pprint-dispatch (type function &optional
                            (priority 0) (table *print-pprint-dispatch*))
  (declare (type (or null callable) function)
           (type real priority)
           (type pprint-dispatch-table table))
  (/show0 "entering SET-PPRINT-DISPATCH, TYPE=...")
  (/hexstr type)
  (assert-not-standard-pprint-dispatch-table table 'set-pprint-dispatch)
  (let* ((ctype (or (handler-bind
                        ((parse-unknown-type
                          (lambda (c)
                            (warn "~S is not a recognized type specifier"
                                  (parse-unknown-type-specifier c)))))
                      (sb!c::careful-specifier-type type))
                    (error "~S is not a valid type-specifier" type)))
         (consp (and (cons-type-p ctype)
                     (eq (cons-type-cdr-type ctype) *universal-type*)
                     (member-type-p (cons-type-car-type ctype))))
         (disabled-p (not (testable-type-p ctype)))
         (entry (if function
                    (make-pprint-dispatch-entry
                     :type type
                     :test-fn (unless (or consp disabled-p)
                                (compute-test-fn ctype type function))
                     :priority priority :fun function))))
    (when (and function disabled-p)
      ;; a DISABLED-P test function has to close over the ENTRY
      (setf (pprint-dispatch-entry-test-fn entry) (defer-type-checker entry))
      (unless (unknown-type-p ctype) ; already warned in this case
        ;; But (OR KNOWN UNKNOWN) did not signal - actually it is indeterminate
        ;; - depending on whather it was cached. I think we should not cache
        ;; any specifier that contains any unknown anywhere within it.
        (warn "~S contains an unrecognized type specifier" type)))
    (if consp
        (let ((hashtable (pprint-dispatch-table-cons-entries table)))
          (dolist (key (member-type-members (cons-type-car-type ctype)))
            (if function
                (setf (gethash key hashtable) entry)
                (remhash key hashtable))))
        (setf (pprint-dispatch-table-entries table)
              (let ((list (delete type (pprint-dispatch-table-entries table)
                                  :key #'pprint-dispatch-entry-type
                                  :test #'equal)))
                (if function
                    ;; ENTRY< is T if lower in priority, which should sort to
                    ;; the end, but MERGE's predicate wants T for the (a,b) pair
                    ;; if 'a' should go in front of 'b', so swap them.
                    ;; (COMPLEMENT #'entry<) is unstable wrt insertion order.
                    (merge 'list list (list entry) (lambda (a b) (entry< b a)))
                    list)))))
  (/show0 "about to return NIL from SET-PPRINT-DISPATCH")
  nil)

;;;; standard pretty-printing routines

(defun pprint-array (stream array)
  (cond ((and (null *print-array*) (null *print-readably*))
         (output-ugly-object array stream))
        ((and *print-readably*
              (not (array-readably-printable-p array)))
         (if *read-eval*
             (if (vectorp array)
                 (sb!impl::output-unreadable-vector-readably array stream)
                 (sb!impl::output-unreadable-array-readably array stream))
             (print-not-readable-error array stream)))
        ((vectorp array)
         (pprint-vector stream array))
        (t
         (pprint-multi-dim-array stream array))))

(defun pprint-vector (stream vector)
  (pprint-logical-block (stream nil :prefix "#(" :suffix ")")
    (dotimes (i (length vector))
      (unless (zerop i)
        (format stream " ~:_"))
      (pprint-pop)
      (output-object (aref vector i) stream))))

(defun pprint-multi-dim-array (stream array)
  (funcall (formatter "#~DA") stream (array-rank array))
  (with-array-data ((data array) (start) (end))
    (declare (ignore end))
    (labels ((output-guts (stream index dimensions)
               (if (null dimensions)
                   (output-object (aref data index) stream)
                   (pprint-logical-block
                       (stream nil :prefix "(" :suffix ")")
                     (let ((dim (car dimensions)))
                       (unless (zerop dim)
                         (let* ((dims (cdr dimensions))
                                (index index)
                                (step (reduce #'* dims))
                                (count 0))
                           (loop
                             (pprint-pop)
                             (output-guts stream index dims)
                             (when (= (incf count) dim)
                               (return))
                             (write-char #\space stream)
                             (pprint-newline (if dims :linear :fill)
                                             stream)
                             (incf index step)))))))))
      (output-guts stream start (array-dimensions array)))))

(defun pprint-lambda-list (stream lambda-list &rest noise)
  (declare (ignore noise))
  (pprint-logical-block (stream lambda-list :prefix "(" :suffix ")")
    (let ((state :required)
          (first t))
      (loop
        (pprint-exit-if-list-exhausted)
        (unless first
          (write-char #\space stream))
        (let ((arg (pprint-pop)))
          (unless first
            (case arg
              (&optional
               (setf state :optional)
               (pprint-newline :linear stream))
              ((&rest &body)
               (setf state :required)
               (pprint-newline :linear stream))
              (&key
               (setf state :key)
               (pprint-newline :linear stream))
              (&aux
               (setf state :optional)
               (pprint-newline :linear stream))
              (t
               (pprint-newline :fill stream))))
          (ecase state
            (:required
             (pprint-lambda-list stream arg))
            ((:optional :key)
             (pprint-logical-block
                 (stream arg :prefix "(" :suffix ")")
               (pprint-exit-if-list-exhausted)
               (if (eq state :key)
                   (pprint-logical-block
                       (stream (pprint-pop) :prefix "(" :suffix ")")
                     (pprint-exit-if-list-exhausted)
                     (output-object (pprint-pop) stream)
                     (pprint-exit-if-list-exhausted)
                     (write-char #\space stream)
                     (pprint-newline :fill stream)
                     (pprint-lambda-list stream (pprint-pop))
                     (loop
                       (pprint-exit-if-list-exhausted)
                       (write-char #\space stream)
                       (pprint-newline :fill stream)
                       (output-object (pprint-pop) stream)))
                   (pprint-lambda-list stream (pprint-pop)))
               (loop
                 (pprint-exit-if-list-exhausted)
                 (write-char #\space stream)
                 (pprint-newline :linear stream)
                 (output-object (pprint-pop) stream))))))
        (setf first nil)))))

(defun pprint-lambda (stream list &rest noise)
  (declare (ignore noise))
  (funcall (formatter
            ;; KLUDGE: This format string, and other format strings which also
            ;; refer to SB!PRETTY, rely on the current SBCL not-quite-ANSI
            ;; behavior of FORMATTER in order to make code which survives the
            ;; transition when SB!PRETTY is renamed to SB-PRETTY after cold
            ;; init. (ANSI says that the FORMATTER functions should be
            ;; equivalent to the format string, but the SBCL FORMATTER
            ;; functions contain references to package objects, not package
            ;; names, so they keep right on going if the packages are renamed.)
            ;; If our FORMATTER behavior is ever made more compliant, the code
            ;; here will have to change. -- WHN 19991207
            "~:<~^~W~^~3I ~:_~/SB!PRETTY:PPRINT-LAMBDA-LIST/~1I~@{ ~_~W~}~:>")
           stream
           list))

(defun pprint-block (stream list &rest noise)
  (declare (ignore noise))
  (funcall (formatter "~:<~^~W~^~3I ~:_~W~1I~@{ ~_~W~}~:>") stream list))

(defun pprint-flet (stream list &rest noise)
  (declare (ignore noise))
  (if (and (consp list)
           (consp (cdr list))
           (cddr list)
           ;; Filter out (FLET FOO :IN BAR) names.
           (and (consp (cddr list))
                (not (eq :in (third list)))))
      (funcall (formatter
                "~:<~^~W~^ ~@_~:<~@{~:<~^~W~^~3I ~:_~/SB!PRETTY:PPRINT-LAMBDA-LIST/~1I~:@_~@{~W~^ ~_~}~:>~^ ~_~}~:>~1I~@:_~@{~W~^ ~_~}~:>")
               stream
               list)
      ;; for printing function names like (flet foo)
      (pprint-logical-block (stream list :prefix "(" :suffix ")")
        (pprint-exit-if-list-exhausted)
        (write (pprint-pop) :stream stream)
        (loop
           (pprint-exit-if-list-exhausted)
           (write-char #\space stream)
           (write (pprint-pop) :stream stream)))))

(defun pprint-let (stream list &rest noise)
  (declare (ignore noise))
  (funcall (formatter "~:<~^~W~^ ~@_~:<~@{~:<~^~W~@{ ~_~W~}~:>~^ ~_~}~:>~1I~:@_~@{~W~^ ~_~}~:>")
           stream
           list))

(defun pprint-progn (stream list &rest noise)
  (declare (ignore noise))
  (pprint-linear stream list))

(defun pprint-progv (stream list &rest noise)
  (declare (ignore noise))
  (funcall (formatter "~:<~^~W~^~3I ~_~W~^ ~_~W~^~1I~@{ ~_~W~}~:>")
           stream list))

(defun pprint-prog2 (stream list &rest noise)
  (declare (ignore noise))
  (funcall (formatter "~:<~^~W~^~3I ~:_~W~^ ~_~W~^~1I~@{ ~_~W~}~:>")
           stream list))

(defun pprint-unquoting-comma (stream obj &rest noise)
  (declare (ignore noise))
  (write-string (svref #("," ",." ",@") (comma-kind obj)) stream)
  (when (eql (comma-kind obj) 0)
    ;; Ensure a space is written before any output that would change the meaning
    ;; of the preceding the comma to ",." or ",@" such as a symbol named "@BAR".
    (setf (pretty-stream-char-out-oneshot-hook stream)
          (lambda (stream char)
            (when (member char '(#\. #\@))
              (write-char #\Space stream)))))
  (output-object (comma-expr obj) stream))

(defvar *pprint-quote-with-syntactic-sugar* t)

(defun pprint-quote (stream list &rest noise)
  (declare (ignore noise))
  (when (and (listp list) (singleton-p (cdr list)))
    (let* ((pretty-p nil)
           (sigil (case (car list)
                    (function "#'")
                    ;; QUASIQUOTE can't choose not to print prettily.
                    ;; Wrongly nested commas beget unreadable sexprs.
                    (quasiquote (setq pretty-p t) "`")
                    (t "'")))) ; ordinary QUOTE
      (when (or pretty-p *pprint-quote-with-syntactic-sugar*)
        (write-string sigil stream)
        (return-from pprint-quote (output-object (cadr list) stream)))))
  (pprint-fill stream list))

(defun pprint-declare (stream list &rest noise)
  (declare (ignore noise))
  ;; Make sure to print (DECLARE (FUNCTION F)) not (DECLARE #'A).
  (let ((*pprint-quote-with-syntactic-sugar* nil))
    (pprint-spread-fun-call stream list)))

;;; Try to print every variable-value pair on one line; if that doesn't
;;; work print the value indented by 2 spaces:
;;;
;;;      (setq foo bar
;;;            quux xoo)
;;;  vs.
;;;      (setf foo
;;;              (long form ...)
;;;            quux xoo)
(defun pprint-setq (stream list &rest noise)
  (declare (ignore noise))
  (pprint-logical-block (stream list :prefix "(" :suffix ")")
    (pprint-exit-if-list-exhausted)
    (output-object (pprint-pop) stream)
    (pprint-exit-if-list-exhausted)
    (write-char #\space stream)
    (unless (listp (cdr list))
      (write-string ". " stream))
    (pprint-newline :miser stream)
    (pprint-logical-block (stream (cdr list) :prefix "" :suffix "")
      (loop
       (pprint-indent :block 2 stream)
       (output-object (pprint-pop) stream)
       (pprint-exit-if-list-exhausted)
       (write-char #\space stream)
       (pprint-newline :fill stream)
       (pprint-indent :block 0 stream)
       (output-object (pprint-pop) stream)
       (pprint-exit-if-list-exhausted)
       (write-char #\space stream)
       (pprint-newline :mandatory stream)))))

(eval-when (:compile-toplevel :execute)
(sb!xc:defmacro pprint-tagbody-guts (stream)
  `(loop
     (pprint-exit-if-list-exhausted)
     (write-char #\space ,stream)
     (let ((form-or-tag (pprint-pop)))
       (pprint-indent :block
                      (if (atom form-or-tag) 0 1)
                      ,stream)
       (pprint-newline :linear ,stream)
       (output-object form-or-tag ,stream)))))

(defun pprint-tagbody (stream list &rest noise)
  (declare (ignore noise))
  (pprint-logical-block (stream list :prefix "(" :suffix ")")
    (pprint-exit-if-list-exhausted)
    (output-object (pprint-pop) stream)
    (pprint-tagbody-guts stream)))

(defun pprint-case (stream list &rest noise)
  (declare (ignore noise))
  (funcall (formatter
            "~:<~^~W~^ ~3I~:_~W~1I~@{ ~_~:<~^~:/SB!PRETTY:PPRINT-FILL/~^~@{ ~_~W~}~:>~}~:>")
           stream
           list))

(defun pprint-defun (stream list &rest noise)
  (declare (ignore noise))
  (funcall (formatter
            "~:<~^~W~^ ~@_~:I~W~^ ~:_~/SB!PRETTY:PPRINT-LAMBDA-LIST/~1I~@{ ~_~W~}~:>")
           stream
           list))

(defun pprint-defmethod (stream list &rest noise)
  (declare (ignore noise))
  (if (and (consp (cdr list))
           (consp (cddr list))
           (consp (third list)))
      (pprint-defun stream list)
      (funcall (formatter
                "~:<~^~W~^ ~@_~:I~W~^ ~W~^ ~:_~/SB!PRETTY:PPRINT-LAMBDA-LIST/~1I~@{ ~_~W~}~:>")
               stream
               list)))

(defun pprint-defpackage (stream list &rest noise)
  (declare (ignore noise))
  (funcall  (formatter
             "~:<~W~^ ~3I~:_~W~^~1I~@{~:@_~:<~^~W~^ ~:I~@_~@{~W~^ ~_~}~:>~}~:>")
            stream
            list))

(defun pprint-destructuring-bind (stream list &rest noise)
  (declare (ignore noise))
  (funcall (formatter
            "~:<~^~W~^~3I ~_~:/SB!PRETTY:PPRINT-LAMBDA-LIST/~^ ~_~W~^~1I~@{ ~_~W~}~:>")
           stream list))

(defun pprint-do (stream list &rest noise)
  (declare (ignore noise))
  (pprint-logical-block (stream list :prefix "(" :suffix ")")
    (pprint-exit-if-list-exhausted)
    (output-object (pprint-pop) stream)
    (pprint-exit-if-list-exhausted)
    (write-char #\space stream)
    (pprint-indent :current 0 stream)
    (funcall (formatter "~:<~@{~:<~^~W~^ ~@_~:I~W~@{ ~_~W~}~:>~^~:@_~}~:>")
             stream
             (pprint-pop))
    (pprint-exit-if-list-exhausted)
    (write-char #\space stream)
    (pprint-newline :linear stream)
    (pprint-linear stream (pprint-pop))
    (pprint-tagbody-guts stream)))

(defun pprint-dolist (stream list &rest noise)
  (declare (ignore noise))
  (pprint-logical-block (stream list :prefix "(" :suffix ")")
    (pprint-exit-if-list-exhausted)
    (output-object (pprint-pop) stream)
    (pprint-exit-if-list-exhausted)
    (pprint-indent :block 3 stream)
    (write-char #\space stream)
    (pprint-newline :fill stream)
    (funcall (formatter "~:<~^~W~^ ~:_~:I~W~@{ ~_~W~}~:>")
             stream
             (pprint-pop))
    (pprint-tagbody-guts stream)))

(defun pprint-typecase (stream list &rest noise)
  (declare (ignore noise))
  (funcall (formatter
            "~:<~^~W~^ ~3I~:_~W~1I~@{ ~_~:<~^~W~^~@{ ~_~W~}~:>~}~:>")
           stream
           list))

(defun pprint-prog (stream list &rest noise)
  (declare (ignore noise))
  (pprint-logical-block (stream list :prefix "(" :suffix ")")
    (pprint-exit-if-list-exhausted)
    (output-object (pprint-pop) stream)
    (pprint-exit-if-list-exhausted)
    (write-char #\space stream)
    (pprint-newline :miser stream)
    (pprint-fill stream (pprint-pop))
    (pprint-tagbody-guts stream)))

;;; Each clause in this list will get its own line.
;;; FIXME: (LOOP for x in list summing (f x) into count finally ...)
;;;        puts a newline in between INTO and COUNT.
;;;        It would be awesome to have code in common with the macro
;;;        the properly represents each clauses.
(defvar *loop-seperating-clauses*
  '(:and
    :with :for
    :initially :finally
    :do :doing
    :collect :collecting
    :append :appending
    :nconc :nconcing
    :count :counting
    :sum :summing
    :maximize :maximizing
    :minimize :minimizing
    :if :when :unless :end
    :for :while :until :repeat :always :never :thereis
    ))

(defun pprint-extended-loop (stream list)
  (pprint-logical-block (stream list :prefix "(" :suffix ")")
    (output-object (pprint-pop) stream)
    (pprint-exit-if-list-exhausted)
    (write-char #\space stream)
    (pprint-indent :current 0 stream)
    (output-object (pprint-pop) stream)
    (pprint-exit-if-list-exhausted)
    (write-char #\space stream)
    (loop for thing = (pprint-pop)
          when (and (symbolp thing)
                    (member thing  *loop-seperating-clauses* :test #'string=))
          do (pprint-newline :mandatory stream)
          do (output-object thing stream)
          do (pprint-exit-if-list-exhausted)
          do (write-char #\space stream))))

(defun pprint-loop (stream list &rest noise)
  (declare (ignore noise))
  (destructuring-bind (loop-symbol . clauses) list
    (declare (ignore loop-symbol))
    (if (or (atom clauses) (consp (car clauses)))
        (pprint-spread-fun-call stream list)
        (pprint-extended-loop stream list))))

(defun pprint-if (stream list &rest noise)
  (declare (ignore noise))
  ;; Indent after the ``predicate'' form, and the ``then'' form.
  (funcall (formatter "~:<~^~W~^ ~:I~W~^ ~:@_~@{~W~^ ~:@_~}~:>")
           stream
           list))

(defun pprint-fun-call (stream list &rest noise)
  (declare (ignore noise))
  (funcall (formatter "~:<~^~W~^ ~:_~:I~@{~W~^ ~:_~}~:>")
           stream
           list))

(defun pprint-spread-fun-call (stream list &rest noise)
  (declare (ignore noise))
  ;; Similiar to PPRINT-FUN-CALL but emit a mandatory newline after
  ;; each parameter. I.e. spread out each parameter on its own line.
  (funcall (formatter "~:<~^~W~^ ~:_~:I~@{~W~^ ~:@_~}~:>")
           stream
           list))

(defun pprint-data-list (stream list &rest noise)
  (declare (ignore noise))
  (pprint-fill stream list))

;;; Returns an Emacs-style indent spec: an integer N, meaning indent
;;; the first N arguments specially then indent any further arguments
;;; like a body.
(defun macro-indentation (name)
  (labels ((clean-arglist (arglist)
             ;; FIXME: for purposes of introspection, we should never "leak"
             ;; that a macro uses an &AUX variable, that it takes &WHOLE,
             ;; or that it cares about its lexenv (though that's debatable).
             ;; Certainly the first two aspects are not part of the macro's
             ;; interface, and as such, should not be stored at all.
             "Remove &whole, &enviroment, and &aux elements from ARGLIST."
             (cond ((null arglist) '())
                   ((member (car arglist) '(&whole &environment))
                    (clean-arglist (cddr arglist)))
                   ((eq (car arglist) '&aux)
                    '())
                   (t (cons (car arglist) (clean-arglist (cdr arglist)))))))
    (let ((arglist (%fun-lambda-list (macro-function name))))
      (if (proper-list-p arglist)       ; guard against dotted arglists
          (position '&body (remove '&optional (clean-arglist arglist)))
          nil))))

;;; Pretty-Print macros by looking where &BODY appears in a macro's
;;; lambda-list.
(defun pprint-macro-call (stream list &rest noise)
  (declare (ignore noise))
  (let ((indentation (and (car list) (macro-indentation (car list)))))
    (unless indentation
      (return-from pprint-macro-call
        (pprint-fun-call stream list)))
    (pprint-logical-block (stream list :prefix "(" :suffix ")")
      (output-object (pprint-pop) stream)
      (pprint-exit-if-list-exhausted)
      (write-char #\space stream)
      (loop for indent from 0 below indentation do
            (cond
              ;; Place the very first argument next to the macro name
              ((zerop indent)
               (output-object (pprint-pop) stream)
               (pprint-exit-if-list-exhausted))
              ;; Indent any other non-body argument by the same
              ;; amount. It's what Emacs seems to do, too.
              (t
               (pprint-indent :block 3 stream)
               (pprint-newline :mandatory stream)
               (output-object (pprint-pop) stream)
               (pprint-exit-if-list-exhausted))))
      ;; Indent back for the body.
      (pprint-indent :block 1 stream)
      (pprint-newline :mandatory stream)
      (loop
       (output-object (pprint-pop) stream)
       (pprint-exit-if-list-exhausted)
       (pprint-newline :mandatory stream)))))

;;;; the interface seen by regular (ugly) printer and initialization routines

(eval-when (:compile-toplevel :execute)
(sb!xc:defmacro with-pretty-stream ((stream-var
                                     &optional (stream-expression stream-var))
                                    &body body)
  (let ((flet-name (sb!xc:gensym "WITH-PRETTY-STREAM")))
    `(flet ((,flet-name (,stream-var)
              ,@body))
       (let ((stream ,stream-expression))
         (if (pretty-stream-p stream)
             (,flet-name stream)
             (catch 'line-limit-abbreviation-happened
               (let ((stream (make-pretty-stream stream)))
                 (,flet-name stream)
                 (force-pretty-output stream)))))
       nil))))

;;; OUTPUT-PRETTY-OBJECT is called by OUTPUT-OBJECT when
;;; *PRINT-PRETTY* is true.
(defun output-pretty-object (object stream)
  (multiple-value-bind (fun pretty) (pprint-dispatch object)
    (if pretty
        (with-pretty-stream (stream)
          (funcall fun stream object))
        ;; No point in consing up a pretty stream if we are not using pretty
        ;; printing the object after all.
        (output-ugly-object object stream))))

(defun call-logical-block-printer (proc stream prefix per-line-p suffix
                                   &optional (object nil obj-supplied-p))
  ;; PREFIX and SUFFIX will be checked for stringness by START-LOGICAL-BLOCK.
  ;; Doing it here would be more strict, but I really don't think it's worth
  ;; an extra check. The only observable difference would occur when you have
  ;; a non-list object which bypasses START-LOGICAL-BLOCK.
  ;; Also, START-LOGICAL-BLOCK could become an FLET inside here.
  (declare (function proc))
  (with-pretty-stream (stream (out-synonym-of stream))
    (if (or (not (listp object)) ; implies obj-supplied-p
            (and (eq (car object) 'quasiquote)
                 ;; We can only bail out from printing this logical block
                 ;; if the quasiquote printer would *NOT* punt.
                 ;; If it would punt, then we have to forge ahead.
                 (singleton-p (cdr object))))
        ;; the spec says "If object is not a list, it is printed using WRITE"
        ;; but I guess this is close enough.
        (output-object object stream)
        (dx-let ((state (cons 0 stream)))
          (if obj-supplied-p
              (with-circularity-detection (object stream)
                (descend-into (stream)
                  (start-logical-block stream prefix per-line-p suffix)
                  (funcall proc object state stream)
                  ;; Comment preserved for posterity:
                  ;;   FIXME: Don't we need UNWIND-PROTECT to ensure this
                  ;;   always gets executed?
                  ;; I think not because I wouldn't characterize this as
                  ;; "cleanup" code. If and only if you follow the accepted
                  ;; protocol for defining and using print functions should
                  ;; the behavior be expected to be reasonable and predictable.
                  ;; Throwing to LINE-LIMIT-ABBREVIATION-HAPPENED is designed
                  ;; to do the right thing, and printing should not generally
                  ;; continue to have side-effects if the user felt it necessary
                  ;; to nonlocally exit in an unexpected way for other reasons.
                  (end-logical-block stream)))
              (descend-into (stream)
                (start-logical-block stream prefix per-line-p suffix)
                (funcall proc state stream)
                (end-logical-block stream)))))))

;; Return non-nil if we should keep printing within the logical-block,
;; or NIL to stop printing due to non-list, length cutoff, or circularity.
(defun pprint-length-check (obj state)
  (let ((stream (cdr state)))
    (cond ((or (not (listp obj))
               ;; Consider (A . `(,B C)) = (A QUASIQUOTE ,B C)
               ;; We have to detect this and print as the form on the left,
               ;; since pretty commas with no containing #\` will be unreadable
               ;; due to a nesting error.
               (and (eq (car obj) 'quasiquote) (singleton-p (cdr obj))))
           (write-string ". " stream)
           (output-object obj stream)
           nil)
          ((and (not *print-readably*) (eql (car state) *print-length*))
           (write-string "..." stream)
           nil)
          ((and obj
                (plusp (car state))
                (check-for-circularity obj nil :logical-block))
           (write-string ". " stream)
           (output-object obj stream)
           nil)
          (t
           (incf (car state))))))

;; As above, but for logical blocks with an unspecific object.
(defun pprint-length-check* (state)
  (let ((stream (cdr state)))
    (cond ((and (not *print-readably*) (eql (car state) *print-length*))
           (write-string "..." stream)
           nil)
          (t
           (incf (car state))))))

(defun !pprint-cold-init ()
  (/show0 "entering !PPRINT-COLD-INIT")
  ;; Kludge: We set *STANDARD-PP-D-TABLE* to a new table even though
  ;; it's going to be set to a copy of *INITIAL-PP-D-T* below because
  ;; it's used in WITH-STANDARD-IO-SYNTAX, and condition reportery
  ;; possibly performed in the following extent may use W-S-IO-SYNTAX.
  (setf *standard-pprint-dispatch-table* (make-pprint-dispatch-table))
  (setf *initial-pprint-dispatch-table*  nil)
  (let ((*print-pprint-dispatch* (make-pprint-dispatch-table)))
    (/show0 "doing SET-PPRINT-DISPATCH for regular types")
    (set-pprint-dispatch '(and array (not (or string bit-vector))) #'pprint-array)
    ;; MACRO-FUNCTION must have effectively higher priority than FBOUNDP.
    ;; The implementation happens to check identical priorities in the order added,
    ;; but that's unspecified behavior.  Both must be _strictly_ lower than the
    ;; default cons entries though.
    (set-pprint-dispatch '(cons (and symbol (satisfies macro-function)))
                         #'pprint-macro-call -1)
    (set-pprint-dispatch '(cons (and symbol (satisfies fboundp)))
                         #'pprint-fun-call -1)
    (set-pprint-dispatch '(cons symbol)
                         #'pprint-data-list -2)
    (set-pprint-dispatch 'cons #'pprint-fill -2)
    (set-pprint-dispatch 'sb!impl::comma #'pprint-unquoting-comma -3)
    ;; cons cells with interesting things for the car
    (/show0 "doing SET-PPRINT-DISPATCH for CONS with interesting CAR")

    (dolist (magic-form '((lambda pprint-lambda)
                          (declare pprint-declare)

                          ;; special forms
                          (block pprint-block)
                          (catch pprint-block)
                          (eval-when pprint-block)
                          (flet pprint-flet)
                          (function pprint-quote)
                          (if pprint-if)
                          (labels pprint-flet)
                          ((let let*) pprint-let)
                          (locally pprint-progn)
                          (macrolet pprint-flet)
                          (multiple-value-call pprint-block)
                          (multiple-value-prog1 pprint-block)
                          (progn pprint-progn)
                          (progv pprint-progv)
                          ((quasiquote quote) pprint-quote)
                          (return-from pprint-block)
                          ((setq psetq setf psetf) pprint-setq)
                          (symbol-macrolet pprint-let)
                          (tagbody pprint-tagbody)
                          (throw pprint-block)
                          (unwind-protect pprint-block)

                          ;; macros
                          ((case ccase ecase) pprint-case)
                          ((ctypecase etypecase typecase) pprint-typecase)
                          (declaim pprint-declare)
                          (defconstant pprint-block)
                          (define-modify-macro pprint-defun)
                          (define-setf-expander pprint-defun)
                          (defmacro pprint-defun)
                          (defmethod pprint-defmethod)
                          (defpackage pprint-defpackage)
                          (defparameter pprint-block)
                          (defsetf pprint-defun)
                          (defstruct pprint-block)
                          (deftype pprint-defun)
                          (defun pprint-defun)
                          (defvar pprint-block)
                          (destructuring-bind pprint-destructuring-bind)
                          ((do do*) pprint-do)
                          ((do-all-symbols do-external-symbols do-symbols
                            dolist dotimes) pprint-dolist)
                          #+nil (handler-bind ...)
                          #+nil (handler-case ...)
                          (loop pprint-loop)
                          (multiple-value-bind pprint-prog2)
                          (multiple-value-setq pprint-block)
                          (pprint-logical-block pprint-block)
                          (print-unreadable-object pprint-block)
                          ((prog prog*) pprint-prog)
                          (prog1 pprint-block)
                          (prog2 pprint-prog2)
                          #+nil (restart-bind ...)
                          #+nil (restart-case ...)
                          (step pprint-progn)
                          (time pprint-progn)
                          ((unless when) pprint-block)
                          (with-compilation-unit pprint-block)
                          #+nil (with-condition-restarts ...)
                          (with-hash-table-iterator pprint-block)
                          (with-input-from-string pprint-block)
                          (with-open-file pprint-block)
                          (with-open-stream pprint-block)
                          (with-output-to-string pprint-block)
                          (with-package-iterator pprint-block)
                          (with-simple-restart pprint-block)
                          (with-standard-io-syntax pprint-progn)

                          ;; sbcl specific
                          (sb!int:dx-flet pprint-flet)
                          ))

      ;; Grouping some symbols together in the above list looks pretty.
      ;; The sharing of dispatch entries is inconsequential.
      (set-pprint-dispatch (let ((thing (first magic-form)))
                             `(cons (member
                                     ,@(if (consp thing) thing (list thing)))))
                           (symbol-function (second magic-form))))
    (setf *initial-pprint-dispatch-table* *print-pprint-dispatch*))

  (setf *standard-pprint-dispatch-table*
        (copy-pprint-dispatch *initial-pprint-dispatch-table*))
  (setf *print-pprint-dispatch*
        (copy-pprint-dispatch *initial-pprint-dispatch-table*))
  (setf *print-pretty* t))
