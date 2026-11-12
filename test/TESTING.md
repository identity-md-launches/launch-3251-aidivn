# Additional ADVN test coverage

The original metadata, supply, tax, launch-flow and transfer-ledger tests are retained.
The additions focus on authorization across transactions, failed-call atomicity,
integer boundaries, and external lookup behavior. No production code or dependency
changes are required.

## Discovery and property choices

The five discovery passes from the supplied Pashov reference were performed locally.
The Trail of Bits reference informed bounded input generation, explicit boundary
examples, and separating a wrong test assumption from an implementation failure.

| Pass | Property and source basis | Added coverage |
|---|---|---|
| Conservation | The constructor creates `1e27` units once (`src/ADVNToken.sol:57`); transfer splits may only remove the burn (`:92`). All balances must sum to supply. | Independent balance ledger, cumulative burns, fee/burn rounding bounds, full-supply transfer, repeated wallet round trips. |
| State transitions | `ERC20.approve` replaces an allowance; `transferFrom` spends gross value, preserves infinite allowances, and cannot partially commit a rejected call. | Separate approve/revoke/spend actions; all owner–spender allowances checked after every action; exact rejection reasons and rollback tests. |
| Round trips and rounding | Tax components round down (`src/ADVNToken.sol:83`). Wallet round trips cannot create value; the loss equals fees plus burns. | Zero, one, 99/100/101, 199/200/201 and 10,000 minor-unit examples; whole-supply example; splitting and 200-unit translation properties. |
| Adversarial inputs | Insufficient balances/allowances, zero recipients, account aliasing, and invalid lookup responses must not cause unauthorized value changes. | Gross-versus-net authorization, maximum integer transfer rejection, self-transfer and Jensen aliases, factory response lengths 0–31 and recovery after a reverting lookup. |
| Token-specific behavior | Burning reduces supply rather than crediting the zero address; approvals do not move balances; a holder can still transfer after arbitrary valid calls. | Zero-account invariant, complete allowance matrix, transfer events, and full-balance liveness after each invariant sequence. |

The fee oracle uses division by 200 and 100, independently of the token's public
constants and preview function. Exemption expectations come from the existing launch
rules: factory-origin and registered distributor-origin transfers, and transfers into
the PoolManager. Aliased addresses are accounted for additively, including transfers
from Jensen to Jensen. The generic “self-transfer changes nothing” property is not
applicable to this fee-and-burn token.

## Stateful campaign

`ADVNToken.allowances.invariant.t.sol` runs 256 sequences of depth 64. Its seven
actions approve, revoke, transfer, transfer an entire balance, spend an existing
allowance, attempt a deliberately invalid spend, and change the test factory's
distributor registration. Factory, manager, distributor, Jensen and three ordinary
holders all start funded. Finite and infinite initial approvals make useful spending
reachable immediately; spending actions never grant themselves a fresh approval.

Inputs are selected from the tracked actors and bounded against the independent
ledger. The amount generator explicitly includes zero, one, full balances, and dust.
Expected rejections are caught and their exact data checked; unexpected reverts or
successes fail. Rejected calls leave the model unchanged, so the invariants also check
that no balance, allowance, or supply change survived the failure. The deterministic
handler test checks that positive transfers, positive delegated spends, rejected
spends and registry transitions are reachable. The registry mutation is a capability
of the mock, not an assumed permission on the production factory.

The existing invariant suite remains in place. Each new stateless fuzz property runs
1,000 cases. Counts and depth are specified inline; `foundry.toml` is unchanged.

## Pool settlement failures

The additional tests in `LaunchFlow.t.sol` use the existing real v4 PoolManager.
Selling one minor unit more than the trader owns must revert and restore the ETH
already paid earlier in the settlement callback. Buying without ETH must also revert
without changing token balances or supply. Each test performs a valid swap afterward
to check that the failed unlock has not left the pool unusable. Each swap runs through
one helper call so its transient accounting stays inside one transaction.

## Findings and reproduction

The previous round reported two low-severity boundary findings. Both are now fixed in
`src/ADVNToken.sol`, so no open findings are filed in this revision:

- A noncanonical 32-byte distributor response used to make ABI decoding revert and
  freeze transfers that needed the lookup. `distributor()` now decodes a word and
  treats anything above `type(uint160).max` as "no distributor". Regressions:
  `testFuzz_dirtyDistributorWordNeverFreezesOrExemptsTransfers` sets random nonzero
  upper bits on the real distributor's address. It checks that transfers go through,
  that the distributor gets no exemption while the answer is malformed, and that a
  clean answer restores the exemption.
  `test_distributorWordBoundaryAndTrailingData` pins `2^160 - 1` versus `2^160` and
  checks that answers longer than one word are read by their first word.
- `previewTransfer(type(uint256).max / 100 + 1)` used to panic. It now divides by
  200 and 100. Regressions: `testFuzz_previewIsTotalAndFloorsOverWholeDomain` runs
  over every `uint256` and checks that each levy is the floor of its rate and that the
  parts add up to the input. `test_previewEdgeExamplesAboveFormerOverflowPoint` pins
  `max / 100`, `max / 100 + 1`, `max - 1` and `max`, including the remainders
  135 (mod 200) and 35 (mod 100) at `2^256 - 1`.

The implementation review (`REVIEW.md`, item 6) separately documents that pool
trades settled as Uniswap v4 ERC-6909 claims bypass the ERC-20 tax, and that the
burn base needs the requester's confirmation (item 2). This suite does not assert
either one as intended behaviour beyond what that review already reproduces.

## Check commands

Run `forge build --offline`, followed by:

```sh
FOUNDRY_FUZZ_SEED=0x48d910aa1f88c5315161c01f22b8dbdd8a1acdb99cbeb81dff08930b725e6453 forge test --offline
```

For a workspace restricted to test-path writes, set `FOUNDRY_OUT=test/scratch/out`
and `FOUNDRY_CACHE_PATH=test/scratch/cache` on those commands. These only relocate
generated artifacts; no test imports or reads them. All dependencies already reside
in the repository, so the suite needs no network, fork, FFI, or external configuration.
The supplied protected checks were read and used for scope; their separate deployment
harness was not imported into this project.
