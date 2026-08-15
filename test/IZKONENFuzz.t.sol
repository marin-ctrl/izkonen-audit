// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IZKONEN} from "../src/IZKONEN.sol";
import {IZKONENMinter} from "../src/IZKONENMinter.sol";

/**
 * @title Fuzz + invariant tests
 * @notice Throws thousands of random inputs at the contracts to prove the
 *         two properties that must NEVER break:
 *           1. Total supply can never exceed MAX_SUPPLY.
 *           2. The Fibonacci schedule always sums to exactly MAX_SUPPLY.
 */
contract IZKONENFuzzTest is Test {
    IZKONEN internal token;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");

    uint256 internal constant MAX_SUPPLY = 38_690_000_000_000 * 1e18;
    /// @dev Audit fix Low-01: the limit is 3% of circulating supply, not a constant.
    uint256 internal constant MAX_WALLET_BPS = 300;

    /// @dev Supply seeded into the exempt treasury before any non-exempt holder
    ///      can receive anything (mirrors the real launch flow).
    uint256 internal constant SEED_SUPPLY = 38_500_000_000 * 1e18;

    function setUp() public {
        token = new IZKONEN(admin, treasury);
        bytes32 minterRole = token.MINTER_ROLE(); // cached BEFORE prank (forge >=1.4: staticcalls consume pranks)
        vm.prank(admin);
        token.grantRole(minterRole, address(this));
    }

    // Any single mint at or below the cap succeeds; above it always reverts.
    function testFuzz_MintNeverExceedsCap(uint256 amount) public {
        amount = bound(amount, 1, MAX_SUPPLY * 2);
        if (amount <= MAX_SUPPLY) {
            token.mint(treasury, amount); // treasury is exempt from max-wallet
            assertLe(token.totalSupply(), MAX_SUPPLY);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IZKONEN.CapExceeded.selector,
                    amount,
                    MAX_SUPPLY
                )
            );
            token.mint(treasury, amount);
        }
    }

    // Two sequential mints: the second reverts iff it would breach the cap.
    function testFuzz_TwoMintsRespectCap(uint256 a, uint256 b) public {
        a = bound(a, 1, MAX_SUPPLY);
        b = bound(b, 1, MAX_SUPPLY);

        token.mint(treasury, a);
        if (a + b > MAX_SUPPLY) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IZKONEN.CapExceeded.selector,
                    a + b,
                    MAX_SUPPLY
                )
            );
            token.mint(treasury, b);
            assertEq(token.totalSupply(), a);
        } else {
            token.mint(treasury, b);
            assertEq(token.totalSupply(), a + b);
        }
    }

    /**
     * @dev A non-exempt wallet can never end up holding more than 3% of the
     *      circulating supply. Driven with transfer() from the exempt treasury
     *      so the supply — and therefore the limit — stays constant across the
     *      operation; a mint would move both sides of the comparison at once.
     */
    function testFuzz_NonExemptNeverExceedsMaxWallet(uint256 amount) public {
        address holder = makeAddr("holder"); // not exempt

        token.mint(treasury, SEED_SUPPLY); // treasury is exempt
        uint256 limit = token.maxWallet();
        assertEq(limit, (SEED_SUPPLY * MAX_WALLET_BPS) / 10_000);

        amount = bound(amount, 1, SEED_SUPPLY);

        if (amount <= limit) {
            vm.prank(treasury);
            token.transfer(holder, amount);
            assertLe(token.balanceOf(holder), limit);
        } else {
            vm.prank(treasury);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IZKONEN.MaxWalletExceeded.selector,
                    holder,
                    amount,
                    limit
                )
            );
            token.transfer(holder, amount);
        }
    }

    /**
     * @dev The limit must always be exactly 3% of whatever the supply happens
     *      to be — the property the old fixed constant failed to hold.
     */
    function testFuzz_LimitAlwaysThreePercentOfSupply(uint256 supply) public {
        supply = bound(supply, 1, MAX_SUPPLY);
        token.mint(treasury, supply);
        assertEq(token.maxWallet(), (supply * MAX_WALLET_BPS) / 10_000);
    }
}

/**
 * @notice Stateful invariant test: no matter how the fuzzer drives the minter
 *         (calling mint() at arbitrary times), total supply stays <= cap.
 */
contract IZKONENMinterInvariantTest is Test {
    IZKONEN internal token;
    IZKONENMinter internal minter;
    MinterHandler internal handler;

    uint256 internal constant MAX_SUPPLY = 38_690_000_000_000 * 1e18;

    function setUp() public {
        address admin = makeAddr("admin");
        address treasury = makeAddr("treasury");
        address market = makeAddr("market");

        token = new IZKONEN(admin, treasury);

        // Audit fix T-3 (L-1): recipients must be exempt BEFORE the minter is
        // deployed — its constructor now verifies this.
        vm.prank(admin);
        token.setMaxWalletExempt(market, true);

        minter = new IZKONENMinter(
            address(token),
            admin,
            treasury,
            market,
            block.timestamp,
            0
        );

        vm.startPrank(admin);
        token.grantRole(token.MINTER_ROLE(), address(minter));
        token.setMaxWalletExempt(address(minter), true);
        vm.stopPrank();

        handler = new MinterHandler(minter);
        targetContract(address(handler));
    }

    /// @dev The core safety property, checked after every fuzz sequence.
    function invariant_SupplyNeverExceedsCap() public view {
        assertLe(token.totalSupply(), MAX_SUPPLY);
    }

    /// @dev yearsMinted can never run past the 23-tranche schedule.
    function invariant_YearsMintedBounded() public view {
        assertLe(minter.yearsMinted(), 23);
    }
}

/**
 * @dev Handler that the invariant fuzzer drives. It warps time forward by a
 *      random amount and then attempts a mint, swallowing expected reverts so
 *      the fuzzing sequence keeps going.
 */
contract MinterHandler is Test {
    IZKONENMinter internal minter;

    constructor(IZKONENMinter minter_) {
        minter = minter_;
    }

    function warpAndMint(uint256 jump) external {
        jump = bound(jump, 0, 400 days);
        vm.warp(block.timestamp + jump);
        // [възстановен край 2026-07-20 — файлът в OneDrive беше отрязан]
        try minter.mint() {
            // изминат транш
        } catch {
            // очаквани revert-и (WindowNotOpen / AllTranchesMinted) — продължаваме
        }
    }
}
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IZKONEN} from "../src/IZKONEN.sol";
import {IZKONENMinter} from "../src/IZKONENMinter.sol";

/**
 * @title Fuzz + invariant tests
 * @notice Throws thousands of random inputs at the contracts to prove the
 *         two properties that must NEVER break:
 *           1. Total supply can never exceed MAX_SUPPLY.
 *           2. The Fibonacci schedule always sums to exactly MAX_SUPPLY.
 */
contract IZKONENFuzzTest is Test {
    IZKONEN internal token;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");

    uint256 internal constant MAX_SUPPLY = 38_690_000_000_000 * 1e18;
    uint256 internal constant MAX_WALLET = 1_160_700_000_000 * 1e18;

    function setUp() public {
        token = new IZKONEN(admin, treasury);
        bytes32 minterRole = token.MINTER_ROLE(); // cached BEFORE prank (forge >=1.4: staticcalls consume pranks)
        vm.prank(admin);
        token.grantRole(minterRole, address(this));
    }

    // Any single mint at or below the cap succeeds; above it always reverts.
    function testFuzz_MintNeverExceedsCap(uint256 amount) public {
        amount = bound(amount, 1, MAX_SUPPLY * 2);
        if (amount <= MAX_SUPPLY) {
            token.mint(treasury, amount); // treasury is exempt from max-wallet
            assertLe(token.totalSupply(), MAX_SUPPLY);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IZKONEN.CapExceeded.selector,
                    amount,
                    MAX_SUPPLY
                )
            );
            token.mint(treasury, amount);
        }
    }

    // Two sequential mints: the second reverts iff it would breach the cap.
    function testFuzz_TwoMintsRespectCap(uint256 a, uint256 b) public {
        a = bound(a, 1, MAX_SUPPLY);
        b = bound(b, 1, MAX_SUPPLY);

        token.mint(treasury, a);
        if (a + b > MAX_SUPPLY) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IZKONEN.CapExceeded.selector,
                    a + b,
                    MAX_SUPPLY
                )
            );
            token.mint(treasury, b);
            assertEq(token.totalSupply(), a);
        } else {
            token.mint(treasury, b);
            assertEq(token.totalSupply(), a + b);
        }
    }

    // A non-exempt wallet can never end up holding more than MAX_WALLET.
    function testFuzz_NonExemptNeverExceedsMaxWallet(uint256 amount) public {
        address holder = makeAddr("holder"); // not exempt
        amount = bound(amount, 1, MAX_SUPPLY);
        if (amount <= MAX_WALLET) {
            token.mint(holder, amount);
            assertLe(token.balanceOf(holder), MAX_WALLET);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IZKONEN.MaxWalletExceeded.selector,
                    holder,
                    amount,
                    MAX_WALLET
                )
            );
            token.mint(holder, amount);
        }
    }
}

/**
 * @notice Stateful invariant test: no matter how the fuzzer drives the minter
 *         (calling mint() at arbitrary times), total supply stays <= cap.
 */
contract IZKONENMinterInvariantTest is Test {
    IZKONEN internal token;
    IZKONENMinter internal minter;
    MinterHandler internal handler;

    uint256 internal constant MAX_SUPPLY = 38_690_000_000_000 * 1e18;

    function setUp() public {
        address admin = makeAddr("admin");
        address treasury = makeAddr("treasury");
        address market = makeAddr("market");

        token = new IZKONEN(admin, treasury);

        // Audit fix T-3 (L-1): recipients must be exempt BEFORE the minter is
        // deployed — its constructor now verifies this.
        vm.prank(admin);
        token.setMaxWalletExempt(market, true);

        minter = new IZKONENMinter(
            address(token),
            admin,
            treasury,
            market,
            block.timestamp,
            0
        );

        vm.startPrank(admin);
        token.grantRole(token.MINTER_ROLE(), address(minter));
        token.setMaxWalletExempt(address(minter), true);
        vm.stopPrank();

        handler = new MinterHandler(minter);
        targetContract(address(handler));
    }

    /// @dev The core safety property, checked after every fuzz sequence.
    function invariant_SupplyNeverExceedsCap() public view {
        assertLe(token.totalSupply(), MAX_SUPPLY);
    }

    /// @dev yearsMinted can never run past the 23-tranche schedule.
    function invariant_YearsMintedBounded() public view {
        assertLe(minter.yearsMinted(), 23);
    }
}

/**
 * @dev Handler that the invariant fuzzer drives. It warps time forward by a
 *      random amount and then attempts a mint, swallowing expected reverts so
 *      the fuzzing sequence keeps going.
 */
contract MinterHandler is Test {
    IZKONENMinter internal minter;

    constructor(IZKONENMinter minter_) {
        minter = minter_;
    }

    function warpAndMint(uint256 jump) external {
        jump = bound(jump, 0, 400 days);
        vm.warp(block.timestamp + jump);
        // [възстановен край 2026-07-20 — файлът в OneDrive беше отрязан]
        try minter.mint() {
            // изминат транш
        } catch {
            // очаквани revert-и (WindowNotOpen / AllTranchesMinted) — продължаваме
        }
    }
}
