(defpackage :endb/sql
  (:use :cl)
  (:export #:*query-timing* #:*lib-parser* #:make-db #:make-directory-db #:close-db #:begin-write-tx #:commit-write-tx #:execute-sql)
  (:import-from :alexandria)
  (:import-from :endb/sql/expr)
  (:import-from :endb/sql/parser)
  (:import-from :endb/sql/compiler)
  (:import-from :endb/lib/arrow)
  (:import-from :endb/lib/parser)
  (:import-from :endb/storage/buffer-pool)
  (:import-from :endb/storage/meta-data)
  (:import-from :endb/storage/object-store)
  (:import-from :endb/storage/wal)
  (:import-from :fset))
(in-package :endb/sql)

(defvar *query-timing* nil)
(defvar *lib-parser* nil)

(defun %replay-log (read-wal)
  (loop with md = (fset:empty-map)
        for (buffer . name) = (multiple-value-bind (buffer name)
                                  (endb/storage/wal:wal-read-next-entry read-wal :skip-if (lambda (x)
                                                                                            (not (alexandria:starts-with-subseq "_log/" x))))
                                (cons buffer name))
        when buffer
          do (setf md (endb/storage/meta-data:meta-data-merge-patch md (endb/storage/meta-data:json->meta-data buffer)))
        while name
        finally (return md)))

(defun make-db (&key (meta-data (fset:empty-map)) (wal (endb/storage/wal:make-memory-wal)) (object-store (endb/storage/object-store:make-memory-object-store)))
  (let* ((buffer-pool (endb/storage/buffer-pool:make-buffer-pool :object-store object-store)))
    (endb/sql/expr:make-db :wal wal :object-store object-store :buffer-pool buffer-pool :meta-data meta-data)))

(defun make-directory-db (&key (directory "endb_data")
                            (object-store-path (merge-pathnames "object_store" (uiop:ensure-directory-pathname directory)))
                            (wal-file (merge-pathnames "wal.log" (uiop:ensure-directory-pathname directory))))
  (ensure-directories-exist wal-file)
  (let* ((md (with-open-file (read-in wal-file :direction :io
                                               :element-type '(unsigned-byte 8)
                                               :if-exists :overwrite
                                               :if-does-not-exist :create)
               (if (plusp (file-length read-in))
                   (%replay-log (endb/storage/wal:open-tar-wal :stream read-in :direction :input))
                   (fset:empty-map))))
         (write-io (open wal-file :direction :io :element-type '(unsigned-byte 8) :if-exists :overwrite :if-does-not-exist :create))
         (write-wal (endb/storage/wal:open-tar-wal :stream write-io))
         (os (if (or (null object-store-path)
                     (equal (pathname object-store-path) (pathname wal-file)))
                 (endb/storage/object-store:open-tar-object-store :stream (open wal-file :element-type '(unsigned-byte 8) :if-does-not-exist :create))
                 (endb/storage/object-store:make-directory-object-store :path object-store-path))))
    (endb/storage/wal:tar-wal-position-stream-at-end write-io)
    (make-db :wal write-wal :object-store os :meta-data md)))

(defun close-db (db)
  (endb/storage/wal:wal-close (endb/sql/expr:db-wal db))
  (endb/storage/buffer-pool:buffer-pool-close (endb/sql/expr:db-buffer-pool db))
  (endb/storage/object-store:object-store-close (endb/sql/expr:db-object-store db)))

(defun begin-write-tx (db)
  (let* ((bp (endb/storage/buffer-pool:make-writeable-buffer-pool :parent-pool (endb/sql/expr:db-buffer-pool db)))
         (write-db (endb/sql/expr:copy-db db)))
    (setf (endb/sql/expr:db-buffer-pool write-db) bp)
    write-db))

(defun %log-filename (tx-id)
  (format nil "_log/~(~16,'0x~).json" tx-id))

(defun %write-new-buffers (write-db)
  (let ((os (endb/sql/expr:db-object-store write-db))
        (bp (endb/sql/expr:db-buffer-pool write-db))
        (wal (endb/sql/expr:db-wal write-db)))
    (loop for k being the hash-key
            using (hash-value v)
              of (endb/storage/buffer-pool:writeable-buffer-pool-pool bp)
          for buffer = (endb/lib/arrow:write-arrow-arrays-to-ipc-buffer v)
          do (endb/storage/object-store:object-store-put os k buffer)
             (endb/storage/wal:wal-append-entry wal k buffer))))

(defun commit-write-tx (current-db write-db &key (fsyncp t))
  (let ((current-md (endb/sql/expr:db-meta-data current-db))
        (tx-md (endb/sql/expr:db-meta-data write-db)))
    (if (eq current-md tx-md)
        current-db
        (let* ((tx-id (1+ (or (fset:lookup tx-md "_last_tx") 0)))
               (tx-md (fset:with tx-md "_last_tx" tx-id))
               (md-diff (endb/storage/meta-data:meta-data-diff current-md tx-md))
               (wal (endb/sql/expr:db-wal write-db)))
          (%write-new-buffers write-db)
          (endb/storage/wal:wal-append-entry wal (%log-filename tx-id) (endb/storage/meta-data:meta-data->json md-diff))
          (when fsyncp
            (endb/storage/wal:wal-fsync wal))
          (let ((new-db (endb/sql/expr:copy-db current-db))
                (new-md (endb/storage/meta-data:meta-data-merge-patch current-md md-diff)))
            (setf (endb/sql/expr:db-meta-data new-db) new-md)
            new-db)))))

(defun %execute-sql (db sql)
  (let* ((ast (if *lib-parser*
                  (endb/lib/parser:parse-sql sql)
                  (endb/sql/parser:parse-sql sql)))
         (ctx (fset:map (:db db)))
         (sql-fn (endb/sql/compiler:compile-sql ctx ast))
         (*print-length* 16))
    (funcall sql-fn db)))

(defun execute-sql (db sql)
  (if *query-timing*
      (time (%execute-sql db sql))
      (%execute-sql db sql)))
