// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
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

    function test_sellAboveBalanceRollsBackTheEarlierEtherPayout() public {
        _seed();
        trader.swap(key, true, -1 ether);
        uint256 held = token.balanceOf(address(trader));
        bytes32 beforeState = _launchBalances();
        // The callback takes currency0 (ETH) before paying currency1 (ADVN). A failure
        // paying the tokens must roll back that earlier ETH payment and every token balance.
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(trader), held, held + 1)
        );
        trader.swap(key, false, -int256(held + 1));
        assertEq(_launchBalances(), beforeState);
        // The failed unlock must not leave the pool unusable or its deltas unsettled.
        trader.swap(key, false, -int256(held));
        assertEq(token.balanceOf(address(trader)), 0);
    }

    function test_unfundedBuyRollsBackAndTheNextFundedBuySucceeds() public {
        _seed();
        vm.deal(address(trader), 0);
        bytes32 beforeState = _launchBalances();
        // The value-bearing settlement call fails because the trader has no ETH.
        vm.expectRevert();
        trader.swap(key, true, -1 ether);
        assertEq(_launchBalances(), beforeState);
        vm.deal(address(trader), 1 ether);
        trader.swap(key, true, -1 ether);
        assertGt(token.balanceOf(address(trader)), 0);
        assertEq(address(trader).balance, 0);
    }

    function _launchBalances() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                token.totalSupply(),
                token.balanceOf(address(manager)),
                token.balanceOf(address(factory)),
                token.balanceOf(address(trader)),
                token.balanceOf(JENSEN),
                token.balanceOf(DISTRIBUTOR),
                address(trader).balance,
                address(manager).balance
            )
        );
    }
}
