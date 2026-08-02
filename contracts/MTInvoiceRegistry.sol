// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * MTInvoiceRegistry — Mechanical Temp LLC
 * Arc Testnet (chain 5042002)
 *
 * WHY THIS IS SHAPED THIS WAY
 *
 * Arc uses USDC as the NATIVE gas token. That means a customer pays an invoice
 * with plain `msg.value` — no ERC-20 approve, no allowance, no second signature.
 * One transaction, one confirmation. That is the entire reason this contract is
 * short.
 *
 * NO CUSTODY. Every payment is forwarded to `treasury` inside the same call.
 * This contract never holds a balance, so there is nothing here to drain and
 * nothing to sweep. It is a receipt ledger, not a wallet.
 *
 * PARTIAL PAYMENT is supported because DSM already models partially-paid
 * invoices (dashboard.py:9156). Overpayment reverts rather than refunds —
 * refunds would mean sending value back to an untrusted caller, and a clear
 * revert is better than a clever refund.
 *
 * The `invNum` string is emitted un-hashed in every event so the DSM indexer
 * can match on INVNum directly without maintaining a hash->number crosswalk.
 */
contract MTInvoiceRegistry {
    // ---------------------------------------------------------------- errors

    error NotOwner();
    error NotPendingOwner();
    error Paused();
    error Reentrant();
    error ZeroAddress();
    error ZeroAmount();
    error InvoiceExists();
    error NoSuchInvoice();
    error InvoiceIsVoided();
    error InvoiceSettled();
    error Overpayment(uint256 sent, uint256 remaining);
    error AlreadyPaid();
    error ForwardFailed();

    // ----------------------------------------------------------------- types

    struct Invoice {
        uint128 amountDue;   // native wei (see DECIMALS note in the pay page)
        uint128 amountPaid;
        uint64  createdAt;
        uint64  settledAt;   // 0 until fully paid
        address lastPayer;
        bool    exists;
        bool    voided;
    }

    // ----------------------------------------------------------------- state

    address public owner;
    address public pendingOwner;
    address public treasury;
    bool    public paused;
    uint256 private _lock = 1;

    mapping(bytes32 => Invoice) private _invoices;
    bytes32[] private _ids;
    mapping(bytes32 => string) private _numbers; // id -> original INVNum

    // ---------------------------------------------------------------- events

    event InvoiceCreated(bytes32 indexed id, string invNum, uint256 amountDue);
    event InvoicePaid(
        bytes32 indexed id,
        string  invNum,
        address indexed payer,
        uint256 amount,
        uint256 amountPaid,
        uint256 amountDue,
        bool    settled
    );
    event InvoiceVoided(bytes32 indexed id, string invNum);
    event TreasuryChanged(address indexed from, address indexed to);
    event PausedSet(bool paused);
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

    constructor(address _treasury) {
        if (_treasury == address(0)) revert ZeroAddress();
        owner = msg.sender;
        treasury = _treasury;
        emit OwnershipTransferred(address(0), msg.sender);
        emit TreasuryChanged(address(0), _treasury);
    }

    // ---------------------------------------------------------------- issue

    function idOf(string calldata invNum) public pure returns (bytes32) {
        return keccak256(bytes(invNum));
    }

    function createInvoice(string calldata invNum, uint256 amountDue)
        external
        onlyOwner
    {
        _create(invNum, amountDue);
    }

    function createInvoices(
        string[] calldata invNums,
        uint256[] calldata amountsDue
    ) external onlyOwner {
        uint256 n = invNums.length;
        require(n == amountsDue.length, "length mismatch");
        for (uint256 i = 0; i < n; i++) {
            _create(invNums[i], amountsDue[i]);
        }
    }

    function _create(string calldata invNum, uint256 amountDue) internal {
        if (amountDue == 0) revert ZeroAmount();
        bytes32 id = keccak256(bytes(invNum));
        if (_invoices[id].exists) revert InvoiceExists();

        _invoices[id] = Invoice({
            amountDue: uint128(amountDue),
            amountPaid: 0,
            createdAt: uint64(block.timestamp),
            settledAt: 0,
            lastPayer: address(0),
            exists: true,
            voided: false
        });
        _ids.push(id);
        _numbers[id] = invNum;

        emit InvoiceCreated(id, invNum, amountDue);
    }

    // ------------------------------------------------------------------ pay

    /// @notice Pay an invoice with native USDC. Partial payments allowed.
    function pay(string calldata invNum) external payable nonReentrant {
        if (paused) revert Paused();
        if (msg.value == 0) revert ZeroAmount();

        bytes32 id = keccak256(bytes(invNum));
        Invoice storage inv = _invoices[id];

        if (!inv.exists) revert NoSuchInvoice();
        if (inv.voided) revert InvoiceIsVoided();
        if (inv.settledAt != 0) revert InvoiceSettled();

        uint256 remaining = uint256(inv.amountDue) - uint256(inv.amountPaid);
        if (msg.value > remaining) revert Overpayment(msg.value, remaining);

        // effects
        uint256 newPaid = uint256(inv.amountPaid) + msg.value;
        inv.amountPaid = uint128(newPaid);
        inv.lastPayer = msg.sender;
        bool settled = newPaid >= uint256(inv.amountDue);
        if (settled) inv.settledAt = uint64(block.timestamp);

        emit InvoicePaid(
            id,
            invNum,
            msg.sender,
            msg.value,
            newPaid,
            uint256(inv.amountDue),
            settled
        );

        // interaction — forward, never custody
        (bool ok, ) = treasury.call{value: msg.value}("");
        if (!ok) revert ForwardFailed();
    }

    // ----------------------------------------------------------------- void

    /// @dev Soft-void, matching the Bookkeeper's void semantics. An invoice
    ///      that has taken money cannot be voided — that would orphan a real
    ///      payment. Settle or refund off-chain instead.
    function voidInvoice(string calldata invNum) external onlyOwner {
        bytes32 id = keccak256(bytes(invNum));
        Invoice storage inv = _invoices[id];
        if (!inv.exists) revert NoSuchInvoice();
        if (inv.voided) revert InvoiceIsVoided();
        if (inv.amountPaid != 0) revert AlreadyPaid();
        inv.voided = true;
        emit InvoiceVoided(id, invNum);
    }

    // ----------------------------------------------------------------- admin

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        emit TreasuryChanged(treasury, _treasury);
        treasury = _treasury;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedSet(_paused);
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

    function getInvoice(string calldata invNum)
        external
        view
        returns (
            bool exists,
            bool voided,
            uint256 amountDue,
            uint256 amountPaid,
            uint256 remaining,
            uint64 createdAt,
            uint64 settledAt,
            address lastPayer
        )
    {
        Invoice storage inv = _invoices[keccak256(bytes(invNum))];
        exists = inv.exists;
        voided = inv.voided;
        amountDue = inv.amountDue;
        amountPaid = inv.amountPaid;
        remaining = inv.exists ? amountDue - amountPaid : 0;
        createdAt = inv.createdAt;
        settledAt = inv.settledAt;
        lastPayer = inv.lastPayer;
    }

    function invoiceCount() external view returns (uint256) {
        return _ids.length;
    }

    /// @notice Enumerate for the DSM backfill job. Returns the human INVNum.
    function invoiceAt(uint256 i)
        external
        view
        returns (string memory invNum, uint256 amountDue, uint256 amountPaid, bool settled, bool voided)
    {
        bytes32 id = _ids[i];
        Invoice storage inv = _invoices[id];
        return (_numbers[id], inv.amountDue, inv.amountPaid, inv.settledAt != 0, inv.voided);
    }

    /// @dev No receive()/fallback on purpose. Money sent without an invoice
    ///      number has no receipt attached, so this contract refuses it.
}
