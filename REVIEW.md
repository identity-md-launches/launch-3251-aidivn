# Review: ADVNToken

Scope: `src/ADVNToken.sol` against the brief (0.5% trade fee to a named address, 1% burn, 1e27
supply minted once to the deployer), the custom token launch floor
(`.imd/reads/protected/custom_token/*.t.sol`) and the eth-security checklist.

## Findings

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | Info | Sells into the Uniswap v4 pool cannot be taxed: v4 settlement (`sync`/`settle`) checks the PoolManager received exactly the declared amount, so a tax on `to == POOL_MANAGER` reverts every sell with `CurrencyNotSettled` and fails the floor's sell check. | Accepted by design. Transfers into the PoolManager are exempt; tokens leaving it (buys, LP withdrawals) are taxed. Documented in the README. The only way to tax sells is a v4 hook, which this launch kind does not deploy. |
| 2 | Info | The brief's wording ("a 1% burn of supply from every fee") is ambiguous. | Read as 1% of the transferred amount, the same base as the fee; the alternative (1% of the fee) is noted in the README with the one constant to change. |
| 3 | Low | Each taxed-path transfer makes one `staticcall` to the factory to resolve the distributor (about 3k gas). | Accepted: the distributor's address is not known at deployment and the factory is the source of truth. The call is a `staticcall`, result length is checked, and failure degrades to "no exemption", never to a revert. Tested with a factory that has no code, reverts, and returns a short word. |
| 4 | Low | `balanceOf(from) < value` is re-checked before the split so a sender short by the fee gets `ERC20InsufficientBalance(from, balance, value)` rather than a confusing error from the second `_update`. | Fixed in the implementation; covered by `test_transferMoreThanBalanceReverts` and the fuzz test. |
| 5 | Info | Rounding: fee and burn each round down, so transfers under 200 minor units pay less than 1.5% and under 100 pay nothing. | Accepted; dust is economically irrelevant at 18 decimals and no path lets a large transfer avoid the tax by splitting profitably (gas dominates). Tested. |
| 6 | Medium | **Pool trades settled as ERC-6909 claims are untaxed** (independent review, revision 2). The tax lives in ERC-20 `_update`, and v4 lets any unlocker credit a buy with `PoolManager.mint` (claims) instead of `take`, pay a sell with `PoolManager.burn`, and move claims with the PoolManager's own `transfer`. None of these calls the token. A buy as claims pays 0 fee and burns 0; a claim-only round trip is untaxed; ERC-20 can be wrapped into claims untaxed because transfers into the PoolManager are exempt (item 1, required by the floor's whole-balance sell). The fee stream and the burn are therefore optional for sophisticated flow. No holder funds are at risk. | Reproduced (`test_buySettledAsClaimsIsUntaxedUntilRedeemedAsErc20`, `test_claimRoundTripIsUntaxed`, `test_claimToClaimMoveIsUntaxedAndRedemptionIsTaxed`, `test_wrappingErc20IntoClaimsIsUntaxedAndUnwrappingIsTaxed`). **No token-only change can close it**: the token is never called, and the only token-side lever (taxing transfers into the PoolManager) breaks every sell and fails the floor. The README's "Limits", NatSpec and operational notes were wrong to say buys and other venues are reliably taxed; they now state the exact scope (ERC-20 transfers out of the PoolManager and ordinary ERC-20 transfers) and that claims-settled trades are untaxed until redeemed as ERC-20. Taxing all pool trades needs a v4 `afterSwap` hook, a separate hook launch the requester must decide on. |
| 7 | Low | `distributor()` decoded the factory's answer with `abi.decode(data, (address))`, which reverts on a 32-byte word with any of the top 96 bits set; `isExempt` runs it on every taxed-path transfer, so such a factory answer would have frozen ordinary transfers and buys. Not reachable with the real factory (a `mapping(uint64 => address)` getter) but a documented promise ("never reverts a transfer") the code did not keep. | Fixed: decoded as `uint256`, anything above `type(uint160).max` is "no distributor". `MalformedAnswerFactory` mock and `test_transfersWorkWhenTheFactoryAnswersANonAddressWord`. |
| 8 | Info | `previewTransfer` multiplied before dividing and so panicked (0x11) for amounts >= 2^256/100, although every result fits. Unreachable through `_update` (balance check first, supply 1e27); only off-chain callers could hit it. | Fixed: divides by the exact reciprocals (200 and 100), identical results for every amount where the old formula was defined and defined everywhere; `test_previewTransferIsDefinedForEveryAmount` and `testFuzz_previewTransferMatchesTheBasisPointFormula`. |

Item 6 is a stated-guarantee gap, not a loss of funds; items 7 and 8 are robustness fixes. The
burn-base ambiguity (item 2) is unchanged and flagged in the README for the requester to confirm.

## Checklist (eth-security)

- Reentrancy: the only external call is a `staticcall` to the factory before any state write; the
  callee cannot write state. No ETH is handled. OpenZeppelin's `_update` does the balance maths.
- Access control: no owner, no privileged function. `transferFrom` only spends the caller's
  allowance, so neither the factory nor anyone else can move a holder's balance
  (`test_factoryCannotMoveAHoldersBalance`, floor test `noPrivilegedHandMovesOrFreezesAHolder`).
- Supply: minted once in the constructor; no mint path exists (`test_noMintOrAdminEntryPoints`,
  invariant `supplyNeverGrowsAndShrinksOnlyByBurns`, floor test `noCommonAdminCallIncreasesSupply`).
- Arithmetic: Solidity 0.8 checked maths; `previewTransfer` divides by the exact reciprocals
  (`amount / 200`, `amount / 100`), so it is defined for every `uint256`.
- Constructor: stores three words and mints; no external call; works on an empty chain
  (`test_constructorDoesNotNeedCodeAtTheLaunchAddresses`).
- Bytecode: no `delegatecall`, `callcode` or `selfdestruct` in the token; no proxy; no library with
  external functions; `bytecode_hash = "none"`, `cbor_metadata = false`.
- Floor flows: factory sends whole, distributor sends whole, seed exact, buy succeeds, sell of the
  whole bought balance succeeds (`test/LaunchFlow.t.sol` against a real `PoolManager`).

## What was run

Revision 2 (after the independent review):

- `forge build --offline`: clean.
- `FOUNDRY_FUZZ_SEED=0x48d910aa1f88c5315161c01f22b8dbdd8a1acdb99cbeb81dff08930b725e6453 forge test --offline`
  (the verifier's seed): 50 tests pass (39 unit and fuzz, 10 v4 flow tests, 3 invariants over 64
  runs x 32 depth with `fail_on_revert`), and again with `--fuzz-seed 0x1234 --fuzz-runs 1000`.
- `forge fmt --check`: clean.
- Slither was not available on this machine for the revision; the changes touch no detector in the
  verifier's refusal list (no delegatecall, selfdestruct, upgrade path, storage pointer, shift or
  packed encoding).

Revision 1:

- `forge build --offline --sizes`: ADVNToken runtime 3,179 bytes, initcode 5,214 bytes.
- `forge test --offline`: 43 tests pass (36 unit and fuzz, 6 v4 flow tests, 3 invariants over 64
  runs x 32 depth with `fail_on_revert`).
- `FOUNDRY_FUZZ_SEED=0x48d910aa1f88c5315161c01f22b8dbdd8a1acdb99cbeb81dff08930b725e6453 forge test --offline`
  (the verifier's seed) and `forge test --offline --fuzz-seed 0x1234 --fuzz-runs 1000`: all pass.
- `forge fmt --check`: clean.
- `slither . --exclude-informational --exclude-optimization --exclude-low`: 0 results.
- The protected floor tests were read and each assertion mapped to a local test above; they are
  executed by the verifier's harness with the attested creation code.

## Open items for the launch

- The manifest step fills `constructorArgs` with `$factory`, `$poolManager`, `$launchNumber` and
  `totalSupply` `1000000000000000000000000000`, decimals 18, contract `ADVNToken`.
- An independent adversarial review is still required before release; tests are not an audit.
- Requester decisions before release: (a) whether the fee and burn must also reach pool trades
  settled as ERC-6909 claims, which needs a Uniswap v4 hook ordered as its own launch (item 6);
  (b) whether the burn base is 1% of the transferred amount, as built, or 1% of the fee (item 2).
