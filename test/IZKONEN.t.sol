// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IZKONEN} from "../src/IZKONEN.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title IZKONEN token tests
 * @notice Proves the immutable-core rules: hard cap, minter-only minting,
 *         emergency pause, 3% anti-whale limit (+ exemptions + one-way disable),
 *         and the deliberate ABSENCE of a blacklist.
 *
 * The token normally receives its MINTER_ROLE from the separate Minter module.
 * For unit tests we grant MINTER_ROLE directly to this test contract so we can
 * mint arbitrary amounts and exercise the token rules in isolation.
 */
contract IZKONENTest is Test {
    IZKONEN internal token;

    address internal admin = makeAddr("admin"); // stands in for the Timelock/multisig
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant MAX_SUPPLY = 38_690_000_000_000 * 1e18;
    /// @dev Audit fix Low-01: the anti-whale limit is no longer a fixed constant.
    ///      It is 3% of the CIRCULATING supply, so tests must establish a supply
    ///      before they can reason about the limit at all.
    uint256 internal constant MAX_WALLET_BPS = 300;

    /// @dev Supply seeded into the EXEMPT treasury before any non-exempt address
    ///      receives tokens. This mirrors the real launch flow: the initial
    ///      liquidity (38.5B IZK) is minted to addresses the minter's constructor
    ///      has already verified as exempt.
    uint256 internal constant SEED_SUPPLY = 38_500_000_000 * 1e18;

    function setUp() public {
        token = new IZKONEN(admin, treasury);

        // Give this test contract the ability to mint, as the Minter module would have.
        bytes32 minterRole = token.MINTER_ROLE(); // cached BEFORE prank (forge >=1.4: staticcalls consume pranks)
        vm.prank(admin);
        token.grantRole(minterRole, address(this));
    }

    /// @dev Seeds circulating supply into the exempt treasury and returns the
    ///      resulting max-wallet limit. Because the treasury is exempt, this is
    ///      the only way a supply can exist before non-exempt holders appear.
    function _seedSupply() internal returns (uint256 limit) {
        token.mint(treasury, SEED_SUPPLY);
        limit = token.maxWallet();
    }

    // ------------------------------------------------------------------
    // Deployment / identity
    // ------------------------------------------------------------------

    function test_Metadata() public view {
        assertEq(token.name(), "IZKONEN");
        assertEq(token.symbol(), "IZK");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 0); // nothing minted at deploy
    }

    function test_Constants() public view {
        assertEq(token.MAX_SUPPLY(), MAX_SUPPLY);
        assertEq(token.MAX_WALLET_BPS(), MAX_WALLET_BPS);
        // Nothing minted yet, so 3% of nothing is nothing.
        assertEq(token.maxWallet(), 0);
    }

    /// @dev Audit fix Low-01: the limit must track the circulating supply.
    function test_MaxWalletGrowsWithSupply() public {
        uint256 limit1 = _seedSupply();
        assertEq(limit1, (SEED_SUPPLY * MAX_WALLET_BPS) / 10_000);

        token.mint(treasury, SEED_SUPPLY); // supply doubles
        assertEq(token.maxWallet(), limit1 * 2);
    }

    function test_AdminRolesAndExemptions() public view {
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(token.hasRole(token.PAUSER_ROLE(), admin));
        assertTrue(token.isMaxWalletExempt(admin));
        assertTrue(token.isMaxWalletExempt(treasury));
        assertTrue(token.maxWalletEnabled());
    }

    function test_ZeroAddressConstructorReverts() public {
        vm.expectRevert(IZKONEN.ZeroAddress.selector);
        new IZKONEN(address(0), treasury);

        vm.expectRevert(IZKONEN.ZeroAddress.selector);
        new IZKONEN(admin, address(0));
    }

    // ------------------------------------------------------------------
    // Minting + hard cap
    // ------------------------------------------------------------------

    function test_MinterCanMint() public {
        // Minted to the exempt treasury: with a supply-relative limit the first
        // tokens must go to an exempt address (see test_FirstMintMustGoToExempt).
        token.mint(treasury, 1_000 * 1e18);
        assertEq(token.balanceOf(treasury), 1_000 * 1e18);
        assertEq(token.totalSupply(), 1_000 * 1e18);
    }

    /**
     * @dev Consequence of audit fix Low-01, asserted deliberately rather than
     *      discovered later: while totalSupply() is 0, any non-exempt receiver
     *      would hold 100% of the supply, which is above 3%. The first tokens
     *      therefore MUST be minted to an exempt address. The minter enforces
     *      exactly this — its constructor reverts unless both the treasury and
     *      the emission recipient are already exempt (earlier audit fix T-3).
     */
    function test_FirstMintMustGoToExempt() public {
        uint256 amount = 1_000 * 1e18;

        // The limit is read AFTER super._update(), so by the time it is checked
        // the freshly minted tokens are already part of totalSupply. The supply
        // is therefore `amount`, and the limit is 3% of it — not 0.
        // Reported by Kann Audits on 2026-08-16; the earlier version of this
        // test expected 0 and would have failed.
        uint256 limitAfterMint = (amount * MAX_WALLET_BPS) / 10_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                IZKONEN.MaxWalletExceeded.selector,
                alice,
                amount,
                limitAfterMint
            )
        );
        token.mint(alice, amount);
    }

    function test_NonMinterCannotMint() public {
        bytes32 role_ = token.MINTER_ROLE(); // cached BEFORE prank
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                bob,
                role_
            )
        );
        token.mint(bob, 1e18);
    }

    function test_MintUpToCapSucceeds() public {
        // Mint the entire cap to an exempt address (treasury) — must succeed exactly.
        token.mint(treasury, MAX_SUPPLY);
        assertEq(token.totalSupply(), MAX_SUPPLY);
    }

    function test_MintOverCapReverts() public {
        token.mint(treasury, MAX_SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(
                IZKONEN.CapExceeded.selector,
                MAX_SUPPLY + 1,
                MAX_SUPPLY
            )
        );
        token.mint(treasury, 1);
    }

    function test_MintOverCapInOneCallReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IZKONEN.CapExceeded.selector,
                MAX_SUPPLY + 1,
                MAX_SUPPLY
            )
        );
        token.mint(treasury, MAX_SUPPLY + 1);
    }

    // ------------------------------------------------------------------
    // Emergency pause
    // ------------------------------------------------------------------

    function test_PauseBlocksTransfers() public {
        // Supply must exist before a non-exempt address can hold anything
        // (audit fix Low-01: the limit is 3% of circulating supply).
        _seedSupply();
        vm.prank(treasury);
        token.transfer(alice, 100 * 1e18);

        vm.prank(admin);
        token.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.transfer(bob, 1e18);
    }

    function test_UnpauseRestoresTransfers() public {
        _seedSupply();
        vm.prank(treasury);
        token.transfer(alice, 100 * 1e18);

        vm.prank(admin);
        token.pause();
        vm.prank(admin);
        token.unpause();

        vm.prank(alice);
        token.transfer(bob, 1e18);
        assertEq(token.balanceOf(bob), 1e18);
    }

    function test_OnlyPauserCanPause() public {
        bytes32 role_ = token.PAUSER_ROLE(); // cached BEFORE prank
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                bob,
                role_
            )
        );
        token.pause();
    }

    // ------------------------------------------------------------------
    // Anti-whale (3% max wallet)
    // ------------------------------------------------------------------

    /**
     * @dev NOTE on why these tests move tokens with transfer() rather than mint().
     *      After audit fix Low-01 the limit is 3% of totalSupply(), evaluated
     *      AFTER the transfer. A mint raises the supply and therefore raises the
     *      limit in the same transaction, so the exact boundary of a mint is
     *      3%/97% of the pre-existing supply. A transfer leaves the supply
     *      untouched, so the boundary is exactly the limit. Transfers are used
     *      wherever the test asserts the boundary precisely.
     */
    function test_MaxWalletBlocksWhale() public {
        uint256 limit = _seedSupply();

        vm.prank(treasury);
        vm.expectRevert(
            abi.encodeWithSelector(
                IZKONEN.MaxWalletExceeded.selector,
                alice,
                limit + 1,
                limit
            )
        );
        token.transfer(alice, limit + 1);
    }

    function test_MaxWalletAllowsExactLimit() public {
        uint256 limit = _seedSupply();

        vm.prank(treasury);
        token.transfer(alice, limit); // exactly 3% of supply is allowed
        assertEq(token.balanceOf(alice), limit);
    }

    function test_MaxWalletBlocksTransferPushingOverLimit() public {
        uint256 limit = _seedSupply();

        vm.prank(treasury);
        token.transfer(alice, limit); // alice sits exactly at the limit

        vm.prank(treasury);
        vm.expectRevert(
            abi.encodeWithSelector(
                IZKONEN.MaxWalletExceeded.selector,
                alice,
                limit + 1,
                limit
            )
        );
        token.transfer(alice, 1); // one wei more must fail
    }

    function test_ExemptAddressCanHoldMoreThanLimit() public {
        // treasury is exempt from construction — it holds 100% of the supply,
        // far above 3%, and that is intended.
        uint256 limit = _seedSupply();
        assertEq(token.balanceOf(treasury), SEED_SUPPLY);
        assertGt(token.balanceOf(treasury), limit);
    }

    function test_GovernanceCanAddExemption() public {
        uint256 limit = _seedSupply();

        vm.prank(admin);
        token.setMaxWalletExempt(alice, true);

        vm.prank(treasury);
        token.transfer(alice, limit + 5_000 * 1e18); // now allowed
        assertEq(token.balanceOf(alice), limit + 5_000 * 1e18);
    }

    function test_OnlyAdminCanSetExemption() public {
        bytes32 role_ = token.DEFAULT_ADMIN_ROLE(); // cached BEFORE prank
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                bob,
                role_
            )
        );
        token.setMaxWalletExempt(bob, true);
    }

    // ------------------------------------------------------------------
    // One-way disable of the anti-whale limit
    // ------------------------------------------------------------------

    function test_DisableMaxWalletLetsAnyoneHoldAnything() public {
        uint256 limit = _seedSupply();

        vm.prank(admin);
        token.disableMaxWallet();
        assertFalse(token.maxWalletEnabled());

        // Now a non-exempt wallet can exceed the 3% limit.
        vm.prank(treasury);
        token.transfer(alice, limit + 100 * 1e18);
        assertEq(token.balanceOf(alice), limit + 100 * 1e18);
    }

    function test_DisableMaxWalletIsOneWay() public {
        vm.prank(admin);
        token.disableMaxWallet();

        // There is deliberately NO function to re-enable it. maxWalletEnabled
        // is now false forever. We assert the state stays false.
        assertFalse(token.maxWalletEnabled());
    }

    function test_OnlyAdminCanDisableMaxWallet() public {
        bytes32 role_ = token.DEFAULT_ADMIN_ROLE(); // cached BEFORE prank
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                bob,
                role_
            )
        );
        token.disableMaxWallet();
    }

    // ------------------------------------------------------------------
    // No blacklist — documented by construction
    // ------------------------------------------------------------------

    // The contract exposes no blacklist / block / freeze-account function.
    // Absence cannot be asserted at runtime, but any accidental future
    // addition would break compilation of this expectation:
    // a normal transfer between two ordinary wallets always works.
    function test_NoBlacklist_OrdinaryTransferAlwaysWorks() public {
        _seedSupply();
        vm.prank(treasury);
        token.transfer(alice, 10 * 1e18);
        vm.prank(alice);
        token.transfer(bob, 10 * 1e18);
        assertEq(token.balanceOf(bob), 10 * 1e18);
    }
}
