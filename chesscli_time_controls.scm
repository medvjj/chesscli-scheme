(display "PROGRAM STARTED\n")
(force-output)

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 threads)
             (ice-9 format)
             (srfi srfi-13))

;; ------------------------------------------------------------
;; ENGINE CONFIGURATION
;; ------------------------------------------------------------

(define home (getenv "HOME"))

(unless home
  (error "HOME environment variable is not set"))

(define engine-path
  (string-append home
                 "/guile_scheme_programms/chesscli/sf19"))

(unless (file-exists? engine-path)
  (error "Engine executable not found:" engine-path))

(define engine
  (open-pipe* OPEN_BOTH engine-path))

(display "ENGINE OPENED\n")
(force-output)

;; ------------------------------------------------------------
;; LOG FILE
;; ------------------------------------------------------------

(define log-port
  (open-file "chess-session.log" "a"))

(define log-mutex (make-mutex))

(display "LOG FILE OPENED\n")
(force-output)

;; ------------------------------------------------------------
;; SYNCHRONIZATION
;; ------------------------------------------------------------

(define state-mutex (make-mutex))
(define output-mutex (make-mutex))
(define engine-write-mutex (make-mutex))

(define state-changed
  (make-condition-variable))

(define stop-requested? #f)
(define searching? #f)
(define game-running? #f)
(define engine-alive? #t)

(define best-move #f)
(define current-fen "")
(define fen-version 0)

(define depth "10")

;; Search/time-control configuration.
;; mode: "depth", "move", or "game".
(define search-mode "depth")
(define move-time-ms 10000)
(define increment-ms 0)
(define white-time-ms 600000)
(define black-time-ms 600000)
(define white-reserve-ms 0)
(define black-reserve-ms 0)
(define last-search-start 0)
(define last-search-budget-ms 0)

(display "SYNCHRONIZATION READY\n")
(force-output)

;; ------------------------------------------------------------
;; MUTEX HELPER
;; ------------------------------------------------------------

(define (with-mutex mutex thunk)
  (lock-mutex mutex)
  (dynamic-wind
    (lambda () #t)
    thunk
    (lambda ()
      (unlock-mutex mutex))))

;; ------------------------------------------------------------
;; OUTPUT FUNCTIONS
;; ------------------------------------------------------------

(define (print-safely text)
  (with-mutex
   output-mutex
   (lambda ()
     (display text)
     (force-output))))

(define (log-entry text)
  (with-mutex
   log-mutex
   (lambda ()
     (display text log-port)
     (newline log-port)
     (force-output log-port))))

(define (ask prompt)
  (display prompt)
  (force-output)
  (let ((line (read-line)))
    (if (eof-object? line)
        "q"
        line)))

;; ------------------------------------------------------------
;; ENGINE COMMUNICATION
;; ------------------------------------------------------------

(define (send-command command)
  (with-mutex
   engine-write-mutex
   (lambda ()
     (unless engine-alive?
       (error "Cannot send command: engine is not running"))
     (display command engine)
     (newline engine)
     (force-output engine))))

(define (read-until marker)
  (let loop ()
    (let ((line (read-line engine)))
      (when (eof-object? line)
        (error "Engine closed the connection"))
      (unless (string=? line marker)
        (loop)))))

(define (set-option name value)
  (send-command
   (string-append "setoption name "
                  name
                  " value "
                  value))

  (send-command "isready")
  (read-until "readyok"))

;; ------------------------------------------------------------
;; STATE ACCESSORS
;; ------------------------------------------------------------

(define (get-stop-requested?)
  (with-mutex
   state-mutex
   (lambda () stop-requested?)))

(define (get-searching?)
  (with-mutex
   state-mutex
   (lambda () searching?)))

(define (get-current-fen)
  (with-mutex
   state-mutex
   (lambda () current-fen)))

(define (get-fen-version)
  (with-mutex
   state-mutex
   (lambda () fen-version)))

;; ------------------------------------------------------------
;; STOP REQUEST
;; ------------------------------------------------------------

(define (request-stop!)
  (let ((result
         (with-mutex
          state-mutex
          (lambda ()
            (if game-running?
                (begin
                  (set! stop-requested? #t)
                  (list #t searching?))
                (list #f #f))))))

    (when (and (car result)
               (cadr result))
      (send-command "stop"))

    (car result)))

;; ------------------------------------------------------------
;; WAIT FOR SEARCH COMPLETION
;; ------------------------------------------------------------

(define (wait-for-search)
  (with-mutex
   state-mutex
   (lambda ()
     (let loop ()
       (when (and searching? engine-alive?)
         (wait-condition-variable
          state-changed
          state-mutex)
         (loop)))

     best-move)))

;; ------------------------------------------------------------
;; UCI ANALYSIS FORMATTING
;; ------------------------------------------------------------

(define (token-value tokens key)
  (cond
   ((or (null? tokens) (null? (cdr tokens))) #f)
   ((string=? (car tokens) key) (cadr tokens))
   (else (token-value (cdr tokens) key))))

(define (tokens-after tokens key)
  (cond
   ((null? tokens) '())
   ((string=? (car tokens) key) (cdr tokens))
   (else (tokens-after (cdr tokens) key))))

(define (format-centipawns centipawns white-to-move?)
  ;; UCI scores are from the side-to-move perspective.
  ;; Convert them to White's perspective for display.
  (let* ((white-score
          (if white-to-move?
              centipawns
              (- centipawns)))
         (value (/ white-score 100.0))
         (formatted (format #f "~,2f" value)))
    (if (> white-score 0)
        (string-append "+" formatted)
        formatted)))

(define (format-mate mate white-to-move?)
  (let ((mating-side
         (if (> mate 0)
             (if white-to-move? "White" "Black")
             (if white-to-move? "Black" "White"))))
    (string-append
     "Mate: "
     mating-side
     " in "
     (number->string (abs mate)))))

(define (format-analysis-line line)
  (let* ((tokens (string-tokenize line))
         (depth-value (token-value tokens "depth"))
         (multipv-value (token-value tokens "multipv"))
         (score-tail (tokens-after tokens "score"))
         (pv (tokens-after tokens "pv"))
         (fen-fields (string-tokenize (get-current-fen)))
         (white-to-move?
          (or (null? fen-fields)
              (not (and (>= (length fen-fields) 2)
                        (string=? (list-ref fen-fields 1) "b"))))))
    (if (and depth-value
             (>= (length score-tail) 2)
             (pair? pv)
             (or (not multipv-value)
                 (string=? multipv-value "1")))
        (let* ((score-kind (car score-tail))
               (score-value (string->number (cadr score-tail)))
               (evaluation
                (cond
                 ((and score-value (string=? score-kind "cp"))
                  (string-append
                   "Eval: "
                   (format-centipawns score-value white-to-move?)))
                 ((and score-value (string=? score-kind "mate"))
                  (format-mate score-value white-to-move?))
                 (else #f))))
          (if evaluation
              (string-append
               "Depth: " depth-value
               " | " evaluation
               " | PV: " (string-join pv " ")
               "\n")
              (string-append line "\n")))
        (string-append line "\n"))))

;; ------------------------------------------------------------
;; ENGINE READER THREAD
;; ------------------------------------------------------------

(define (engine-reader)

  (define (reader-loop)
    (let loop ()
      (let ((line (read-line engine)))

        (if (eof-object? line)

            (begin
              (with-mutex
               state-mutex
               (lambda ()
                 (set! engine-alive? #f)
                 (set! searching? #f)
                 (signal-condition-variable
                  state-changed)))

              (print-safely
               "ENGINE CONNECTION CLOSED\n"))

            (begin

              (cond

               ;; Best move received.

               ((string-prefix? "bestmove " line)

                (with-mutex
                 state-mutex
                 (lambda ()

                   (let ((parts
                          (string-tokenize line)))

                     (set! best-move
                           (if (>= (length parts) 2)
                               (cadr parts)
                               #f)))

                   (set! searching? #f)

                   (signal-condition-variable
                    state-changed)))

                (print-safely
                 (string-append line "\n")))

               ;; Current FEN received.

               ((string-prefix? "Fen: " line)

                (with-mutex
                 state-mutex
                 (lambda ()

                   (set! current-fen
                         (substring line 5))

                   (set! fen-version
                         (+ fen-version 1))

                   (signal-condition-variable
                    state-changed))))

               ;; Analysis information.

               ((string-prefix? "info " line)

                (print-safely
                 (format-analysis-line line)))

               ;; Other engine messages.

               (else

                (print-safely
                 (string-append
                  "ENGINE: "
                  line
                  "\n"))))

              (loop))))))

  ;; Protect the application if the reader encounters an error.

  (catch #t

    (lambda ()
      (reader-loop))

    (lambda (key . args)

      (with-mutex
       state-mutex
       (lambda ()
         (set! engine-alive? #f)
         (set! searching? #f)
         (signal-condition-variable
          state-changed)))

      (print-safely
       (format #f
               "ENGINE READER ERROR: ~a ~a\n"
               key
               args)))))

;; ------------------------------------------------------------
;; FEN HANDLING
;; ------------------------------------------------------------

(define (validate-fen fen)

  (let ((fields (string-tokenize fen)))

    (unless (>= (length fields) 6)
      (error "Invalid FEN: six fields are required"))

    (unless (or (string=? (list-ref fields 1) "w")
                (string=? (list-ref fields 1) "b"))
      (error "Invalid FEN: active color must be w or b"))

    (let ((move-number
           (string->number (list-ref fields 5))))

      (unless (and move-number
                   (integer? move-number)
                   (> move-number 0))
        (error "Invalid FEN: invalid move number")))

    fields))

;; ------------------------------------------------------------
;; MOVE HANDLING
;; ------------------------------------------------------------

(define (join-moves moves)
  (if (null? moves)
      ""
      (string-append
       " moves "
       (string-join moves " "))))

(define (position-command initial-fen moves)

  (string-append
   "position fen "
   initial-fen
   (join-moves moves)))

;; ------------------------------------------------------------
;; WAIT FOR NEW FEN
;; ------------------------------------------------------------

(define (wait-for-fen old-version)

  (let loop ((attempts 0))

    (cond

     ((> (get-fen-version) old-version)
      #t)

     ((>= attempts 5)
      #f)

     ((not engine-alive?)
      #f)

     (else
      (sleep 1)
      (loop (+ attempts 1))))))

;; ------------------------------------------------------------
;; START ENGINE SEARCH
;; ------------------------------------------------------------

(define (start-search! search-config white-to-move?)

  (with-mutex
   state-mutex
   (lambda ()

     (if (or stop-requested?
             (not engine-alive?))

         #f

         (let* ((mode (list-ref search-config 0))
                (command
                 (cond
                  ((string=? mode "depth")
                   (string-append "go depth " (list-ref search-config 1)))
                  ((string=? mode "move")
                   (let* ((base (list-ref search-config 1))
                          (reserve (if white-to-move?
                                       white-reserve-ms
                                       black-reserve-ms))
                          (budget (+ base reserve)))
                     (set! last-search-budget-ms budget)
                     (string-append "go movetime "
                                    (number->string budget))))
                  ((string=? mode "game")
                   (string-append
                    "go wtime " (number->string white-time-ms)
                    " btime " (number->string black-time-ms)
                    " winc " (number->string (list-ref search-config 2))
                    " binc " (number->string (list-ref search-config 2))))
                  (else (error "Unknown search mode" mode)))))

           (set! best-move #f)
           (set! searching? #t)
           (set! last-search-start (get-internal-real-time))

           ;; Send GO while holding the state lock so STOP cannot precede GO.
           (send-command command)
           #t)))))

(define (elapsed-search-ms)
  (inexact->exact
   (round
    (* 1000.0
       (/ (- (get-internal-real-time) last-search-start)
          internal-time-units-per-second)))))

(define (update-time-after-move! white-move?)
  (let ((elapsed (elapsed-search-ms)))
    (cond
     ((string=? search-mode "move")
      (let* ((base move-time-ms)
             (spent-beyond-base (max 0 (- elapsed base)))
             (new-reserve
              (max 0 (+ (if white-move?
                            white-reserve-ms
                            black-reserve-ms)
                        increment-ms
                        (- spent-beyond-base)))))
        (if white-move?
            (set! white-reserve-ms new-reserve)
            (set! black-reserve-ms new-reserve))
        (print-safely
         (format #f "TIME: ~a move used ~a ms; reserve ~a ms\n"
                 (if white-move? "White" "Black")
                 elapsed new-reserve))))
     ((string=? search-mode "game")
      (let ((remaining
             (max 0 (+ (if white-move? white-time-ms black-time-ms)
                       (- elapsed)
                       increment-ms))))
        (if white-move?
            (set! white-time-ms remaining)
            (set! black-time-ms remaining))
        (print-safely
         (format #f "CLOCK: White ~a ms | Black ~a ms\n"
                 white-time-ms black-time-ms)))))))

;; ------------------------------------------------------------
;; PLAY GAME
;; ------------------------------------------------------------

(define (play-game initial-fen search-config)

  (let* ((moves '())

         (fen-fields
          (validate-fen initial-fen))

         (move-number
          (string->number
           (list-ref fen-fields 5)))

         (white-to-move?
          (string=? (list-ref fen-fields 1) "w"))

         (pending-white #f))

    ;; Start session logging.

    (log-entry "")
    (log-entry "=== NEW SESSION ===")

    (log-entry
     (string-append
      "Starting FEN: "
      initial-fen))

    (log-entry
     (format #f "Search configuration: ~a" search-config))

    (log-entry "Moves:")

    (with-mutex
     state-mutex
     (lambda ()
       (set! current-fen initial-fen)))

    ;; Main game loop.

    (let game-loop ()

      (unless (get-stop-requested?)

        ;; Send current position.

        (send-command
         (position-command initial-fen moves))

        ;; Start search.

        (if (start-search! search-config white-to-move?)

            (let ((move (wait-for-search)))

              (cond

               ;; Stop requested.

               ((get-stop-requested?)

                (print-safely
                 "GAME STOPPED.\n")

                ;; Save an unfinished white move.

                (when pending-white
                  (log-entry
                   (string-append
                    (number->string move-number)
                    ". "
                    pending-white))))

               ;; No legal move or engine failure.

               ((or (not move)
                    (string=? move "(none)"))

                (print-safely
                 "ENGINE FOUND NO MOVE. GAME FINISHED.\n")

                (when pending-white
                  (log-entry
                   (string-append
                    (number->string move-number)
                    ". "
                    pending-white)))

                (log-entry
                 "Game ended: no legal move."))

               ;; Valid move received.

               (else

                (set! moves
                      (append moves (list move)))

                ;; Record move notation.

                (if white-to-move?

                    (set! pending-white move)

                    (let ((entry

                           (if pending-white

                               (string-append
                                (number->string move-number)
                                ". "
                                pending-white
                                " "
                                move)

                               (string-append
                                (number->string move-number)
                                "... "
                                move))))

                      (log-entry entry)

                      (print-safely
                       (string-append
                        "MOVE "
                        entry
                        "\n"))

                      (set! move-number
                            (+ move-number 1))

                      (set! pending-white #f)))

                ;; Apply elapsed time and increment for the side that moved.

                (unless (string=? search-mode "depth")
                  (update-time-after-move! white-to-move?))

                ;; Change side to move.

                (set! white-to-move?
                      (not white-to-move?))

                ;; Request updated position and FEN.

                (send-command
                 (position-command initial-fen moves))

                (let ((old-version
                       (get-fen-version)))

                  (send-command "d")

                  (if (wait-for-fen old-version)

                      (print-safely
                       (string-append
                        "\nCURRENT FEN: "
                        (get-current-fen)
                        "\n"))

                      (print-safely
                       "WARNING: COULD NOT RECEIVE NEW FEN.\n")))

                ;; Continue playing.

                (game-loop))))

            ;; Search could not be started.

            (unless (get-stop-requested?)

              (print-safely
               "ENGINE IS NOT AVAILABLE.\n")))))))

;; ------------------------------------------------------------
;; GAME THREAD MANAGEMENT
;; ------------------------------------------------------------

(define (launch-game! fen search-config)

  (let ((started?

         (with-mutex
          state-mutex
          (lambda ()

            (if game-running?

                #f

                (begin
                  (set! game-running? #t)
                  (set! stop-requested? #f)
                  #t))))))

    (if started?

        (begin

          (make-thread

           (lambda ()

             (dynamic-wind

               (lambda () #t)

               (lambda ()
                 (play-game fen search-config))

               ;; Always release game-running state.

               (lambda ()

                 (with-mutex
                  state-mutex
                  (lambda ()

                    (set! game-running? #f)

                    (signal-condition-variable
                     state-changed)))))))

          (print-safely
           "GAME STARTED.\n"))

        (print-safely
         "A GAME IS ALREADY RUNNING.\n"))))

;; ------------------------------------------------------------
;; WAIT FOR GAME THREAD
;; ------------------------------------------------------------

(define (wait-for-game)

  (with-mutex
   state-mutex
   (lambda ()

     (let loop ()

       (when game-running?

         (wait-condition-variable
          state-changed
          state-mutex)

         (loop))))))

;; ------------------------------------------------------------
;; INPUT VALIDATION
;; ------------------------------------------------------------

(define (ask-positive-integer prompt default)

  (let loop ()

    (let* ((answer (ask prompt))

           (value
            (if (string=? answer "")
                default
                answer))

           (number
            (string->number value)))

      (if (and number
               (integer? number)
               (> number 0))

          (number->string number)

          (begin

            (print-safely
             "PLEASE ENTER A POSITIVE INTEGER.\n")

            (loop))))))

;; ------------------------------------------------------------
;; UCI INITIALIZATION
;; ------------------------------------------------------------

(display "SENDING UCI\n")
(force-output)

(send-command "uci")

(display "WAITING FOR UCIOK\n")
(force-output)

(read-until "uciok")

(display "UCIOK RECEIVED\n")
(force-output)

(display "ENGINE CONNECTED\n")
(force-output)

;; ------------------------------------------------------------
;; ENGINE OPTIONS
;; ------------------------------------------------------------

(let ((threads
       (ask-positive-integer
        "Threads [2]: "
        "2")))

  (set-option "Threads" threads))

(let ((hash-mb
       (ask-positive-integer
        "Hash MB [512]: "
        "512")))

  (set-option "Hash" hash-mb))

;; ------------------------------------------------------------
;; SEARCH MODE AND TIME CONTROL
;; ------------------------------------------------------------

(define mode-choice
  (let loop ()
    (let ((answer
           (ask "Search mode: 1 - depth, 2 - time per move + increment, 3 - game time + increment [1]: ")))
      (let ((choice (if (string=? answer "") "1" answer)))
        (if (member choice '("1" "2" "3"))
            choice
            (begin
              (print-safely "PLEASE ENTER 1, 2 OR 3.\n")
              (loop)))))))

(define search-config
  (cond
   ((string=? mode-choice "1")
    (set! search-mode "depth")
    (set! depth
          (ask-positive-integer "Search depth [10]: " "10"))
    (list "depth" depth))
   ((string=? mode-choice "2")
    (set! search-mode "move")
    (set! move-time-ms
          (* 1000
             (string->number
              (ask-positive-integer "Base time per move, seconds [10]: " "10"))))
    (set! increment-ms
          (* 1000
             (string->number
              (ask-positive-integer "Increment after each move, seconds [2]: " "2"))))
    (set! white-reserve-ms 0)
    (set! black-reserve-ms 0)
    (list "move" move-time-ms increment-ms))
   (else
    (set! search-mode "game")
    (set! white-time-ms
          (* 1000
             (string->number
              (ask-positive-integer "Initial time for the whole game, seconds [600]: " "600"))))
    (set! black-time-ms white-time-ms)
    (set! increment-ms
          (* 1000
             (string->number
              (ask-positive-integer "Increment after each move, seconds [3]: " "3"))))
    (list "game" white-time-ms increment-ms))))

;; ------------------------------------------------------------
;; INITIAL POSITION
;; ------------------------------------------------------------

(define default-fen
  "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")

(define initial-fen

  (let ((fen
         (ask
          "Initial FEN (press Enter for starting position): ")))

    (if (string=? fen "")
        default-fen
        fen)))

;; Validate FEN before starting the reader and command loop.

(validate-fen initial-fen)

;; ------------------------------------------------------------
;; START READER THREAD
;; ------------------------------------------------------------

(display "STARTING ENGINE READER\n")
(force-output)

(define reader-thread
  (make-thread engine-reader))

;; ------------------------------------------------------------
;; MAIN COMMAND LOOP
;; ------------------------------------------------------------

(print-safely
 "COMMANDS: p - play, s - stop, q - quit\n")

(let command-loop ()

  (let ((command (ask "> ")))

    (cond

     ;; Start game.

     ((string=? command "p")

      (launch-game! initial-fen search-config)

      (command-loop))

     ;; Stop game.

     ((string=? command "s")

      (if (request-stop!)

          (print-safely
           "STOP REQUEST SENT. WAITING FOR ENGINE...\n")

          (print-safely
           "NO ACTIVE GAME.\n"))

      (command-loop))

     ;; Exit program.

     ((string=? command "q")

      (print-safely
       "SHUTTING DOWN...\n")

      ;; Stop current search if necessary.

      (request-stop!)

      ;; Wait until the game thread has finished.

      (wait-for-game)

      ;; Shut down engine.

      (when engine-alive?
        (send-command "quit"))

      (print-safely
       "PROGRAM TERMINATED.\n"))

     ;; Unknown command.

     (else

      (print-safely
       "UNKNOWN COMMAND. USE p, s OR q.\n")

      (command-loop)))))

;; ------------------------------------------------------------
;; CLEANUP
;; ------------------------------------------------------------

(close-pipe engine)

(close-port log-port)

(display "ALL RESOURCES CLOSED.\n")
(force-output)
