;; StackCredit - Decentralized P2P Lending Protocol
;; A comprehensive peer-to-peer lending platform on Stacks blockchain for STX lending

;; Error codes
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-INSUFFICIENT-FUNDS (err u101))
(define-constant ERR-CREDIT-REQUEST-NOT-FOUND (err u102))
(define-constant ERR-CREDIT-ALREADY-FUNDED (err u103))
(define-constant ERR-INSUFFICIENT-COLLATERAL (err u104))
(define-constant ERR-PAYMENT-NOT-DUE (err u105))
(define-constant ERR-CREDIT-DEFAULTED (err u106))
(define-constant ERR-INVALID-AMOUNT (err u107))
(define-constant ERR-PAYMENT-TOO-LOW (err u108))
(define-constant ERR-NO-LIQUIDATION-REQUIRED (err u109))

;; Protocol constants
(define-constant BLOCKS-PER-DAY u144) ;; Approximate number of blocks per day
(define-constant DEFAULT-PENALTY-RATE u10) ;; 10% penalty rate for late payments
(define-constant LIQUIDATION-THRESHOLD u130) ;; 130% minimum collateral ratio before liquidation

;; Credit status constants
(define-constant STATUS-PENDING "PENDING")
(define-constant STATUS-FUNDED "FUNDED")
(define-constant STATUS-COMPLETED "COMPLETED")
(define-constant STATUS-LIQUIDATED "LIQUIDATED")
(define-constant STATUS-DEFAULTED "DEFAULTED")

;; Protocol configuration variables
(define-data-var minimum-collateral-ratio uint u150) ;; 150% collateralization ratio
(define-data-var protocol-admin principal tx-sender)

;; Credit agreement data structure
(define-map credit-agreements
    {credit-id: uint}
    {
        borrower: principal,
        creditor: (optional principal),
        principal-amount: uint,
        collateral-amount: uint,
        interest-rate: uint,
        term-length: uint,
        funding-height: uint,
        last-payment-height: uint,
        payment-frequency: uint,
        installment-amount: uint,
        outstanding-balance: uint,
        agreement-status: (string-ascii 20)
    }
)

;; Payment tracking for credit agreements
(define-map repayment-schedules
    {credit-id: uint}
    {
        next-due-height: uint,
        missed-payments: uint,
        total-penalties: uint
    }
)

;; Protocol state tracking
(define-data-var next-credit-id uint u1)
(define-data-var total-collateral-locked uint u0)

;; Read-only functions
(define-read-only (get-credit-agreement (credit-id uint))
    (map-get? credit-agreements {credit-id: credit-id})
)

(define-read-only (get-repayment-schedule (credit-id uint))
    (map-get? repayment-schedules {credit-id: credit-id})
)

(define-read-only (calculate-collateral-ratio (collateral uint) (principal uint))
    (let
        (
            (ratio (* (/ collateral principal) u100))
        )
        ratio
    )
)

(define-read-only (get-current-collateral-ratio (credit-id uint))
    (let
        (
            (agreement (unwrap! (get-credit-agreement credit-id) u0))
            (ratio (calculate-collateral-ratio 
                (get collateral-amount agreement) 
                (get outstanding-balance agreement)))
        )
        ratio
    )
)

(define-read-only (requires-liquidation (credit-id uint))
    (let
        (
            (current-ratio (get-current-collateral-ratio credit-id))
        )
        (< current-ratio LIQUIDATION-THRESHOLD)
    )
)

;; Private helper functions
(define-private (calculate-late-penalty (installment-amount uint))
    (/ (* installment-amount DEFAULT-PENALTY-RATE) u100)
)

(define-private (initialize-repayment-schedule (credit-id uint) (start-height uint) (frequency uint))
    (begin
        (map-set repayment-schedules
            {credit-id: credit-id}
            {
                next-due-height: (+ start-height frequency),
                missed-payments: u0,
                total-penalties: u0
            }
        )
        true
    )
)

;; Public functions
(define-public (request-credit 
    (principal-amount uint) 
    (collateral-amount uint) 
    (interest-rate uint) 
    (term-length uint) 
    (payment-frequency uint))
    (let
        (
            (credit-id (var-get next-credit-id))
            (collateral-ratio (calculate-collateral-ratio collateral-amount principal-amount))
            (installment-amount (/ (+ principal-amount (* principal-amount interest-rate)) term-length))
        )
        (asserts! (>= collateral-ratio (var-get minimum-collateral-ratio)) ERR-INSUFFICIENT-COLLATERAL)
        (asserts! (> principal-amount u0) ERR-INVALID-AMOUNT)
        (try! (stx-transfer? collateral-amount tx-sender (as-contract tx-sender)))
        
        (var-set total-collateral-locked (+ (var-get total-collateral-locked) collateral-amount))
        
        (map-set credit-agreements
            {credit-id: credit-id}
            {
                borrower: tx-sender,
                creditor: none,
                principal-amount: principal-amount,
                collateral-amount: collateral-amount,
                interest-rate: interest-rate,
                term-length: term-length,
                funding-height: u0,
                last-payment-height: u0,
                payment-frequency: payment-frequency,
                installment-amount: installment-amount,
                outstanding-balance: principal-amount,
                agreement-status: STATUS-PENDING
            }
        )
        (var-set next-credit-id (+ credit-id u1))
        (ok credit-id)
    )
)

(define-public (fund-credit-request (credit-id uint))
    (let
        (
            (agreement (unwrap! (get-credit-agreement credit-id) ERR-CREDIT-REQUEST-NOT-FOUND))
            (principal-amount (get principal-amount agreement))
        )
        (asserts! (is-eq (get agreement-status agreement) STATUS-PENDING) ERR-CREDIT-ALREADY-FUNDED)
        (try! (stx-transfer? principal-amount tx-sender (get borrower agreement)))
        
        (map-set credit-agreements
            {credit-id: credit-id}
            (merge agreement {
                creditor: (some tx-sender),
                funding-height: block-height,
                last-payment-height: block-height,
                agreement-status: STATUS-FUNDED
            })
        )
        
        (asserts! (initialize-repayment-schedule credit-id block-height (get payment-frequency agreement)) 
            ERR-CREDIT-REQUEST-NOT-FOUND)
        
        (ok true)
    )
)

(define-public (make-repayment (credit-id uint))
    (let
        (
            (agreement (unwrap! (get-credit-agreement credit-id) ERR-CREDIT-REQUEST-NOT-FOUND))
            (schedule (unwrap! (get-repayment-schedule credit-id) ERR-CREDIT-REQUEST-NOT-FOUND))
            (installment-amount (get installment-amount agreement))
            (creditor (unwrap! (get creditor agreement) ERR-CREDIT-REQUEST-NOT-FOUND))
            (late-penalty (if (>= block-height (get next-due-height schedule))
                        (calculate-late-penalty installment-amount)
                        u0))
            (total-payment (+ installment-amount late-penalty))
        )
        (asserts! (is-eq (get agreement-status agreement) STATUS-FUNDED) ERR-CREDIT-REQUEST-NOT-FOUND)
        (asserts! (is-eq (get borrower agreement) tx-sender) ERR-UNAUTHORIZED)
        
        (try! (stx-transfer? total-payment tx-sender creditor))
        
        (map-set credit-agreements
            {credit-id: credit-id}
            (merge agreement {
                last-payment-height: block-height,
                outstanding-balance: (- (get outstanding-balance agreement) installment-amount)
            })
        )
        
        (map-set repayment-schedules
            {credit-id: credit-id}
            (merge schedule {
                next-due-height: (+ block-height (get payment-frequency agreement)),
                total-penalties: (+ (get total-penalties schedule) late-penalty)
            })
        )
        
        (ok true)
    )
)

(define-public (liquidate-collateral (credit-id uint))
    (let
        (
            (agreement (unwrap! (get-credit-agreement credit-id) ERR-CREDIT-REQUEST-NOT-FOUND))
            (schedule (unwrap! (get-repayment-schedule credit-id) ERR-CREDIT-REQUEST-NOT-FOUND))
            (creditor (unwrap! (get creditor agreement) ERR-CREDIT-REQUEST-NOT-FOUND))
            (liquidation-needed (requires-liquidation credit-id))
        )
        (asserts! liquidation-needed ERR-NO-LIQUIDATION-REQUIRED)
        
        (as-contract
            (try! (stx-transfer? (get collateral-amount agreement) creditor tx-sender))
        )
        
        (var-set total-collateral-locked (- (var-get total-collateral-locked) (get collateral-amount agreement)))
        
        (map-set credit-agreements
            {credit-id: credit-id}
            (merge agreement {
                agreement-status: STATUS-LIQUIDATED
            })
        )
        
        (ok true)
    )
)

;; Administrative functions
(define-public (update-minimum-collateral-ratio (new-ratio uint))
    (begin
        (asserts! (is-eq tx-sender (var-get protocol-admin)) ERR-UNAUTHORIZED)
        (var-set minimum-collateral-ratio new-ratio)
        (ok true)
    )
)

(define-public (transfer-admin-rights (new-admin principal))
    (begin
        (asserts! (is-eq tx-sender (var-get protocol-admin)) ERR-UNAUTHORIZED)
        (var-set protocol-admin new-admin)
        (ok true)
    )
)