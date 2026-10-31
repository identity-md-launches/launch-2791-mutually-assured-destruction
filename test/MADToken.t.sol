// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {MADToken} from "../src/MADToken.sol";
import {DeployMADToken} from "../script/DeployMADToken.s.sol";

/// @notice A contract that deploys the token, to show the supply lands on a contract deployer too.
contract DeployerProbe {
    MADToken public immutable token;

    constructor() {
        token = new MADToken();
    }
}

contract MADTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    MADToken internal token;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    uint256 internal signerKey = 0xA11CE;
    address internal signer;

    function setUp() public {
        signer = vm.addr(signerKey);
        vm.prank(deployer);
        token = new MADToken();
    }

    // ------------------------------------------------------------------
    // Metadata and supply
    // ------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Mutually Assured Destruction");
        assertEq(token.symbol(), "MAD");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "Mutually Assured Destruction");
        assertEq(token.TOKEN_SYMBOL(), "MAD");
        assertEq(token.DECIMALS(), 18);
    }

    function test_supplyConstantsAgree() public view {
        assertEq(token.WHOLE_TOKENS(), 1_000_000_000);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), token.WHOLE_TOKENS() * 10 ** token.decimals());
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), alice, SUPPLY);
        vm.prank(alice);
        new MADToken();
    }

    function test_constructorMintsToAContractDeployer() public {
        DeployerProbe probe = new DeployerProbe();
        assertEq(probe.token().balanceOf(address(probe)), SUPPLY);
        assertEq(probe.token().totalSupply(), SUPPLY);
    }

    function test_deployScriptMintsToItsCaller() public {
        DeployMADToken script = new DeployMADToken();
        MADToken deployed = script.deploy();
        // `deploy()` creates the token from inside the script contract, so the script holds the supply.
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(script)), SUPPLY);
    }

    function test_eachDeploymentIsIndependent() public {
        vm.prank(alice);
        MADToken second = new MADToken();
        assertEq(second.totalSupply(), SUPPLY);
        assertEq(second.balanceOf(alice), SUPPLY);
        assertEq(second.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), 0);
    }

    // ------------------------------------------------------------------
    // No mint, no admin
    // ------------------------------------------------------------------

    function test_noMintOrAdminEntryPointsExist() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "setBlacklist(address,bool)",
            "freeze(address)",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], stranger, type(uint128).max);
            vm.prank(deployer);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(stranger);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(stranger), 0);
    }

    function test_tokenRejectsEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    // ------------------------------------------------------------------
    // Transfers
    // ------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, alice, 100 ether);
        assertTrue(token.transfer(alice, 100 ether));
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 0));
        assertEq(token.balanceOf(alice), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, 5 ether));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferWholeBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferRevertsByOneWeiOverBalance() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
    }

    function test_transferDoesNotTaxAnyParty() public {
        vm.prank(deployer);
        token.transfer(alice, 1000 ether);
        vm.prank(alice);
        token.transfer(bob, 1000 ether);
        vm.prank(bob);
        token.transfer(alice, 1000 ether);
        assertEq(token.balanceOf(alice), 1000 ether);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ------------------------------------------------------------------
    // Allowances and transferFrom
    // ------------------------------------------------------------------

    function test_approveAndTransferFrom() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(deployer, alice, 50 ether);
        assertTrue(token.approve(alice, 50 ether));
        assertEq(token.allowance(deployer, alice), 50 ether);

        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 30 ether));
        assertEq(token.balanceOf(bob), 30 ether);
        assertEq(token.allowance(deployer, alice), 20 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 30 ether);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, alice, 1);
    }

    function test_transferFromRevertsOverAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 10 ether, 11 ether)
        );
        token.transferFrom(deployer, bob, 11 ether);
    }

    function test_transferFromRevertsOverBalanceEvenWithAllowance() public {
        vm.prank(alice);
        token.approve(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1 ether));
        token.transferFrom(alice, bob, 1 ether);
    }

    function test_deployerCannotPullFromHolderWithoutAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    function test_maxAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1 ether);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_approveZeroSpenderReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ------------------------------------------------------------------
    // Burning
    // ------------------------------------------------------------------

    function test_burnReducesSupplyAndBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(alice, address(0), 4 ether);
        token.burn(4 ether);
        assertEq(token.balanceOf(alice), 6 ether);
        assertEq(token.totalSupply(), SUPPLY - 4 ether);
    }

    function test_burnRevertsOverBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.burn(1);
    }

    function test_burnFromSpendsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 3 ether);
        vm.prank(alice);
        token.burnFrom(deployer, 2 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 2 ether);
        assertEq(token.allowance(deployer, alice), 1 ether);
        assertEq(token.totalSupply(), SUPPLY - 2 ether);
    }

    function test_burnFromRevertsWithoutAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.burnFrom(alice, 1);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_supplyNeverReturnsAfterBurn() public {
        vm.prank(deployer);
        token.burn(SUPPLY);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(deployer), 0);
        // Nothing can mint it back.
        vm.prank(deployer);
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", deployer, 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), 0);
    }

    // ------------------------------------------------------------------
    // Permit (ERC-2612)
    // ------------------------------------------------------------------

    function _permitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function test_permitGrantsAllowanceAndBumpsNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(signer, bob, 7 ether, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

        vm.prank(stranger); // anyone may submit a valid permit
        token.permit(signer, bob, 7 ether, deadline, v, r, s);

        assertEq(token.allowance(signer, bob), 7 ether);
        assertEq(token.nonces(signer), 1);
    }

    function test_permitRevertsWhenExpired() public {
        uint256 deadline = vm.getBlockTimestamp() + 1;
        bytes32 digest = _permitDigest(signer, bob, 1 ether, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(signer, bob, 1 ether, deadline, v, r, s);
    }

    function test_permitRevertsOnWrongSigner() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(signer, bob, 1 ether, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, digest);
        address wrong = vm.addr(0xB0B);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, wrong, signer));
        token.permit(signer, bob, 1 ether, deadline, v, r, s);
    }

    function test_permitCannotBeReplayed() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(signer, bob, 1 ether, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        token.permit(signer, bob, 1 ether, deadline, v, r, s);
        vm.expectRevert();
        token.permit(signer, bob, 1 ether, deadline, v, r, s);
        assertEq(token.nonces(signer), 1);
    }

    function test_domainSeparatorBindsChainAndContract() public {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Mutually Assured Destruction")),
                keccak256(bytes("1")),
                block.chainid,
                address(token)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);
        bytes32 before = token.DOMAIN_SEPARATOR();
        vm.chainId(block.chainid + 1);
        assertNotEq(token.DOMAIN_SEPARATOR(), before);
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferOverBalanceReverts(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, amount)
        );
        token.transfer(alice, amount);
    }

    function testFuzz_transferFromWithinAllowance(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, SUPPLY);
        amount = bound(amount, 0, allowance);
        vm.prank(deployer);
        token.approve(alice, allowance);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, amount));
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.allowance(deployer, alice), allowance - amount);
    }

    function testFuzz_transferFromOverAllowanceReverts(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, SUPPLY - 1);
        amount = bound(amount, allowance + 1, SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowance);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowance, amount)
        );
        token.transferFrom(deployer, bob, amount);
    }

    function testFuzz_burnOnlyShrinksSupply(uint256 held, uint256 burned) public {
        held = bound(held, 0, SUPPLY);
        burned = bound(burned, 0, held);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        token.burn(burned);
        assertEq(token.balanceOf(alice), held - burned);
        assertEq(token.totalSupply(), SUPPLY - burned);
        assertLe(token.totalSupply(), SUPPLY);
    }

    function testFuzz_strangerCannotMoveHolderBalance(address holder, uint256 held) public {
        vm.assume(holder != address(0) && holder != deployer && holder != stranger);
        held = bound(held, 1, SUPPLY);
        vm.prank(deployer);
        token.transfer(holder, held);
        vm.prank(stranger);
        vm.expectRevert();
        token.transferFrom(holder, stranger, 1);
        vm.prank(stranger);
        vm.expectRevert();
        token.burnFrom(holder, 1);
        assertEq(token.balanceOf(holder), held);
    }
}
