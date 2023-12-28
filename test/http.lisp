(defpackage :endb-test/http
  (:use :cl :fiveam :endb/http)
  (:import-from :bordeaux-threads)
  (:import-from :fset)
  (:import-from :endb/json)
  (:import-from :endb/lib)
  (:import-from :endb/lib/server)
  (:import-from :endb/sql)
  (:import-from :endb/sql/db))
(in-package :endb-test/http)

(in-suite* :http)

(defvar *current-response*)

(defun %on-response-init (status-code content-type)
  (setf *current-response* (list status-code
                                 (unless (equalp "" content-type)
                                   (list :content-type content-type))
                                 ""))
  nil)

(defun %on-response-send (body)
  (setf *current-response* (append (butlast *current-response*)
                                   (list (concatenate 'string (car (last *current-response*)) body))))
  nil)

(defun %do-query (request-method content-type sql parameters manyp &optional (on-response-init #'%on-response-init) (on-response-send #'%on-response-send))
  (let ((*current-response*))
    (endb-query request-method content-type sql parameters manyp on-response-init on-response-send)
    *current-response*))

(defun %do-websocket (connection message)
  (let* ((acc)
         (on-ws-send (lambda (message)
                       (setf acc message))))
    (endb-on-ws-message connection message on-ws-send)
    acc))

(test parameters
  (let* ((endb/lib/server:*db* (endb/sql:make-db)))
    (is (equal
         (list +http-ok+
               '(:content-type "application/json")
               (format nil "[[\"2001-01-01\",{\"b\":1}]]~%"))
         (%do-query "POST" "application/json" "SELECT ?, ?" "[{\"@value\":\"2001-01-01\",\"@type\":\"xsd:date\"},{\"b\":1}]" "false")))


    (is (equal (list +http-ok+
                     '(:content-type "application/json")
                     (format nil "[[3]]~%"))
               (%do-query "POST" "application/json" "SELECT :a + :b" "{\"a\":1,\"b\":2}" "false")))

    (is (equal (list +http-created+
                     '(:content-type "application/json")
                     (format nil "[[2]]~%"))
               (%do-query "POST" "application/json" "INSERT INTO foo {:a, :b}" "[{\"a\":1,\"b\":2},{\"a\":3,\"b\":4}]" "true")))

    (is (equal (list +http-ok+
                     '(:content-type "application/x-ndjson")
                     (format nil "{\"a\":1,\"b\":2}~%{\"a\":3,\"b\":4}~%"))
               (%do-query "GET" "application/x-ndjson" "SELECT * FROM foo ORDER BY a" "[]" "false")))))

(test errors
  (let* ((endb/lib/server:*db* (endb/sql:make-db)))

    (is (equal (list +http-created+
                     '(:content-type "application/json")
                     (format nil "[[1]]~%"))
               (%do-query "POST" "application/json" "INSERT INTO foo {a: 1, b: 2}" "[]" "false")))

    (is (equal (list +http-ok+
                     '(:content-type "application/json")
                     (format nil "[[true]]~%"))
               (%do-query "POST" "application/json" "ROLLBACK" "[]" "false")))

    (is (equal (list +http-bad-request+ () "")
               (%do-query "GET" "application/json" "ROLLBACK" "[]" "false")))

    (is (equal (list +http-bad-request+
                     '(:content-type "text/plain")
                     (format nil "Explicit transactions not supported~%"))
               (%do-query "POST" "application/json" "COMMIT" "[]" "false")))

    (is (equal (list +http-bad-request+ () "")
               (%do-query "GET" "application/json" "DELETE FROM foo" "[]" "false")))

    (is (equal (list +http-bad-request+ '(:content-type "text/plain") (format nil "Invalid argument types: SIN(\"foo\")~%"))
               (%do-query "GET" "application/json" "SELECT SIN(\"foo\")" "[]" "false")))

    (is (equal (list +http-bad-request+ '(:content-type "text/plain") (format nil "Invalid parameters: 1~%"))
               (%do-query "GET" "application/json" "SELECT 1" "1" "false")))

    (is (equal (list +http-bad-request+ '(:content-type "text/plain") (format nil "Invalid many: 1~%"))
               (%do-query "GET" "application/json" "SELECT 1" "[]" "1")))


    (destructuring-bind (status-code headers body)
        (%do-query "GET" "application/json" "SELECT" "[]" "false")
      (declare (ignore body))
      (is (eq +http-bad-request+ status-code))
      (is (equal '(:content-type "text/plain") headers)))

    (let ((endb/lib:*log-level* (endb/lib:resolve-log-level :off))
          (calls 0))
      (is (equal (list +http-internal-server-error+ '(:content-type "text/plain")
                       (format nil "common lisp error~%"))
                 (%do-query "GET" "application/json" "SELECT 1" "[]" "false"
                            (lambda (status-code content-type)
                              (incf calls)
                              (if (= 1 calls)
                                  (error "common lisp error")
                                  (%on-response-init status-code content-type)))
                            #'%on-response-send))))

    (let ((endb/lib:*log-level* (endb/lib:resolve-log-level :off))
          (calls 0))
      (is (null (%do-query "GET" "application/json" "SELECT 1" "[]" "false"
                           (lambda (status-code content-type)
                             (incf calls)
                             (if (= 1 calls)
                                 (error 'endb/lib/server:sql-abort-query-error)
                                 (%on-response-init status-code content-type)))
                           #'%on-response-send))))))

(test conflict
  (let ((prev-db (when (boundp 'endb/lib/server:*db*)
                   endb/lib/server:*db*)))
    (unwind-protect
         (progn
           (setf endb/lib/server:*db* (endb/sql:make-db))
           (let ((write-db (endb/sql:begin-write-tx endb/lib/server:*db*))
                 (write-lock (endb/sql/db:db-write-lock endb/lib/server:*db*)))

             (is (bt:acquire-lock write-lock))
             (let ((thread (bt:make-thread
                            (lambda ()
                              (%do-query "POST" "application/json" "INSERT INTO foo {a: 1, b: 2}" "[]" "false")))))

               (multiple-value-bind (result result-code)
                   (endb/sql:execute-sql write-db "INSERT INTO foo {a: 1, b: 2}")
                 (is (null result))
                 (is (= 1 result-code))
                 (setf endb/lib/server:*db* (endb/sql:commit-write-tx endb/lib/server:*db* write-db)))

               (bt:release-lock write-lock)

               (is (equal (list +http-conflict+ () "")
                          (bt:join-thread thread))))))
      (when prev-db
        (setf endb/lib/server:*db* prev-db)))))


(test websocket
  (let* ((endb/lib/server:*db* (endb/sql:make-db))
         (conn (endb/sql/db:make-db-connection :remote-addr "foo")))

    (let* ((response (%do-websocket conn (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                             ("id" 1)
                                                                             ("method" "sql")
                                                                             ("params" (fset:map ("q" "select 1")))))))
           (response-map (endb/json:json-parse response)))

      (is (equal "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"@context\":{\"xsd\":\"http://www.w3.org/2001/XMLSchema#\",\"@vocab\":\"http://endb.io/\"},\"@graph\":[{\"column1\":1}]}}"
                 response))
      (is (equalp "2.0" (fset:lookup response-map "jsonrpc")))
      (is (equalp 1 (fset:lookup response-map "id")))
      (is (equalp (fset:seq (fset:map ("column1" 1)))
                  (fset:lookup (fset:lookup response-map "result") "@graph"))))

    (let* ((response (%do-websocket conn (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                             ("id" 1)
                                                                             ("method" "sql")
                                                                             ("params" (fset:seq "select 1"))))))
           (response-map (endb/json:json-parse response)))
      (is (equalp (fset:seq (fset:map ("column1" 1)))
                  (fset:lookup (fset:lookup response-map "result") "@graph"))))

    (let* ((response (%do-websocket conn (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                             ("id" 1)
                                                                             ("method" "sql")
                                                                             ("params" (fset:seq "select ?" (fset:seq 1)))))))
           (response-map (endb/json:json-parse response)))

      (is (equalp (fset:seq (fset:map ("column1" 1)))
                  (fset:lookup (fset:lookup response-map "result") "@graph"))))

    (let* ((response (%do-websocket conn (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                             ("id" 1)
                                                                             ("method" "sql")
                                                                             ("params" (fset:map ("q" "select ?")
                                                                                                 ("p" (fset:seq (fset:seq 1) (fset:seq 2)))
                                                                                                 ("m" t)))))))
           (response-map (endb/json:json-parse response)))
      (is (equalp (fset:seq (fset:map ("column1" 2)))
                  (fset:lookup (fset:lookup response-map "result") "@graph"))))

    (let* ((response (%do-websocket conn (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                             ("id" 1)
                                                                             ("method" "sql")
                                                                             ("params" (fset:map ("q" "select :x")
                                                                                                 ("p" (fset:map ("x" 2)))))))))
           (response-map (endb/json:json-parse response)))
      (is (equalp (fset:seq (fset:map ("x" 2)))
                  (fset:lookup (fset:lookup response-map "result") "@graph"))))

    (let* ((response (%do-websocket conn (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                             ("id" 1)
                                                                             ("method" "sql")
                                                                             ("params" (fset:map ("q" "select :x")
                                                                                                 ("p" (fset:map ("x" 2)))
                                                                                                 ("m" t)))))))
           (response-map (endb/json:json-parse response)))
      (is (equalp (fset:map ("jsonrpc" "2.0")
                            ("id" 1)
                            ("error" (fset:map ("message" "Many parameters must be an array")
                                               ("code" +json-rpc-internal-error+))))
                  response-map)))

    (let* ((response (%do-websocket conn (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                             ("method" "sql")
                                                                             ("params" (fset:map ("q" "select 1")))))))
           (response-map (endb/json:json-parse response)))

      (is (equalp (fset:map ("jsonrpc" "2.0")
                            ("id" :null)
                            ("error" (fset:map ("message" "Invalid Request")
                                               ("code" +json-rpc-invalid-request+))))
                  response-map)))

    (let* ((response (%do-websocket conn (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                             ("id" 1)
                                                                             ("method" "foo")
                                                                             ("params" (fset:map ("q" "select 1")))))))
           (response-map (endb/json:json-parse response)))

      (is (equalp (fset:map ("jsonrpc" "2.0")
                            ("id" 1)
                            ("error" (fset:map ("message" "Method not found")
                                               ("code" +json-rpc-method-not-found+))))
                  response-map)))

    (let* ((response (%do-websocket conn "foo"))
           (response-map (endb/json:json-parse response)))

      (is (equalp (fset:map ("jsonrpc" "2.0")
                            ("id" :null)
                            ("error" (fset:map ("message" "Parse error")
                                               ("code" +json-rpc-parse-error+))))
                  response-map)))

    (let* ((response (%do-websocket conn (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                             ("id" 1)
                                                                             ("method" "sql")
                                                                             ("params" (fset:map ("q" "select 1")
                                                                                                 ("m" "foo")))))))
           (response-map (endb/json:json-parse response)))

      (is (equalp (fset:map ("jsonrpc" "2.0")
                            ("id" 1)
                            ("error" (fset:map ("message" "Invalid params")
                                               ("code" +json-rpc-invalid-params+))))
                  response-map)))

    (let* ((response (%do-websocket conn (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                             ("id" 1)
                                                                             ("method" "sql")
                                                                             ("params" (fset:map ("q" "select 1")
                                                                                                 ("p" "foo")))))))
           (response-map (endb/json:json-parse response)))

      (is (equalp (fset:map ("jsonrpc" "2.0")
                            ("id" 1)
                            ("error" (fset:map ("message" "Invalid params")
                                               ("code" +json-rpc-invalid-params+))))
                  response-map)))

    (let* ((response (%do-websocket conn (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                             ("id" 1)
                                                                             ("method" "sql")
                                                                             ("params" (fset:map ("q" "select")))))))
           (response-map (endb/json:json-parse response)))

      (is (equalp "2.0" (fset:lookup response-map "jsonrpc")))
      (is (equalp 1 (fset:lookup response-map "id")))
      (is (equalp +json-rpc-internal-error+ (fset:lookup (fset:lookup response-map "error") "code"))))))

(test websocket-interactive-tx
  (let* ((endb/lib/server:*db* (endb/sql:make-db))
         (conn-1 (endb/sql/db:make-db-connection :remote-addr "foo"))
         (conn-2 (endb/sql/db:make-db-connection :remote-addr "bar")))

    (let* ((response (%do-websocket conn-1 (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                               ("id" 1)
                                                                               ("method" "sql")
                                                                               ("params" (fset:seq "select 1; select 2;"))))))
           (response-map (endb/json:json-parse response)))
      (is (equalp (fset:map ("jsonrpc" "2.0")
                            ("id" 1)
                            ("error" (fset:map ("message" "Multiple statements not allowed")
                                               ("code" +json-rpc-internal-error+))))
                  response-map)))

    (is (null (endb/sql/db:db-connection-db conn-1)))

    (let* ((response (%do-websocket conn-1 (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                               ("id" 1)
                                                                               ("method" "sql")
                                                                               ("params" (fset:seq "begin"))))))
           (response-map (endb/json:json-parse response)))

      (is (equalp (fset:seq (fset:map ("result" t)))
                  (fset:lookup (fset:lookup response-map "result") "@graph")))

      (is (endb/sql/db:db-connection-db conn-1))
      (is (endb/sql/db:db-connection-original-md conn-1))
      (is (not (eq endb/lib/server:*db* (endb/sql/db:db-connection-db conn-1)))))

    (let* ((response (%do-websocket conn-1 (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                               ("id" 1)
                                                                               ("method" "sql")
                                                                               ("params" (fset:seq "rollback"))))))
           (response-map (endb/json:json-parse response)))

      (is (equalp (fset:seq (fset:map ("result" t)))
                  (fset:lookup (fset:lookup response-map "result") "@graph")))

      (is (null (endb/sql/db:db-connection-db conn-1)))
      (is (null (endb/sql/db:db-connection-original-md conn-1))))

    (let* ((response (%do-websocket conn-1 (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                               ("id" 1)
                                                                               ("method" "sql")
                                                                               ("params" (fset:seq "begin"))))))
           (response-map (endb/json:json-parse response)))

      (is (equalp (fset:seq (fset:map ("result" t)))
                  (fset:lookup (fset:lookup response-map "result") "@graph"))))

    (let* ((response (%do-websocket conn-1 (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                               ("id" 1)
                                                                               ("method" "sql")
                                                                               ("params" (fset:seq "INSERT INTO foo {a: 1, b: 2}"))))))
           (response-map (endb/json:json-parse response)))

      (is (equalp (fset:seq (fset:map ("result" 1)))
                  (fset:lookup (fset:lookup response-map "result") "@graph"))))


    (let* ((response (%do-websocket conn-1 (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                               ("id" 1)
                                                                               ("method" "sql")
                                                                               ("params" (fset:seq "SELECT * FROM foo"))))))
           (response-map (endb/json:json-parse response)))

      (is (equalp (fset:seq (fset:map ("a" 1) ("b" 2)))
                  (fset:lookup (fset:lookup response-map "result") "@graph"))))

    (let* ((response (%do-websocket conn-2 (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                               ("id" 1)
                                                                               ("method" "sql")
                                                                               ("params" (fset:seq "SELECT * FROM foo"))))))
           (response-map (endb/json:json-parse response)))

      (is (equalp +json-rpc-internal-error+ (fset:lookup (fset:lookup response-map "error") "code"))))

    (let* ((response (%do-websocket conn-2 (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                               ("id" 1)
                                                                               ("method" "sql")
                                                                               ("params" (fset:seq "begin"))))))
           (response-map (endb/json:json-parse response)))

      (is (equalp (fset:seq (fset:map ("result" t)))
                  (fset:lookup (fset:lookup response-map "result") "@graph"))))

    (let* ((response (%do-websocket conn-2 (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                               ("id" 1)
                                                                               ("method" "sql")
                                                                               ("params" (fset:seq "BEGIN TRANSACTION"))))))
           (response-map (endb/json:json-parse response)))

      (is (equalp (fset:map ("jsonrpc" "2.0")
                            ("id" 1)
                            ("error" (fset:map ("message" "Cannot nest transactions")
                                               ("code" +json-rpc-internal-error+))))
                  response-map)))

    (let* ((response (%do-websocket conn-2 (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                               ("id" 1)
                                                                               ("method" "sql")
                                                                               ("params" (fset:seq "INSERT INTO bar {a: 1, b: 2}"))))))
           (response-map (endb/json:json-parse response)))

      (is (equalp (fset:seq (fset:map ("result" 1)))
                  (fset:lookup (fset:lookup response-map "result") "@graph"))))

    (let* ((response (%do-websocket conn-1 (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                               ("id" 1)
                                                                               ("method" "sql")
                                                                               ("params" (fset:seq "commit"))))))
           (response-map (endb/json:json-parse response)))

      (is (equalp (fset:seq (fset:map ("result" t)))
                  (fset:lookup (fset:lookup response-map "result") "@graph")))

      (is (null (endb/sql/db:db-connection-db conn-1)))
      (is (null (endb/sql/db:db-connection-original-md conn-1))))

    (let* ((response (%do-websocket conn-2 (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                               ("id" 1)
                                                                               ("method" "sql")
                                                                               ("params" (fset:seq "COMMIT TRANSACTION"))))))
           (response-map (endb/json:json-parse response)))

      (is (equalp (fset:map ("jsonrpc" "2.0")
                            ("id" 1)
                            ("error" (fset:map ("message" "Conflict")
                                               ("code" +json-rpc-internal-error+))))
                  response-map))
      (is (null (endb/sql/db:db-connection-db conn-2)))
      (is (null (endb/sql/db:db-connection-original-md conn-2))))

    (let* ((response (%do-websocket conn-2 (endb/json:json-stringify (fset:map ("jsonrpc" "2.0")
                                                                               ("id" 1)
                                                                               ("method" "sql")
                                                                               ("params" (fset:seq "SELECT * FROM foo"))))))
           (response-map (endb/json:json-parse response)))

      (is (equalp (fset:seq (fset:map ("a" 1) ("b" 2)))
                  (fset:lookup (fset:lookup response-map "result") "@graph"))))))
