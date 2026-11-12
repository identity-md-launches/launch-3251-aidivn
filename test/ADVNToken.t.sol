// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {ADVNToken} from "../src/ADVNToken.sol";
import {MockFactory, RevertingFactory, ShortAnswerFactory} from "./mocks/MockFactory.sol";

contract ADVNTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint64 constant LAUNCH_NUMBER = 42;

    address constant POOL_MANAGER = address(0x900C);
    address constant DISTRIBUTOR = address(0xD157);
    address constant JENSEN = 0xc59b0c072f73ceEA3Dc354031165501c0Ff25023;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    MockFactory factory;
    ADVNToken token;

    event TradeTaxed(address indexed from, address indexed to, uint256 amount, uint256 fee, uint256 burned);

    function setUp() public {
        factory = new MockFactory();
        token = factory.deployToken(POOL_MANAGER, LAUNCH_NUMBER);
    }

    function _fund(address who, uint256 amount) internal {
        // The factory's outgoing transfers are exempt, so `who` receives exactly `amount`.
        assertTrue(factory.move(token, who, amount));
        assertEq(token.balanceOf(who), amount);
    }

    // ---------------------------------------------------------------- metadata and supply

    function test_metadata() public view {
        assertEq(token.name(), "AIDIVN");
        assertEq(token.symbol(), "ADVN");
        assertEq(token.decimals(), 18);
    }

    function test_mintsWholeSupplyToDeployerOnce() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(JENSEN), 0);
    }

    function test_launchParametersAreRecorded() public view {
        assertEq(token.FACTORY(), address(factory));
        assertEq(token.POOL_MANAGER(), POOL_MANAGER);
        assertEq(token.LAUNCH_NUMBER(), LAUNCH_NUMBER);
        assertEq(token.FEE_RECIPIENT(), JENSEN);
        assertEq(token.FEE_BPS(), 50);
        assertEq(token.BURN_BPS(), 100);
        assertEq(token.BPS_DENOMINATOR(), 10_000);
    }

    function test_constructorRejectsZeroFactory() public {
        vm.expectRevert(ADVNToken.ZeroAddress.selector);
        new ADVNToken(address(0), POOL_MANAGER, LAUNCH_NUMBER);
    }

    function test_constructorRejectsZeroPoolManager() public {
        vm.expectRevert(ADVNToken.ZeroAddress.selector);
        new ADVNToken(address(factory), address(0), LAUNCH_NUMBER);
    }

    function test_constructorDoesNotNeedCodeAtTheLaunchAddresses() public {
        // The launch checks run the constructor on an empty chain: nothing may be called from it.
        address emptyFactory = makeAddr("emptyFactory");
        address emptyManager = makeAddr("emptyManager");
        vm.prank(emptyFactory);
        ADVNToken fresh = new ADVNToken(emptyFactory, emptyManager, 7);
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(emptyFactory), SUPPLY);
    }

    function test_noMintOrAdminEntryPoints() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "owner()",
            "pause()",
            "burnFrom(address,uint256)",
            "setFeeRecipient(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(address(factory));
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, 1));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- exempt launch flows

    function test_factoryTransfersAreUntaxed() public {
        uint256 swarm = SUPPLY / 10;
        _fund(DISTRIBUTOR, swarm);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(JENSEN), 0);
    }

    function test_distributorTransfersAreUntaxedOnceRecorded() public {
        factory.setDistributor(LAUNCH_NUMBER, DISTRIBUTOR);
        assertEq(token.distributor(), DISTRIBUTOR);
        _fund(DISTRIBUTOR, 1_000e18);
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(alice, 1_000e18));
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(JENSEN), 0);
    }

    function test_distributorIsOrdinaryUntilTheFactoryRecordsIt() public {
        assertEq(token.distributor(), address(0));
        _fund(DISTRIBUTOR, 1_000e18);
        vm.prank(DISTRIBUTOR);
        token.transfer(alice, 1_000e18);
        assertEq(token.balanceOf(alice), 985e18);
        assertEq(token.balanceOf(JENSEN), 5e18);
        assertEq(token.totalSupply(), SUPPLY - 10e18);
    }

    function test_distributorOfAnotherLaunchIsNotExempt() public {
        factory.setDistributor(LAUNCH_NUMBER + 1, DISTRIBUTOR);
        assertEq(token.distributor(), address(0));
        assertFalse(token.isExempt(DISTRIBUTOR, alice));
    }

    function test_transfersIntoThePoolManagerAreUntaxed() public {
        _fund(alice, 1_000e18);
        vm.prank(alice);
        assertTrue(token.transfer(POOL_MANAGER, 1_000e18));
        assertEq(token.balanceOf(POOL_MANAGER), 1_000e18);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(JENSEN), 0);
    }

    function test_transferFromIntoThePoolManagerIsUntaxed() public {
        _fund(alice, 1_000e18);
        vm.prank(alice);
        token.approve(bob, 1_000e18);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, POOL_MANAGER, 1_000e18));
        assertEq(token.balanceOf(POOL_MANAGER), 1_000e18);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_isExemptView() public {
        factory.setDistributor(LAUNCH_NUMBER, DISTRIBUTOR);
        assertTrue(token.isExempt(address(factory), alice));
        assertTrue(token.isExempt(alice, POOL_MANAGER));
        assertTrue(token.isExempt(DISTRIBUTOR, alice));
        assertFalse(token.isExempt(POOL_MANAGER, alice));
        assertFalse(token.isExempt(alice, bob));
        assertFalse(token.isExempt(alice, address(factory)));
        assertFalse(token.isExempt(alice, DISTRIBUTOR));
        assertFalse(token.isExempt(JENSEN, alice));
    }

    // ---------------------------------------------------------------- taxed transfers

    function test_walletTransferPaysFeeAndBurns() public {
        _fund(alice, 10_000e18);
        vm.expectEmit(true, true, true, true, address(token));
        emit TradeTaxed(alice, bob, 1_000e18, 5e18, 10e18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 1_000e18));
        assertEq(token.balanceOf(alice), 9_000e18, "sender pays the full amount");
        assertEq(token.balanceOf(bob), 985e18, "recipient gets 98.5%");
        assertEq(token.balanceOf(JENSEN), 5e18, "Jensen gets 0.5%");
        assertEq(token.totalSupply(), SUPPLY - 10e18, "1% is burned");
    }

    function test_tokensLeavingThePoolManagerAreTaxed() public {
        // A buy from the launch pool: the PoolManager pays the trader.
        _fund(POOL_MANAGER, 1_000e18);
        vm.prank(POOL_MANAGER);
        assertTrue(token.transfer(alice, 1_000e18));
        assertEq(token.balanceOf(alice), 985e18);
        assertEq(token.balanceOf(JENSEN), 5e18);
        assertEq(token.balanceOf(POOL_MANAGER), 0);
        assertEq(token.totalSupply(), SUPPLY - 10e18);
    }

    function test_transferFromIsTaxed() public {
        _fund(alice, 1_000e18);
        vm.prank(alice);
        token.approve(bob, 600e18);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, 600e18));
        assertEq(token.balanceOf(alice), 400e18);
        assertEq(token.balanceOf(carol), 591e18);
        assertEq(token.balanceOf(JENSEN), 3e18);
        assertEq(token.allowance(alice, bob), 0, "allowance is spent on the full amount");
        assertEq(token.totalSupply(), SUPPLY - 6e18);
    }

    function test_feeRecipientPaysTaxLikeAnyoneElse() public {
        _fund(JENSEN, 1_000e18);
        vm.prank(JENSEN);
        token.transfer(alice, 1_000e18);
        assertEq(token.balanceOf(alice), 985e18);
        assertEq(token.balanceOf(JENSEN), 5e18, "the fee comes back to the recipient");
        assertEq(token.totalSupply(), SUPPLY - 10e18);
    }

    function test_transferToFeeRecipientIsTaxed() public {
        _fund(alice, 1_000e18);
        vm.prank(alice);
        token.transfer(JENSEN, 1_000e18);
        assertEq(token.balanceOf(JENSEN), 990e18);
        assertEq(token.totalSupply(), SUPPLY - 10e18);
    }

    function test_selfTransferIsTaxed() public {
        _fund(alice, 1_000e18);
        vm.prank(alice);
        token.transfer(alice, 1_000e18);
        assertEq(token.balanceOf(alice), 985e18);
        assertEq(token.balanceOf(JENSEN), 5e18);
    }

    function test_dustBelowTheRoundingThresholdMovesWhole() public {
        _fund(alice, 1_000);
        vm.prank(alice);
        token.transfer(bob, 99); // 0.5% and 1% of 99 both round down to 0
        assertEq(token.balanceOf(bob), 99);
        assertEq(token.balanceOf(JENSEN), 0);
        assertEq(token.totalSupply(), SUPPLY);
        vm.prank(alice);
        token.transfer(bob, 199); // burn 1, fee 0
        assertEq(token.balanceOf(bob), 99 + 198);
        assertEq(token.balanceOf(JENSEN), 0);
        assertEq(token.totalSupply(), SUPPLY - 1);
        vm.prank(alice);
        token.transfer(bob, 200); // burn 2, fee 1
        assertEq(token.balanceOf(bob), 99 + 198 + 197);
        assertEq(token.balanceOf(JENSEN), 1);
        assertEq(token.totalSupply(), SUPPLY - 3);
    }

    function test_zeroTransferIsAllowedAndMovesNothing() public {
        _fund(alice, 1e18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(JENSEN), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_previewTransfer() public view {
        (uint256 fee, uint256 burned, uint256 received) = token.previewTransfer(1_000e18);
        assertEq(fee, 5e18);
        assertEq(burned, 10e18);
        assertEq(received, 985e18);
    }

    // ---------------------------------------------------------------- failure paths

    function test_transferMoreThanBalanceReverts() public {
        _fund(alice, 1_000e18);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1_000e18, 1_000e18 + 1)
        );
        token.transfer(bob, 1_000e18 + 1);
    }

    function test_exemptTransferMoreThanBalanceReverts() public {
        _fund(alice, 1_000e18);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1_000e18, 1_000e18 + 1)
        );
        token.transfer(POOL_MANAGER, 1_000e18 + 1);
    }

    function test_wholeBalanceCanBeSentDespiteTheTax() public {
        _fund(alice, 1_000e18);
        vm.prank(alice);
        token.transfer(bob, 1_000e18);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 985e18);
    }

    function test_transferFromWithoutAllowanceReverts() public {
        _fund(alice, 1_000e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1e18));
        token.transferFrom(alice, carol, 1e18);
    }

    function test_transferToZeroAddressReverts() public {
        _fund(alice, 1_000e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1e18);
    }

    function test_factoryCannotMoveAHoldersBalance() public {
        _fund(alice, 1_000e18);
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 1)
        );
        token.transferFrom(alice, address(factory), 1);
        assertEq(token.balanceOf(alice), 1_000e18);
    }

    // ---------------------------------------------------------------- factory lookup robustness

    function test_transfersWorkWhenTheFactoryHasNoCode() public {
        address bareFactory = makeAddr("bareFactory");
        vm.prank(bareFactory);
        ADVNToken fresh = new ADVNToken(bareFactory, POOL_MANAGER, LAUNCH_NUMBER);
        assertEq(fresh.distributor(), address(0));
        vm.prank(bareFactory);
        fresh.transfer(alice, 1_000e18);
        assertEq(fresh.balanceOf(alice), 1_000e18, "factory sends untaxed");
        vm.prank(alice);
        fresh.transfer(bob, 1_000e18);
        assertEq(fresh.balanceOf(bob), 985e18, "ordinary transfer taxed");
    }

    function test_transfersWorkWhenTheFactoryLookupReverts() public {
        RevertingFactory reverting = new RevertingFactory();
        ADVNToken fresh = reverting.deployToken(POOL_MANAGER, LAUNCH_NUMBER);
        assertEq(fresh.distributor(), address(0));
        reverting.move(fresh, alice, 1_000e18);
        vm.prank(alice);
        fresh.transfer(bob, 1_000e18);
        assertEq(fresh.balanceOf(bob), 985e18);
    }

    function test_transfersWorkWhenTheFactoryAnswersShort() public {
        ShortAnswerFactory short = new ShortAnswerFactory();
        ADVNToken fresh = short.deployToken(POOL_MANAGER, LAUNCH_NUMBER);
        assertEq(fresh.distributor(), address(0));
        short.move(fresh, alice, 1_000e18);
        vm.prank(alice);
        fresh.transfer(bob, 1_000e18);
        assertEq(fresh.balanceOf(bob), 985e18);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_taxedTransferConservesValue(uint256 funded, uint256 amount) public {
        funded = bound(funded, 0, SUPPLY);
        amount = bound(amount, 0, funded);
        _fund(alice, funded);
        (uint256 fee, uint256 burned, uint256 received) = token.previewTransfer(amount);
        assertEq(fee + burned + received, amount);
        assertEq(fee, amount * 50 / 10_000);
        assertEq(burned, amount * 100 / 10_000);

        vm.prank(alice);
        assertTrue(token.transfer(bob, amount));
        assertEq(token.balanceOf(alice), funded - amount);
        assertEq(token.balanceOf(bob), received);
        assertEq(token.balanceOf(JENSEN), fee);
        assertEq(token.totalSupply(), SUPPLY - burned);
        assertEq(
            token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(JENSEN) + token.balanceOf(address(factory)),
            token.totalSupply()
        );
    }

    function testFuzz_taxedTransferAboveBalanceReverts(uint256 funded, uint256 amount) public {
        funded = bound(funded, 0, SUPPLY - 1);
        amount = bound(amount, funded + 1, SUPPLY);
        _fund(alice, funded);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, funded, amount));
        token.transfer(bob, amount);
    }

    function testFuzz_exemptFlowsMoveExactly(uint256 amount, address to) public {
        amount = bound(amount, 0, SUPPLY);
        vm.assume(to != address(0) && to != address(factory));
        factory.setDistributor(LAUNCH_NUMBER, DISTRIBUTOR);
        vm.assume(to != DISTRIBUTOR && to != POOL_MANAGER);

        // factory -> distributor -> anyone, and anyone -> pool manager, all exact.
        assertTrue(factory.move(token, DISTRIBUTOR, amount));
        assertEq(token.balanceOf(DISTRIBUTOR), amount);
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        vm.prank(to);
        assertTrue(token.transfer(POOL_MANAGER, amount));
        assertEq(token.balanceOf(POOL_MANAGER), amount);
        assertEq(token.balanceOf(to), 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(JENSEN), 0);
    }

    function testFuzz_taxNeverExceedsOnePointFivePercent(uint256 amount) public view {
        amount = bound(amount, 0, SUPPLY);
        (uint256 fee, uint256 burned, uint256 received) = token.previewTransfer(amount);
        assertLe(fee + burned, amount * 150 / 10_000);
        assertGe(received, amount - amount * 150 / 10_000);
    }
}
