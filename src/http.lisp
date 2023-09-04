(defpackage :endb/http
  (:use :cl)
  (:export #:make-api-handler
           #:+http-ok+
           #:+http-created+
           #:+http-bad-request+
           #:+http-unauthorized+
           #:+http-not-found+
           #:+http-method-not-allowed+
           #:+http-not-acceptable+
           #:+http-conflict+
           #:+http-unsupported-media-type+
           #:+http-internal-server-error+)
  (:import-from :alexandria)
  (:import-from :bordeaux-threads)
  (:import-from :lack.request)
  (:import-from :cl-ppcre)
  (:import-from :com.inuoe.jzon)
  (:import-from :local-time)
  (:import-from :log4cl)
  (:import-from :trivial-utf-8)
  (:import-from :qbase64)
  (:import-from :endb/lib/parser)
  (:import-from :endb/sql)
  (:import-from :endb/sql/expr)
  (:import-from :endb/json))
(in-package :endb/http)

(defconstant +http-ok+ 200)
(defconstant +http-created+ 201)
(defconstant +http-bad-request+ 400)
(defconstant +http-unauthorized+ 401)
(defconstant +http-not-found+ 404)
(defconstant +http-method-not-allowed+ 405)
(defconstant +http-not-acceptable+ 406)
(defconstant +http-conflict+ 409)
(defconstant +http-unsupported-media-type+ 415)
(defconstant +http-internal-server-error+ 500)

(defparameter +crlf+ (coerce '(#\return #\linefeed) 'string))
(defparameter +request-json-media-types+ '("application/json" "application/ld+json"))
(defparameter +request-media-types+ (append '("application/sql" "application/x-www-form-urlencoded" "multipart/")
                                            +request-json-media-types+))
(defparameter +response-media-types+ '("application/json" "application/x-ndjson" "application/ld+json" "text/csv"))

(defun %format-csv (x)
  (ppcre:regex-replace-all "\\\\\"" (com.inuoe.jzon:stringify x) "\"\""))

(defun %row-to-json (column-names row)
  (with-output-to-string (out)
    (com.inuoe.jzon:with-writer (writer :stream out)
      (com.inuoe.jzon:with-object writer
        (loop for column in row
              for column-name in column-names
              do (com.inuoe.jzon:write-key writer column-name)
                 (com.inuoe.jzon:write-value writer column))))))

(defun %empty-response (status &optional headers)
  (list status (append headers '(:content-type "text/plain" :content-length 0)) '("")))

(defun %stream-response (req status column-names rows)
  (lambda (responder)
    (let* ((content-type (cond
                           ((lack.request:request-accepts-p req "application/json")
                            "application/json")
                           ((lack.request:request-accepts-p req "application/ld+json")
                            "application/ld+json")
                           ((lack.request:request-accepts-p req "application/x-ndjson")
                            "application/x-ndjson")
                           ((lack.request:request-accepts-p req "text/csv")
                            "text/csv")))
           (endb/json:*json-ld-scalars* (equal "application/ld+json" content-type))
           (writer (funcall responder (list status (list :content-type content-type)))))
      (cond
        ((equal "application/json" content-type)
         (funcall writer "[")
         (loop for row in rows
               for idx from 0
               unless (zerop idx)
                 do (funcall writer ",")
               do (funcall writer (com.inuoe.jzon:stringify row))
               finally (funcall writer (format nil "]~%") :close t)))
        ((equal "application/ld+json" content-type)
         (funcall writer "{\"@context\":{\"xsd\":\"http://www.w3.org/2001/XMLSchema#\",\"@vocab\":\"http://endb.io/\"},\"@graph\":[")
         (loop for row in rows
               for idx from 0
               unless (zerop idx)
                 do (funcall writer ",")
               do (funcall writer (%row-to-json column-names row))
               finally (funcall writer (format nil "]}~%") :close t)))
        ((equal "application/x-ndjson" content-type)
         (loop for row in rows
               do (funcall writer (%row-to-json column-names row))
                  (funcall writer (format nil "~%"))
               finally (funcall writer nil :close t)))
        ((equal "text/csv" content-type)
         (loop for row in (cons column-names rows)
               do (funcall writer (format nil "~{~A~^,~}~A" (mapcar #'%format-csv row) +crlf+))
               finally (funcall writer nil :close t)))))))

(defun %error-response (status error)
  (list status '(:content-type "text/plain") (list (format nil "~A~%" error))))

(defun %encode-basic-auth-header (username password)
  (when (or username password)
    (let ((basic-auth-bytes (trivial-utf-8:string-to-utf-8-bytes (format nil "~A:~A" (or username "") (or password "")))))
      (format nil "Basic ~A" (qbase64:encode-bytes basic-auth-bytes)))))

(defun %sql-and-parameters (req)
  (if (and (eq :post (lack.request:request-method req))
           (some (lambda (x)
                   (alexandria:starts-with-subseq x (lack.request:request-content-type req)))
                 +request-json-media-types+))
      (let ((envelope (endb/json:json-parse (trivial-utf-8:utf-8-bytes-to-string (lack.request:request-content req)))))
        (values (fset:lookup envelope "q")
                (or (fset:lookup envelope "p") (fset:empty-seq))
                (fset:lookup envelope "m")))
      (let* ((sql (if (and (eq :post (lack.request:request-method req))
                           (alexandria:starts-with-subseq "application/sql" (lack.request:request-content-type req)))
                      (trivial-utf-8:utf-8-bytes-to-string (lack.request:request-content req))
                      (cdr (assoc "q" (lack.request:request-parameters req) :test 'equal))))
             (parameters (cdr (assoc "p" (lack.request:request-parameters req) :test 'equal)))
             (parameters (if parameters
                             (endb/json:resolve-json-ld-xsd-scalars (endb/sql:interpret-sql-literal parameters))
                             (fset:empty-seq)))
             (manyp (cdr (assoc "m" (lack.request:request-parameters req) :test 'equal)))
             (manyp (when manyp
                      (endb/sql:interpret-sql-literal manyp))))
        (values sql parameters manyp))))

(defun make-api-handler (db &key username password (realm "restricted area"))
  (let* ((write-lock (bt:make-lock))
         (basic-auth-header (%encode-basic-auth-header username password)))
    (lambda (env)
      (handler-case
          (let* ((req (lack.request:make-request env))
                 (headers (lack.request:request-headers req)))
            (log:debug req)
            (if (and basic-auth-header (not (equal basic-auth-header (gethash "authorization" headers))))
                (%empty-response +http-unauthorized+ (list :www-authenticate (format nil "Basic realm=\"~A\"" realm)))
                (if (equal "/sql" (lack.request:request-path-info req))
                    (if (member (lack.request:request-method req) '(:get :post))
                        (if (and (eq :post (lack.request:request-method req))
                                 (notany (lambda (x)
                                           (alexandria:starts-with-subseq x (lack.request:request-content-type req)))
                                         +request-media-types+))
                            (%empty-response +http-unsupported-media-type+)
                            (let* ((write-db (endb/sql:begin-write-tx db))
                                   (original-md (endb/sql/expr:db-meta-data write-db)))
                              (multiple-value-bind (sql parameters manyp)
                                  (%sql-and-parameters req)
                                (if (and (stringp sql) (fset:collection? parameters) (typep manyp 'boolean))
                                    (if (some (lambda (media-type)
                                                (lack.request:request-accepts-p req media-type))
                                              +response-media-types+)
                                        (multiple-value-bind (result result-code)
                                            (endb/sql:execute-sql write-db sql parameters manyp)
                                          (cond
                                            ((or result (and (listp result-code)
                                                             (not (null result-code))))
                                             (%stream-response req +http-ok+ result-code result))
                                            (result-code (if (eq :get (lack.request:request-method req))
                                                             (%empty-response +http-bad-request+)
                                                             (bt:with-lock-held (write-lock)
                                                               (if (eq original-md (endb/sql/expr:db-meta-data db))
                                                                   (progn
                                                                     (setf db (endb/sql:commit-write-tx db write-db))
                                                                     (%stream-response req +http-created+ '("result") (list (list result-code))))
                                                                   (%empty-response +http-conflict+)))))
                                            (t (%empty-response +http-conflict+))))
                                        (%empty-response +http-not-acceptable+))
                                    (%empty-response +http-bad-request+)))))
                        (%empty-response +http-method-not-allowed+ '(:allow "GET, POST")))
                    (%empty-response +http-not-found+))))
        (endb/lib/parser:sql-parse-error (e)
          (%error-response +http-bad-request+ e))
        (endb/sql/expr:sql-runtime-error (e)
          (%error-response +http-bad-request+ e))
        (local-time:invalid-timestring (e)
          (%error-response +http-bad-request+ e))
        (com.inuoe.jzon:json-error (e)
          (%error-response +http-bad-request+ e))
        (error (e)
          (log:error "~A" e)
          (%error-response +http-internal-server-error+ e))))))
