(defpackage :endb-test/lib/arrow
  (:use :cl :fiveam :endb/lib/arrow)
  (:import-from :endb/arrow)
  (:import-from :fset)
  (:import-from :asdf))
(in-package :endb-test/lib/arrow)

(in-suite* :lib)

(test arrow-ffi
  (let ((expected (coerce #(65 82 82 79 87 49 0 0 255 255 255 255 120 0 0 0 4 0 0 0 242 255 255 255 20 0
                            0 0 4 0 1 0 0 0 10 0 11 0 8 0 10 0 4 0 248 255 255 255 12 0 0 0 8 0 8 0 0 0 4
                            0 1 0 0 0 4 0 0 0 236 255 255 255 56 0 0 0 32 0 0 0 24 0 0 0 1 2 0 0 16 0 18
                            0 4 0 16 0 17 0 8 0 0 0 12 0 0 0 0 0 244 255 255 255 64 0 0 0 1 0 0 0 8 0 9 0
                            4 0 8 0 1 0 0 0 97 0 0 0 255 255 255 255 136 0 0 0 4 0 0 0 236 255 255 255 64
                            0 0 0 0 0 0 0 20 0 0 0 4 0 3 0 12 0 19 0 16 0 18 0 12 0 4 0 230 255 255 255 1
                            0 0 0 0 0 0 0 64 0 0 0 20 0 0 0 0 0 0 0 0 0 10 0 20 0 4 0 12 0 16 0 2 0 0 0 0
                            0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 8 0 0 0 0 0 0 0 0 0 0 0 1 0 0 0
                            1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
                            0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
                            0 0 0 0 0 0 255 255 255 255 0 0 0 0 8 0 0 0 0 0 0 0 236 255 255 255 64 0 0 0
                            56 0 0 0 20 0 0 0 4 0 0 0 12 0 18 0 16 0 4 0 8 0 12 0 1 0 0 0 136 0 0 0 0 0 0
                            0 144 0 0 0 0 0 0 0 64 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 248 255 255 255 12 0 0 0
                            8 0 8 0 0 0 4 0 1 0 0 0 4 0 0 0 236 255 255 255 56 0 0 0 32 0 0 0 24 0 0 0 1
                            2 0 0 16 0 18 0 4 0 16 0 17 0 8 0 0 0 12 0 0 0 0 0 244 255 255 255 64 0 0 0 1
                            0 0 0 8 0 9 0 4 0 8 0 1 0 0 0 97 0 166 0 0 0 65 82 82 79 87 49)
                          '(vector (unsigned-byte 8))))
        (array (list (fset:map ("a" 1)))))

    (is (equalp (list array)
                (loop for x in (read-arrow-arrays-from-ipc-buffer expected)
                      collect (coerce x 'list))))

    (is (equalp (list array)
                (loop for x in (read-arrow-arrays-from-ipc-buffer
                                (write-arrow-arrays-to-ipc-buffer
                                 (list (endb/arrow:to-arrow array))))
                      collect (coerce x 'list))))

    (dolist (array `((1 :null 2 4 8)
                     (1 2 3 4 8)
                     (,(fset:seq 12 -7 25) :null ,(fset:seq 0 -127 127 50) ,(fset:seq))
                     (,(fset:seq (fset:seq 1 2) (fset:seq 3 4)) ,(fset:seq (fset:seq 5 6 7) :null (fset:seq 8)) ,(fset:seq (fset:seq 9 10)))
                     (1.2d0 :null 3.4d0 5)
                     ;; wrapped in a list as a top-level row cannot be null.
                     (,(fset:seq (fset:map ("name" "joe") ("id" 1))
                                 (fset:map ("name" :null) ("id" 2))
                                 :null
                                 (fset:map ("name" "mark") ("id" 4))))
                     (170141183460469231731687303715884105727 -170141183460469231731687303715884105728)
                     (,(fset:empty-map))
                     (,(endb/arrow:parse-arrow-date-millis "2001-01-01")
                      ,(endb/arrow:parse-arrow-time-micros "12:01:20")
                      ,(endb/arrow:parse-arrow-timestamp-micros "2023-05-16T14:43:39.970062Z")
                      ,(endb/arrow:parse-arrow-interval-month-day-nanos "P3Y6M")
                      ,(endb/arrow:parse-arrow-interval-month-day-nanos "PT12H30M5S"))))
      (is (equalp (list array)
                  (loop for x in (read-arrow-arrays-from-ipc-buffer
                                  (write-arrow-arrays-to-ipc-buffer
                                   (list (endb/arrow:to-arrow (loop for x in array
                                                                    collect (fset:map ("" x)))))))
                        collect (loop for y in (coerce x 'list)
                                      collect (fset:lookup y ""))))))

    (let ((arrays '((1 :null 2 4 8)
                    (1 2 3 4 8))))
      (is (equalp arrays
                  (loop for x in (read-arrow-arrays-from-ipc-buffer
                                  (write-arrow-arrays-to-ipc-buffer
                                   (loop for array in arrays
                                         collect (endb/arrow:to-arrow (loop for x in array
                                                                            collect (fset:map ("" x)))))))
                        collect (loop for y in (coerce x 'list)
                                      collect (fset:lookup y ""))))))))

(test arrow-ffi-ipc-files
  (let* ((target-dir (asdf:system-relative-pathname :endb-test "target/"))
         (test-file (merge-pathnames "example.arrow" target-dir))
         (arrays `((,(fset:map ("a" 1)))
                   (,(fset:map ("a" 2))))))
    (ensure-directories-exist target-dir)
    (unwind-protect
         (progn
           (write-arrow-arrays-to-ipc-file test-file (mapcar #'endb/arrow:to-arrow arrays))
           (is (equalp arrays (loop for x in (read-arrow-arrays-from-ipc-file test-file)
                                    collect (coerce x 'list)))))
      (when (probe-file test-file)
        (delete-file test-file)))))

(test arrow-ffi-ipc-streams
  (let ((arrays `((,(fset:map ("a" 1)))
                  (,(fset:map ("a" 2))))))
    (is (equalp arrays (loop for x in (read-arrow-arrays-from-ipc-buffer
                                       (write-arrow-arrays-to-ipc-buffer
                                        (mapcar #'endb/arrow:to-arrow arrays)
                                        :ipc-stream-p t))
                             collect (coerce x 'list))))))
