// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {ADVNToken} from "src/ADVNToken.sol";
import {MockFactory} from "./mocks/MockFactory.sol";

/// @notice Complements the launch and basic transfer tests with authorization, rollback,
/// rounding, and aliased-account cases. Expected amounts never come from previewTransfer.
/// forge-config: default.fuzz.runs = 1000
contract ADVNTokenAdversarialTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint64 internal constant LAUNCH = 42;
    address internal constant JENSEN = 0xc59b0c072f73ceEA3Dc354031165501c0Ff25023;

    address internal alice = makeAddr("adversarial alice");
    address internal bob = makeAddr("adversarial bob");
    address internal spender = makeAddr("adversarial spender");
    address internal manager = makeAddr("adversarial manager");
    address internal distributor = makeAddr("adversarial distributor");
    MockFactory internal factory;
    ADVNToken internal token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        factory = new MockFactory();
        token = factory.deployToken(manager, LAUNCH);
        factory.setDistributor(LAUNCH, distributor);
    }

    function _fund(address account, uint256 amount) internal {
        assertTrue(factory.move(token, account, amount));
    }

    function _approve(address owner, address delegate, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(delegate, amount));
    }

    function _state() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                token.totalSupply(),
                token.balanceOf(address(factory)),
                token.balanceOf(alice),
                token.balanceOf(bob),
                token.balanceOf(spender),
                token.balanceOf(JENSEN),
                token.balanceOf(manager),
                token.balanceOf(distributor),
                token.balanceOf(address(0)),
                token.allowance(alice, spender),
                token.allowance(alice, alice)
            )
        );
    }

    function test_constructorMintsToActualDeployerEvenWhenFactoryArgumentDiffers() public {
        vm.prank(alice);
        ADVNToken fresh = new ADVNToken(address(factory), manager, type(uint64).max);
        assertEq(fresh.balanceOf(alice), SUPPLY);
        assertEq(fresh.balanceOf(address(factory)), 0);
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.LAUNCH_NUMBER(), type(uint64).max);
    }

    function test_constructorEmitsExactlyOneMint() public {
        vm.recordLogs();
        ADVNToken fresh = factory.deployToken(manager, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        _assertTransfer(logs[0], address(fresh), address(0), address(factory), SUPPLY);
        assertEq(fresh.LAUNCH_NUMBER(), 0);
    }

    function test_approvalOverwriteAndRevocationDoNotMoveTokens() public {
        _fund(alice, 1_000);
        _approve(alice, bob, 17);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(alice, spender, type(uint256).max);
        _approve(alice, spender, type(uint256).max);
        assertEq(token.allowance(alice, spender), type(uint256).max);
        _approve(alice, spender, 500);
        assertEq(token.allowance(alice, spender), 500, "approve replaces rather than adds");
        _approve(alice, spender, 0);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.allowance(alice, bob), 17, "other spender's approval is independent");
        assertEq(token.allowance(bob, spender), 0, "other owner's approval is independent");
        assertEq(token.balanceOf(alice), 1_000);
        assertEq(token.balanceOf(JENSEN), 0);
        assertEq(token.totalSupply(), SUPPLY);
        bytes32 beforeState = _state();
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(alice, bob, 1);
        assertEq(_state(), beforeState);
    }

    function test_approveZeroSpenderRevertsWithoutChangingExistingAllowance() public {
        _approve(alice, spender, 123);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), type(uint256).max);
        assertEq(token.allowance(alice, address(0)), 0);
        assertEq(_state(), beforeState);
    }

    function test_zeroCallerCannotApproveOrTransfer() public {
        bytes32 beforeState = _state();
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.approve(spender, 0);
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        token.transfer(bob, 0);
        assertEq(_state(), beforeState);
    }

    function test_transferFromSelfStillRequiresApproval() public {
        _fund(alice, 1_000);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 200));
        token.transferFrom(alice, bob, 200);
        assertEq(_state(), beforeState);
        _approve(alice, alice, 200);
        vm.prank(alice);
        assertTrue(token.transferFrom(alice, bob, 200));
        assertEq(token.allowance(alice, alice), 0);
        assertEq(token.balanceOf(bob), 197);
    }

    function test_zeroTransferFromNeedsNoPositiveAllowanceOrBalance() public {
        bytes32 beforeState = _state();
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(_state(), beforeState);
    }

    function test_zeroRecipientIsRejectedEvenForZeroAmountAndExemptSender() public {
        bytes32 beforeState = _state();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        factory.move(token, address(0), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        assertEq(_state(), beforeState);
    }

    function test_transferFromZeroRecipientRollsBackSpentAllowance() public {
        _fund(alice, 1_000);
        _approve(alice, spender, 600);
        bytes32 beforeState = _state();
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(alice, address(0), 200);
        assertEq(_state(), beforeState, "reverted transfer must restore the allowance debit");
    }

    function test_transferFromInsufficientBalanceRollsBackSpentAllowance() public {
        _fund(alice, 199);
        _approve(alice, spender, 1_000);
        bytes32 beforeState = _state();
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 199, 200));
        token.transferFrom(alice, bob, 200);
        assertEq(_state(), beforeState, "no partial payment, burn, or allowance consumption");
    }

    function test_allowanceMustCoverGrossAmountEvenIfItCoversNetReceipt() public {
        _fund(alice, 200);
        _approve(alice, spender, 197);
        bytes32 beforeState = _state();
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 197, 200));
        token.transferFrom(alice, bob, 200);
        assertEq(_state(), beforeState);
    }

    function test_maximumTransferFailsWithBalanceErrorBeforeTaxArithmetic() public {
        _fund(alice, 1_000);
        _approve(alice, spender, type(uint256).max);
        bytes32 beforeState = _state();
        bytes memory reason =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1_000, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(reason);
        token.transfer(bob, type(uint256).max);
        vm.prank(spender);
        vm.expectRevert(reason);
        token.transferFrom(alice, bob, type(uint256).max);
        vm.prank(spender);
        vm.expectRevert(reason);
        token.transferFrom(alice, manager, type(uint256).max);
        assertEq(_state(), beforeState);
    }

    function test_infiniteApprovalSurvivesRepeatedSpendsThenCanBeRevoked() public {
        _fund(alice, 1_000);
        _approve(alice, spender, type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            vm.prank(spender);
            assertTrue(token.transferFrom(alice, bob, 200));
            assertEq(token.allowance(alice, spender), type(uint256).max);
        }
        assertEq(token.balanceOf(alice), 400);
        assertEq(token.balanceOf(bob), 591);
        assertEq(token.balanceOf(JENSEN), 3);
        assertEq(token.totalSupply(), SUPPLY - 6);
        _approve(alice, spender, 0);
        bytes32 beforeState = _state();
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 200));
        token.transferFrom(alice, bob, 200);
        assertEq(_state(), beforeState);
    }

    function test_finiteApprovalIsSpentOnGrossAndCannotBeReused() public {
        _fund(alice, 1_000);
        _approve(alice, spender, 400);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, alice, 200));
        assertEq(token.allowance(alice, spender), 200);
        assertEq(token.balanceOf(alice), 997, "self-transfer still pays tax");
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 200));
        assertEq(token.allowance(alice, spender), 0);
        bytes32 beforeState = _state();
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(alice, bob, 1);
        assertEq(_state(), beforeState);
    }

    function test_directTransferDoesNotConsumeApproval() public {
        _fund(alice, 400);
        _approve(alice, spender, 400);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 200));
        assertEq(token.allowance(alice, spender), 400);
        assertEq(token.balanceOf(alice), 200);
    }

    function test_feeRecipientSelfTransferBurnsExactlyOnce() public {
        _fund(JENSEN, 200);
        vm.prank(JENSEN);
        assertTrue(token.transfer(JENSEN, 200));
        assertEq(token.balanceOf(JENSEN), 198);
        assertEq(token.totalSupply(), SUPPLY - 2);
        assertEq(token.balanceOf(address(0)), 0, "burn reduces supply; zero address holds no tokens");
    }

    function test_selfTransferRequiresFullGrossBalanceIncludingFeeRecipient() public {
        _fund(alice, 199);
        _fund(JENSEN, 199);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 199, 200));
        token.transfer(alice, 200);
        vm.prank(JENSEN);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, JENSEN, 199, 200));
        token.transfer(JENSEN, 200);
        assertEq(_state(), beforeState);
    }

    function test_entireInitialSupplyCanBeTransferredAndTaxed() public {
        _fund(alice, SUPPLY);
        vm.prank(alice);
        assertTrue(token.transfer(bob, SUPPLY));
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 985_000_000e18);
        assertEq(token.balanceOf(JENSEN), 5_000_000e18);
        assertEq(token.totalSupply(), 990_000_000e18);
    }

    function test_roundingBoundaryExamples() public {
        uint256[9] memory amounts = [uint256(0), 1, 99, 100, 101, 199, 200, 201, 10_000];
        uint256[9] memory fees = [uint256(0), 0, 0, 0, 0, 0, 1, 1, 50];
        uint256[9] memory burns = [uint256(0), 0, 0, 1, 1, 1, 2, 2, 100];
        _fund(alice, SUPPLY);
        for (uint256 i; i < amounts.length; ++i) {
            uint256 recipientBefore = token.balanceOf(bob);
            uint256 feeBefore = token.balanceOf(JENSEN);
            uint256 supplyBefore = token.totalSupply();
            uint256 senderBefore = token.balanceOf(alice);
            vm.prank(alice);
            assertTrue(token.transfer(bob, amounts[i]));
            assertEq(senderBefore - token.balanceOf(alice), amounts[i]);
            assertEq(token.balanceOf(bob) - recipientBefore, amounts[i] - fees[i] - burns[i]);
            assertEq(token.balanceOf(JENSEN) - feeBefore, fees[i]);
            assertEq(supplyBefore - token.totalSupply(), burns[i]);
        }
    }

    function test_transferEventsDescribeRecipientFeeAndSupplyBurn() public {
        _fund(alice, 200);
        vm.recordLogs();
        vm.prank(alice);
        token.transfer(bob, 200);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 4);
        _assertTransfer(logs[0], address(token), alice, bob, 197);
        _assertTransfer(logs[1], address(token), alice, JENSEN, 1);
        _assertTransfer(logs[2], address(token), alice, address(0), 2);
        assertEq(logs[3].emitter, address(token));
        assertEq(logs[3].topics.length, 3);
        assertEq(logs[3].topics[0], keccak256("TradeTaxed(address,address,uint256,uint256,uint256)"));
        assertEq(logs[3].topics[1], bytes32(uint256(uint160(alice))));
        assertEq(logs[3].topics[2], bytes32(uint256(uint160(bob))));
        assertEq(logs[3].data, abi.encode(uint256(200), uint256(1), uint256(2)));
    }

    function test_distributorLookupIsScopedToLaunchAndIsNotCached() public {
        ADVNToken other = factory.deployToken(manager, type(uint64).max);
        factory.setDistributor(type(uint64).max, bob);
        assertEq(token.distributor(), distributor);
        assertEq(other.distributor(), bob);
        _fund(distributor, 600);
        vm.prank(distributor);
        assertTrue(token.transfer(alice, 200));
        assertEq(token.balanceOf(alice), 200);
        factory.setDistributor(LAUNCH, address(0));
        assertEq(token.distributor(), address(0));
        vm.prank(distributor);
        assertTrue(token.transfer(alice, 200));
        assertEq(token.balanceOf(alice), 397);
        factory.setDistributor(LAUNCH, distributor);
        vm.prank(distributor);
        assertTrue(token.transfer(alice, 200));
        assertEq(token.balanceOf(alice), 597);
        assertEq(token.balanceOf(JENSEN), 1);
        assertEq(token.totalSupply(), SUPPLY - 2);
        assertEq(other.totalSupply(), SUPPLY, "another launch is unaffected");
    }

    function test_everyShortDistributorResponseFallsBackToTaxation() public {
        _fund(alice, 32 * 200);
        bytes memory lookup = abi.encodeWithSignature("distributorOf(uint64)", LAUNCH);
        for (uint256 size; size < 32; ++size) {
            vm.mockCall(address(factory), lookup, new bytes(size));
            assertEq(token.distributor(), address(0));
            vm.prank(alice);
            assertTrue(token.transfer(bob, 200));
            assertEq(token.balanceOf(bob), (size + 1) * 197);
            assertEq(token.balanceOf(JENSEN), size + 1);
            assertEq(token.totalSupply(), SUPPLY - (size + 1) * 2);
        }
        vm.clearMockedCalls();
        assertEq(token.distributor(), distributor);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_revertingLookupRecoversWithoutResettingTheToken() public {
        _fund(distributor, 400);
        bytes memory lookup = abi.encodeWithSignature("distributorOf(uint64)", LAUNCH);
        vm.mockCallRevert(address(factory), lookup, abi.encodeWithSignature("Error(string)", "lookup unavailable"));
        vm.prank(distributor);
        assertTrue(token.transfer(alice, 200));
        assertEq(token.balanceOf(alice), 197);
        vm.clearMockedCalls();
        vm.prank(distributor);
        assertTrue(token.transfer(alice, 200));
        assertEq(token.balanceOf(alice), 397);
        assertEq(token.balanceOf(JENSEN), 1);
        assertEq(token.totalSupply(), SUPPLY - 2);
    }

    /// Regression for the earlier noncanonical-word finding: any 32-byte answer with a bit above the
    /// low 160 set means "no distributor". Transfers keep working and the registered distributor is
    /// taxed like anyone else while the answer is malformed; a clean answer restores the exemption.
    function testFuzz_dirtyDistributorWordNeverFreezesOrExemptsTransfers(uint256 high) public {
        high = bound(high, 1, type(uint96).max);
        uint256 word = (high << 160) | uint256(uint160(distributor));
        bytes memory lookup = abi.encodeWithSignature("distributorOf(uint64)", LAUNCH);
        _fund(distributor, 400);
        _fund(alice, 200);
        vm.mockCall(address(factory), lookup, abi.encode(word));
        assertEq(token.distributor(), address(0));
        assertFalse(token.isExempt(distributor, alice));
        vm.prank(distributor);
        assertTrue(token.transfer(bob, 200));
        vm.prank(alice);
        assertTrue(token.transfer(bob, 200));
        assertEq(token.balanceOf(bob), 394, "both transfers taxed");
        assertEq(token.balanceOf(JENSEN), 2);
        assertEq(token.totalSupply(), SUPPLY - 4);
        vm.clearMockedCalls();
        assertEq(token.distributor(), distributor);
        vm.prank(distributor);
        assertTrue(token.transfer(bob, 200));
        assertEq(token.balanceOf(bob), 594, "exemption restored with a clean answer");
        assertEq(token.totalSupply(), SUPPLY - 4);
    }

    function test_distributorWordBoundaryAndTrailingData() public {
        bytes memory lookup = abi.encodeWithSignature("distributorOf(uint64)", LAUNCH);
        vm.mockCall(address(factory), lookup, abi.encode(uint256(type(uint160).max)));
        assertEq(token.distributor(), address(type(uint160).max), "largest address is still an address");
        vm.mockCall(address(factory), lookup, abi.encode(uint256(type(uint160).max) + 1));
        assertEq(token.distributor(), address(0), "first word above the address range");
        vm.mockCall(address(factory), lookup, abi.encode(type(uint256).max));
        assertEq(token.distributor(), address(0));
        // An over-long answer is read by its first word, as ABI decoding does.
        vm.mockCall(address(factory), lookup, abi.encode(distributor, type(uint256).max));
        assertEq(token.distributor(), distributor);
        vm.mockCall(address(factory), lookup, abi.encode(type(uint256).max, distributor));
        assertEq(token.distributor(), address(0));
    }

    /// Regression for the earlier preview-overflow finding: defined over the whole uint256 domain,
    /// each levy is the floor of its rate, and the three parts always add back to the input.
    function testFuzz_previewIsTotalAndFloorsOverWholeDomain(uint256 amount) public view {
        (uint256 fee, uint256 burned, uint256 received) = token.previewTransfer(amount);
        assertLe(fee * 200, amount);
        assertLt(amount - fee * 200, 200);
        assertLe(burned * 100, amount);
        assertLt(amount - burned * 100, 100);
        assertEq(fee + burned + received, amount);
        assertGe(received, amount - amount / 200 - amount / 100);
    }

    function test_previewEdgeExamplesAboveFormerOverflowPoint() public view {
        uint256 max = type(uint256).max;
        uint256[4] memory amounts = [max / 100, max / 100 + 1, max - 1, max];
        for (uint256 i; i < amounts.length; ++i) {
            (uint256 fee, uint256 burned, uint256 received) = token.previewTransfer(amounts[i]);
            assertEq(fee + burned + received, amounts[i]);
            assertGt(fee, 0);
            assertApproxEqAbs(fee, burned / 2, 1, "fee is half the burn up to rounding");
        }
        (uint256 f, uint256 b, uint256 r) = token.previewTransfer(max);
        // 2^256 - 1 = 200q + 135 and 100q' + 35.
        assertEq(max - f * 200, 135);
        assertEq(max - b * 100, 35);
        assertEq(r, max - f - b);
    }

    function testFuzz_failedDelegatedSpendIsAtomic(uint256 funded, uint256 excess, bool exempt) public {
        funded = bound(funded, 0, SUPPLY);
        uint256 amount = funded + bound(excess, 1, SUPPLY);
        _fund(alice, funded);
        _approve(alice, spender, amount);
        bytes32 beforeState = _state();
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, funded, amount));
        token.transferFrom(alice, exempt ? manager : bob, amount);
        assertEq(_state(), beforeState);
    }

    function testFuzz_roundTripCannotCreateValue(uint256 amount, uint8 cycles) public {
        amount = bound(amount, 0, SUPPLY);
        cycles = uint8(bound(cycles, 1, 12));
        _fund(alice, amount);
        for (uint256 i; i < cycles; ++i) {
            uint256 held = token.balanceOf(alice);
            vm.prank(alice);
            token.transfer(bob, held);
            uint256 received = token.balanceOf(bob);
            vm.prank(bob);
            token.transfer(alice, received);
            assertLe(token.balanceOf(alice), held);
            assertEq(token.balanceOf(bob), 0);
            assertEq(amount - token.balanceOf(alice), token.balanceOf(JENSEN) + SUPPLY - token.totalSupply());
        }
    }

    function testFuzz_previewAdvancesByOneWholeFeeQuantum(uint256 amount) public view {
        amount = bound(amount, 0, SUPPLY - 200);
        (uint256 f0, uint256 b0, uint256 r0) = token.previewTransfer(amount);
        (uint256 f1, uint256 b1, uint256 r1) = token.previewTransfer(amount + 200);
        assertEq(f1 - f0, 1);
        assertEq(b1 - b0, 2);
        assertEq(r1 - r0, 197);
        assertEq(f0 + b0 + r0, amount);
    }

    function testFuzz_splittingPaymentSavesAtMostOneUnitOfEachLevy(uint256 amount, uint256 split) public view {
        amount = bound(amount, 0, SUPPLY);
        split = bound(split, 0, amount);
        (uint256 fee, uint256 burned, uint256 received) = token.previewTransfer(amount);
        (uint256 f0, uint256 b0, uint256 r0) = token.previewTransfer(split);
        (uint256 f1, uint256 b1, uint256 r1) = token.previewTransfer(amount - split);
        assertGe(fee, f0 + f1);
        assertLe(fee - f0 - f1, 1);
        assertGe(burned, b0 + b1);
        assertLe(burned - b0 - b1, 1);
        assertGe(r0 + r1, received);
        assertLe(r0 + r1 - received, 2);
    }

    function _assertTransfer(Vm.Log memory log, address emitter, address from, address to, uint256 value)
        internal
        pure
    {
        assertEq(log.emitter, emitter);
        assertEq(log.topics.length, 3);
        assertEq(log.topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(log.topics[1], bytes32(uint256(uint160(from))));
        assertEq(log.topics[2], bytes32(uint256(uint160(to))));
        assertEq(log.data, abi.encode(value));
    }
}
