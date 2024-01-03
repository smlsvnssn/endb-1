(defpackage :endb/sql
  (:use :cl)
  (:export #:*query-timing*
           #:make-db #:make-directory-db #:db-close #:make-dbms #:dbms-close #:begin-write-tx #:commit-write-tx #:execute-sql #:interpret-sql-literal)
  (:import-from :endb/arrow)
  (:import-from :endb/json)
  (:import-from :endb/sql/db)
  (:import-from :endb/sql/expr)
  (:import-from :endb/sql/compiler)
  (:import-from :endb/lib/arrow)
  (:import-from :endb/lib/cst)
  (:import-from :endb/lib)
  (:import-from :endb/storage)
  (:import-from :endb/storage/buffer-pool)
  (:import-from :fset)
  (:import-from :uiop))
(in-package :endb/sql)

(defvar *query-timing* nil)

(defun make-db (&key (store (make-instance 'endb/storage:in-memory-store)))
  (endb/lib:init-lib)
  (let* ((buffer-pool (endb/storage/buffer-pool:make-buffer-pool :get-object-fn (lambda (path)
                                                                                  (endb/storage:store-get-object store path))))
         (meta-data (endb/storage:store-replay store)))
    (endb/sql/db:make-db :store store :buffer-pool buffer-pool :meta-data meta-data)))

(defun make-directory-db (&key (directory "endb_data"))
  (endb/lib:init-lib)
  (let* ((store (make-instance 'endb/storage:disk-store :directory directory)))
    (make-db :store store)))

(defun db-close (db)
  (endb/queue:queue-close (endb/sql/db:db-indexer-queue db))
  (when (endb/sql/db:db-indexer-thread db)
    (bt:join-thread (endb/sql/db:db-indexer-thread db)))
  (endb/storage:store-close (endb/sql/db:db-store db))
  (endb/storage/buffer-pool:buffer-pool-close (endb/sql/db:db-buffer-pool db)))

(defun make-dbms (&key directory)
  (let ((dbms (endb/sql/db:make-dbms :db (if directory
                                             (make-directory-db :directory directory)
                                             (make-db)))))
    (when directory
      (endb/sql/db:start-background-compaction
       dbms
       (lambda (tx-fn)
         (bt:with-lock-held ((endb/sql/db:dbms-write-lock dbms))
           (let ((write-db (begin-write-tx (endb/sql/db:dbms-db dbms))))
             (funcall tx-fn write-db)
             (setf (endb/sql/db:dbms-db dbms) (commit-write-tx (endb/sql/db:dbms-db dbms) write-db)))))
       (lambda (path buffer)
         (endb/storage:store-put-object (endb/sql/db:db-store (endb/sql/db:dbms-db dbms)) path buffer))))
    (endb/sql/db:start-background-indexer (endb/sql/db:dbms-db dbms))
    dbms))

(defun dbms-close (dbms)
  (endb/queue:queue-close (endb/sql/db:dbms-compaction-queue dbms))
  (when (endb/sql/db:dbms-compaction-thread dbms)
    (bt:join-thread (endb/sql/db:dbms-compaction-thread dbms)))
  (db-close (endb/sql/db:dbms-db dbms)))

(defun begin-write-tx (db)
  (let* ((bp (endb/storage/buffer-pool:make-writeable-buffer-pool :parent-pool (endb/sql/db:db-buffer-pool db)))
         (write-db (endb/sql/db:copy-db db)))
    (setf (endb/sql/db:db-buffer-pool write-db) bp)
    (setf (endb/sql/db:db-current-timestamp write-db) (endb/sql/db:syn-current_timestamp db))
    write-db))

(defun %execute-constraints (db)
  (fset:do-map (k v (endb/sql/db:constraint-definitions db))
    (when (equalp '(#(nil)) (handler-case
                                (execute-sql db v)
                              (endb/sql/expr:sql-runtime-error (e)
                                (endb/lib:log-warn "Constraint ~A raised an error, ignoring: ~A" k e))))
      (error 'endb/sql/expr:sql-runtime-error :message (format nil "Constraint failed: ~A" k)))))

(defun commit-write-tx (current-db write-db &key (fsyncp t))
  (let ((current-md (endb/sql/db:db-meta-data current-db))
        (tx-md (endb/sql/db:db-meta-data write-db)))
    (if (eq current-md tx-md)
        current-db
        (progn
          (%execute-constraints write-db)
          (let* ((tx-id (1+ (or (fset:lookup tx-md "_last_tx") 0)))
                 (tx-md (fset:with tx-md "_last_tx" tx-id))
                 (md-diff (endb/json:json-diff current-md tx-md))
                 (md-diff (fset:with md-diff "_tx_log_version" endb/storage:*tx-log-version*))
                 (store (endb/sql/db:db-store write-db))
                 (bp (endb/sql/db:db-buffer-pool write-db))
                 (arrow-buffers-map (make-hash-table :test 'equal)))
            (maphash
             (lambda (k v)
               (let ((buffer (endb/lib/arrow:write-arrow-arrays-to-ipc-buffer v)))
                 (destructuring-bind (table batch-file)
                     (uiop:split-string k :max 2 :separator "/")
                   (let* ((table-md (fset:lookup md-diff table))
                          (batch-md (fset:map-union (fset:lookup table-md batch-file)
                                                    (fset:map ("sha1" (string-downcase (endb/lib:sha1 buffer)))
                                                              ("byte_size" (length buffer))))))
                     (setf md-diff (fset:with md-diff table (fset:with table-md batch-file batch-md)))))
                 (setf (gethash k arrow-buffers-map) buffer)))
             (endb/storage/buffer-pool:writeable-buffer-pool-pool bp))
            (let ((new-md (endb/json:json-merge-patch current-md md-diff))
                  (current-local-time (endb/arrow:arrow-timestamp-micros-to-local-time (endb/sql/db:db-current-timestamp write-db))))
              (endb/storage:store-write-tx store tx-id new-md md-diff arrow-buffers-map :fsyncp fsyncp :mtime current-local-time)
              (let ((new-db (endb/sql/db:copy-db current-db)))
                (setf (endb/sql/db:db-meta-data new-db) new-md)
                new-db)))))))

(defun %resolve-parameters (ast)
  (let ((idx 0)
        (parameters))
    (labels ((walk (x)
               (cond
                 ((and (listp x)
                       (eq :parameter (first x)))
                  (if (second x)
                      (progn
                        (pushnew (symbol-name (second x)) parameters)
                        x)
                      (let ((src `(:parameter ,idx)))
                        (push idx parameters)
                        (incf idx)
                        src)))
                 ((listp x)
                  (mapcar #'walk x))
                 (t x))))
      (values (walk ast) parameters))))

(defun %compile-sql-fn (db sql)
  (let ((k (endb/sql/db:query-cache-key db sql)))
    (or (gethash k (endb/sql/db:db-query-cache db))
        (let* ((ast (endb/lib/cst:parse-sql-ast sql))
               (ctx (fset:map (:db db) (:sql sql)))
               (*print-length* 16))
          (multiple-value-bind (sql-fn cachep)
              (multiple-value-bind (ast expected-parameters)
                  (%resolve-parameters ast)
                (if (eq :multiple-statments (first ast))
                    (let ((asts (second ast)))
                      (if (= 1 (length asts))
                          (endb/sql/compiler:compile-sql ctx (first asts) expected-parameters)
                          (values
                           (lambda (db parameters)
                             (handler-case
                                 (loop with end-idx = (length asts)
                                       for ast in asts
                                       for idx from 1
                                       for sql-fn = (endb/sql/compiler:compile-sql ctx ast expected-parameters)
                                       if (= end-idx idx)
                                         do (return (funcall sql-fn db parameters))
                                       else
                                         do (funcall sql-fn db parameters))
                               (endb/sql/db:sql-tx-error ()
                                 (error 'endb/sql/expr:sql-runtime-error :message "Explicit transactions not supported in multiple statements"))))
                           nil)))
                    (endb/sql/compiler:compile-sql ctx ast expected-parameters)))
            (when cachep
              (setf (gethash k (endb/sql/db:db-query-cache db)) sql-fn))
            sql-fn)))))

(defun %execute-sql (db sql parameters manyp)
  (when (and manyp (not (fset:seq? parameters)))
    (error 'endb/sql/expr:sql-runtime-error :message "Many parameters must be an array"))
  (let* ((sql-fn (%compile-sql-fn db sql))
         (all-parameters (if manyp
                             (fset:convert 'list parameters)
                             (list parameters)))
         (all-parameters (loop for parameters in all-parameters
                               collect (etypecase parameters
                                         (fset:map parameters)
                                         (fset:seq (fset:convert 'fset:map (loop for x in (fset:convert 'list parameters)
                                                                                 for idx from 0
                                                                                 collect (cons idx x))))
                                         (t (error 'endb/sql/expr:sql-runtime-error :message "Parameters must be an array or an object"))))))
    (loop with final-result = nil
          with final-result-code = nil
          for parameters in all-parameters
          do (multiple-value-bind (result result-code)
                 (funcall sql-fn db parameters)
               (setf final-result result)
               (if (numberp result-code)
                   (setf final-result-code (+ result-code (or final-result-code 0)))
                   (setf final-result-code result-code)))
          finally (return (values final-result final-result-code)))))

(defun execute-sql (db sql &optional (parameters (fset:empty-seq)) manyp)
  (handler-case
      (if *query-timing*
          (time (%execute-sql db sql parameters manyp))
          (%execute-sql db sql parameters manyp))
    #+sbcl (sb-pcl::effective-method-condition (e)
             (let ((fn (sb-pcl::generic-function-name
                        (sb-pcl::effective-method-condition-generic-function e))))
               (if (equal (find-package 'endb/sql/expr)
                          (symbol-package fn))
                   (error 'endb/sql/expr:sql-runtime-error
                          :message (format nil "Invalid argument types: ~A(~{~A~^, ~})"
                                           (ppcre:regex-replace "^SQL-(UNARY)?"
                                                                (symbol-name fn)
                                                                "")
                                           (loop for arg in (sb-pcl::effective-method-condition-args e)
                                                 collect (if (stringp arg)
                                                             (prin1-to-string arg)
                                                             (endb/sql/expr:syn-cast arg :varchar)))))
                   (error e))))))

(defun %interpret-sql-literal (ast)
  (cond
    ((or (stringp ast)
         (numberp ast)
         (vectorp ast))
     ast)
    ((eq :true ast) t)
    ((eq :false ast) nil)
    ((eq :null ast) :null)
    ((and (listp ast)
          (eq :object (first ast))
          (>= (length ast) 2))
     (reduce
      (lambda (acc kv)
        (let ((k (first kv)))
          (fset:with acc (if (stringp k)
                             k
                             (symbol-name k))
                     (%interpret-sql-literal (second kv)))))
      (second ast)
      :initial-value (fset:empty-map)))
    ((and (listp ast)
          (= 2 (length ast)))
     (case (first ast)
       (:- (if (numberp (second ast))
               (- (second ast))
               (error 'endb/sql/expr:sql-runtime-error :message "Invalid literal")))
       (:date (endb/sql/expr:sql-date (second ast)))
       (:time (endb/sql/expr:sql-time (second ast)))
       (:timestamp (endb/sql/expr:sql-datetime (second ast)))
       (:duration (endb/sql/expr:sql-duration (second ast)))
       (:blob (endb/sql/expr:sql-unhex (second ast)))
       (:array (fset:convert 'fset:seq (mapcar #'%interpret-sql-literal (second ast))))
       (t (error 'endb/sql/expr:sql-runtime-error :message "Invalid literal"))))
    ((and (listp ast)
          (eq :interval (first ast))
          (<= 2 (length (rest ast)) 3))
     (apply #'endb/sql/expr:syn-interval (rest ast)))
    (t (error 'endb/sql/expr:sql-runtime-error :message "Invalid literal"))))

(defun interpret-sql-literal (src)
  (let* ((select-list (handler-case
                          (cadr (endb/lib/cst:parse-sql-ast (format nil "SELECT ~A" src)))
                        (endb/lib/cst:sql-parse-error (e)
                          (declare (ignore e)))))
         (ast (car select-list))
         (literal (if (or (not (= 1 (length select-list)))
                          (not (= 1 (length ast))))
                      :error
                      (handler-case
                          (%interpret-sql-literal (car ast))
                        (endb/sql/expr:sql-runtime-error (e)
                          (declare (ignore e))
                          :error)))))
    (if (eq :error literal)
        (error 'endb/sql/expr:sql-runtime-error
               :message (format nil "Invalid literal: ~A" src))
        literal)))
