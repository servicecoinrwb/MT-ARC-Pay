// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * Custody — refrigerant cylinder chain of custody on Arc
 *
 * Every pound of refrigerant a contractor touches has to be accounted for:
 * what came out of which appliance, on what date, and who it was handed to
 * for reclamation. The records must be kept for three years, and the
 * penalties for not having them run into six figures a day.
 *
 * Today that record is a paper tag on a cylinder and a line in somebody's
 * logbook. Two things go wrong with it. The tag gets illegible or falls
 * off. And when the reclaimer's records and the contractor's records
 * disagree about how many pounds changed hands, there is no third thing to
 * check — both parties wrote their own number down separately.
 *
 * WHY EVERY HANDOFF NEEDS TWO SIGNATURES
 *
 * A one-sided "I gave it to them" is exactly the record that gets
 * disputed, so it isn't allowed here. A transfer is proposed by the holder
 * and stays pending until the receiver accepts it from their own wallet.
 * Nobody can push custody onto someone who didn't take it, and nobody can
 * later claim they never received a cylinder they signed for.
 *
 * WHAT STAYS OFF THE CHAIN
 *
 * Job addresses and customer names are nobody's business and would be
 * public forever. So a recovery event carries a *reference* — a hash of
 * the job record that lives in the contractor's own system. The chain
 * proves that a specific, unaltered job record existed and how much
 * refrigerant it accounted for. It doesn't publish whose house it was.
 *
 * ─────────────────────────────────────────────────────────────────────
 * THIS IS NOT A COMPLIANCE SYSTEM
 *
 * It records custody and quantities in a way that is hard to alter and
 * easy to audit. It does not satisfy any regulator's recordkeeping
 * requirement on its own, cannot verify that anyone's certification is
 * valid, and cannot check that the pounds entered match the pounds
 * actually recovered. It is a corroborating record alongside the required
 * ones, never a replacement for them. Anyone treating a smart contract as
 * their EPA filing is going to have a bad time.
 * ─────────────────────────────────────────────────────────────────────
 */
contract Custody {

    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    error ZeroAmount();
    error EmptySerial();
    error CylinderExists();
    error NoSuchCylinder();
    error NotHolder();
    error NotReceiver();
    error TransferPending();
    error NoTransferPending();
    error SelfTransfer();
    error OverCapacity(uint256 attempted, uint256 capacity);
    error InsufficientContents(uint256 attempted, uint256 held);
    error CylinderRetired();
    error WrongRefrigerant();
    error NotRegistrar();

    // ----------------------------------------------------------------- types

    enum Move { Registered, Recovered, Charged, TransferOut, TransferIn, SentToReclaim, SentToDestroy, Retired }

    struct Cylinder {
        address holder;
        address pendingTo;      // non-zero while a handoff is unaccepted
        uint64  registeredAt;
        uint64  lastMoveAt;
        uint64  capacity;       // thousandths of a pound
        uint64  contents;       // thousandths of a pound
        bool    exists;
        bool    retired;
        string  serial;         // as stamped on the cylinder
        string  refrigerant;    // "R-410A", "R-22", "R-32"…
    }

    struct Entry {
        Move    kind;
        address actor;          // who did it
        address other;          // counterparty, where there is one
        uint64  amount;         // thousandths of a pound, 0 where n/a
        uint64  at;
        bytes32 jobRef;         // hash of the offchain record, or 0
        string  note;
    }

    // -------------------------------------------------------------- constants

    /// @dev Thousandths of a pound. A 30 lb recovery cylinder is 30_000.
    uint64 public constant SCALE = 1000;

    // ----------------------------------------------------------------- state

    uint256 public nextId = 1;
    mapping(uint256 => Cylinder) private _c;
    mapping(uint256 => Entry[]) private _log;
    mapping(bytes32 => uint256) private _bySerial;   // keccak(serial) => id
    mapping(address => uint256[]) private _held;

    // ---------------------------------------------------------------- events

    event Registered(uint256 indexed id, string serial, string refrigerant, uint256 capacity, address indexed holder);
    event Recovered(uint256 indexed id, address indexed tech, uint256 amount, uint256 contents, bytes32 jobRef);
    event Charged(uint256 indexed id, address indexed tech, uint256 amount, uint256 contents, bytes32 jobRef);
    event TransferProposed(uint256 indexed id, address indexed from, address indexed to, uint256 contents);
    event TransferAccepted(uint256 indexed id, address indexed from, address indexed to, uint256 contents);
    event TransferCancelled(uint256 indexed id, address indexed by);
    event Disposed(uint256 indexed id, address indexed by, address indexed to, uint256 amount, bool destroyed, bytes32 jobRef);
    event RetiredCylinder(uint256 indexed id, address indexed by, string reason);

    // ------------------------------------------------------------- modifiers

    modifier held(uint256 id) {
        Cylinder storage c = _c[id];
        if (!c.exists) revert NoSuchCylinder();
        if (c.retired) revert CylinderRetired();
        if (msg.sender != c.holder) revert NotHolder();
        if (c.pendingTo != address(0)) revert TransferPending();
        _;
    }

    // -------------------------------------------------------------- register

    /**
     * @notice Put a cylinder on the chain.
     * @param serial As stamped on the cylinder. Also the lookup key, so two
     *        cylinders can't share one.
     * @param capacity Thousandths of a pound — a 30 lb cylinder is 30000.
     * @param contents What's already in it at registration, if anything.
     */
    function registerCylinder(
        string calldata serial,
        string calldata refrigerant,
        uint64 capacity,
        uint64 contents,
        string calldata note
    ) external returns (uint256 id) {
        if (bytes(serial).length == 0) revert EmptySerial();
        if (capacity == 0) revert ZeroAmount();
        if (contents > capacity) revert OverCapacity(contents, capacity);

        bytes32 key = keccak256(bytes(serial));
        if (_bySerial[key] != 0) revert CylinderExists();

        id = nextId++;
        _c[id] = Cylinder({
            holder: msg.sender,
            pendingTo: address(0),
            registeredAt: uint64(block.timestamp),
            lastMoveAt: uint64(block.timestamp),
            capacity: capacity,
            contents: contents,
            exists: true,
            retired: false,
            serial: serial,
            refrigerant: refrigerant
        });
        _bySerial[key] = id;
        _held[msg.sender].push(id);

        _push(id, Move.Registered, msg.sender, address(0), contents, bytes32(0), note);
        emit Registered(id, serial, refrigerant, capacity, msg.sender);
    }

    // -------------------------------------------------------------- movement

    /**
     * @notice Refrigerant pulled out of an appliance and into this cylinder.
     * @param jobRef Hash of the job record in your own system. The regulator
     *        wants the location and date; that stays in your files, and this
     *        proves the file you produce later is the one you had at the time.
     */
    function recordRecovery(
        uint256 id,
        uint64 amount,
        bytes32 jobRef,
        string calldata note
    ) external held(id) {
        if (amount == 0) revert ZeroAmount();
        Cylinder storage c = _c[id];
        uint256 after_ = uint256(c.contents) + amount;
        if (after_ > c.capacity) revert OverCapacity(after_, c.capacity);

        c.contents = uint64(after_);
        c.lastMoveAt = uint64(block.timestamp);

        _push(id, Move.Recovered, msg.sender, address(0), amount, jobRef, note);
        emit Recovered(id, msg.sender, amount, c.contents, jobRef);
    }

    /// @notice Refrigerant taken out of this cylinder and into a system.
    function recordCharge(
        uint256 id,
        uint64 amount,
        bytes32 jobRef,
        string calldata note
    ) external held(id) {
        if (amount == 0) revert ZeroAmount();
        Cylinder storage c = _c[id];
        if (amount > c.contents) revert InsufficientContents(amount, c.contents);

        c.contents -= amount;
        c.lastMoveAt = uint64(block.timestamp);

        _push(id, Move.Charged, msg.sender, address(0), amount, jobRef, note);
        emit Charged(id, msg.sender, amount, c.contents, jobRef);
    }

    // -------------------------------------------------------------- handoffs

    /// @notice Offer the cylinder to someone. Custody doesn't move until
    ///         they accept it themselves.
    function proposeTransfer(uint256 id, address to) external held(id) {
        if (to == address(0)) revert ZeroAddress();
        if (to == msg.sender) revert SelfTransfer();
        Cylinder storage c = _c[id];
        c.pendingTo = to;
        emit TransferProposed(id, msg.sender, to, c.contents);
    }

    /// @notice Take custody. From here on it's yours in the record.
    function acceptTransfer(uint256 id) external {
        Cylinder storage c = _c[id];
        if (!c.exists) revert NoSuchCylinder();
        if (c.pendingTo == address(0)) revert NoTransferPending();
        if (msg.sender != c.pendingTo) revert NotReceiver();

        address from = c.holder;
        c.holder = msg.sender;
        c.pendingTo = address(0);
        c.lastMoveAt = uint64(block.timestamp);
        _held[msg.sender].push(id);

        // Both halves are logged so either party's export shows the handoff
        // from their own side, which is how the paperwork actually reads.
        _push(id, Move.TransferOut, from, msg.sender, c.contents, bytes32(0), "");
        _push(id, Move.TransferIn, msg.sender, from, c.contents, bytes32(0), "");
        emit TransferAccepted(id, from, msg.sender, c.contents);
    }

    /// @notice Withdraw an offer, or decline one made to you.
    function cancelTransfer(uint256 id) external {
        Cylinder storage c = _c[id];
        if (!c.exists) revert NoSuchCylinder();
        if (c.pendingTo == address(0)) revert NoTransferPending();
        if (msg.sender != c.holder && msg.sender != c.pendingTo) revert NotHolder();
        c.pendingTo = address(0);
        emit TransferCancelled(id, msg.sender);
    }

    // ------------------------------------------------------------ disposition

    /**
     * @notice Refrigerant sent out for reclamation or destruction.
     * @dev This is the entry a regulator asks for by name: how much, of what,
     *      to whom, on what date. Recorded against the cylinder it left.
     */
    function recordDisposition(
        uint256 id,
        uint64 amount,
        address to,
        bool destroyed,
        bytes32 jobRef,
        string calldata note
    ) external held(id) {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        Cylinder storage c = _c[id];
        if (amount > c.contents) revert InsufficientContents(amount, c.contents);

        c.contents -= amount;
        c.lastMoveAt = uint64(block.timestamp);

        _push(id, destroyed ? Move.SentToDestroy : Move.SentToReclaim, msg.sender, to, amount, jobRef, note);
        emit Disposed(id, msg.sender, to, amount, destroyed, jobRef);
    }

    /// @notice Take a cylinder out of service. The history stays readable —
    ///         retiring closes the record, it doesn't erase it.
    function retire(uint256 id, string calldata reason) external held(id) {
        Cylinder storage c = _c[id];
        c.retired = true;
        c.lastMoveAt = uint64(block.timestamp);
        _push(id, Move.Retired, msg.sender, address(0), c.contents, bytes32(0), reason);
        emit RetiredCylinder(id, msg.sender, reason);
    }

    function _push(
        uint256 id, Move kind, address actor, address other,
        uint64 amount, bytes32 jobRef, string memory note
    ) internal {
        _log[id].push(Entry({
            kind: kind, actor: actor, other: other,
            amount: amount, at: uint64(block.timestamp),
            jobRef: jobRef, note: note
        }));
    }

    // ----------------------------------------------------------------- views

    struct CylinderView {
        bool exists;
        bool retired;
        address holder;
        address pendingTo;
        string serial;
        string refrigerant;
        uint64 capacity;
        uint64 contents;
        uint64 registeredAt;
        uint64 lastMoveAt;
        uint256 entries;
    }

    function getCylinder(uint256 id) external view returns (CylinderView memory v) {
        Cylinder storage c = _c[id];
        if (!c.exists) return v;
        v.exists = true; v.retired = c.retired;
        v.holder = c.holder; v.pendingTo = c.pendingTo;
        v.serial = c.serial; v.refrigerant = c.refrigerant;
        v.capacity = c.capacity; v.contents = c.contents;
        v.registeredAt = c.registeredAt; v.lastMoveAt = c.lastMoveAt;
        v.entries = _log[id].length;
    }

    function findBySerial(string calldata serial) external view returns (uint256) {
        return _bySerial[keccak256(bytes(serial))];
    }

    /// @notice The full history, oldest first. This is the export.
    function history(uint256 id) external view returns (Entry[] memory) {
        return _log[id];
    }

    function entryAt(uint256 id, uint256 i) external view returns (Entry memory) {
        return _log[id][i];
    }

    /// @notice Everything this address has ever held, including cylinders
    ///         since handed on — the record follows the person, not the can.
    function cylindersOf(address who) external view returns (uint256[] memory) {
        return _held[who];
    }

    /**
     * @notice Total recovered, charged and disposed on one cylinder.
     * @dev recovered − charged − disposed should equal current contents for
     *      any cylinder registered empty. A UI can assert that and flag a
     *      cylinder whose arithmetic has drifted, which usually means an
     *      event went unlogged rather than that refrigerant vanished.
     */
    function totals(uint256 id)
        external
        view
        returns (uint256 recovered, uint256 charged, uint256 reclaimed, uint256 destroyed)
    {
        Entry[] storage es = _log[id];
        for (uint256 i = 0; i < es.length; i++) {
            Move k = es[i].kind;
            if (k == Move.Recovered) recovered += es[i].amount;
            else if (k == Move.Charged) charged += es[i].amount;
            else if (k == Move.SentToReclaim) reclaimed += es[i].amount;
            else if (k == Move.SentToDestroy) destroyed += es[i].amount;
        }
    }

    /// @dev No owner, no admin, no way to alter or delete an entry once it's
    ///      written. A custody log that can be edited is not a custody log.
}
