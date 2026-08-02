// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ERC4626} from "@openzeppelin/contracts@5.0.2/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts@5.0.2/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts@5.0.2/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts@5.0.2/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts@5.0.2/utils/math/Math.sol";

/**
 * MTYLD — Mechanical Temp Yield vault, Arc deployment
 *
 * An ERC-4626 vault denominated in USDC. Deposits represent a claim on
 * Mechanical Temp's HVAC revenue; NAV rises when revenue is reported in.
 *
 * ============================================================
 * WHY THE NAV GUARDS ARE HERE — READ BEFORE CHANGING ANYTHING
 * ============================================================
 *
 * Share price is totalAssets / totalSupply. If supply is ever allowed to
 * approach zero while assets remain — one full withdrawal leaving dust,
 * one stray token transfer — that division produces a nonsense price.
 * This has already happened once on a sibling vault, where price per share
 * ran to over a million dollars and the funds had to be pulled.
 *
 * Three independent guards prevent it, and removing any one of them
 * reopens the hole:
 *
 *   1. VIRTUAL SHARES (_decimalsOffset = 6)
 *      OpenZeppelin's 4626 computes against (totalAssets + 1) and
 *      (totalSupply + 10^offset). The denominator therefore has a floor
 *      of one million virtual shares even at zero real supply, so price
 *      per share is mathematically bounded. This also makes the classic
 *      donation/inflation attack cost more than it could ever return.
 *
 *   2. DEAD-SHARE SEED
 *      seed() runs once at launch and mints DEAD_SHARES to a burn
 *      address. Nobody can redeem them — not depositors, not the owner,
 *      not a future upgrade, because there is no upgrade path. Real
 *      supply therefore never returns to zero for the life of the vault.
 *
 *   3. EXPLICIT FLOOR
 *      _withdraw asserts supply stays at or above DEAD_SHARES. Guard 2
 *      already makes this true; it is asserted anyway so that anyone
 *      refactoring later trips a revert instead of silently reopening
 *      the bug.
 *
 * The vault refuses every deposit until seed() has run. An unseeded
 * vault is exactly the broken state we're preventing, so it isn't
 * allowed to accept money in that state.
 */
contract MTYLDArc is ERC4626, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------- NAV guards

    /// @dev Locked forever at seed(). Set at the NORMAL conversion rate, not
    ///      a fixed count — a fixed count would mint a dead position out of
    ///      proportion to the assets taken in and skew price per share from
    ///      block one. That mistake is the whole reason this vault exists.
    uint256 public deadShares;

    /// @dev Unredeemable by construction — no key exists for it.
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    /// @dev Virtual share offset. 6 is OpenZeppelin's recommended value.
    uint8 private constant OFFSET = 6;

    bool public seeded;

    // ------------------------------------------------------------- policy

    uint256 public depositCap;
    uint256 public minDeposit;
    address public treasury;

    // --------------------------------------------------------------- fees
    //
    // Mechanical Temp's cut. Entry fee is charged on the way in, exit fee on
    // the way out; both are taken in USDC and sent straight to treasury, so
    // they never sit in the vault pretending to be depositor assets.
    //
    // Hard-capped at MAX_FEE_BPS. The cap is a constant, not an owner
    // setting — an owner who can set a 100% exit fee owns everyone's money.

    uint16 public constant MAX_FEE_BPS = 300; // 3.00%
    uint16 public constant BPS = 10_000;

    uint16 public entryFeeBps;
    uint16 public exitFeeBps;

    // -------------------------------------------------------------- errors

    error NotSeeded();
    error AlreadySeeded();
    error CapExceeded(uint256 attempted, uint256 cap);
    error BelowMinimum(uint256 attempted, uint256 minimum);
    error FloorBreached();
    error ZeroAddress();
    error ZeroAmount();
    error FeeTooHigh(uint16 requested, uint16 max);

    // -------------------------------------------------------------- events

    event Seeded(uint256 assets, uint256 deadShares);
    event RevenueReported(address indexed from, uint256 amount, uint256 newTotalAssets);
    event DepositCapSet(uint256 cap);
    event MinDepositSet(uint256 min);
    event TreasuryChanged(address indexed from, address indexed to);
    event FeesSet(uint16 entryBps, uint16 exitBps);
    event FeeCollected(address indexed payer, uint256 amount, bool onExit);

    // --------------------------------------------------------- constructor

    constructor(
        IERC20 usdc,
        address treasury_,
        uint256 depositCap_,
        uint256 minDeposit_,
        uint16 entryFeeBps_,
        uint16 exitFeeBps_
    )
        ERC4626(usdc)
        ERC20("Mechanical Temp Yield", "MTYLD")
        Ownable(msg.sender)
    {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        depositCap = depositCap_;
        minDeposit = minDeposit_;
        emit TreasuryChanged(address(0), treasury_);
        emit DepositCapSet(depositCap_);
        emit MinDepositSet(minDeposit_);
        if (entryFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh(entryFeeBps_, MAX_FEE_BPS);
        if (exitFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh(exitFeeBps_, MAX_FEE_BPS);
        entryFeeBps = entryFeeBps_;
        exitFeeBps = exitFeeBps_;
        emit FeesSet(entryFeeBps_, exitFeeBps_);
    }

    // ------------------------------------------------------------ fee math
    // Standard OpenZeppelin fee-on-raw / fee-on-total split. On the way in
    // the quoted amount already includes the fee (fee on total); on the way
    // out the fee is added to what the user asked for (fee on raw).

    function _feeOnRaw(uint256 assets, uint16 bps) private pure returns (uint256) {
        return Math.mulDiv(assets, bps, BPS, Math.Rounding.Ceil);
    }

    function _feeOnTotal(uint256 assets, uint16 bps) private pure returns (uint256) {
        return Math.mulDiv(assets, bps, uint256(bps) + BPS, Math.Rounding.Ceil);
    }

    // ---------------------------------------------------------- fee quotes

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return super.previewDeposit(assets - _feeOnTotal(assets, entryFeeBps));
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        uint256 assets = super.previewMint(shares);
        return assets + _feeOnRaw(assets, entryFeeBps);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return super.previewWithdraw(assets + _feeOnRaw(assets, exitFeeBps));
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 assets = super.previewRedeem(shares);
        return assets - _feeOnTotal(assets, exitFeeBps);
    }

    /// @notice Guard 1. Never remove this override.
    function _decimalsOffset() internal pure override returns (uint8) {
        return OFFSET;
    }

    // ----------------------------------------------------------------- seed

    /**
     * @notice Guard 2. Lock the first shares forever so supply can never
     *         collapse toward zero. Must run before the vault opens.
     * @param assets USDC to seed with. Approve this contract first.
     */
    function seed(uint256 assets) external onlyOwner {
        if (seeded) revert AlreadySeeded();
        // A meaningful seed, not dust: at least one whole unit of the asset.
        uint256 floorAssets = 10 ** IERC20Metadata(asset()).decimals();
        if (assets < floorAssets) revert BelowMinimum(assets, floorAssets);

        // convertToShares, NOT previewDeposit — the seed must not pay the
        // entry fee, or the vault opens at a price above par and the whole
        // point of seeding at 1.00 is lost.
        uint256 shares = convertToShares(assets);
        if (shares == 0) revert ZeroAmount();

        seeded = true;
        deadShares = shares;
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        _mint(BURN, shares);

        emit Seeded(assets, shares);
    }

    // -------------------------------------------------------------- revenue

    /**
     * @notice Push HVAC revenue into the vault, raising NAV for holders.
     * @dev Deliberately a function rather than a bare transfer so every
     *      NAV increase leaves an event trail. Safe against donation
     *      attacks because guards 1 and 2 are already in force.
     */
    function reportRevenue(uint256 amount) external onlyOwner {
        if (!seeded) revert NotSeeded();
        if (amount == 0) revert ZeroAmount();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        emit RevenueReported(msg.sender, amount, totalAssets());
    }

    // --------------------------------------------------------------- limits

    function maxDeposit(address) public view override returns (uint256) {
        if (!seeded || paused()) return 0;
        uint256 held = totalAssets();
        if (depositCap == 0) return type(uint256).max;
        return held >= depositCap ? 0 : depositCap - held;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 d = maxDeposit(receiver);
        return d == type(uint256).max ? type(uint256).max : previewDeposit(d);
    }

    function maxWithdraw(address o) public view override returns (uint256) {
        return paused() ? 0 : super.maxWithdraw(o);
    }

    function maxRedeem(address o) public view override returns (uint256) {
        return paused() ? 0 : super.maxRedeem(o);
    }

    // ----------------------------------------------------------- overrides

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused {
        if (!seeded) revert NotSeeded();
        if (assets < minDeposit) revert BelowMinimum(assets, minDeposit);
        if (depositCap != 0) {
            uint256 after_ = totalAssets() + assets;
            if (after_ > depositCap) revert CapExceeded(after_, depositCap);
        }
        super._deposit(caller, receiver, assets, shares);

        uint256 fee = _feeOnTotal(assets, entryFeeBps);
        if (fee > 0) {
            IERC20(asset()).safeTransfer(treasury, fee);
            emit FeeCollected(caller, fee, false);
        }
    }

    /// @notice Guard 3. Belt and braces over guard 2.
    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused {
        super._withdraw(caller, receiver, owner_, assets, shares);

        uint256 fee = _feeOnRaw(assets, exitFeeBps);
        if (fee > 0) {
            IERC20(asset()).safeTransfer(treasury, fee);
            emit FeeCollected(owner_, fee, true);
        }

        if (totalSupply() < deadShares) revert FloorBreached();
    }

    // ----------------------------------------------------------------- admin

    function setDepositCap(uint256 cap) external onlyOwner {
        depositCap = cap;
        emit DepositCapSet(cap);
    }

    function setMinDeposit(uint256 min) external onlyOwner {
        minDeposit = min;
        emit MinDepositSet(min);
    }

    function setFees(uint16 entryBps, uint16 exitBps) external onlyOwner {
        if (entryBps > MAX_FEE_BPS) revert FeeTooHigh(entryBps, MAX_FEE_BPS);
        if (exitBps > MAX_FEE_BPS) revert FeeTooHigh(exitBps, MAX_FEE_BPS);
        entryFeeBps = entryBps;
        exitFeeBps = exitBps;
        emit FeesSet(entryBps, exitBps);
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        emit TreasuryChanged(treasury, t);
        treasury = t;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ----------------------------------------------------------------- views

    /// @notice Price of one whole share, in asset units. Reads sanely even
    ///         at zero real supply because of the virtual offset.
    function pricePerShare() external view returns (uint256) {
        return convertToAssets(10 ** decimals());
    }

    /// @notice Everything a NAV dashboard needs in one call.
    function navSnapshot()
        external
        view
        returns (
            uint256 assets,
            uint256 supply,
            uint256 pps,
            uint256 locked,
            uint256 cap,
            uint16 entryBps,
            uint16 exitBps,
            bool isSeeded,
            bool isPaused
        )
    {
        assets = totalAssets();
        supply = totalSupply();
        pps = convertToAssets(10 ** decimals());
        locked = deadShares;
        cap = depositCap;
        entryBps = entryFeeBps;
        exitBps = exitFeeBps;
        isSeeded = seeded;
        isPaused = paused();
    }
}
