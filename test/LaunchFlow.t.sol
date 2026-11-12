// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ADVNToken} from "../src/ADVNToken.sol";

/// @notice Anyone who drives the PoolManager through `unlock`: adds or removes liquidity and swaps,
///         paying from its own balances and taking to itself, exactly as the launch factory and a
///         trader's router do.
abstract contract V4Actor is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function modify(PoolKey calldata key, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        external
        returns (BalanceDelta)
    {
        return abi.decode(
            manager.unlock(abi.encode(uint8(0), abi.encode(key, tickLower, tickUpper, liquidityDelta))), (BalanceDelta)
        );
    }

    function swap(PoolKey calldata key, bool zeroForOne, int256 amountSpecified) external returns (BalanceDelta) {
        return
            abi.decode(
                manager.unlock(abi.encode(uint8(1), abi.encode(key, zeroForOne, amountSpecified))), (BalanceDelta)
            );
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        (uint8 kind, bytes memory inner) = abi.decode(data, (uint8, bytes));
        BalanceDelta delta;
        PoolKey memory key;
        if (kind == 0) {
            (PoolKey memory k, int24 tickLower, int24 tickUpper, int256 liquidityDelta) =
                abi.decode(inner, (PoolKey, int24, int24, int256));
            key = k;
            (delta,) = manager.modifyLiquidity(
                key, ModifyLiquidityParams(tickLower, tickUpper, liquidityDelta, bytes32(0)), ""
            );
        } else {
            (PoolKey memory k, bool zeroForOne, int256 amountSpecified) = abi.decode(inner, (PoolKey, bool, int256));
            key = k;
            uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            delta = manager.swap(key, SwapParams(zeroForOne, amountSpecified, limit), "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) internal {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                manager.sync(currency);
                require(IERC20(Currency.unwrap(currency)).transfer(address(manager), owed), "transfer failed");
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}

/// @notice The launch factory: deploys the token (so the supply is minted to it), records the
///         distributor, forwards tokens, and seeds the pool.
contract FactoryProbe is V4Actor {
    mapping(uint64 => address) public distributorOf;

    constructor(IPoolManager manager_) V4Actor(manager_) {}

    function deployToken(uint64 launchNumber) external returns (ADVNToken) {
        return new ADVNToken(address(this), address(manager), launchNumber);
    }

    function setDistributor(uint64 launchNumber, address distributor) external {
        distributorOf[launchNumber] = distributor;
    }

    function move(ADVNToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice An ordinary trader with its own router: nothing the token has reason to exempt.
contract TraderProbe is V4Actor {
    constructor(IPoolManager manager_) V4Actor(manager_) {}
}

/// @notice A trader whose router settles ADVN as ERC-6909 claims inside the PoolManager instead of
///         ERC-20: buys are credited with `mint`, sells are paid with `burn`, and claims can be moved
///         with the PoolManager's own `transfer` or redeemed as ERC-20 with `take`. None of these
///         calls the token, so none of them can be taxed by it.
contract ClaimTraderProbe is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function claimId(PoolKey memory key) public pure returns (uint256) {
        return uint256(uint160(Currency.unwrap(key.currency1)));
    }

    /// @dev Exact-input buy of ADVN with `ethIn`, credited as claims. Returns the gross output.
    function buyAsClaims(PoolKey calldata key, uint256 ethIn) external returns (uint256) {
        return abi.decode(manager.unlock(abi.encode(uint8(0), abi.encode(key, ethIn))), (uint256));
    }

    /// @dev Exact-input sell of `amount` ADVN paid from claims; the ETH is taken as native.
    function sellFromClaims(PoolKey calldata key, uint256 amount) external returns (uint256) {
        return abi.decode(manager.unlock(abi.encode(uint8(1), abi.encode(key, amount))), (uint256));
    }

    /// @dev Burn `amount` of claims and take the ERC-20 out of the PoolManager to `to`.
    function redeemClaims(PoolKey calldata key, address to, uint256 amount) external {
        manager.unlock(abi.encode(uint8(2), abi.encode(key, to, amount)));
    }

    /// @dev Move claims to another account without leaving the PoolManager.
    function moveClaims(PoolKey calldata key, address to, uint256 amount) external returns (bool) {
        return manager.transfer(to, claimId(key), amount);
    }

    /// @dev Wrap ERC-20 held here into claims: sync, transfer in (exempt), settle, mint.
    function wrapIntoClaims(PoolKey calldata key, uint256 amount) external {
        manager.unlock(abi.encode(uint8(3), abi.encode(key, amount)));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        (uint8 kind, bytes memory inner) = abi.decode(data, (uint8, bytes));
        if (kind == 0) {
            (PoolKey memory key, uint256 ethIn) = abi.decode(inner, (PoolKey, uint256));
            BalanceDelta delta = manager.swap(key, SwapParams(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1), "");
            manager.settle{value: uint256(uint128(-delta.amount0()))}();
            uint256 gross = uint256(uint128(delta.amount1()));
            manager.mint(address(this), claimId(key), gross);
            return abi.encode(gross);
        }
        if (kind == 1) {
            (PoolKey memory key, uint256 amount) = abi.decode(inner, (PoolKey, uint256));
            BalanceDelta delta = manager.swap(key, SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1), "");
            manager.burn(address(this), claimId(key), amount);
            uint256 ethOut = uint256(uint128(delta.amount0()));
            manager.take(key.currency0, address(this), ethOut);
            return abi.encode(ethOut);
        }
        if (kind == 2) {
            (PoolKey memory k, address to, uint256 redeemed) = abi.decode(inner, (PoolKey, address, uint256));
            manager.burn(address(this), claimId(k), redeemed);
            manager.take(k.currency1, to, redeemed);
            return "";
        }
        (PoolKey memory wk, uint256 wrapped) = abi.decode(inner, (PoolKey, uint256));
        manager.sync(wk.currency1);
        require(IERC20(Currency.unwrap(wk.currency1)).transfer(address(manager), wrapped), "transfer failed");
        manager.settle();
        manager.mint(address(this), claimId(wk), wrapped);
        return "";
    }
}

/// @notice The launch flows against a real Uniswap v4 PoolManager paired with native ETH: the swarm
///         share and claims move whole, the seed takes exactly what it says, a trader buys (taxed on
///         the way out of the pool) and sells everything back (untaxed into the pool).
contract LaunchFlowTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint64 constant LAUNCH_NUMBER = 3;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 constant TICK_LOWER = -887_220;
    int24 constant TICK_UPPER = -60;
    uint128 constant SEED_LIQUIDITY = 1e26;
    address constant DISTRIBUTOR = address(0xD157);
    address constant CLAIMANT = address(0xC1A1);
    address constant JENSEN = 0xc59b0c072f73ceEA3Dc354031165501c0Ff25023;

    PoolManager manager;
    FactoryProbe factory;
    ADVNToken token;
    TraderProbe trader;
    PoolKey key;

    function setUp() public {
        manager = new PoolManager(address(this));
        factory = new FactoryProbe(manager);
        token = factory.deployToken(LAUNCH_NUMBER);
        factory.setDistributor(LAUNCH_NUMBER, DISTRIBUTOR);
        trader = new TraderProbe(manager);
        vm.deal(address(trader), 100 ether);

        // Native ETH is always currency0 (address zero sorts first).
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12_500, 60, IHooks(address(0)));
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function _seed() internal returns (uint256 taken) {
        uint256 before = token.balanceOf(address(factory));
        BalanceDelta delta = factory.modify(key, TICK_LOWER, TICK_UPPER, int256(uint256(SEED_LIQUIDITY)));
        taken = before - token.balanceOf(address(factory));
        assertEq(delta.amount0(), 0, "a single-sided seed takes no ETH");
        assertEq(taken, uint256(uint128(-delta.amount1())), "the seed took exactly what the pool asked for");
    }

    function test_swarmShareAndClaimsMoveWhole() public {
        uint256 swarm = SUPPLY / 10;
        assertTrue(factory.move(token, DISTRIBUTOR, swarm));
        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm));
        assertEq(token.balanceOf(CLAIMANT), swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_seedTakesExactlyWhatItSays() public {
        uint256 taken = _seed();
        assertGt(taken, 0);
        assertLe(taken, SUPPLY * 88 / 100, "within the requester's pool share");
        assertEq(token.balanceOf(address(manager)), taken, "the pool holds exactly the seed");
        assertEq(token.totalSupply(), SUPPLY, "seeding burned nothing");
        assertEq(token.balanceOf(JENSEN), 0, "seeding paid no fee");
    }

    function test_buyIsTaxedOnTheWayOutAndSellIsExactOnTheWayIn() public {
        _seed();
        uint256 supplyBefore = token.totalSupply();

        // Buy: 1 ETH in, exact input, zeroForOne.
        BalanceDelta buy = trader.swap(key, true, -1 ether);
        assertEq(buy.amount0(), -1 ether, "the trader paid 1 ETH");
        uint256 gross = uint256(uint128(buy.amount1()));
        assertGt(gross, 0, "the pool paid out tokens");
        (uint256 fee, uint256 burned, uint256 received) = token.previewTransfer(gross);
        assertEq(token.balanceOf(address(trader)), received, "the trader received 98.5% of the swap output");
        assertEq(token.balanceOf(JENSEN), fee, "Jensen received 0.5% of the swap output");
        assertEq(token.totalSupply(), supplyBefore - burned, "1% of the swap output was burned");
        assertGt(fee, 0);
        assertGt(burned, 0);

        // Sell everything back: exact input of the whole balance, oneForZero.
        uint256 ethBefore = address(trader).balance;
        BalanceDelta sell = trader.swap(key, false, -int256(received));
        assertEq(uint256(uint128(-sell.amount1())), received, "the pool took exactly what was sold");
        assertEq(token.balanceOf(address(trader)), 0, "the trader could sell its whole balance");
        assertGt(address(trader).balance, ethBefore, "the trader got ETH back");
        assertEq(token.balanceOf(JENSEN), fee, "selling into the pool paid no fee");
        assertEq(token.totalSupply(), supplyBefore - burned, "selling into the pool burned nothing");
    }

    function test_liquidityWithdrawalIsTaxedOnTheWayOut() public {
        uint256 taken = _seed();
        uint256 factoryBefore = token.balanceOf(address(factory));
        BalanceDelta delta = factory.modify(key, TICK_LOWER, TICK_UPPER, -int256(uint256(SEED_LIQUIDITY)));
        uint256 gross = uint256(uint128(delta.amount1()));
        assertLe(gross, taken);
        (uint256 fee, uint256 burned, uint256 received) = token.previewTransfer(gross);
        assertEq(token.balanceOf(address(factory)) - factoryBefore, received, "tokens leaving the pool are taxed");
        assertEq(token.balanceOf(JENSEN), fee);
        assertEq(token.totalSupply(), SUPPLY - burned);
    }

    function test_buyThenSellSeveralTimesNeverReverts() public {
        _seed();
        for (uint256 i; i < 5; ++i) {
            trader.swap(key, true, -0.1 ether);
            uint256 held = token.balanceOf(address(trader));
            assertGt(held, 0);
            trader.swap(key, false, -int256(held));
            assertEq(token.balanceOf(address(trader)), 0);
        }
        assertLt(token.totalSupply(), SUPPLY, "buys burned supply");
        assertGt(token.balanceOf(JENSEN), 0, "buys paid Jensen");
    }

    // ------------------------------------------------------------ ERC-6909 claims (documented limit)

    /// @dev Records the limit the README states: a buy settled as claims pays no fee and burns
    ///      nothing, because nothing calls the token. The tax is only deferred for anyone who wants
    ///      ERC-20 tokens: redeeming the claims with `take` is a transfer out of the PoolManager.
    function test_buySettledAsClaimsIsUntaxedUntilRedeemedAsErc20() public {
        _seed();
        ClaimTraderProbe claimer = new ClaimTraderProbe(manager);
        vm.deal(address(claimer), 10 ether);
        uint256 supplyBefore = token.totalSupply();
        uint256 poolBefore = token.balanceOf(address(manager));

        uint256 gross = claimer.buyAsClaims(key, 1 ether);
        assertGt(gross, 0);
        assertEq(manager.balanceOf(address(claimer), claimer.claimId(key)), gross, "the whole output is claims");
        assertEq(token.balanceOf(address(claimer)), 0, "no ERC-20 moved");
        assertEq(token.balanceOf(address(manager)), poolBefore, "the PoolManager still holds the tokens");
        assertEq(token.balanceOf(JENSEN), 0, "a claim-settled buy pays no fee");
        assertEq(token.totalSupply(), supplyBefore, "a claim-settled buy burns nothing");

        // Redeeming the claims as ERC-20 is a transfer out of the PoolManager and is taxed.
        claimer.redeemClaims(key, address(claimer), gross);
        (uint256 fee, uint256 burned, uint256 received) = token.previewTransfer(gross);
        assertEq(manager.balanceOf(address(claimer), claimer.claimId(key)), 0);
        assertEq(token.balanceOf(address(claimer)), received, "the redeemed tokens are taxed on the way out");
        assertEq(token.balanceOf(JENSEN), fee);
        assertEq(token.totalSupply(), supplyBefore - burned);
    }

    /// @dev A full round trip settled as claims never touches the token: untaxed in both directions.
    function test_claimRoundTripIsUntaxed() public {
        _seed();
        ClaimTraderProbe claimer = new ClaimTraderProbe(manager);
        vm.deal(address(claimer), 10 ether);
        uint256 supplyBefore = token.totalSupply();
        uint256 gross = claimer.buyAsClaims(key, 1 ether);
        uint256 ethOut = claimer.sellFromClaims(key, gross);
        assertGt(ethOut, 0);
        assertEq(manager.balanceOf(address(claimer), claimer.claimId(key)), 0);
        assertEq(token.balanceOf(JENSEN), 0, "nothing in the round trip called the token");
        assertEq(token.totalSupply(), supplyBefore);
    }

    /// @dev Claims move between accounts through the PoolManager's own ERC-6909 `transfer`, untaxed;
    ///      the recipient pays the tax when it redeems them as ERC-20.
    function test_claimToClaimMoveIsUntaxedAndRedemptionIsTaxed() public {
        _seed();
        ClaimTraderProbe claimer = new ClaimTraderProbe(manager);
        ClaimTraderProbe bob = new ClaimTraderProbe(manager);
        vm.deal(address(claimer), 10 ether);
        uint256 supplyBefore = token.totalSupply();
        uint256 gross = claimer.buyAsClaims(key, 1 ether);

        assertTrue(claimer.moveClaims(key, address(bob), gross));
        assertEq(manager.balanceOf(address(bob), claimer.claimId(key)), gross, "bob holds the full amount as claims");
        assertEq(token.balanceOf(JENSEN), 0, "a claim-to-claim move pays no fee");
        assertEq(token.totalSupply(), supplyBefore);

        bob.redeemClaims(key, address(bob), gross);
        (uint256 fee, uint256 burned, uint256 received) = token.previewTransfer(gross);
        assertEq(token.balanceOf(address(bob)), received);
        assertEq(token.balanceOf(JENSEN), fee);
        assertEq(token.totalSupply(), supplyBefore - burned);
    }

    /// @dev ERC-20 holdings can be wrapped into claims untaxed (the transfer into the PoolManager is
    ///      exempt by the floor) and unwrapped taxed, so wrapping is never a way to keep tokens
    ///      ERC-20-usable without paying.
    function test_wrappingErc20IntoClaimsIsUntaxedAndUnwrappingIsTaxed() public {
        _seed();
        ClaimTraderProbe claimer = new ClaimTraderProbe(manager);
        uint256 amount = 1_000e18;
        assertTrue(factory.move(token, address(claimer), amount));
        uint256 supplyBefore = token.totalSupply();

        claimer.wrapIntoClaims(key, amount);
        assertEq(manager.balanceOf(address(claimer), claimer.claimId(key)), amount, "wrapped whole");
        assertEq(token.balanceOf(address(claimer)), 0);
        assertEq(token.balanceOf(JENSEN), 0);
        assertEq(token.totalSupply(), supplyBefore);

        claimer.redeemClaims(key, address(claimer), amount);
        (uint256 fee, uint256 burned, uint256 received) = token.previewTransfer(amount);
        assertEq(token.balanceOf(address(claimer)), received, "unwrapping is taxed");
        assertEq(token.balanceOf(JENSEN), fee);
        assertEq(token.totalSupply(), supplyBefore - burned);
    }

    function testFuzz_anyBuySizeSettlesAndTaxes(uint256 ethIn) public {
        ethIn = bound(ethIn, 1 gwei, 50 ether);
        _seed();
        uint256 supplyBefore = token.totalSupply();
        BalanceDelta buy = trader.swap(key, true, -int256(ethIn));
        uint256 gross = uint256(uint128(buy.amount1()));
        (uint256 fee, uint256 burned, uint256 received) = token.previewTransfer(gross);
        assertEq(token.balanceOf(address(trader)), received);
        assertEq(token.balanceOf(JENSEN), fee);
        assertEq(token.totalSupply(), supplyBefore - burned);
        trader.swap(key, false, -int256(received));
        assertEq(token.balanceOf(address(trader)), 0);
    }
}
