// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IZKONEN} from "../src/IZKONEN.sol";
import {IZKONENMinter} from "../src/IZKONENMinter.sol";

/**
 * @title IZKONENMinter tests
 * @notice Proves the emission module: Fibonacci schedule, timestamp gating,
 *         0.1% mint fee split, exact-to-cap total, no early/double minting,
 *         and that a replacement minter resumes the schedule.
 */
contract IZKONENMinterTest is Test {
    IZKONEN internal token;
    IZKONENMinter internal minter;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal market = makeAddr("market"); // emissionRecipient (liquidity)

    uint256 internal constant MAX_SUPPLY = 38_690_000_000_000 * 1e18;
    uint256 internal constant TOTAL_YEARS = 23;
    uint256 internal constant MINT_INTERVAL = 365 days;
    uint256 internal startTime;

    function setUp() public {
        token = new IZKONEN(admin, treasury);
        startTime = block.timestamp;

        // Audit fix T-3 (L-1): the minter constructor now REQUIRES both mint
        // recipients to already be exempt from MAX_WALLET. The treasury is
        // exempted by the token constructor; the market/liquidity wallet must
        // be exempted BEFORE the minter is deployed (real deployment order).
        vm.prank(admin);
        token.setMaxWalletExempt(market, true);

        minter = new IZKONENMinter(
            address(token),
            admin,
            treasury,
            market,
            startTime,
            0 // first minter, nothing minted yet
        );

        // Wire the minter into the token.
        vm.startPrank(admin);
        token.grantRole(token.MINTER_ROLE(), address(minter));
        token.setMaxWalletExempt(address(minter), true);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // First tranche + fee split
    // ------------------------------------------------------------------

    function test_FirstWindowOpenImmediately() public view {
        assertTrue(minter.isMintDue());
        assertEq(minter.nextWindowOpensAt(), startTime);
        assertEq(minter.yearsMinted(), 0);
    }

    function test_FirstMintSplitsFee() public {
        uint256 gross = minter.tranches(0);
        uint256 fee = (gross * 10) / 10_000; // 0.1%
        uint256 net = gross - fee;

        minter.mint();

        assertEq(token.balanceOf(treasury), fee);
        assertEq(token.balanceOf(market), net);
        assertEq(token.totalSupply(), gross);
        assertEq(minter.yearsMinted(), 1);
    }

    function test_FeeIsExactlyTenBps() public {
        minter.mint();
        uint256 gross = minter.tranches(0);
        // fee/gross == 0.1% => fee*1000 == gross exactly (10bps).
        assertEq(token.balanceOf(treasury) * 1000, gross);
    }

    // ------------------------------------------------------------------
    // Timestamp gating
    // ------------------------------------------------------------------

    function test_SecondMintBeforeWindowReverts() public {
        minter.mint(); // year 0

        // Window 1 opens at startTime + 1*interval; we are still before it.
        vm.expectRevert(
            abi.encodeWithSelector(
                IZKONENMinter.WindowNotOpen.selector,
                1,
                startTime + MINT_INTERVAL
            )
        );
        minter.mint();
    }

    function test_CannotMintTwiceInSameWindow() public {
        minter.mint();
        vm.expectRevert(
            abi.encodeWithSelector(
                IZKONENMinter.WindowNotOpen.selector,
                1,
                startTime + MINT_INTERVAL
            )
        );
        minter.mint();
    }

    function test_MintDueAfterWarp() public {
        minter.mint(); // year 0
        assertFalse(minter.isMintDue());

        vm.warp(startTime + MINT_INTERVAL);
        assertTrue(minter.isMintDue());
        minter.mint(); // year 1
        assertEq(minter.yearsMinted(), 2);
    }

    function test_Permissionless_AnyoneCanCall() public {
        address randomCaller = makeAddr("random");
        vm.prank(randomCaller);
        minter.mint();
        assertEq(minter.yearsMinted(), 1); // succeeded from a random EOA
    }

    // ------------------------------------------------------------------
    // Full schedule → exact cap
    // ------------------------------------------------------------------

    function test_FullScheduleHitsExactCap() public {
        // Initial liquidity + all 23 tranches must land on exactly MAX_SUPPLY.
        vm.prank(admin);
        minter.mintInitialLiquidity();
        for (uint256 i = 0; i < TOTAL_YEARS; i++) {
            vm.warp(startTime + i * MINT_INTERVAL);
            minter.mint();
        }
        assertEq(minter.yearsMinted(), TOTAL_YEARS);
        assertEq(token.totalSupply(), MAX_SUPPLY); // exact, to the wei
    }

    function test_ScheduleWithoutInitialLiquidityIsBelowCap() public {
        for (uint256 i = 0; i < TOTAL_YEARS; i++) {
            vm.warp(startTime + i * MINT_INTERVAL);
            minter.mint();
        }
        // Without the initial-liquidity mint, the schedule alone is exactly
        // INITIAL_LIQUIDITY short of the cap.
        assertEq(token.totalSupply(), MAX_SUPPLY - minter.INITIAL_LIQUIDITY());
    }

    function test_MintAfterAllTranchesReverts() public {
        for (uint256 i = 0; i < TOTAL_YEARS; i++) {
            vm.warp(startTime + i * MINT_INTERVAL);
            minter.mint();
        }
        vm.warp(startTime + TOTAL_YEARS * MINT_INTERVAL);
        vm.expectRevert(IZKONENMinter.AllTranchesMinted.selector);
        minter.mint();
    }

    function test_SumOfTranchesEqualsCap() public view {
        // The 23 tranches alone are INITIAL_LIQUIDITY short of the cap (the
        // 2048 tranche was reduced by exactly that amount). Tranches PLUS the
        // one-time initial liquidity land on exactly MAX_SUPPLY.
        uint256 sum;
        for (uint256 i = 0; i < TOTAL_YEARS; i++) {
            sum += minter.tranches(i);
        }
        assertEq(sum + minter.INITIAL_LIQUIDITY(), MAX_SUPPLY);
    }

    function test_GoldenRatioLastTwoYears() public view {
        // Whitepaper claim: 61.8% of supply is emitted in the final 2 years.
        uint256 lastTwo = minter.tranches(21) + minter.tranches(22);
        // Assert it is between 61% and 62.5% of the cap.
        assertGe(lastTwo * 1000, MAX_SUPPLY * 610);
        assertLe(lastTwo * 1000, MAX_SUPPLY * 625);
    }

    // ------------------------------------------------------------------
    // Initial liquidity (one-time day-one mint, whitepaper §10.6a)
    // ------------------------------------------------------------------

    function test_InitialLiquiditySplitsFee() public {
        uint256 gross = minter.INITIAL_LIQUIDITY();
        uint256 fee = (gross * 10) / 10_000; // 0.1%
        uint256 net = gross - fee;

        vm.prank(admin);
        minter.mintInitialLiquidity();

        assertEq(token.balanceOf(treasury), fee);
        assertEq(token.balanceOf(market), net);
        assertEq(token.totalSupply(), gross);
        assertTrue(minter.initialLiquidityMinted());
    }

    function test_InitialLiquidityFeeIsExactlyTenBps() public {
        vm.prank(admin);
        minter.mintInitialLiquidity();
        uint256 gross = minter.INITIAL_LIQUIDITY();
        // fee/gross == 0.1% => fee*1000 == gross exactly (10bps).
        assertEq(token.balanceOf(treasury) * 1000, gross);
    }

    function test_InitialLiquidityCannotBeMintedTwice() public {
        vm.startPrank(admin);
        minter.mintInitialLiquidity();
        vm.expectRevert(IZKONENMinter.InitialLiquidityAlreadyMinted.selector);
        minter.mintInitialLiquidity();
        vm.stopPrank();
    }

    function test_OnlyAdminCanMintInitialLiquidity() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        minter.mintInitialLiquidity();
    }

    function test_InitialLiquidityDoesNotConsumeYearlyTranche() public {
        // Minting day-one liquidity must not advance the yearly schedule.
        vm.prank(admin);
        minter.mintInitialLiquidity();
        assertEq(minter.yearsMinted(), 0);
        assertTrue(minter.isMintDue()); // year-0 window still available
    }

    // ------------------------------------------------------------------
    // Governance setters
    // ------------------------------------------------------------------

    function test_SetTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        // T-3: the new treasury must be exempt from MAX_WALLET first.
        vm.prank(admin);
        token.setMaxWalletExempt(newTreasury, true);

        vm.prank(admin);
        minter.setTreasury(newTreasury);
        assertEq(minter.treasury(), newTreasury);
    }

    function test_OnlyAdminCanSetTreasury() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        minter.setTreasury(makeAddr("x"));
    }

    function test_SetTreasuryZeroReverts() public {
        vm.prank(admin);
        vm.expectRevert(IZKONENMinter.ZeroAddress.selector);
        minter.setTreasury(address(0));
    }

    function test_SetTreasuryNonExemptReverts() public {
        // Audit fix T-3 (L-1): a non-exempt treasury must be rejected, otherwise
        // a future fee mint could revert and stall the schedule.
        address nonExempt = makeAddr("nonExemptTreasury");
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IZKONENMinter.RecipientNotMaxWalletExempt.selector,
                nonExempt
            )
        );
        minter.setTreasury(nonExempt);
    }

    // ------------------------------------------------------------------
    // setEmissionRecipient (audit fix T-2)
    // ------------------------------------------------------------------

    function test_SetEmissionRecipientExemptSucceeds() public {
        address newMarket = makeAddr("newMarket");
        vm.prank(admin);
        token.setMaxWalletExempt(newMarket, true);

        vm.prank(admin);
        minter.setEmissionRecipient(newMarket);
        assertEq(minter.emissionRecipient(), newMarket);

        // The schedule keeps working: next mint pays the NEW recipient.
        minter.mint();
        uint256 gross = minter.tranches(0);
        uint256 fee = (gross * 10) / 10_000;
        assertEq(token.balanceOf(newMarket), gross - fee);
        assertEq(token.balanceOf(market), 0);
    }

    function test_SetEmissionRecipientNonExemptReverts() public {
        // Audit fix T-2: a non-exempt emission recipient would halt the
        // emission schedule forever — must be rejected.
        address nonExempt = makeAddr("nonExemptMarket");
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IZKONENMinter.RecipientNotMaxWalletExempt.selector,
                nonExempt
            )
        );
        minter.setEmissionRecipient(nonExempt);
    }

    function test_SetEmissionRecipientZeroReverts() public {
        vm.prank(admin);
        vm.expectRevert(IZKONENMinter.ZeroAddress.selector);
        minter.setEmissionRecipient(address(0));
    }

    function test_OnlyAdminCanSetEmissionRecipient() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        minter.setEmissionRecipient(makeAddr("x"));
    }

    // ------------------------------------------------------------------
    // Replacement minter resumes the schedule
    // ------------------------------------------------------------------

    function test_ReplacementMinterResumesSchedule() public {
        // Mint the first 3 years with the original minter.
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(startTime + i * MINT_INTERVAL);
            minter.mint();
        }
        assertEq(minter.yearsMinted(), 3);
        uint256 supplyAfter3 = token.totalSupply();

        // Governance retires the old minter and installs a replacement that
        // continues from year 3 with the ORIGINAL startTime.
        IZKONENMinter minter2 = new IZKONENMinter(
            address(token),
            admin,
            treasury,
            market,
            startTime,
            3 // three tranches already minted
        );
        vm.startPrank(admin);
        token.revokeRole(token.MINTER_ROLE(), address(minter));
        token.grantRole(token.MINTER_ROLE(), address(minter2));
        token.setMaxWalletExempt(address(minter2), true);
        vm.stopPrank();

        // Finish the remaining tranches (years 3..22) via the new minter.
        for (uint256 i = 3; i < TOTAL_YEARS; i++) {
            vm.warp(startTime + i * MINT_INTERVAL);
            minter2.mint();
        }

        // The 23 tranches alone are INITIAL_LIQUIDITY short of the cap; the
        // replacement minter can still mint it, landing exactly on MAX_SUPPLY.
        vm.prank(admin);
        minter2.mintInitialLiquidity();

        assertEq(minter2.yearsMinted(), TOTAL_YEARS);
        assertEq(token.totalSupply(), MAX_SUPPLY); // still exact
        assertGt(token.totalSupply(), supplyAfter3);
    }

    function test_ConstructorRejectsBadStartingIndex() public {
        vm.expectRevert(IZKONENMinter.BadStartingIndex.selector);
        new IZKONENMinter(
            address(token),
            admin,
            treasury,
            market,
            startTime,
            TOTAL_YEARS + 1
        );
    }

    function test_ConstructorRejectsZeroAddress() public {
        vm.expectRevert(IZKONENMinter.ZeroAddress.selector);
        new IZKONENMinter(address(0), admin, treasury, market, startTime, 0);
    }

    function test_ConstructorRejectsNonExemptEmissionRecipient() public {
        // Audit fix T-3 (L-1): deploying a minter whose emission recipient is
        // not exempt from MAX_WALLET must fail at construction time.
        address nonExempt = makeAddr("nonExemptMarket2");
        vm.expectRevert(
            abi.encodeWithSelector(
                IZKONENMinter.RecipientNotMaxWalletExempt.selector,
                nonExempt
            )
        );
        new IZKONENMinter(
            address(token),
            admin,
            treasury,
            nonExempt,
            startTime,
            0
        );
    }

    function test_ConstructorRejectsNonExemptTreasury() public {
        address nonExempt = makeAddr("nonExemptTreasury2");
        vm.expectRevert(
            abi.encodeWithSelector(
                IZKONENMinter.RecipientNotMaxWalletExempt.selector,
                nonExempt
            )
        );
        new IZKONENMinter(
            address(token),
            admin,
            nonExempt,
            market,
            startTime,
            0
        );
    }
}
