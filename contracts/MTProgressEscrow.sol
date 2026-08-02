// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * MTProgressEscrow — Mechanical Temp LLC
 * Arc (chain 5042002 testnet)
 *
 * PROGRESS BILLING WITH A CLAIM-AND-OBJECT RELEASE MODEL
 *
 * Unlike MTInvoiceRegistry, this contract HOLDS MONEY. That changes
 * everything about how it's written. Every payout follows
 * checks-effects-interactions, every state change is guarded, and there is
 * no owner function anywhere that can move customer funds to an arbitrary
 * address. The owner can claim milestones and refund them. That is all.
 *
 * THE FLOW
 *
 *   1. Owner creates a job: customer address + an ordered list of milestone
 *      amounts + an objection window.
 *   2. Customer funds the FULL total in one transaction. Nothing can be
 *      claimed before this. Funding is also how the customer consents to
 *      the milestone schedule and window — they can read both first.
 *   3. Owner claims a milestone when that phase of work is done. This starts
 *      the objection window.
 *   4. Three things can happen:
 *        - Customer stays silent past the window  -> anyone may release it
 *        - Customer approves early                -> releases immediately
 *        - Customer objects inside the window     -> milestone freezes
 *   5. A frozen milestone unfreezes only by the customer approving it or the
 *      owner refunding it. There is deliberately no arbitration path.
 *   6. If the job goes quiet for LONG_STOP, the customer reclaims everything
 *      not yet released.
 *
 * WHAT PROTECTS WHOM
 *
 *   Customer: full funding is visible to them before work starts; the
 *   objection window stops early or false billing; the long-stop returns
 *   their money if the contractor walks.
 *
 *   Contractor: money is provably escrowed before equipment is ordered;
 *   silence can't stall a legitimate draw forever.
 *
 * WHAT THIS DOESN'T DO
 *
 *   It does not resolve disputes. A frozen milestone stays frozen until a
 *   human relents. Any escrow claiming to arbitrate on-chain is lying about
 *   what a blockchain can know. Stalemate here is a feature: it's visible,
 *   it's symmetric, and it forces the phone call.
 */
contract MTProgressEscrow {
    // ---------------------------------------------------------------- errors

    error NotOwner();
    error NotPendingOwner();
    error NotCustomer();
    error ZeroAddress();
    error ZeroAmount();
    error JobExists();
    error NoSuchJob();
    error NoSuchMilestone();
    error AlreadyFunded();
    error NotFunded();
    error WrongAmount(uint256 sent, uint256 required);
    error BadWindow();
    error NoMilestones();
    error TooManyMilestones();
    error NotClaimable();
    error NotClaimed();
    error WindowOpen(uint64 releasableAt);
    error WindowClosed();
    error NotRefundable();
    error NothingToReclaim();
    error TooSoonToReclaim(uint64 reclaimableAt);
    error PayoutFailed();
    error Reentrant();

    // ----------------------------------------------------------------- types

    enum MState { Pending, Claimed, Released, Disputed, Refunded }
    enum JState { Draft, Funded, Closed }

    struct Milestone {
        uint128 amount;
        uint64  claimedAt;   // 0 until claimed
        MState  state;
    }

    struct Job {
        address customer;
        uint64  createdAt;
        JState  status;
        bool    exists;
        uint128 total;
        uint128 released;
        uint128 refunded;
        uint64  lastActivity;
        uint32  objectionWindow; // seconds
    }

    // -------------------------------------------------------------- constants

    /// @dev Absolute floor. minWindow is set per-deployment above this so a
    ///      testnet instance can use seconds while mainnet uses days.
    uint32 public constant FLOOR_WINDOW = 60;
    uint32 public constant MAX_WINDOW = 30 days;
    uint64 public constant LONG_STOP  = 90 days;
    uint256 public constant MAX_MILESTONES = 20;

    // ----------------------------------------------------------------- state

    address public owner;
    address public pendingOwner;
    address public treasury;
    uint32 public immutable minWindow;
    uint256 private _lock = 1;

    mapping(bytes32 => Job) private _jobs;
    mapping(bytes32 => Milestone[]) private _milestones;
    mapping(bytes32 => string) private _refs;
    bytes32[] private _ids;

    // ---------------------------------------------------------------- events

    event JobCreated(
        bytes32 indexed id,
        string  jobRef,
        address indexed customer,
        uint256 total,
        uint256 milestoneCount,
        uint32  objectionWindow
    );
    event JobFunded(bytes32 indexed id, string jobRef, address indexed customer, uint256 amount);
    event MilestoneClaimed(
        bytes32 indexed id,
        string  jobRef,
        uint256 indexed index,
        uint256 amount,
        uint64  releasableAt
    );
    event MilestoneObjected(bytes32 indexed id, string jobRef, uint256 indexed index);
    event MilestoneReleased(
        bytes32 indexed id,
        string  jobRef,
        uint256 indexed index,
        uint256 amount,
        bool    early
    );
    event MilestoneRefunded(bytes32 indexed id, string jobRef, uint256 indexed index, uint256 amount);
    event JobReclaimed(bytes32 indexed id, string jobRef, uint256 amount);
    event JobClosed(bytes32 indexed id, string jobRef);
    event TreasuryChanged(address indexed from, address indexed to);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    // ------------------------------------------------------------- modifiers

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrant();
        _lock = 2;
        _;
        _lock = 1;
    }

    // ----------------------------------------------------------- constructor

    constructor(address _treasury, uint32 _minWindow) {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_minWindow < FLOOR_WINDOW || _minWindow > MAX_WINDOW) revert BadWindow();
        owner = msg.sender;
        treasury = _treasury;
        minWindow = _minWindow;
        emit OwnershipTransferred(address(0), msg.sender);
        emit TreasuryChanged(address(0), _treasury);
    }

    // ------------------------------------------------------------------ jobs

    function idOf(string calldata jobRef) public pure returns (bytes32) {
        return keccak256(bytes(jobRef));
    }

    /// @notice Create a job schedule. Nothing is owed or held until the
    ///         customer funds it, so this is safe to call speculatively.
    function createJob(
        string calldata jobRef,
        address customer,
        uint256[] calldata amounts,
        uint32 objectionWindow
    ) external onlyOwner {
        if (customer == address(0)) revert ZeroAddress();
        if (amounts.length == 0) revert NoMilestones();
        if (amounts.length > MAX_MILESTONES) revert TooManyMilestones();
        if (objectionWindow < minWindow || objectionWindow > MAX_WINDOW) revert BadWindow();

        bytes32 id = keccak256(bytes(jobRef));
        if (_jobs[id].exists) revert JobExists();

        uint256 total;
        Milestone[] storage ms = _milestones[id];
        for (uint256 i = 0; i < amounts.length; i++) {
            if (amounts[i] == 0) revert ZeroAmount();
            total += amounts[i];
            ms.push(Milestone({
                amount: uint128(amounts[i]),
                claimedAt: 0,
                state: MState.Pending
            }));
        }

        _jobs[id] = Job({
            customer: customer,
            createdAt: uint64(block.timestamp),
            status: JState.Draft,
            exists: true,
            total: uint128(total),
            released: 0,
            refunded: 0,
            lastActivity: uint64(block.timestamp),
            objectionWindow: objectionWindow
        });
        _ids.push(id);
        _refs[id] = jobRef;

        emit JobCreated(id, jobRef, customer, total, amounts.length, objectionWindow);
    }

    /// @notice Customer funds the whole job. Exact amount, one shot.
    function fund(string calldata jobRef) external payable nonReentrant {
        bytes32 id = keccak256(bytes(jobRef));
        Job storage j = _jobs[id];
        if (!j.exists) revert NoSuchJob();
        if (msg.sender != j.customer) revert NotCustomer();
        if (j.status != JState.Draft) revert AlreadyFunded();
        if (msg.value != uint256(j.total)) revert WrongAmount(msg.value, j.total);

        j.status = JState.Funded;
        j.lastActivity = uint64(block.timestamp);

        emit JobFunded(id, jobRef, msg.sender, msg.value);
    }

    // ------------------------------------------------------------ milestones

    /// @notice Owner marks a phase complete, starting the objection window.
    function claim(string calldata jobRef, uint256 index) external onlyOwner {
        bytes32 id = keccak256(bytes(jobRef));
        Job storage j = _jobs[id];
        if (!j.exists) revert NoSuchJob();
        if (j.status != JState.Funded) revert NotFunded();

        Milestone[] storage ms = _milestones[id];
        if (index >= ms.length) revert NoSuchMilestone();
        Milestone storage m = ms[index];
        if (m.state != MState.Pending) revert NotClaimable();

        m.state = MState.Claimed;
        m.claimedAt = uint64(block.timestamp);
        j.lastActivity = uint64(block.timestamp);

        emit MilestoneClaimed(
            id, jobRef, index, m.amount,
            uint64(block.timestamp) + j.objectionWindow
        );
    }

    /// @notice Customer freezes a claimed milestone. Only inside the window.
    function object(string calldata jobRef, uint256 index) external {
        bytes32 id = keccak256(bytes(jobRef));
        Job storage j = _jobs[id];
        if (!j.exists) revert NoSuchJob();
        if (msg.sender != j.customer) revert NotCustomer();

        Milestone[] storage ms = _milestones[id];
        if (index >= ms.length) revert NoSuchMilestone();
        Milestone storage m = ms[index];
        if (m.state != MState.Claimed) revert NotClaimed();
        if (block.timestamp >= uint256(m.claimedAt) + j.objectionWindow) revert WindowClosed();

        m.state = MState.Disputed;
        j.lastActivity = uint64(block.timestamp);

        emit MilestoneObjected(id, jobRef, index);
    }

    /// @notice Release after the window expires. Callable by anyone — the
    ///         right to be paid shouldn't depend on who sends the tx.
    function release(string calldata jobRef, uint256 index) external nonReentrant {
        bytes32 id = keccak256(bytes(jobRef));
        Job storage j = _jobs[id];
        if (!j.exists) revert NoSuchJob();

        Milestone[] storage ms = _milestones[id];
        if (index >= ms.length) revert NoSuchMilestone();
        Milestone storage m = ms[index];
        if (m.state != MState.Claimed) revert NotClaimed();

        uint64 releasableAt = m.claimedAt + uint64(j.objectionWindow);
        if (block.timestamp < releasableAt) revert WindowOpen(releasableAt);

        _payOut(id, jobRef, j, m, index, false);
    }

    /// @notice Customer releases early, or unfreezes a disputed milestone.
    ///         Same function because both are the customer saying yes.
    function approve(string calldata jobRef, uint256 index) external nonReentrant {
        bytes32 id = keccak256(bytes(jobRef));
        Job storage j = _jobs[id];
        if (!j.exists) revert NoSuchJob();
        if (msg.sender != j.customer) revert NotCustomer();

        Milestone[] storage ms = _milestones[id];
        if (index >= ms.length) revert NoSuchMilestone();
        Milestone storage m = ms[index];
        if (m.state != MState.Claimed && m.state != MState.Disputed) revert NotClaimed();

        _payOut(id, jobRef, j, m, index, true);
    }

    function _payOut(
        bytes32 id,
        string calldata jobRef,
        Job storage j,
        Milestone storage m,
        uint256 index,
        bool early
    ) internal {
        uint256 amt = m.amount;

        // effects
        m.state = MState.Released;
        j.released += uint128(amt);
        j.lastActivity = uint64(block.timestamp);
        _maybeClose(id, jobRef, j);

        emit MilestoneReleased(id, jobRef, index, amt, early);

        // interaction
        (bool ok, ) = treasury.call{value: amt}("");
        if (!ok) revert PayoutFailed();
    }

    /// @notice Owner gives a milestone back — the way out of a stalemate
    ///         when the customer is right, or when scope is cut.
    function refundMilestone(string calldata jobRef, uint256 index)
        external
        onlyOwner
        nonReentrant
    {
        bytes32 id = keccak256(bytes(jobRef));
        Job storage j = _jobs[id];
        if (!j.exists) revert NoSuchJob();
        if (j.status != JState.Funded) revert NotFunded();

        Milestone[] storage ms = _milestones[id];
        if (index >= ms.length) revert NoSuchMilestone();
        Milestone storage m = ms[index];
        if (m.state != MState.Disputed && m.state != MState.Pending && m.state != MState.Claimed) {
            revert NotRefundable();
        }

        uint256 amt = m.amount;
        address to = j.customer;

        m.state = MState.Refunded;
        j.refunded += uint128(amt);
        j.lastActivity = uint64(block.timestamp);
        _maybeClose(id, jobRef, j);

        emit MilestoneRefunded(id, jobRef, index, amt);

        (bool ok, ) = to.call{value: amt}("");
        if (!ok) revert PayoutFailed();
    }

    /// @notice Customer's escape hatch. After LONG_STOP of no activity,
    ///         everything unreleased goes home.
    function reclaim(string calldata jobRef) external nonReentrant {
        bytes32 id = keccak256(bytes(jobRef));
        Job storage j = _jobs[id];
        if (!j.exists) revert NoSuchJob();
        if (msg.sender != j.customer) revert NotCustomer();
        if (j.status != JState.Funded) revert NotFunded();

        uint64 unlockAt = j.lastActivity + LONG_STOP;
        if (block.timestamp < unlockAt) revert TooSoonToReclaim(unlockAt);

        Milestone[] storage ms = _milestones[id];
        uint256 amt;
        for (uint256 i = 0; i < ms.length; i++) {
            MState s = ms[i].state;
            if (s == MState.Pending || s == MState.Claimed || s == MState.Disputed) {
                amt += ms[i].amount;
                ms[i].state = MState.Refunded;
            }
        }
        if (amt == 0) revert NothingToReclaim();

        j.refunded += uint128(amt);
        j.lastActivity = uint64(block.timestamp);
        j.status = JState.Closed;

        emit JobReclaimed(id, jobRef, amt);
        emit JobClosed(id, jobRef);

        (bool ok, ) = j.customer.call{value: amt}("");
        if (!ok) revert PayoutFailed();
    }

    function _maybeClose(bytes32 id, string calldata jobRef, Job storage j) internal {
        if (uint256(j.released) + uint256(j.refunded) >= uint256(j.total)) {
            j.status = JState.Closed;
            emit JobClosed(id, jobRef);
        }
    }

    // ----------------------------------------------------------------- admin

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        emit TreasuryChanged(treasury, _treasury);
        treasury = _treasury;
    }

    function transferOwnership(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        pendingOwner = to;
        emit OwnershipTransferStarted(owner, to);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    // ----------------------------------------------------------------- views

    function getJob(string calldata jobRef)
        external
        view
        returns (
            bool exists,
            address customer,
            uint8 status,
            uint256 total,
            uint256 released,
            uint256 refunded,
            uint256 held,
            uint64 createdAt,
            uint64 lastActivity,
            uint32 objectionWindow,
            uint256 milestoneCount
        )
    {
        bytes32 id = keccak256(bytes(jobRef));
        Job storage j = _jobs[id];
        exists = j.exists;
        customer = j.customer;
        status = uint8(j.status);
        total = j.total;
        released = j.released;
        refunded = j.refunded;
        held = j.status == JState.Draft ? 0 : total - released - refunded;
        createdAt = j.createdAt;
        lastActivity = j.lastActivity;
        objectionWindow = j.objectionWindow;
        milestoneCount = _milestones[id].length;
    }

    function getMilestone(string calldata jobRef, uint256 index)
        external
        view
        returns (uint256 amount, uint8 state, uint64 claimedAt, uint64 releasableAt)
    {
        bytes32 id = keccak256(bytes(jobRef));
        Milestone[] storage ms = _milestones[id];
        if (index >= ms.length) revert NoSuchMilestone();
        Milestone storage m = ms[index];
        amount = m.amount;
        state = uint8(m.state);
        claimedAt = m.claimedAt;
        releasableAt = m.claimedAt == 0 ? 0 : m.claimedAt + uint64(_jobs[id].objectionWindow);
    }

    function reclaimableAt(string calldata jobRef) external view returns (uint64) {
        Job storage j = _jobs[keccak256(bytes(jobRef))];
        if (!j.exists) revert NoSuchJob();
        return j.lastActivity + LONG_STOP;
    }

    function jobCount() external view returns (uint256) {
        return _ids.length;
    }

    function jobAt(uint256 i) external view returns (string memory jobRef, uint8 status) {
        bytes32 id = _ids[i];
        return (_refs[id], uint8(_jobs[id].status));
    }

    /// @dev No receive()/fallback. Funds enter only through fund(), which
    ///      binds them to a job. Loose value would be unattributable and
    ///      therefore unrecoverable.
}
