// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ADVNToken} from "../src/ADVNToken.sol";
import {MockFactory} from "./mocks/MockFactory.sol";

/// @notice Drives random transfers and transferFroms between the launch's roles and ordinary wallets,
///         keeping an independent ledger of what every balance and the supply should be.
contract TransferHandler is Test {
    ADVNToken public immutable token;
    address public immutable factory;
    address public immutable poolManager;
    address public immutable distributor;
    address public immutable jensen;

    address[] public actors;
    mapping(address => uint256) public ghostBalance;
    uint256 public ghostBurned;
    uint256 public ghostFees;
    uint256 public taxedTransfers;
    uint256 public exemptTransfers;

    constructor(ADVNToken token_, address factory_, address poolManager_, address distributor_, address jensen_) {
        token = token_;
        factory = factory_;
        poolManager = poolManager_;
        distributor = distributor_;
        jensen = jensen_;
        actors.push(factory_);
        actors.push(poolManager_);
        actors.push(distributor_);
        actors.push(jensen_);
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        ghostBalance[factory_] = token_.totalSupply();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        require(token.transfer(to, amount), "transfer returned false");
        _record(from, to, amount);
    }

    function transferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.approve(spender, amount);
        vm.prank(spender);
        require(token.transferFrom(from, to, amount), "transferFrom returned false");
        _record(from, to, amount);
    }

    /// @dev The rule, written independently of the contract: the factory and the distributor send
    ///      untaxed, anything into the pool manager is untaxed, everything else pays 0.5% + burns 1%.
    function _record(address from, address to, uint256 amount) internal {
        bool exempt = from == factory || from == distributor || to == poolManager;
        ghostBalance[from] -= amount;
        if (exempt) {
            ghostBalance[to] += amount;
            exemptTransfers++;
            return;
        }
        uint256 fee = amount * 50 / 10_000;
        uint256 burned = amount * 100 / 10_000;
        ghostBalance[to] += amount - fee - burned;
        ghostBalance[jensen] += fee;
        ghostBurned += burned;
        ghostFees += fee;
        taxedTransfers++;
    }
}

contract ADVNTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint64 constant LAUNCH_NUMBER = 1;
    address constant POOL_MANAGER = address(0x900C);
    address constant DISTRIBUTOR = address(0xD157);
    address constant JENSEN = 0xc59b0c072f73ceEA3Dc354031165501c0Ff25023;

    MockFactory factory;
    ADVNToken token;
    TransferHandler handler;

    function setUp() public {
        factory = new MockFactory();
        token = factory.deployToken(POOL_MANAGER, LAUNCH_NUMBER);
        factory.setDistributor(LAUNCH_NUMBER, DISTRIBUTOR);
        handler = new TransferHandler(token, address(factory), POOL_MANAGER, DISTRIBUTOR, JENSEN);
        targetContract(address(handler));
    }

    function invariant_supplyNeverGrowsAndShrinksOnlyByBurns() public view {
        assertLe(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY - handler.ghostBurned());
    }

    function invariant_balancesMatchTheIndependentLedger() public view {
        uint256 count = handler.actorCount();
        uint256 sum;
        for (uint256 i; i < count; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.ghostBalance(actor), "balance drifted from the ledger");
            sum += token.balanceOf(actor);
        }
        assertEq(sum, token.totalSupply(), "balances do not add up to the supply");
    }

    function invariant_feesAndBurnsAccountForTheMissingSupply() public view {
        assertEq(SUPPLY - token.totalSupply(), handler.ghostBurned());
        // Per transfer burned = floor(a / 100) >= 2 * floor(a / 200) = 2 * fee, so it holds for the sums too.
        assertLe(handler.ghostFees() * 2, handler.ghostBurned());
    }
}
