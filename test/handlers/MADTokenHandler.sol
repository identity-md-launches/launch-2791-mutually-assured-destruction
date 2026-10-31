// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {MADToken} from "src/MADToken.sol";

/// @dev All token movements stay among four signers and the token itself (a passive
/// recipient). No balance/storage cheatcodes are used. The model starts from the
/// required constructor supply and changes only by requested successful actions;
/// it is never resynchronized to balanceOf/allowance/nonces from the implementation.
contract MADTokenHandler is Test {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 public constant ACTOR_COUNT = 4;
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    MADToken public immutable token;
    bytes32 private immutable domain;
    address[4] public actors;
    mapping(address => uint256) private keys;

    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    mapping(address => uint256) public expectedNonce;
    uint256 public totalBurned;
    uint256 public positiveTransfers;
    uint256 public positiveBurns;
    uint256 public successfulPermits;
    uint256 public expectedReverts;

    constructor() {
        token = new MADToken();
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY);
        domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Mutually Assured Destruction")),
                keccak256(bytes("1")),
                block.chainid,
                address(token)
            )
        );
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            (address actor, uint256 key) = makeAddrAndKey(string.concat("MAD invariant actor ", vm.toString(i)));
            actors[i] = actor;
            keys[actor] = key;
            assertTrue(token.transfer(actor, INITIAL_SUPPLY / ACTOR_COUNT));
            expectedBalance[actor] = INITIAL_SUPPLY / ACTOR_COUNT;
        }
        // Start with both finite and infinite approvals, while leaving most pairs
        // unapproved. Delegated actions can do real work even early in a sequence.
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            _approve(actors[i], actors[(i + 1) % ACTOR_COUNT], i == 0 ? type(uint256).max : INITIAL_SUPPLY / 16);
        }
    }

    function transfer(uint256 ownerSeed, uint256 recipientSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address to = _recipient(recipientSeed);
        _transfer(owner, to, _amount(amountSeed, expectedBalance[owner]));
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), _approvalAmount(amountSeed));
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 recipientSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _recipient(recipientSeed);
        uint256 amount = _amount(amountSeed, _spendable(owner, spender));
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        _spendAllowance(owner, spender, amount);
        _move(owner, to, amount);
    }

    function burn(uint256 ownerSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[owner]);
        vm.prank(owner);
        token.burn(amount);
        _destroy(owner, amount);
    }

    function burnFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = _amount(amountSeed, _spendable(owner, spender));
        vm.prank(spender);
        token.burnFrom(owner, amount);
        _spendAllowance(owner, spender, amount);
        _destroy(owner, amount);
    }

    function permitAndReplay(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = _approvalAmount(amountSeed);
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _sign(owner, spender, amount, deadline, keys[owner]);
        // This handler is a relayer; it is neither the owner nor the spender.
        token.permit(owner, spender, amount, deadline, v, r, s);
        expectedAllowance[owner][spender] = amount;
        expectedNonce[owner]++;
        successfulPermits++;

        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(owner, spender, amount, deadline, v, r, s);
        expectedReverts++;
    }

    function roundTrip(uint256 ownerSeed, uint256 otherSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address other = _actor(otherSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[owner]);
        uint256 ownerBefore = token.balanceOf(owner);
        uint256 otherBefore = token.balanceOf(other);
        uint256 supplyBefore = token.totalSupply();
        _transfer(owner, other, amount);
        _transfer(other, owner, amount);
        assertEq(token.balanceOf(owner), ownerBefore, "round trip changed sender balance");
        assertEq(token.balanceOf(other), otherBefore, "round trip changed recipient balance");
        assertEq(token.totalSupply(), supplyBefore, "round trip changed supply");
    }

    function rejectOverBalance(uint256 ownerSeed, uint256 amountSeed, uint8 operation) external {
        uint256 index = bound(ownerSeed, 0, ACTOR_COUNT - 1);
        address owner = actors[index];
        address spender = actors[(index + 1) % ACTOR_COUNT];
        uint256 balance = expectedBalance[owner];
        uint256 amount = bound(amountSeed, balance + 1, type(uint256).max);
        operation = uint8(bound(operation, 0, 3));
        // The delegated failure must reach the balance check, after allowance
        // spending. The global model then verifies that spending was rolled back.
        if (operation >= 2) _approve(owner, spender, amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount));
        vm.prank(operation < 2 ? owner : spender);
        if (operation == 0) token.transfer(spender, amount);
        else if (operation == 1) token.burn(amount);
        else if (operation == 2) token.transferFrom(owner, spender, amount);
        else token.burnFrom(owner, amount);
        expectedReverts++;
    }

    function rejectUnauthorized(uint256 ownerSeed, uint256 spenderSeed, bool useBurn) external {
        uint256 index = bound(ownerSeed, 0, ACTOR_COUNT - 1);
        address owner = actors[index];
        address spender = actors[(index + 1 + bound(spenderSeed, 0, ACTOR_COUNT - 2)) % ACTOR_COUNT];
        _approve(owner, spender, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        if (useBurn) token.burnFrom(owner, 1);
        else token.transferFrom(owner, spender, 1);
        expectedReverts++;
    }

    function rejectZeroReceiver(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[owner]);
        _approve(owner, spender, amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(owner, address(0), amount);
        expectedReverts++;
    }

    function rejectPermit(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, uint8 kind) external {
        uint256 index = bound(ownerSeed, 0, ACTOR_COUNT - 1);
        address owner = actors[index];
        address spender = _actor(spenderSeed);
        uint256 amount = _approvalAmount(amountSeed);
        kind = uint8(bound(kind, 0, 2));
        uint256 deadline = kind == 0 ? vm.getBlockTimestamp() - 1 : vm.getBlockTimestamp() + 1 days;
        address signer = kind == 1 ? actors[(index + 1) % ACTOR_COUNT] : owner;
        if (kind == 2) spender = address(0);
        (uint8 v, bytes32 r, bytes32 s) = _sign(owner, spender, amount, deadline, keys[signer]);
        if (kind == 0) {
            vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        } else if (kind == 1) {
            vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, signer, owner));
        } else {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        }
        token.permit(owner, spender, amount, deadline, v, r, s);
        expectedReverts++;
    }

    function rejectAdminCall(uint256 callerSeed, uint8 kind) external {
        kind = uint8(bound(kind, 0, 3));
        bytes memory data;
        if (kind == 0) data = abi.encodeWithSignature("mint(address,uint256)", actors[0], 1);
        else if (kind == 1) data = abi.encodeWithSignature("pause()");
        else if (kind == 2) data = abi.encodeWithSignature("freeze(address)", actors[0]);
        else data = abi.encodeWithSignature("initialize(address)", actors[0]);
        // Include the original contract deployer as well as ordinary holders.
        address caller = callerSeed % 2 == 0 ? address(this) : _actor(callerSeed);
        vm.prank(caller);
        (bool success,) = address(token).call(data);
        assertFalse(success, "an administrative entry point succeeded");
        expectedReverts++;
    }

    function advanceTime(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 1, 30 days));
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[bound(seed, 0, ACTOR_COUNT - 1)];
    }

    function _recipient(uint256 seed) private view returns (address) {
        uint256 index = bound(seed, 0, ACTOR_COUNT);
        return index == ACTOR_COUNT ? address(token) : actors[index];
    }

    // Deliberately weight zero, one wei, and full balances alongside general values.
    function _amount(uint256 seed, uint256 limit) private pure returns (uint256) {
        if (seed % 8 == 0) return 0;
        if (seed % 8 == 1) return limit == 0 ? 0 : 1;
        if (seed % 8 == 2) return limit;
        return bound(seed, 0, limit);
    }

    function _approvalAmount(uint256 seed) private pure returns (uint256) {
        if (seed % 8 == 0) return 0;
        if (seed % 8 == 1) return type(uint256).max;
        if (seed % 8 == 2) return type(uint256).max - 1;
        return bound(seed, 0, INITIAL_SUPPLY);
    }

    function _spendable(address owner, address spender) private view returns (uint256) {
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 balance = expectedBalance[owner];
        return allowance < balance ? allowance : balance;
    }

    function _approve(address owner, address spender, uint256 amount) private {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function _transfer(address owner, address to, uint256 amount) private {
        vm.prank(owner);
        assertTrue(token.transfer(to, amount));
        _move(owner, to, amount);
    }

    function _move(address owner, address to, uint256 amount) private {
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (amount > 0) positiveTransfers++;
    }

    function _spendAllowance(address owner, address spender, uint256 amount) private {
        if (expectedAllowance[owner][spender] != type(uint256).max) expectedAllowance[owner][spender] -= amount;
    }

    function _destroy(address owner, uint256 amount) private {
        expectedBalance[owner] -= amount;
        totalBurned += amount;
        if (amount > 0) positiveBurns++;
    }

    function _sign(address owner, address spender, uint256 amount, uint256 deadline, uint256 key)
        private
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, amount, expectedNonce[owner], deadline));
        return vm.sign(key, keccak256(abi.encodePacked(hex"1901", domain, structHash)));
    }
}
