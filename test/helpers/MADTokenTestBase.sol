// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MADToken} from "src/MADToken.sol";

abstract contract MADTokenTestBase is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    MADToken internal token;
    address internal holder;
    uint256 internal holderKey;
    address internal spender;
    address internal recipient;
    address internal outsider;

    function setUp() public virtual {
        (holder, holderKey) = makeAddrAndKey("MAD test holder");
        spender = makeAddr("MAD test spender");
        recipient = makeAddr("MAD test recipient");
        outsider = makeAddr("MAD test outsider");
        vm.prank(holder);
        token = new MADToken();
    }

    // Build the domain independently of DOMAIN_SEPARATOR(), so signing tests can
    // catch a token that uses the wrong name, version, chain, or verifying contract.
    function _domain(address verifyingContract, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Mutually Assured Destruction")),
                keccak256(bytes("1")),
                chainId,
                verifyingContract
            )
        );
    }

    function _digest(bytes32 domain, address owner, address approved, uint256 value, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                hex"1901", domain, keccak256(abi.encode(PERMIT_TYPEHASH, owner, approved, value, nonce, deadline))
            )
        );
    }

    function _signPermit(address approved, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        return vm.sign(
            holderKey, _digest(_domain(address(token), block.chainid), holder, approved, value, nonce, deadline)
        );
    }

    function _approve(uint256 value) internal {
        vm.prank(holder);
        assertTrue(token.approve(spender, value));
    }

    function _assertInitialBalances() internal view {
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        assertEq(token.balanceOf(holder), SUPPLY, "holder balance changed");
        assertEq(token.balanceOf(spender), 0, "spender received tokens");
        assertEq(token.balanceOf(recipient), 0, "recipient received tokens");
        assertEq(token.balanceOf(outsider), 0, "outsider received tokens");
        assertEq(token.balanceOf(address(0)), 0, "zero address received tokens");
        assertEq(token.balanceOf(address(token)), 0, "token received tokens");
    }
}
