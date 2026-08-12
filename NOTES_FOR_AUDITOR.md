# IZKONEN — notes for the auditor

Prepared 11 August 2026 for Kann Audits.

## Scope

Two contracts, both in `src/`:

| File | Bytes | nSLOC (excl. blanks, comments, pragma, imports) |
|---|---|---|
| `IZKONEN.sol` | 7 318 | 58 |
| `IZKONENMinter.sol` | 14 061 | 133 |
| **Total** | **21 379** | **191** |

Non-blank non-comment lines: 198. Physical lines: 480.

**OpenZeppelin is out of scope.** Imports are OpenZeppelin Contracts 5.1.0, audited separately. A flattened Remix file exists elsewhere in our archive with OpenZeppelin inlined (678 lines) — it is NOT the subject of this review and should not be used as the basis for anything.

Compiler: solc 0.8.26. Toolchain: Foundry (forge 1.7.1).

## Build

```
forge build
forge test
```

Expected: clean build, **57/57 tests pass** — 22 token, 3 fuzz, 30 minter, 2 invariant.

`remappings.txt` and `foundry.toml` are included. Dependencies are `openzeppelin-contracts` and `forge-std` in `lib/`.

## What the contracts do

`IZKONEN.sol` — ERC-20 on OpenZeppelin 5.1.0, on Base. Hard cap, 3% max-wallet limit, ERC-2612 permit. All roles sit behind a Safe 2-of-3 under a TimelockController.

`IZKONENMinter.sol` — a separate, replaceable emission module. 23 annual tranches following a Fibonacci schedule through 2048, each opening on block timestamp and callable permissionlessly. One-off initial-liquidity mint. A 0.1% fee on newly minted tranches routes to the treasury.

**The area we care most about is the emission logic and its interaction with the max-wallet limit across the 23-year schedule.** Automated tools cannot judge that; it is the reason for this engagement.

## Already done in-house — not an audit

Slither 0.11.6 (102 detectors) and Mythril 0.24.8 were run on 8 August 2026.

Slither: 4 findings, all low. Two `reentrancy-events` (false positives — the external call is to the immutable own token, and state is written before it). Two `timestamp` (accepted by design — annual windows intentionally key off `block.timestamp` so no external keeper is needed; drift of seconds is irrelevant over 365 days).

Mythril: one medium SWC-123 on `mint()` (artifact of analysing bytecode in isolation without the real token) and two low SWC-116 `block.timestamp` (same as above; one is OpenZeppelin's ERC-2612 deadline check).

`slither-check-erc`: full ERC-20 compliance. The only note is the well-known approve race condition, which applies to every OpenZeppelin ERC20 and is handled at UI level.

Arithmetic checked separately: the 23 tranches plus initial liquidity sum **exactly** to MAX_SUPPLY (38 651 500 000 000 + 38 500 000 000 = 38 690 000 000 000, difference zero). MAX_WALLET is exactly 3.000% of MAX_SUPPLY. The 0.1% fee leaves no integer-division remainder on any of the 23 tranches.

None of this reduces the need for manual review. It is included only so you do not spend hours on what a tool already answered.

## Three observations we want you to look at explicitly

These are not vulnerabilities in the narrow sense. All three require a governance action, and governance goes through Safe 2-of-3 plus Timelock. We would still like your view on each.

### O-1 — the exemption check is only tested at configuration time

The T-2/T-3 fixes require the recipient to be exempt from MAX_WALLET at the moment it is configured. But the token allows the exemption to be revoked later via `setMaxWalletExempt(address, false)`. If that happens to `emissionRecipient` or `treasury`, the next `mint()` reverts and the schedule stalls.

Recoverable — restore the exemption and minting resumes — but it is an operational trap. Question: should the check be re-asserted at mint time rather than only at configuration?

### O-2 — the initial-liquidity flag is module-local, not global

`initialLiquidityMinted` lives in the minter. A replacement minter starts with `false`, so `mintInitialLiquidity()` could be called a second time and emit an additional 38.5 billion IZK. The token's hard cap would not be breached, but the final 2048 tranche would then revert with `CapExceeded`.

Question: should a replacement minter take the flag as a constructor parameter, or should the token itself hold this state?

### O-3 — three tranches deviate by one token from a strict Fibonacci series

2030 is one token above, 2037 and 2043 one token below the sum of the two preceding tranches. This almost certainly comes from rounding in the whitepaper figures and has no economic significance at a scale of billions.

Flagged for completeness: if the whitepaper claims a strict Fibonacci series, the wording needs reconciling with the code. This is a documents-versus-code consistency question, not a technical defect.

## Test file versions — please read

The test files here are the corrected versions of 21 July 2026 (57/57 passing on forge 1.7.1). Earlier copies exist in our archive; they fail on forge >= 1.4 because `vm.prank` is consumed by an internal staticcall in an argument position (for example `token.MINTER_ROLE()` inside `grantRole`). The fix caches the role in a local `bytes32` before the prank. **Only test files were touched. The contracts were not modified.**

Byte sizes of the correct test files, for verification: `IZKONEN.t.sol` 9 635, `IZKONENFuzz.t.sol` 5 581, `IZKONENMinter.t.sol` 14 935.

## Contact

Marin Yosifov — founder, IZKONEN — marin@izkonen.com
