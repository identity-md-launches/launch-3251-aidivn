// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {ADVNToken} from "src/ADVNToken.sol";
import {MockFactory} from "./mocks/MockFactory.sol";

/// @notice Unlike the original transfer handler, approvals and spending are separate actions.
/// Ghost allowances survive arbitrary intervening calls, including failed calls and revocations.
contract AllowanceSequenceHandler is Test {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000e18;
    uint64 public constant LAUNCH = 91;
    address public constant JENSEN = 0xc59b0c072f73ceEA3Dc354031165501c0Ff25023;

    ADVNToken public immutable token;
    MockFactory public immutable factory;
    address public immutable manager;
    address public immutable claimDistributor;
    address[] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public expectedBurned;
    uint256 public expectedFees;
    uint256 public taxedCalls;
    bool public distributorRegistered;

    uint256 public nonzeroTransfers;
    uint256 public nonzeroDelegatedTransfers;
    uint256 public rejectedTransfers;
    uint256 public approvals;
    uint256 public registryChanges;

    constructor(ADVNToken token_, MockFactory factory_, address manager_, address distributor_) {
        token = token_;
        factory = factory_;
        manager = manager_;
        claimDistributor = distributor_;
        actors.push(address(factory_));
        actors.push(manager_);
        actors.push(distributor_);
        actors.push(JENSEN);
        actors.push(makeAddr("sequence alice"));
        actors.push(makeAddr("sequence bob"));
        actors.push(makeAddr("sequence carol"));

        // Every role starts funded, so early sequences do not degenerate into zero transfers.
        expectedBalance[address(factory_)] = INITIAL_SUPPLY;
        for (uint256 i = 1; i < actors.length; ++i) {
            uint256 funding = INITIAL_SUPPLY / 16;
            assertTrue(factory_.move(token_, actors[i], funding));
            expectedBalance[address(factory_)] -= funding;
            expectedBalance[actors[i]] = funding;
        }
        // Seed both finite and infinite approvals; later spends never grant themselves approval.
        for (uint256 i; i < actors.length; ++i) {
            _approve(actors[i], actors[(i + 1) % actors.length], 1_000e18);
            _approve(actors[i], actors[i], type(uint256).max);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 rawAmount) external {
        address owner = _actor(ownerSeed);
        uint256 amount;
        uint256 mode = rawAmount % 4;
        if (mode == 0) amount = type(uint256).max;
        else if (mode == 1) amount = bound(rawAmount, 0, INITIAL_SUPPLY);
        else if (mode == 2) amount = expectedBalance[owner];
        else amount = rawAmount; // also exercise large finite allowances above the supply
        _approve(owner, _actor(spenderSeed), amount);
    }

    function revoke(uint256 ownerSeed, uint256 spenderSeed) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), 0);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = _actor(fromSeed);
        _transfer(from, _actor(toSeed), _amount(rawAmount, expectedBalance[from]));
    }

    function transferAll(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        _transfer(from, _actor(toSeed), expectedBalance[from]);
    }

    function transferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = _actor(fromSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = expectedAllowance[from][spender];
        uint256 available = expectedBalance[from] < allowed ? expectedBalance[from] : allowed;
        uint256 amount = _amount(rawAmount, available);
        uint256 supplyBefore = token.totalSupply();
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        if (allowed != type(uint256).max) expectedAllowance[from][spender] -= amount;
        _recordTransfer(from, to, amount);
        assertLe(token.totalSupply(), supplyBefore, "a transferFrom increased supply");
        if (amount > 0) nonzeroDelegatedTransfers++;
    }

    /// @dev Catch only a predicted failure. Unexpected success or a different revert is a failure
    /// of the handler, not a discarded fuzz call. The ledger stays unchanged on rejection.
    function rejectedTransferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = _actor(fromSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 balance = expectedBalance[from];
        uint256 allowed = expectedAllowance[from][spender];
        uint256 mode = rawAmount % 4;
        uint256 amount;
        if (mode == 0) {
            amount = allowed == type(uint256).max ? type(uint256).max : allowed + 1;
        } else if (mode == 1) {
            amount = balance + 1;
        } else if (mode == 2) {
            amount = type(uint256).max;
        } else {
            amount = _amount(rawAmount, balance < allowed ? balance : allowed);
            to = address(0);
        }
        bytes memory reason;
        if (allowed < amount) {
            reason = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount);
        } else if (to == address(0)) {
            reason = abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0));
        } else {
            reason = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount);
        }
        vm.prank(spender);
        (bool ok, bytes memory result) = address(token).call(abi.encodeCall(token.transferFrom, (from, to, amount)));
        assertFalse(ok, "invalid transferFrom succeeded");
        assertEq(result, reason, "unexpected failure reason");
        rejectedTransfers++;
    }

    /// @dev Exercise the runtime lookup before/after registration. This is a test factory action,
    /// not a claim that ordinary holders can change the production factory's registry.
    function registerDistributor(bool registered, uint256 otherLaunchActor) external {
        factory.setDistributor(LAUNCH, registered ? claimDistributor : address(0));
        factory.setDistributor(LAUNCH + 1, _actor(otherLaunchActor));
        distributorRegistered = registered;
        registryChanges++;
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
        approvals++;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 supplyBefore = token.totalSupply();
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _recordTransfer(from, to, amount);
        assertLe(token.totalSupply(), supplyBefore, "a transfer increased supply");
    }

    function _recordTransfer(address from, address to, uint256 amount) internal {
        // An independent integer-denominator oracle, including account aliasing. Neither
        // previewTransfer nor isExempt is used to determine the expected result.
        bool exempt = from == address(factory) || to == manager || (distributorRegistered && from == claimDistributor);
        uint256 fee = exempt ? 0 : amount / 200;
        uint256 burn = exempt ? 0 : amount / 100;
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount - fee - burn;
        expectedBalance[JENSEN] += fee;
        expectedBurned += burn;
        expectedFees += fee;
        if (!exempt) taxedCalls++;
        if (amount > 0) nonzeroTransfers++;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _amount(uint256 raw, uint256 available) internal pure returns (uint256) {
        uint256 mode = raw % 5;
        if (mode == 0) return 0;
        if (mode == 1) return available;
        if (mode == 2) return available == 0 ? 0 : 1;
        if (mode == 3) return bound(raw, 0, available < 201 ? available : 201);
        return bound(raw, 0, available);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
contract ADVNTokenAllowanceInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint64 internal constant LAUNCH = 91;
    MockFactory internal factory;
    ADVNToken internal token;
    AllowanceSequenceHandler internal handler;
    address internal manager = makeAddr("sequence manager");
    address internal distributor = makeAddr("sequence distributor");

    function setUp() public {
        factory = new MockFactory();
        token = factory.deployToken(manager, LAUNCH);
        handler = new AllowanceSequenceHandler(token, factory, manager, distributor);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.approve.selector;
        selectors[1] = handler.revoke.selector;
        selectors[2] = handler.transfer.selector;
        selectors[3] = handler.transferAll.selector;
        selectors[4] = handler.transferFrom.selector;
        selectors[5] = handler.rejectedTransferFrom.selector;
        selectors[6] = handler.registerDistributor.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_allBalancesAndSupplyMatchTheLedger() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            address account = handler.actors(i);
            uint256 balance = token.balanceOf(account);
            assertEq(balance, handler.expectedBalance(account), "balance changed without a modeled transfer");
            sum += balance;
        }
        assertEq(sum, token.totalSupply(), "sum of balances differs from supply");
        assertEq(token.totalSupply() + handler.expectedBurned(), SUPPLY, "supply changed beyond the burn");
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariant_allAllowancesMatchIndependentApprovalHistory() public view {
        uint256 count = handler.actorCount();
        for (uint256 i; i < count; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < count; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
            assertEq(token.allowance(owner, address(0)), 0);
            assertEq(token.allowance(address(0), owner), 0);
        }
    }

    function invariant_registryChangesOnlyAffectTheCurrentDistributor() public view {
        address expected = handler.distributorRegistered() ? distributor : address(0);
        assertEq(token.distributor(), expected);
        assertEq(token.FACTORY(), address(factory));
        assertEq(token.POOL_MANAGER(), manager);
        assertEq(token.LAUNCH_NUMBER(), LAUNCH);
    }

    function invariant_roundingErrorIsBoundedAcrossTheWholeSequence() public view {
        // floor(x/100) - 2*floor(x/200) is either zero or one for each taxable call.
        uint256 twiceFees = 2 * handler.expectedFees();
        uint256 burns = handler.expectedBurned();
        assertGe(burns, twiceFees);
        assertLe(burns - twiceFees, handler.taxedCalls());
    }

    /// @dev Every actor can still send their entire balance after an arbitrary call sequence.
    function afterInvariant() public {
        for (uint256 i; i < handler.actorCount(); ++i) {
            handler.transferAll(i, 4);
        }
        invariant_allBalancesAndSupplyMatchTheLedger();
        invariant_allAllowancesMatchIndependentApprovalHistory();
    }

    /// @dev Deterministic reachability check: all action kinds, a nonzero delegated spend,
    /// an exhausted approval, a rejected call and an exemption transition are exercised.
    function test_handlerExercisesSuccessfulAndRejectedSpendsWithoutAutoApproving() public {
        handler.transferFrom(4, 5, 6, 1); // use the existing finite approval in full
        assertEq(token.allowance(handler.actors(4), handler.actors(5)), 0);
        handler.rejectedTransferFrom(4, 5, 6, 0);
        handler.approve(4, 5, 0); // explicitly grant infinite approval
        handler.transferFrom(4, 5, 4, 1); // self-transfer, infinite approval stays infinite
        handler.revoke(4, 5);
        handler.rejectedTransferFrom(4, 5, 6, 1);
        handler.registerDistributor(true, 6);
        handler.transfer(2, 4, 203);
        handler.registerDistributor(false, 6);
        handler.transferAll(2, 4);
        assertGt(handler.nonzeroTransfers(), 0);
        assertGt(handler.nonzeroDelegatedTransfers(), 0);
        assertEq(handler.rejectedTransfers(), 2);
        assertEq(handler.registryChanges(), 2);
        invariant_allBalancesAndSupplyMatchTheLedger();
        invariant_allAllowancesMatchIndependentApprovalHistory();
        invariant_registryChangesOnlyAffectTheCurrentDistributor();
        invariant_roundingErrorIsBoundedAcrossTheWholeSequence();
        afterInvariant();
    }
}
