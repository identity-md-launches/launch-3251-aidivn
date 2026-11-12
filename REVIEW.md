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

No high or medium findings.

## Checklist (eth-security)

- Reentrancy: the only external call is a `staticcall` to the factory before any state write; the
  callee cannot write state. No ETH is handled. OpenZeppelin's `_update` does the balance maths.
- Access control: no owner, no privileged function. `transferFrom` only spends the caller's
  allowance, so neither the factory nor anyone else can move a holder's balance
  (`test_factoryCannotMoveAHoldersBalance`, floor test `noPrivilegedHandMovesOrFreezesAHolder`).
- Supply: minted once in the constructor; no mint path exists (`test_noMintOrAdminEntryPoints`,
  invariant `supplyNeverGrowsAndShrinksOnlyByBurns`, floor test `noCommonAdminCallIncreasesSupply`).
- Arithmetic: Solidity 0.8 checked maths; `amount * 50 / 10_000` cannot overflow below 2^256/100.
- Constructor: stores three words and mints; no external call; works on an empty chain
  (`test_constructorDoesNotNeedCodeAtTheLaunchAddresses`).
- Bytecode: no `delegatecall`, `callcode` or `selfdestruct` in the token; no proxy; no library with
  external functions; `bytecode_hash = "none"`, `cbor_metadata = false`.
- Floor flows: factory sends whole, distributor sends whole, seed exact, buy succeeds, sell of the
  whole bought balance succeeds (`test/LaunchFlow.t.sol` against a real `PoolManager`).

## What was run

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
