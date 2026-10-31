// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MADToken} from "src/MADToken.sol";
import {MADTokenTestBase} from "./helpers/MADTokenTestBase.sol";

/// forge-config: default.fuzz.runs = 1000
contract MADTokenEdgesTest is MADTokenTestBase {
    function test_constructorEmitsExactlyOneMint() public {
        vm.recordLogs();
        vm.prank(holder);
        MADToken fresh = new MADToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(holder))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    function test_zeroOperationsWorkWithoutFundsOrApproval() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(outsider, recipient, 0);
        vm.prank(outsider);
        assertTrue(token.transfer(recipient, 0));

        vm.prank(outsider);
        assertTrue(token.transferFrom(holder, recipient, 0));
        vm.prank(outsider);
        token.burn(0);
        vm.prank(outsider);
        token.burnFrom(holder, 0);

        _assertInitialBalances();
        assertEq(token.allowance(holder, outsider), 0);
    }

    function test_zeroAmountDoesNotBypassZeroReceiverValidation() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(holder);
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(holder, address(0), 0);
        _assertInitialBalances();
    }

    function test_zeroApprovalDoesNotBypassZeroSpenderValidation() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(holder);
        token.approve(address(0), 0);
        assertEq(token.allowance(holder, address(0)), 0);
        _assertInitialBalances();
    }

    function test_failedTransferFromRestoresAllowance() public {
        _approve(SUPPLY + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, SUPPLY, SUPPLY + 1)
        );
        vm.prank(spender);
        token.transferFrom(holder, recipient, SUPPLY + 1);
        assertEq(token.allowance(holder, spender), SUPPLY + 1);
        _assertInitialBalances();

        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, SUPPLY));
        assertEq(token.allowance(holder, spender), 1);
        assertEq(token.balanceOf(recipient), SUPPLY);
    }

    function test_failedBurnFromRestoresAllowance() public {
        _approve(SUPPLY + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, SUPPLY, SUPPLY + 1)
        );
        vm.prank(spender);
        token.burnFrom(holder, SUPPLY + 1);
        assertEq(token.allowance(holder, spender), SUPPLY + 1);
        _assertInitialBalances();

        vm.prank(spender);
        token.burnFrom(holder, SUPPLY);
        assertEq(token.allowance(holder, spender), 1);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.totalSupply(), 0);
    }

    function test_failedTransferToZeroRestoresAllowance() public {
        _approve(SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(holder, address(0), SUPPLY);
        assertEq(token.allowance(holder, spender), SUPPLY);
        _assertInitialBalances();
    }

    function test_approveReplacesAndRevokesWithoutChangingBalances() public {
        _approve(type(uint256).max);
        _approve(7);
        assertEq(token.allowance(holder, spender), 7);
        _approve(7);
        assertEq(token.allowance(holder, spender), 7);
        _approve(0);
        _expectUnauthorizedSpend(spender);
        assertEq(token.nonces(holder), 0);
        _assertInitialBalances();
    }

    function test_allowanceIsSpecificToOwnerAndSpender() public {
        _approve(SUPPLY);
        _expectUnauthorizedSpend(outsider);
        vm.prank(recipient);
        token.approve(spender, SUPPLY);
        _approve(0);
        _expectUnauthorizedSpend(spender);
        assertEq(token.allowance(recipient, spender), SUPPLY);
        _assertInitialBalances();
    }

    function test_holderNeedsAllowanceForDelegatedCallsToItself() public {
        _expectUnauthorizedSpend(holder);
        vm.prank(holder);
        token.approve(holder, 2);
        vm.prank(holder);
        token.transferFrom(holder, holder, 1);
        assertEq(token.allowance(holder, holder), 1);
        assertEq(token.balanceOf(holder), SUPPLY);
        vm.prank(holder);
        token.burnFrom(holder, 1);
        assertEq(token.allowance(holder, holder), 0);
        assertEq(token.balanceOf(holder), SUPPLY - 1);
        assertEq(token.totalSupply(), SUPPLY - 1);
    }

    function test_transferFromToOwnerConsumesAllowanceWithoutMovingBalances() public {
        _approve(SUPPLY);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, holder, SUPPLY));
        assertEq(token.allowance(holder, spender), 0);
        _assertInitialBalances();
    }

    function test_transferFromAndBurnFromShareOneAllowance() public {
        _approve(3);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, 1));
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(holder, address(0), 2);
        vm.prank(spender);
        token.burnFrom(holder, 2);
        _expectUnauthorizedSpend(spender);
        assertEq(token.balanceOf(holder), SUPPLY - 3);
        assertEq(token.balanceOf(recipient), 1);
        assertEq(token.totalSupply(), SUPPLY - 2);
    }

    function test_maximumFiniteAllowanceIsSpentButInfiniteAllowanceIsNot() public {
        _approve(type(uint256).max - 1);
        vm.prank(spender);
        token.transferFrom(holder, recipient, 1);
        vm.prank(spender);
        token.burnFrom(holder, 1);
        assertEq(token.allowance(holder, spender), type(uint256).max - 3);
        _approve(type(uint256).max);
        vm.prank(spender);
        token.transferFrom(holder, recipient, 1);
        vm.prank(spender);
        token.burnFrom(holder, 1);
        assertEq(token.allowance(holder, spender), type(uint256).max);
        assertEq(token.balanceOf(holder), SUPPLY - 4);
        assertEq(token.balanceOf(recipient), 2);
        assertEq(token.totalSupply(), SUPPLY - 2);
    }

    function test_uint256MaximumCannotWrapBalancesOrSupply() public {
        uint256 amount = type(uint256).max;
        bytes memory errorData =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, SUPPLY, amount);
        _approve(amount);
        vm.expectRevert(errorData);
        vm.prank(holder);
        token.transfer(recipient, amount);
        vm.expectRevert(errorData);
        vm.prank(holder);
        token.burn(amount);
        vm.expectRevert(errorData);
        vm.prank(spender);
        token.transferFrom(holder, recipient, amount);
        vm.expectRevert(errorData);
        vm.prank(spender);
        token.burnFrom(holder, amount);
        assertEq(token.allowance(holder, spender), amount);
        _assertInitialBalances();
    }

    function test_dustThenFullBurnLeavesAnEmptyTokenThatCannotBeSpent() public {
        vm.prank(holder);
        token.burn(SUPPLY - 1);
        assertEq(token.totalSupply(), 1);
        vm.prank(holder);
        token.transfer(recipient, 1);
        vm.prank(recipient);
        token.burn(1);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(recipient), 0);
        _approve(type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 0, 1));
        vm.prank(spender);
        token.transferFrom(holder, recipient, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 0, 1));
        vm.prank(spender);
        token.burnFrom(holder, 1);
        vm.prank(holder);
        assertTrue(token.transfer(recipient, 0));
        assertEq(token.totalSupply(), 0);
    }

    function testFuzz_transferRoundTripHasNoFeeOrRounding(uint256 amount, uint8 cycles) public {
        amount = bound(amount, 0, SUPPLY);
        cycles = uint8(bound(cycles, 1, 8));
        for (uint256 i; i < cycles; ++i) {
            vm.prank(holder);
            assertTrue(token.transfer(recipient, amount));
            assertEq(token.balanceOf(recipient), amount);
            vm.prank(recipient);
            assertTrue(token.transfer(holder, amount));
        }
        _assertInitialBalances();
    }

    function testFuzz_selfTransferStillChecksBalance(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, SUPPLY, amount));
        vm.prank(holder);
        token.transfer(holder, amount);
        _assertInitialBalances();
    }

    function testFuzz_splitTransfersAndBurnsConserveEveryWei(uint256 first, uint256 second, uint256 burned) public {
        first = bound(first, 0, SUPPLY);
        second = bound(second, 0, SUPPLY - first);
        burned = bound(burned, 0, first + second);
        vm.startPrank(holder);
        token.transfer(recipient, first);
        token.transfer(recipient, second);
        vm.stopPrank();
        vm.prank(recipient);
        token.burn(burned);
        assertEq(token.balanceOf(recipient), first + second - burned);
        assertEq(token.balanceOf(holder), SUPPLY - first - second);
        assertEq(token.totalSupply() + burned, SUPPLY);
        assertEq(token.balanceOf(recipient) + token.balanceOf(holder), token.totalSupply());
    }

    function testFuzz_burnFromOverAllowanceIsAtomic(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, SUPPLY - 1);
        amount = bound(amount, allowance + 1, SUPPLY);
        _approve(allowance);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, amount)
        );
        vm.prank(spender);
        token.burnFrom(holder, amount);
        assertEq(token.allowance(holder, spender), allowance);
        _assertInitialBalances();
    }

    function testFuzz_failedDelegatedSpendRestoresArbitraryFiniteAllowance(uint256 allowance, bool burn) public {
        allowance = bound(allowance, SUPPLY + 1, type(uint256).max - 1);
        _approve(allowance);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, SUPPLY, SUPPLY + 1)
        );
        vm.prank(spender);
        if (burn) token.burnFrom(holder, SUPPLY + 1);
        else token.transferFrom(holder, recipient, SUPPLY + 1);
        assertEq(token.allowance(holder, spender), allowance);
        _assertInitialBalances();
    }

    function testFuzz_directBurnCannotUseAnotherHoldersTokens(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, held + 1, type(uint256).max);
        vm.prank(holder);
        token.transfer(recipient, held);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, recipient, held, amount));
        vm.prank(recipient);
        token.burn(amount);
        assertEq(token.balanceOf(recipient), held);
        assertEq(token.balanceOf(holder), SUPPLY - held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _expectUnauthorizedSpend(address caller) internal {
        bytes memory errorData = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, caller, 0, 1);
        vm.expectRevert(errorData);
        vm.prank(caller);
        token.transferFrom(holder, recipient, 1);
        vm.expectRevert(errorData);
        vm.prank(caller);
        token.burnFrom(holder, 1);
    }
}
