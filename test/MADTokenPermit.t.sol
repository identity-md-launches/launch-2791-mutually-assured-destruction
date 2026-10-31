// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MADToken} from "src/MADToken.sol";
import {MADTokenTestBase} from "./helpers/MADTokenTestBase.sol";

/// forge-config: default.fuzz.runs = 1000
contract MADTokenPermitTest is MADTokenTestBase {
    function setUp() public override {
        super.setUp();
        vm.warp(1_000_000);
        _approve(9);
    }

    function test_permitIsValidAtExactDeadlineAndEmitsApproval() public {
        uint256 deadline = vm.getBlockTimestamp();
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(spender, 123, 0, deadline);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(holder, spender, 123);
        vm.prank(outsider);
        token.permit(holder, spender, 123, deadline, v, r, s);
        _assertPermitState(123, 1);
    }

    function test_expiredSignaturePreservesAllowanceAndNonce() public {
        uint256 deadline = vm.getBlockTimestamp();
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(spender, 123, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(holder, spender, 123, deadline, v, r, s);
        _assertPermitState(9, 0);
        _submitPermit(spender, 124, 0, vm.getBlockTimestamp());
        _assertPermitState(124, 1);
    }

    function test_validSignatureForZeroSpenderRevertsAndRollsBackNonce() public {
        uint256 deadline = vm.getBlockTimestamp();
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(address(0), 123, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.permit(holder, address(0), 123, deadline, v, r, s);
        assertEq(token.allowance(holder, address(0)), 0);
        _assertPermitState(9, 0);
        _submitPermit(spender, 123, 0, deadline);
        _assertPermitState(123, 1);
    }

    function test_zeroOwnerCannotApproveWithEmptySignature() public {
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(address(0), spender, 1, type(uint256).max, 27, bytes32(0), bytes32(0));
        assertEq(token.nonces(address(0)), 0);
        assertEq(token.allowance(address(0), spender), 0);
        _assertPermitState(9, 0);
    }

    function test_invalidRecoveryIdRollsBackNonce() public {
        uint256 deadline = vm.getBlockTimestamp();
        (, bytes32 r, bytes32 s) = _signPermit(spender, 123, 0, deadline);
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(holder, spender, 123, deadline, 0, r, s);
        _assertPermitState(9, 0);
        _submitPermit(spender, 123, 0, deadline);
        _assertPermitState(123, 1);
    }

    function test_highSSignatureIsRejectedWithoutConsumingNonce() public {
        uint256 deadline = vm.getBlockTimestamp();
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(spender, 123, 0, deadline);
        bytes32 highS = bytes32(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        token.permit(holder, spender, 123, deadline, flippedV, r, highS);
        _assertPermitState(9, 0);
        token.permit(holder, spender, 123, deadline, v, r, s);
        _assertPermitState(123, 1);
    }

    function test_wrongSignerCannotConsumeNonceOrReplaceAllowance() public {
        (, uint256 wrongKey) = makeAddrAndKey("MAD wrong permit signer");
        uint256 deadline = vm.getBlockTimestamp();
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(wrongKey, _digest(_domain(address(token), block.chainid), holder, spender, 123, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, vm.addr(wrongKey), holder));
        token.permit(holder, spender, 123, deadline, v, r, s);
        _assertPermitState(9, 0);
    }

    function test_replayCannotRestoreARevokedAllowance() public {
        uint256 deadline = type(uint256).max;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(spender, 123, 0, deadline);
        token.permit(holder, spender, 123, deadline, v, r, s);
        _approve(0);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(holder, spender, 123, deadline, v, r, s);
        _assertPermitState(0, 1);
    }

    function test_permitRevocationPreventsTransferAndBurn() public {
        _submitPermit(spender, 0, 0, type(uint256).max);
        bytes memory errorData = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1);
        vm.expectRevert(errorData);
        vm.prank(spender);
        token.transferFrom(holder, recipient, 1);
        vm.expectRevert(errorData);
        vm.prank(spender);
        token.burnFrom(holder, 1);
        _assertPermitState(0, 1);
    }

    function test_futureNonceMustWaitForPrecedingPermit() public {
        uint256 deadline = type(uint256).max;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(spender, 456, 1, deadline);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(holder, spender, 456, deadline, v, r, s);
        _assertPermitState(9, 0);
        _submitPermit(spender, 123, 0, deadline);
        token.permit(holder, spender, 456, deadline, v, r, s);
        _assertPermitState(456, 2);
    }

    function test_nonceIsPerOwnerAndSharedBetweenSpenders() public {
        uint256 deadline = type(uint256).max;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(recipient, 456, 0, deadline);
        _submitPermit(spender, 123, 0, deadline);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(holder, recipient, 456, deadline, v, r, s);
        assertEq(token.nonces(recipient), 0);
        assertEq(token.allowance(holder, recipient), 0);
        _submitPermit(recipient, 456, 1, deadline);
        assertEq(token.allowance(holder, recipient), 456);
        _assertPermitState(123, 2);
    }

    function test_signatureCannotBeReplayedOnAnotherDeployment() public {
        MADToken other = new MADToken();
        uint256 deadline = type(uint256).max;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(spender, 123, 0, deadline);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        other.permit(holder, spender, 123, deadline, v, r, s);
        assertEq(other.allowance(holder, spender), 0);
        assertEq(other.nonces(holder), 0);
        _assertPermitState(9, 0);
        token.permit(holder, spender, 123, deadline, v, r, s);
        _assertPermitState(123, 1);
    }

    function test_chainChangeRejectsOldSignatureAndAcceptsNewDomain() public {
        uint256 deadline = type(uint256).max;
        // Read through a contract call so solc cannot reuse a local chainid read
        // across the cheatcode's environment mutation.
        (,,, uint256 originalChain,,,) = token.eip712Domain();
        uint256 otherChain = originalChain + 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(spender, 123, 0, deadline);
        vm.chainId(otherChain);
        assertEq(token.DOMAIN_SEPARATOR(), _domain(address(token), otherChain));
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(holder, spender, 123, deadline, v, r, s);
        _assertPermitState(9, 0);
        (v, r, s) = vm.sign(holderKey, _digest(_domain(address(token), otherChain), holder, spender, 123, 0, deadline));
        token.permit(holder, spender, 123, deadline, v, r, s);
        _assertPermitState(123, 1);
    }

    function test_domainIntrospectionMatchesSigningDomain() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = token.eip712Domain();
        assertEq(uint8(fields), 15);
        assertEq(name, "Mutually Assured Destruction");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(token));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
        assertEq(token.DOMAIN_SEPARATOR(), _domain(address(token), chainId));
    }

    function test_maximumPermitRemainsInfiniteForBothSpendingFunctions() public {
        _submitPermit(spender, type(uint256).max, 0, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(holder, recipient, 1);
        vm.prank(spender);
        token.burnFrom(holder, SUPPLY - 1);
        assertEq(token.allowance(holder, spender), type(uint256).max);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(recipient), 1);
        assertEq(token.totalSupply(), 1);
        assertEq(token.nonces(holder), 1);
    }

    function testFuzz_modifyingAnySignedFieldInvalidatesPermit(uint256 value, uint8 field) public {
        field = uint8(bound(field, 0, 4));
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(spender, value, 0, deadline);
        address ownerArg = field == 0 ? outsider : holder;
        address spenderArg = field == 1 ? recipient : spender;
        uint256 valueArg = field == 2 ? value ^ 1 : value;
        uint256 deadlineArg = field == 3 ? deadline + 1 : deadline;
        if (field == 4) {
            // A signature for nonce 1 is invalid while the account is at nonce 0.
            (v, r, s) = _signPermit(spender, value, 1, deadline);
        }
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(ownerArg, spenderArg, valueArg, deadlineArg, v, r, s);
        assertEq(token.allowance(holder, recipient), 0);
        assertEq(token.allowance(outsider, spender), 0);
        assertEq(token.nonces(outsider), 0);
        _assertPermitState(9, 0);
    }

    function testFuzz_permitAndApprovalReplaceRatherThanAccumulate(uint256 first, uint256 second) public {
        _submitPermit(spender, first, 0, type(uint256).max);
        _assertPermitState(first, 1);
        _approve(second);
        _assertPermitState(second, 1);
        _submitPermit(spender, first, 1, type(uint256).max);
        _assertPermitState(first, 2);
    }

    function testFuzz_permitAuthorizesExactlyTheSharedSpendingBudget(uint256 approved, uint256 moved, uint256 burned)
        public
    {
        uint256 spendable = approved < SUPPLY ? approved : SUPPLY;
        moved = bound(moved, 0, spendable);
        burned = bound(burned, 0, spendable - moved);
        _submitPermit(spender, approved, 0, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, moved));
        vm.prank(spender);
        token.burnFrom(holder, burned);
        assertEq(token.balanceOf(holder), SUPPLY - moved - burned);
        assertEq(token.balanceOf(recipient), moved);
        assertEq(token.totalSupply(), SUPPLY - burned);
        assertEq(token.allowance(holder, spender), approved == type(uint256).max ? approved : approved - moved - burned);
        assertEq(token.nonces(holder), 1);
        assertEq(token.nonces(spender), 0);
    }

    function _submitPermit(address approved, uint256 amount, uint256 nonce, uint256 deadline) internal {
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(approved, amount, nonce, deadline);
        vm.prank(outsider);
        token.permit(holder, approved, amount, deadline, v, r, s);
    }

    function _assertPermitState(uint256 allowance, uint256 nonce) internal view {
        assertEq(token.allowance(holder, spender), allowance, "unexpected allowance");
        assertEq(token.nonces(holder), nonce, "unexpected nonce");
        assertEq(token.nonces(spender), 0);
        _assertInitialBalances();
    }
}
