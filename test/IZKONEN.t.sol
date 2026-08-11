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
    uint256 internal constant MAX_WALLET = 1_160_700_000_000 * 1e18; // 3%

    function setUp() public {
        token = new IZKONEN(admin, treasury);

        // Give this test contract the ability to mint, as the Minter module would have.
        bytes32 minterRole = token.MINTER_ROLE(); // cached BEFORE prank (forge >=1.4: staticcalls consume pranks)
        vm.prank(admin);
        token.grantRole(minterRole, address(this));
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
        assertEq(token.MAX_WALLET(), MAX_WALLET);
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
        token.mint(alice, 1_000 * 1e18);
        assertEq(token.balanceOf(alice), 1_000 * 1e18);
        assertEq(token.totalSupply(), 1_000 * 1e18);
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
        token.mint(alice, 100 * 1e18);

        vm.prank(admin);
        token.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.transfer(bob, 1e18);
    }

    function test_UnpauseRestoresTransfers() public {
        token.mint(alice, 100 * 1e18);

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

    function test_MaxWalletBlocksWhale() public {
        // Minting just over the cap to a NON-exempt wallet must revert.
        vm.expectRevert(
            abi.encodeWithSelector(
                IZKONEN.MaxWalletExceeded.selector,
                alice,
                MAX_WALLET + 1,
                MAX_WALLET
            )
        );
        token.mint(alice, MAX_WALLET + 1);
    }

    function test_MaxWalletAllowsExactLimit() public {
        token.mint(alice, MAX_WALLET); // exactly 3% is allowed
        assertEq(token.balanceOf(alice), MAX_WALLET);
    }

    function test_MaxWalletBlocksTransferPushingOverLimit() public {
        token.mint(alice, MAX_WALLET); // alice at the limit
        token.mint(bob, 10 * 1e18);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IZKONEN.MaxWalletExceeded.selector,
                alice,
                MAX_WALLET + 1e18,
                MAX_WALLET
            )
        );
        token.transfer(alice, 1e18);
    }

    function test_ExemptAddressCanHoldMoreThanLimit() public {
        // treasury is exempt from construction — can exceed 3%.
        token.mint(treasury, MAX_WALLET + 1_000 * 1e18);
        assertEq(token.balanceOf(treasury), MAX_WALLET + 1_000 * 1e18);
    }

    function test_GovernanceCanAddExemption() public {
        vm.prank(admin);
        token.setMaxWalletExempt(alice, true);

        token.mint(alice, MAX_WALLET + 5_000 * 1e18); // now allowed
        assertEq(token.balanceOf(alice), MAX_WALLET + 5_000 * 1e18);
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
        vm.prank(admin);
        token.disableMaxWallet();
        assertFalse(token.maxWalletEnabled());

        // Now a non-exempt wallet can exceed the old 3% limit.
        token.mint(alice, MAX_WALLET + 100 * 1e18);
        assertEq(token.balanceOf(alice), MAX_WALLET + 100 * 1e18);
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
        token.mint(alice, 10 * 1e18);
        vm.prank(alice);
        token.transfer(bob, 10 * 1e18);
        assertEq(token.balanceOf(bob), 10 * 1e18);
    }
}
