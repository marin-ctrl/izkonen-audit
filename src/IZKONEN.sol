// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title IZKONEN (IZK)
 * @notice Immutable ERC-20 core token on Base (Ethereum L2).
 *
 * Design (approved in Phase 0 / whitepaper v3):
 *  - Immutable core: the token address never changes and the token logic is
 *    fixed forever. Emission policy lives in a SEPARATE, swappable Minter
 *    module that holds MINTER_ROLE (so governance can "rework after audit"
 *    without ever moving the token address).
 *  - Hard cap: total supply can never exceed MAX_SUPPLY (38.69 trillion).
 *  - Anti-whale: no single address may hold more than MAX_WALLET (3% of cap),
 *    with exemptions for infrastructure (treasury, DEX pools, minter, timelock)
 *    and a one-way switch to disable the limit later if governance decides.
 *  - Emergency Pausable (governance-controlled) instead of a price circuit breaker.
 *  - NO blacklist (deliberately excluded — not in the whitepaper, trust red-flag).
 *
 * All privileged roles are intended to be held by a TimelockController that is
 * in turn owned by a Safe multisig (2-of-3). No single EOA controls the token.
 */
contract IZKONEN is ERC20, ERC20Permit, ERC20Pausable, AccessControl {
    // ------------------------------------------------------------------
    // Roles
    // ------------------------------------------------------------------

    /// @notice Role allowed to mint new tokens. Held by the Minter module.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Role allowed to pause/unpause transfers in an emergency.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ------------------------------------------------------------------
    // Immutable economic constants
    // ------------------------------------------------------------------

    /// @notice Hard cap on total supply: 38,690,000,000,000 IZK (with 18 decimals).
    uint256 public constant MAX_SUPPLY = 38_690_000_000_000 * 1e18;

    /// @notice Max tokens a single non-exempt wallet may hold: 3% of MAX_SUPPLY.
    uint256 public constant MAX_WALLET = 1_160_700_000_000 * 1e18;

    // ------------------------------------------------------------------
    // Anti-whale state
    // ------------------------------------------------------------------

    /// @notice While true, the MAX_WALLET limit is enforced on non-exempt holders.
    bool public maxWalletEnabled = true;

    /// @notice Addresses exempt from the MAX_WALLET limit (treasury, pools, etc.).
    mapping(address account => bool exempt) public isMaxWalletExempt;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event MaxWalletExemptSet(address indexed account, bool exempt);
    event MaxWalletDisabled();

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error CapExceeded(uint256 attemptedSupply, uint256 cap);
    error MaxWalletExceeded(address account, uint256 balance, uint256 limit);
    error ZeroAddress();

    /**
     * @param admin    Governance address (intended: TimelockController). Receives
     *                 DEFAULT_ADMIN_ROLE and PAUSER_ROLE.
     * @param treasury Operating-fund address; exempted from the max-wallet limit.
     */
    constructor(address admin, address treasury)
        ERC20("IZKONEN", "IZK")
        ERC20Permit("IZKONEN")
    {
        if (admin == address(0) || treasury == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);

        // Infrastructure exemptions from the anti-whale limit.
        _setMaxWalletExempt(admin, true);
        _setMaxWalletExempt(treasury, true);
    }

    // ------------------------------------------------------------------
    // Minting (only the Minter module)
    // ------------------------------------------------------------------

    /**
     * @notice Mint `amount` tokens to `to`. Callable only by MINTER_ROLE.
     * @dev The hard cap is enforced here so it holds regardless of which Minter
     *      module is active now or in the future.
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        uint256 newSupply = totalSupply() + amount;
        if (newSupply > MAX_SUPPLY) revert CapExceeded(newSupply, MAX_SUPPLY);
        _mint(to, amount);
    }

    // ------------------------------------------------------------------
    // Emergency pause (governance)
    // ------------------------------------------------------------------

    /// @notice Pause all transfers, mints and burns. Emergency use only.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume normal operation.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ------------------------------------------------------------------
    // Anti-whale administration (governance)
    // ------------------------------------------------------------------

    /**
     * @notice Add or remove an address from the max-wallet exemption list.
     * @dev Used for DEX pools, the minter, the timelock, bridges, etc.
     */
    function setMaxWalletExempt(address account, bool exempt)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setMaxWalletExempt(account, exempt);
    }

    /**
     * @notice Permanently disable the max-wallet limit. One-way; cannot be re-enabled.
     * @dev Lets the token grow into a normal, unconstrained ERC-20 once the market
     *      is mature, without touching the token address.
     */
    function disableMaxWallet() external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxWalletEnabled = false;
        emit MaxWalletDisabled();
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _setMaxWalletExempt(address account, bool exempt) internal {
        isMaxWalletExempt[account] = exempt;
        emit MaxWalletExemptSet(account, exempt);
    }

    /**
     * @dev Single transfer hook. Combines ERC20 + ERC20Pausable behaviour and then
     *      enforces the anti-whale limit on the receiver (checked post-transfer).
     *      Mints (from == 0) and burns (to == 0) pass through the same hook; the
     *      max-wallet check is skipped when tokens leave circulation (to == 0).
     */
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable)
    {
        super._update(from, to, value);

        if (maxWalletEnabled && to != address(0) && !isMaxWalletExempt[to]) {
            uint256 bal = balanceOf(to);
            if (bal > MAX_WALLET) revert MaxWalletExceeded(to, bal, MAX_WALLET);
        }
    }
}
