#lang racket/base
(require racket/cmdline
         racket/file
         net/url
         scribble/html
         "download-page.rkt"
         "private/find-desired-snapshots.rkt"
         (only-in distro-build/config extract-options))

(module test racket/base)

(define build-dir (build-path "build"))
(define installers-dir (build-path "installers"))

(define-values (config-file config-mode)
  (command-line
   #:args
   (config-file config-mode)
   (values config-file config-mode)))

(define config (extract-options config-file config-mode))

(define site-dir (hash-ref config
                           '#:site-dest
                           (build-path build-dir "site")))

(define site-title (hash-ref config
                             '#:site-title
                             "Racket Downloads"))

(define current-snapshot
  (let-values ([(base name dir?) (split-path site-dir)])
    (path-element->string name)))

(define snapshots-dir (build-path site-dir 'up))

(define link-file (build-path snapshots-dir "current"))

(when (link-exists? link-file)
  (printf "Removing old \"current\" link\n")
  (flush-output)
  (delete-file link-file))

(define (get-snapshots)
  (for/list ([p (in-list (directory-list snapshots-dir))]
             #:when (directory-exists? (build-path snapshots-dir p)))
    (path-element->string p)))

(define week-count (hash-ref config '#:week-count #f))
(define to-remove-snapshots
  (cond
    [week-count
     (define all-snapshots (get-snapshots))
     (define desired-snapshots
       (find-desired-week-and-month-snapshots week-count all-snapshots (current-seconds)))
     (remove* desired-snapshots all-snapshots)]
    [else
     (define n (hash-ref config '#:max-snapshots 5))
     (define snapshots (get-snapshots))
     (cond
       [(n . < . (length snapshots))
        (remove
         current-snapshot
         (list-tail (sort snapshots string>?) n))]
       [else '()])]))
(for ([s (in-list to-remove-snapshots)])
  (printf "Removing snapshot ~a\n" s)
  (flush-output)
  (delete-directory/files (build-path snapshots-dir s)))

(printf "Loading past successes\n")
(define table-file (build-path site-dir installers-dir "table.rktd"))
(define past-successes
  (let ([current-table (get-installers-table table-file)])
    (for/fold ([table (hash)]) ([s (in-list (reverse (remove current-snapshot (get-snapshots))))])
      (with-handlers ([exn:fail? (lambda (exn)
                                   (log-error "failure getting installer table: ~a"
                                              (exn-message exn))
                                   table)])
        (define past-table (get-installers-table
                            (build-path snapshots-dir s installers-dir "table.rktd")))
        (define past-version (let ([f (build-path snapshots-dir s installers-dir "version.rktd")])
                               (if (file-exists? f)
                                   (call-with-input-file* f read)
                                   (version))))
        (for/fold ([table table]) ([(k v) (in-hash past-table)])
          (if (or (hash-ref current-table k #f)
                  (hash-ref table k #f)
                  (not (file-exists? (build-path site-dir "log" k))))
              table
              (hash-set table k (past-success s
                                              (string-append s "/index.html")
                                              v
                                              past-version))))))))

(define (version->current-rx vers)
  (regexp (regexp-quote vers)))

(define current-rx (version->current-rx (version)))

(printf "Creating \"current\" links\n")
(flush-output)
(make-file-or-directory-link current-snapshot link-file)
(let ([installer-dir (build-path snapshots-dir current-snapshot "installers")])
  (define (currentize f current-rx)
    (regexp-replace current-rx
                    (path->bytes f)
                    "current"))
  (define (make-link f to-file current-rx)
    (define file-link (build-path
                       installer-dir
                       (bytes->path (currentize f current-rx))))
    (when (link-exists? file-link)
      (delete-file file-link))
    (make-file-or-directory-link to-file file-link))
  ;; Link current successes:
  (for ([f (in-list (directory-list installer-dir))])
    (when (regexp-match? current-rx f)
      (make-link f f (version))))
  ;; Link past successes:
  (for ([v (in-hash-values past-successes)])
    (define current-rx (version->current-rx (past-success-version v)))
    (when (regexp-match? current-rx (past-success-file v))
      (make-link (string->path (past-success-file v))
                 (build-path 'up 'up 
                             (past-success-name v) installers-dir
                             (past-success-file v))
                 current-rx))))

(printf "Generating web page\n")
(make-download-page table-file
                    #:title site-title
                    #:plt-web-style? (hash-ref config '#:plt-web-style? #t)
                    #:past-successes past-successes
                    #:installers-url "current/installers/"
                    #:log-dir (build-path site-dir "log")
                    #:log-dir-url "current/log/"
                    #:docs-url (and (directory-exists? (build-path site-dir "doc"))
                                    "current/doc/index.html")
                    #:pdf-docs-url (and (directory-exists? (build-path site-dir "pdf-doc"))
                                        "current/pdf-doc/")
                    #:dest (build-path snapshots-dir
                                       "index.html")
                    #:version->current-rx version->current-rx
                    #:git-clone (current-directory)
                    #:help-table (hash-ref config '#:site-help (hash))
                    #:post-content (list
                                    (p "Snapshot ID: " 
                                       (a href: (string-append current-snapshot
                                                               "/index.html")
                                          current-snapshot))
                                    (let ([snapshots (get-snapshots)])
                                      (if ((length snapshots) . < . 2)
                                          null
                                          (div class: "detail"
                                               "Other available snapshots:"
                                               (for/list ([s (remove "current"
                                                                     (remove current-snapshot
                                                                             (sort snapshots string>?)))])
                                                 (span class: "detail"
                                                       nbsp
                                                       (a href: (string-append s "/index.html")
                                                          s))))))))


;; Record the current version number, because that's useful for
;; creating "current" links when later build attempts fail
(call-with-output-file*
 (build-path site-dir installers-dir "version.rktd")
 #:exists 'truncate/replace
 (lambda (o)
   (writeln (version) o)))
