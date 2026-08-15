// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @dev Minimal interface to the immutable IZKONEN token.
interface IMintableIZK {
    function mint(address to, uint256 amount) external;
    function totalSupply() external view returns (uint256);
    /// @dev Whether `account` is exempt from the token's anti-whale MAX_WALLET limit.
    function isMaxWalletExempt(address account) external view returns (bool);
}

/**
 * @title IZKONENMinter
 * @notice Swappable emission module for the IZKONEN token.
 *
 * Holds MINTER_ROLE on the token and is the ONLY thing that can create new IZK.
 * Because it is separate from the immutable token, governance can retire it and
 * install a reworked module (e.g. after an audit) WITHOUT changing the token
 * address — by revoking MINTER_ROLE here and granting it to the replacement.
 *
 * Emission rules (Phase 0 / whitepaper v3):
 *  - A one-time initial liquidity mint at launch (whitepaper §10.6a) of
 *    38,500,000,000 IZK, carved out of the 2048 tranche.
 *  - 23 yearly tranches (2026..2048) following the Fibonacci sequence.
 *  - The final (2048) tranche is calibrated so that all tranches PLUS the
 *    initial liquidity land on exactly 38,690,000,000,000 IZK (== MAX_SUPPLY).
 *  - Permissionless, timestamp-gated: anyone may call mint() once each yearly
 *    window opens (no Chainlink / no external keeper dependency).
 *  - Fee-on-mint 0.1%: of each new tranche, 0.1% goes to the treasury and 99.9%
 *    to the emission recipient (market/liquidity). The fee only exists while
 *    minting; after 2048 there is no more minting, so the fee stops on its own.
 *
 * Changelog:
 *  - 2026-07-12 (audit fix T-2): setEmissionRecipient() now requires the new
 *    recipient to be exempt from the token's MAX_WALLET limit; otherwise the
 *    next mint() would revert and the emission schedule would halt forever.
 *  - 2026-07-12 (audit fix T-3 / finding L-1): the SAME exemption requirement is
 *    now enforced everywhere a mint recipient can be configured — in the
 *    constructor (treasury_ and emissionRecipient_) and in setTreasury().
 *    Invariant: every address that mint() / mintInitialLiquidity() can pay out
 *    to is provably exempt from MAX_WALLET at the moment it is configured.
 *    NOTE deployment order: exemptions must be set on the token BEFORE
 *    deploying/configuring the minter (token constructor already exempts the
 *    token-level treasury; the market/liquidity address must be exempted via
 *    setMaxWalletExempt() first).
 */
contract IZKONENMinter is AccessControl {
    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    /// @notice Number of yearly tranches.
    uint256 public constant TOTAL_YEARS = 23;

    /// @notice Time between successive tranche windows.
    uint256 public constant MINT_INTERVAL = 365 days;

    /// @notice Mint fee in basis points (10 bps = 0.1%).
    uint256 public constant FEE_BPS = 10;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice How far in the past `startTime_` may be set on a FIRST deployment.
    /// @dev Audit fix Informational-03 (Kann Audits, 2026-08-14): without a bound,
    ///      a mistyped or stale `startTime_` could open several tranche windows
    ///      immediately at deployment. The window is deliberately small but not
    ///      zero, so a deployment prepared and signed through the timelock a few
    ///      days earlier still succeeds.
    uint256 public constant START_TIME_GRACE_PERIOD = 7 days;

    /// @notice One-time day-one liquidity minted at launch (whitepaper §10.6a).
    ///         Carved out of the schedule: the 2048 tranche is reduced by this
    ///         same amount, so tranches + initial liquidity == MAX_SUPPLY exactly
    ///         and the hard cap stays the round 38,690,000,000,000 IZK.
    uint256 public constant INITIAL_LIQUIDITY = 38_500_000_000 * 1e18;

    // ------------------------------------------------------------------
    // Immutable configuration
    // ------------------------------------------------------------------

    /// @notice The IZKONEN token this module mints.
    IMintableIZK public immutable token;

    /// @notice Reference start of the emission schedule (tranche 0 opens at this time).
    uint256 public immutable startTime;

    // ------------------------------------------------------------------
    // Mutable configuration (governance)
    // ------------------------------------------------------------------

    /// @notice Receives the 0.1% mint fee.
    address public treasury;

    /// @notice Receives the remaining 99.9% of each tranche (market/liquidity).
    address public emissionRecipient;

    // ------------------------------------------------------------------
    // Schedule state
    // ------------------------------------------------------------------

    /// @notice The 23 tranche amounts (in wei, i.e. already scaled by 1e18).
    uint256[TOTAL_YEARS] public tranches;

    /// @notice How many tranches have been minted so far (0..23).
    uint256 public yearsMinted;

    /// @notice True once the one-time initial liquidity has been minted.
    bool public initialLiquidityMinted;

    // ------------------------------------------------------------------
    // Events / errors
    // ------------------------------------------------------------------

    event YearMinted(
        uint256 indexed yearIndex,
        uint256 grossAmount,
        uint256 feeToTreasury,
        uint256 netToMarket
    );
    event TreasuryUpdated(address indexed newTreasury);
    event EmissionRecipientUpdated(address indexed newRecipient);
    event InitialLiquidityMinted(
        uint256 grossAmount,
        uint256 feeToTreasury,
        uint256 netToMarket
    );

    error AllTranchesMinted();
    error WindowNotOpen(uint256 yearIndex, uint256 opensAt);
    error ZeroAddress();
    error BadStartingIndex();
    /// @dev Reverts when a FIRST deployment is given a `startTime_` in the future
    ///      or further than START_TIME_GRACE_PERIOD in the past (audit fix I-03).
    error BadStartTime(uint256 startTime, uint256 nowTimestamp);
    error InitialLiquidityAlreadyMinted();
    /// @dev Reverts if a configured mint recipient (emission recipient OR treasury,
    ///      in the constructor or in a setter) is not exempt from the token's
    ///      anti-whale MAX_WALLET limit (audit fixes T-2 and T-3/L-1). Without
    ///      exemption the recipient's balance could exceed MAX_WALLET and a future
    ///      mint() would revert, halting the emission schedule.
    error RecipientNotMaxWalletExempt(address recipient);

    /**
     * @param token_             Address of the deployed IZKONEN token.
     * @param admin_             Governance (TimelockController). Gets DEFAULT_ADMIN_ROLE.
     * @param treasury_          Fee recipient (0.1%).
     * @param emissionRecipient_ Market/liquidity recipient (99.9%).
     * @param startTime_         Reference start of the schedule. For the FIRST minter
     *                           pass block.timestamp; for a REPLACEMENT minter pass the
     *                           ORIGINAL start so the yearly windows stay aligned.
     * @param startingYearIndex_ How many tranches were already minted before this module
     *                           took over. 0 for the first minter.
     */
    constructor(
        address token_,
        address admin_,
        address treasury_,
        address emissionRecipient_,
        uint256 startTime_,
        uint256 startingYearIndex_
    ) {
        if (
            token_ == address(0) ||
            admin_ == address(0) ||
            treasury_ == address(0) ||
            emissionRecipient_ == address(0)
        ) revert ZeroAddress();
        if (startingYearIndex_ > TOTAL_YEARS) revert BadStartingIndex();

        // Audit fix I-03 (Kann Audits): bound `startTime_` on a FIRST deployment.
        // A replacement minter (startingYearIndex_ > 0) must keep the ORIGINAL
        // start so the yearly windows stay aligned, and that value is legitimately
        // far in the past — so the bound is applied only to the first minter.
        // The second half of the auditor's recommendation — deriving startTime_
        // from the retired minter on-chain instead of accepting it as input —
        // belongs to the replacement module, which does not exist yet; it is
        // recorded as a mandatory requirement in the migration runbook together
        // with findings Informational-02, -04 and -05.
        if (startingYearIndex_ == 0) {
            if (
                startTime_ > block.timestamp ||
                startTime_ + START_TIME_GRACE_PERIOD < block.timestamp
            ) revert BadStartTime(startTime_, block.timestamp);
        }

        // Audit fix T-3 (finding L-1): both mint recipients must already be
        // exempt from the token's MAX_WALLET limit, otherwise a future mint()
        // would revert and the emission schedule would halt. Same rule as the
        // T-2 check in setEmissionRecipient(), applied at construction time.
        if (!IMintableIZK(token_).isMaxWalletExempt(treasury_))
            revert RecipientNotMaxWalletExempt(treasury_);
        if (!IMintableIZK(token_).isMaxWalletExempt(emissionRecipient_))
            revert RecipientNotMaxWalletExempt(emissionRecipient_);

        token = IMintableIZK(token_);
        startTime = startTime_;
        treasury = treasury_;
        emissionRecipient = emissionRecipient_;
        yearsMinted = startingYearIndex_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        _initTranches();
    }

    // ------------------------------------------------------------------
    // Emission
    // ------------------------------------------------------------------

    /**
     * @notice Mint the next due yearly tranche. Permissionless: anyone may call
     *         once the window is open. Mints exactly one tranche per call.
     */
    function mint() external {
        uint256 idx = yearsMinted;
        if (idx >= TOTAL_YEARS) revert AllTranchesMinted();

        uint256 opensAt = startTime + idx * MINT_INTERVAL;
        if (block.timestamp < opensAt) revert WindowNotOpen(idx, opensAt);

        uint256 gross = tranches[idx];
        uint256 fee = (gross * FEE_BPS) / BPS_DENOMINATOR;
        uint256 net = gross - fee;

        // Effects before interactions.
        yearsMinted = idx + 1;

        if (fee > 0) token.mint(treasury, fee);
        token.mint(emissionRecipient, net);

        emit YearMinted(idx, gross, fee, net);
    }

    /**
     * @notice Mint the one-time day-one liquidity (whitepaper §10.6a). Callable
     *         once, by governance, right after launch/wiring. Same 0.1% fee split
     *         as the yearly tranches. This amount is carved out of the 2048
     *         tranche, so the running total still lands on exactly MAX_SUPPLY.
     */
    function mintInitialLiquidity() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (initialLiquidityMinted) revert InitialLiquidityAlreadyMinted();
        initialLiquidityMinted = true;

        uint256 gross = INITIAL_LIQUIDITY;
        uint256 fee = (gross * FEE_BPS) / BPS_DENOMINATOR;
        uint256 net = gross - fee;

        if (fee > 0) token.mint(treasury, fee);
        token.mint(emissionRecipient, net);

        emit InitialLiquidityMinted(gross, fee, net);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Timestamp when the next tranche window opens (0 if all minted).
    function nextWindowOpensAt() external view returns (uint256) {
        if (yearsMinted >= TOTAL_YEARS) return 0;
        return startTime + yearsMinted * MINT_INTERVAL;
    }

    /// @notice Whether a tranche can be minted right now.
    function isMintDue() external view returns (bool) {
        if (yearsMinted >= TOTAL_YEARS) return false;
        return block.timestamp >= startTime + yearsMinted * MINT_INTERVAL;
    }

    // ------------------------------------------------------------------
    // Governance
    // ------------------------------------------------------------------

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        // Audit fix T-3 (finding L-1): the treasury receives the 0.1% fee on every
        // mint. If it were not exempt from MAX_WALLET, a fee mint could revert and
        // stall the schedule. Same rule as setEmissionRecipient() (T-2).
        if (!token.isMaxWalletExempt(newTreasury)) revert RecipientNotMaxWalletExempt(newTreasury);
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function setEmissionRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRecipient == address(0)) revert ZeroAddress();
        // Audit fix T-2: the emission recipient receives 99.9% of every tranche and
        // its cumulative balance far exceeds MAX_WALLET (3%). If it is not exempt from
        // the anti-whale limit, the next mint() would revert and the schedule would
        // halt forever. Require the new recipient to already be exempt on the token.
        if (!token.isMaxWalletExempt(newRecipient)) revert RecipientNotMaxWalletExempt(newRecipient);
        emissionRecipient = newRecipient;
        emit EmissionRecipientUpdated(newRecipient);
    }

    // ------------------------------------------------------------------
    // Schedule data
    // ------------------------------------------------------------------

    /**
     * @dev Fibonacci tranche amounts in whole tokens, scaled by 1e18.
     *      Sum of all 23 tranches + INITIAL_LIQUIDITY == 38,690,000,000,000e18
     *      == token MAX_SUPPLY. 2026..2047 are the whitepaper values; 2048 is
     *      calibrated so that (schedule + initial liquidity) lands exactly on the
     *      round cap. The 2048 tranche was reduced by INITIAL_LIQUIDITY
     *      (38,500,000,000) vs. the pre-initial-liquidity schedule.
     */
    function _initTranches() internal {
        tranches[0]  = 515_701_642 * 1e18;        // 2026
        tranches[1]  = 515_701_642 * 1e18;        // 2027
        tranches[2]  = 1_031_403_284 * 1e18;      // 2028
        tranches[3]  = 1_547_104_926 * 1e18;      // 2029
        tranches[4]  = 2_578_508_211 * 1e18;      // 2030
        tranches[5]  = 4_125_613_137 * 1e18;      // 2031
        tranches[6]  = 6_704_121_348 * 1e18;      // 2032
        tranches[7]  = 10_829_734_485 * 1e18;     // 2033
        tranches[8]  = 17_533_855_833 * 1e18;     // 2034
        tranches[9]  = 28_363_590_318 * 1e18;     // 2035
        tranches[10] = 45_897_446_151 * 1e18;     // 2036
        tranches[11] = 74_261_036_468 * 1e18;     // 2037
        tranches[12] = 120_158_482_619 * 1e18;    // 2038
        tranches[13] = 194_419_519_087 * 1e18;    // 2039
        tranches[14] = 314_578_001_706 * 1e18;    // 2040
        tranches[15] = 508_997_520_793 * 1e18;    // 2041
        tranches[16] = 823_575_522_499 * 1e18;    // 2042
        tranches[17] = 1_332_573_043_293 * 1e18;  // 2043
        tranches[18] = 2_156_148_565_792 * 1e18;  // 2044
        tranches[19] = 3_488_721_609_085 * 1e18;  // 2045
        tranches[20] = 5_644_870_174_877 * 1e18;  // 2046
        tranches[21] = 9_133_591_783_962 * 1e18;  // 2047
        tranches[22] = 14_739_961_958_842 * 1e18; // 2048 (calibrated)
    }
}
