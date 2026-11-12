# AIDIVN (ADVN)

A fixed-supply ERC-20 with a trade tax, built for an IMD custom token launch on Ethereum
(chain id 1), paired with native ETH in a Uniswap v4 pool.

| | |
|---|---|
| Contract (Solidity name) | `ADVNToken` (`src/ADVNToken.sol`) |
| Name / symbol / decimals | `AIDIVN` / `ADVN` / 18 |
| Total supply | 1,000,000,000 ADVN = `1000000000000000000000000000` minor units, minted once to `msg.sender` (the launch factory) |
| Trade fee | 0.5% of every taxed transfer to `0xc59b0c072f73ceea3dc354031165501c0ff25023` (Jensen Huang) |
| Burn | 1% of every taxed transfer burned (`totalSupply` decreases) |
| Owner / admin | none: no mint, pause, blocklist, fee switch, upgrade or rescue function |

## Rules

Every transfer that is not one of the launch flows below pays the tax. The sender's balance drops
by the full amount; the recipient receives 98.5%, the fee recipient receives 0.5% and 1% is burned.
Both shares are computed in basis points and round down, so amounts under 100 minor units burn
nothing and amounts under 200 pay no fee. A `TradeTaxed(from, to, amount, fee, burned)` event is
emitted next to the usual `Transfer` events. The fee recipient pays the tax like anyone else when
it sends; the fee simply flows back to it.

Untaxed ("exempt") flows, which move exactly the amount they say:

| Flow | Why |
|---|---|
| The factory sends (`from == FACTORY`) | The swarm's share to the MerkleDistributor, the pool seed and the remainder to the requester must arrive whole. |
| The launch's MerkleDistributor sends (`from == factory.distributorOf(LAUNCH_NUMBER)`) | Contributor claims must arrive whole. The distributor is resolved on the factory at transfer time; until the factory records one, no address is exempt on this ground. |
| Anything sent into the PoolManager (`to == POOL_MANAGER`) | Uniswap v4 settlement checks that the PoolManager received exactly what the payer declared. A tax here would make every sell and every liquidity deposit revert with `CurrencyNotSettled`. |

Everything else is taxed. That includes tokens leaving the PoolManager (a buy from the launch
pool, or a liquidity withdrawal paid out with `take`) and wallet-to-wallet transfers through
`transfer` and `transferFrom`. `transferFrom` spends allowance on the full amount.

`isExempt(from, to)`, `distributor()` and `previewTransfer(amount)` are public views that expose
the rule, the resolved distributor and the split for an amount.

### Reading of the brief

The request says "a 0.5% transfered from every trade fee to Jensen Huang ... and a 1% burn of
supply from every fee". This build applies both to each taxed transfer amount: 0.5% to the named
address and 1% burned, 1.5% in total. A reading where the burn is 1% of the 0.5% fee (0.005% of
the amount, 200 times less deflation) seemed too small to be what was meant; if that was intended,
`BURN_BPS` is the single constant to change. **The requester should confirm the intended burn base
before release**: `BURN_BPS` is a constant, so it cannot be changed after deployment. "Trade" is
read as any transfer that is not a launch flow; see the limits below.

### Limits the launch imposes on "every trade"

The tax is an ERC-20 transfer tax: it runs only when this contract's `transfer` or `transferFrom`
is called. Precisely, it applies to **ERC-20 transfers leaving the PoolManager** (`take`) and to
**ordinary ERC-20 transfers** between any two parties other than the three launch flows. It does
not and cannot apply to anything that happens inside the Uniswap v4 PoolManager without calling
the token.

- **Sells into the v4 pool are not taxed.** v4 requires exact settlement, so the only way to tax a
  sell on-chain would be a Uniswap v4 hook, which this launch kind does not deploy. A buy that is
  paid out as ERC-20 is taxed because the PoolManager hands the trader the tokens with a plain
  `transfer`.
- **Trades settled as ERC-6909 claims are not taxed.** Uniswap v4 lets any router credit a positive
  ADVN delta with `PoolManager.mint` (claims) instead of `take`, pay a negative delta with
  `PoolManager.burn` instead of an ERC-20 transfer in, and move claims between accounts with the
  PoolManager's own `transfer(receiver, id, amount)`. None of these calls the token, so a buy
  credited as claims pays no fee and burns nothing, a buy/sell round trip done entirely in claims
  is untaxed, a claim-to-claim move is untaxed, and ERC-20 holdings can be wrapped into claims
  untaxed (the transfer into the PoolManager is exempt by the floor). The tax is only deferred for
  anyone who wants ERC-20 tokens: redeeming claims with `take` is a transfer out of the PoolManager
  and is taxed. Sophisticated flow (bots, aggregators, custom routers) can therefore trade the
  launch pool without paying the fee or burning; the tax reliably reaches users whose router takes
  ERC-20 out of the PoolManager and every ordinary wallet transfer. Charging pool trades regardless
  of how they settle needs a v4 hook (`afterSwap` taking the ADVN side), which is a separate hook
  launch and a requester decision, not a change to this token. `test/LaunchFlow.t.sol` pins each of
  these flows.
- **Buyers paid in ERC-20 receive 98.5% of the quoted output.** A quoter or router computes the swap
  output from the pool; the 1.5% is taken on the transfer out of the PoolManager. Routers that check
  a minimum output against the swap delta still pass; frontends should show the net amount.
- **Liquidity providers are taxed on withdrawal** (tokens leave the PoolManager as ERC-20), not on
  deposit.
- **Transfers through other venues** (a centralised exchange's hot wallet, an OTC transfer, a v2 or
  v3 pool) are ordinary ERC-20 transfers and are taxed in both directions, since nothing but the
  three launch flows is exempt.

## Interface

```solidity
constructor(address factory_, address poolManager_, uint64 launchNumber_); // mints 1e27 to msg.sender

address public constant FEE_RECIPIENT;   // 0xc59b0c072f73ceEA3Dc354031165501c0Ff25023
uint256 public constant FEE_BPS;         // 50
uint256 public constant BURN_BPS;        // 100
uint256 public constant BPS_DENOMINATOR; // 10_000
uint256 public constant INITIAL_SUPPLY;  // 1_000_000_000e18

address public immutable FACTORY;
address public immutable POOL_MANAGER;
uint64 public immutable LAUNCH_NUMBER;

function distributor() external view returns (address);
function isExempt(address from, address to) external view returns (bool);
function previewTransfer(uint256 amount) external pure returns (uint256 fee, uint256 burned, uint256 received);

event TradeTaxed(address indexed from, address indexed to, uint256 amount, uint256 fee, uint256 burned);
error ZeroAddress();
```

Plus the standard ERC-20 surface from OpenZeppelin 5.7 (`transfer`, `transferFrom`, `approve`,
`allowance`, `balanceOf`, `totalSupply`, `name`, `symbol`, `decimals`).

## Deployment parameters

The token is deployed by IMD's ProjectFactory through `launchCustom`; nobody runs a deploy script.
The manifest step (not this build) writes `launch.json` with:

| Constructor argument | Manifest value |
|---|---|
| `factory_` | `$factory` |
| `poolManager_` | `$poolManager` |
| `launchNumber_` | `$launchNumber` |

The constructor only stores these and mints; it calls no contract and needs no code at either
address, so it runs on an empty chain. Both addresses must be non-zero (`ZeroAddress()` otherwise).

Launch terms this token was built against (they come from the job and are not configurable here):
chain 1, paired currency native ETH, `pool.fee` 12500, `tickSpacing` 60,
`economics = {"poolBps":8800,"initialMarketCapWei":"10000000000000000000","remainderTo":"0xd3959c80d11b4d2841fda01de9a0d9b36c52217e"}`.
The factory takes the swarm's 10% to the MerkleDistributor, seeds 88% into the pool and sends the
remaining 2% to `remainderTo`, all untaxed.

## Assumptions

- The factory exposes `distributorOf(uint64) returns (address)` and returns the zero address until
  the launch's distributor exists. If the call fails, returns fewer than 32 bytes, or returns a
  32-byte word that is not a clean address (any of the top 96 bits set), the token treats the
  distributor as unknown and taxes normally; it never reverts a transfer for that. The word is
  decoded as `uint256` and range-checked rather than with `abi.decode(_, (address))`, which would
  revert on dirty upper bits.
- `previewTransfer(amount)` is defined for every `uint256`: it divides by 200 and 100 (the exact
  reciprocals of 50 and 100 basis points) instead of multiplying first, so it cannot overflow.
- The fee recipient address is taken from the brief as written. It is an externally owned address
  on Ethereum; no code is required there, and nothing here can change it after deployment.
- There are no other exempt parties: no treasury, team or marketing wallet, no router allow-list.
  Adding one would need a new deployment.

## Operational responsibilities

- **Nobody operates the token.** There is no owner, no setter and nothing to configure after
  launch. There is no "After launch" checklist.
- **The fee recipient** receives ADVN continuously as buys and transfers happen; it needs no action.
- **Integrators** (frontends, aggregators) should quote the net amount a buyer receives as
  `previewTransfer(quotedOutput).received` when the router takes ERC-20 out of the PoolManager, and
  should know that `transferFrom`-based deposits into contracts other than the PoolManager arrive
  1.5% short. A router that settles in ERC-6909 claims delivers the gross output as claims; the
  1.5% is taken when the claims are redeemed as ERC-20.
- **The requester** should be aware that `totalSupply()` falls over time and that fixed-supply
  assumptions elsewhere (airdrop maths, vesting contracts) must read the live balance; that the fee
  stream and the burn are not collected on pool trades settled as ERC-6909 claims (see the limits
  above), and that collecting them there needs a Uniswap v4 hook ordered as its own launch; and
  that the burn base (1% of the transferred amount) should be confirmed before release.

## Build and test (offline)

```sh
forge build --offline
forge test --offline
forge fmt --check
```

Pinned toolchain: Foundry 1.8 or later, `solc = "0.8.26"`, `evm_version = "cancun"`,
`bytecode_hash = "none"`, `cbor_metadata = false`, optimizer on with 200 runs, no `ffi`, no
filesystem permissions. Dependencies are vendored under `lib/` as plain files: forge-std,
OpenZeppelin Contracts 5.7 (ERC20 and its interfaces only), Uniswap v4-core `src/` and solmate's
`Owned.sol` (the last two only for the PoolManager used in tests).

### Tests

| File | What it checks |
|---|---|
| `test/ADVNToken.t.sol` | Metadata, supply, constructor guards, the exempt flows, taxed `transfer`/`transferFrom`, rounding at dust amounts, zero transfers, failure paths (insufficient balance and allowance, zero receiver, no admin entry points, the factory cannot pull a holder's balance), factory lookup robustness (no code, reverting, short answer, a 32-byte word that is not an address), `previewTransfer` at `type(uint256).max`, fuzz: value conservation, exact exempt flows, bounded tax, preview equals the basis-point formula over the whole `uint256` range. |
| `test/ADVNToken.invariant.t.sol` | Random transfers and transferFroms between the factory, PoolManager, distributor, fee recipient and wallets against an independent ledger: every balance matches, balances sum to the supply, the supply never grows and only burns shrink it. |
| `test/LaunchFlow.t.sol` | Against a real Uniswap v4 `PoolManager` paired with ETH: the swarm share and a claim move whole, a single-sided seed takes exactly what the pool asks, a trader buys (taxed on the way out) and sells its whole balance back (exact on the way in), repeated round trips never revert, liquidity withdrawal is taxed, and a fuzzed buy size always settles. ERC-6909 claims, as documented above: a buy credited as claims pays no fee and burns nothing until redeemed as ERC-20 (then taxed), a claim-only round trip is untaxed, a claim-to-claim move is untaxed and the recipient's redemption is taxed, wrapping ERC-20 into claims is untaxed and unwrapping is taxed. |

## Deploy (operator only)

No script. IMD's deployer launches the attested bytecode through the factory from `launch.json`.
This repository holds no keys and broadcasts nothing.
