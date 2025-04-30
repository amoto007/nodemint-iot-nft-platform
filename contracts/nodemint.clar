;; NodeMint IoT NFT Platform - Core Contract
;; This contract manages IoT device registration, data verification, and NFT minting
;; for the NodeMint platform, creating a bridge between physical IoT data and blockchain assets.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-DEVICE-NOT-FOUND (err u101))
(define-constant ERR-DEVICE-ALREADY-REGISTERED (err u102))
(define-constant ERR-DATA-STREAM-NOT-AUTHORIZED (err u103))
(define-constant ERR-INVALID-SIGNATURE (err u104))
(define-constant ERR-DATA-TIMESTAMP-INVALID (err u105))
(define-constant ERR-NFT-NOT-FOUND (err u106))
(define-constant ERR-NFT-ALREADY-EXISTS (err u107))
(define-constant ERR-INSUFFICIENT-FUNDS (err u108))
(define-constant ERR-LISTING-NOT-FOUND (err u109))
(define-constant ERR-DEVICE-ALREADY-AUTHORIZED (err u110))

;; SIP-009 NFT Interface Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant NFT-NAME "NodeMint IoT NFT")
(define-constant NFT-SYMBOL "NODEMINT")

;; Data storage

;; Device registry - maps device IDs to their registered owner addresses
(define-map device-registry 
  { device-id: (buff 32) } 
  { owner: principal, active: bool, registration-time: uint }
)

;; Device data streams - maps device ID and stream ID to authorization status
(define-map device-data-streams
  { device-id: (buff 32), stream-id: (buff 32) }
  { authorized: bool, description: (string-ascii 100) }
)

;; Device public keys - used for verifying data signatures
(define-map device-public-keys
  { device-id: (buff 32) }
  { public-key: (buff 33) }
)

;; NFT storage - implements SIP-009 standard with IoT-specific extensions
(define-non-fungible-token nodemint-nft uint)

;; NFT metadata - stores information about each minted NFT
(define-map nft-metadata
  { token-id: uint }
  {
    device-id: (buff 32),
    stream-id: (buff 32),
    data-timestamp: uint,
    data-ipfs-hash: (buff 46),
    data-signature: (buff 65),
    mint-time: uint,
    mint-block: uint
  }
)

;; NFT marketplace - for listing and trading IoT NFTs
(define-map nft-listings
  { token-id: uint }
  { 
    seller: principal, 
    price: uint,
    active: bool 
  }
)

;; Token ID counter for minting new NFTs
(define-data-var token-id-counter uint u1)

;; Implement SIP-009: NFT standard

;; Get the last token ID
(define-read-only (get-last-token-id)
  (ok (- (var-get token-id-counter) u1))
)

;; Get the token URI (IPFS hash in this case)
(define-read-only (get-token-uri (token-id uint))
  (match (map-get? nft-metadata { token-id: token-id })
    metadata (ok (some (concat "ipfs://" (buff-to-utf8 (get data-ipfs-hash metadata)))))
    (ok none)
  )
)

;; Get owner of a given NFT
(define-read-only (get-owner (token-id uint))
  (ok (nft-get-owner? nodemint-nft token-id))
)

;; Transfer NFT - standard SIP-009 transfer function
(define-public (transfer (token-id uint) (sender principal) (recipient principal))
  (begin
    ;; Check authorization
    (asserts! (is-eq tx-sender sender) ERR-NOT-AUTHORIZED)
    
    ;; If token is listed, remove listing
    (match (map-get? nft-listings { token-id: token-id })
      listing (map-delete nft-listings { token-id: token-id })
      true
    )
    
    ;; Execute transfer
    (nft-transfer? nodemint-nft token-id sender recipient)
  )
)

;; IoT Device Management Functions

;; Register a new IoT device
(define-public (register-device (device-id (buff 32)) (public-key (buff 33)))
  (let (
    (caller tx-sender)
    (current-time (unwrap-panic (get-block-info? time-ms (- block-height u1))))
  )
    ;; Check the device is not already registered
    (asserts! (is-none (map-get? device-registry { device-id: device-id })) ERR-DEVICE-ALREADY-REGISTERED)
    
    ;; Register the device
    (map-set device-registry 
      { device-id: device-id } 
      { 
        owner: caller, 
        active: true, 
        registration-time: current-time
      }
    )
    
    ;; Store the device's public key
    (map-set device-public-keys
      { device-id: device-id }
      { public-key: public-key }
    )
    
    (ok true)
  )
)

;; Authorize a data stream for an existing device
(define-public (authorize-data-stream (device-id (buff 32)) (stream-id (buff 32)) (description (string-ascii 100)))
  (let ((caller tx-sender))
    ;; Check device exists and caller is owner
    (match (map-get? device-registry { device-id: device-id })
      device (begin
        (asserts! (is-eq (get owner device) caller) ERR-NOT-AUTHORIZED)
        
        ;; Check stream is not already authorized
        (match (map-get? device-data-streams { device-id: device-id, stream-id: stream-id })
          existing-stream (asserts! (not (get authorized existing-stream)) ERR-DEVICE-ALREADY-AUTHORIZED)
          true
        )
        
        ;; Authorize the stream
        (map-set device-data-streams
          { device-id: device-id, stream-id: stream-id }
          { authorized: true, description: description }
        )
        
        (ok true)
      )
      ERR-DEVICE-NOT-FOUND
    )
  )
)

;; Verify IoT data signature
(define-private (verify-data-signature (device-id (buff 32)) (data-hash (buff 32)) (signature (buff 65)))
  (match (map-get? device-public-keys { device-id: device-id })
    key-data (is-eq (secp256k1-recover? data-hash signature) (some (get public-key key-data)))
    false
  )
)

;; IoT NFT Minting

;; Mint a new NFT backed by IoT data
(define-public (mint-iot-nft 
    (device-id (buff 32))
    (stream-id (buff 32))
    (data-timestamp uint)
    (data-ipfs-hash (buff 46))
    (data-signature (buff 65))
  )
  (let (
    (caller tx-sender)
    (token-id (var-get token-id-counter))
    (current-time (unwrap-panic (get-block-info? time-ms (- block-height u1))))
    (data-hash (sha256 (concat data-ipfs-hash (to-consensus-buff data-timestamp))))
  )
    ;; Check device exists and is active
    (match (map-get? device-registry { device-id: device-id })
      device-data (begin
        ;; Only device owner can mint NFTs from their device data
        (asserts! (is-eq (get owner device-data) caller) ERR-NOT-AUTHORIZED)
        (asserts! (get active device-data) ERR-DEVICE-NOT-FOUND)
        
        ;; Check data stream is authorized
        (match (map-get? device-data-streams { device-id: device-id, stream-id: stream-id })
          stream-data (asserts! (get authorized stream-data) ERR-DATA-STREAM-NOT-AUTHORIZED)
          ERR-DATA-STREAM-NOT-AUTHORIZED
        )
        
        ;; Verify data signature to ensure data integrity
        (asserts! (verify-data-signature device-id data-hash data-signature) ERR-INVALID-SIGNATURE)
        
        ;; Ensure data timestamp is reasonable (not in future, not too old)
        (asserts! (< data-timestamp current-time) ERR-DATA-TIMESTAMP-INVALID)
        (asserts! (> data-timestamp (- current-time (* u86400000 u30))) ERR-DATA-TIMESTAMP-INVALID) ;; Within 30 days
        
        ;; Mint the NFT
        (asserts! (is-ok (nft-mint? nodemint-nft token-id caller)) ERR-NFT-ALREADY-EXISTS)
        
        ;; Store metadata
        (map-set nft-metadata
          { token-id: token-id }
          {
            device-id: device-id,
            stream-id: stream-id,
            data-timestamp: data-timestamp,
            data-ipfs-hash: data-ipfs-hash,
            data-signature: data-signature,
            mint-time: current-time,
            mint-block: block-height
          }
        )
        
        ;; Increment token counter
        (var-set token-id-counter (+ token-id u1))
        
        (ok token-id)
      )
      ERR-DEVICE-NOT-FOUND
    )
  )
)

;; IoT NFT Marketplace Functions

;; List an NFT for sale
(define-public (list-nft (token-id uint) (price uint))
  (let ((caller tx-sender))
    ;; Check caller owns the NFT
    (match (nft-get-owner? nodemint-nft token-id)
      owner (begin
        (asserts! (is-eq owner (some caller)) ERR-NOT-AUTHORIZED)
        
        ;; Create listing
        (map-set nft-listings
          { token-id: token-id }
          { 
            seller: caller, 
            price: price,
            active: true 
          }
        )
        
        (ok true)
      )
      ERR-NFT-NOT-FOUND
    )
  )
)

;; Cancel an NFT listing
(define-public (cancel-listing (token-id uint))
  (let ((caller tx-sender))
    ;; Check listing exists and caller is the seller
    (match (map-get? nft-listings { token-id: token-id })
      listing (begin
        (asserts! (is-eq (get seller listing) caller) ERR-NOT-AUTHORIZED)
        (asserts! (get active listing) ERR-LISTING-NOT-FOUND)
        
        ;; Remove listing
        (map-delete nft-listings { token-id: token-id })
        
        (ok true)
      )
      ERR-LISTING-NOT-FOUND
    )
  )
)

;; Buy a listed NFT
(define-public (buy-nft (token-id uint))
  (let (
    (buyer tx-sender)
  )
    ;; Check listing exists and is active
    (match (map-get? nft-listings { token-id: token-id })
      listing (begin
        (asserts! (get active listing) ERR-LISTING-NOT-FOUND)
        (let (
          (seller (get seller listing))
          (price (get price listing))
        )
          ;; Check buyer is not the seller
          (asserts! (not (is-eq buyer seller)) ERR-NOT-AUTHORIZED)
          
          ;; Transfer payment from buyer to seller
          (asserts! (is-ok (stx-transfer? price buyer seller)) ERR-INSUFFICIENT-FUNDS)
          
          ;; Transfer NFT from seller to buyer
          (asserts! (is-ok (nft-transfer? nodemint-nft token-id seller buyer)) ERR-NFT-NOT-FOUND)
          
          ;; Remove listing
          (map-delete nft-listings { token-id: token-id })
          
          (ok true)
        )
      )
      ERR-LISTING-NOT-FOUND
    )
  )
)

;; IoT Data Query Functions

;; Get device information
(define-read-only (get-device-info (device-id (buff 32)))
  (match (map-get? device-registry { device-id: device-id })
    device-data (ok device-data)
    ERR-DEVICE-NOT-FOUND
  )
)

;; Check if a data stream is authorized
(define-read-only (is-stream-authorized (device-id (buff 32)) (stream-id (buff 32)))
  (match (map-get? device-data-streams { device-id: device-id, stream-id: stream-id })
    stream-data (ok (get authorized stream-data))
    (ok false)
  )
)

;; Get NFT metadata
(define-read-only (get-nft-metadata (token-id uint))
  (match (map-get? nft-metadata { token-id: token-id })
    metadata (ok metadata)
    ERR-NFT-NOT-FOUND
  )
)

;; Get NFT listing information
(define-read-only (get-nft-listing (token-id uint))
  (match (map-get? nft-listings { token-id: token-id })
    listing (ok listing)
    ERR-LISTING-NOT-FOUND
  )
)

;; Device Access Management Functions

;; Transfer device ownership
(define-public (transfer-device-ownership (device-id (buff 32)) (new-owner principal))
  (let ((caller tx-sender))
    ;; Check device exists and caller is owner
    (match (map-get? device-registry { device-id: device-id })
      device-data (begin
        (asserts! (is-eq (get owner device-data) caller) ERR-NOT-AUTHORIZED)
        
        ;; Update device ownership
        (map-set device-registry
          { device-id: device-id }
          {
            owner: new-owner,
            active: (get active device-data),
            registration-time: (get registration-time device-data)
          }
        )
        
        (ok true)
      )
      ERR-DEVICE-NOT-FOUND
    )
  )
)

;; Deactivate device
(define-public (deactivate-device (device-id (buff 32)))
  (let ((caller tx-sender))
    ;; Check device exists and caller is owner
    (match (map-get? device-registry { device-id: device-id })
      device-data (begin
        (asserts! (is-eq (get owner device-data) caller) ERR-NOT-AUTHORIZED)
        
        ;; Update device status
        (map-set device-registry
          { device-id: device-id }
          {
            owner: (get owner device-data),
            active: false,
            registration-time: (get registration-time device-data)
          }
        )
        
        (ok true)
      )
      ERR-DEVICE-NOT-FOUND
    )
  )
)

;; Reactivate device
(define-public (reactivate-device (device-id (buff 32)))
  (let ((caller tx-sender))
    ;; Check device exists and caller is owner
    (match (map-get? device-registry { device-id: device-id })
      device-data (begin
        (asserts! (is-eq (get owner device-data) caller) ERR-NOT-AUTHORIZED)
        
        ;; Update device status
        (map-set device-registry
          { device-id: device-id }
          {
            owner: (get owner device-data),
            active: true,
            registration-time: (get registration-time device-data)
          }
        )
        
        (ok true)
      )
      ERR-DEVICE-NOT-FOUND
    )
  )
)

;; Remove data stream authorization
(define-public (deauthorize-data-stream (device-id (buff 32)) (stream-id (buff 32)))
  (let ((caller tx-sender))
    ;; Check device exists and caller is owner
    (match (map-get? device-registry { device-id: device-id })
      device-data (begin
        (asserts! (is-eq (get owner device-data) caller) ERR-NOT-AUTHORIZED)
        
        ;; Check stream is currently authorized
        (match (map-get? device-data-streams { device-id: device-id, stream-id: stream-id })
          stream-data (begin
            (asserts! (get authorized stream-data) ERR-DATA-STREAM-NOT-AUTHORIZED)
            
            ;; Deauthorize the stream but keep its description
            (map-set device-data-streams
              { device-id: device-id, stream-id: stream-id }
              { 
                authorized: false, 
                description: (get description stream-data)
              }
            )
            
            (ok true)
          )
          ERR-DATA-STREAM-NOT-AUTHORIZED
        )
      )
      ERR-DEVICE-NOT-FOUND
    )
  )
)