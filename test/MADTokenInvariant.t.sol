// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MADToken} from "src/MADToken.sol";
import {MADTokenHandler} from "./handlers/MADTokenHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract MADTokenInvariantTest is StdInvariant, Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    MADTokenHandler private handler;
    MADToken private token;

    function setUp() public {
        vm.warp(1_000_000);
        handler = new MADTokenHandler();
        token = handler.token();

        // Only stateful actions are fuzz targets: inherited Test cheatcodes and
        // the model's public getters must never become random calls.
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.burn.selector;
        selectors[4] = handler.burnFrom.selector;
        selectors[5] = handler.permitAndReplay.selector;
        selectors[6] = handler.roundTrip.selector;
        selectors[7] = handler.rejectOverBalance.selector;
        selectors[8] = handler.rejectUnauthorized.selector;
        selectors[9] = handler.rejectZeroReceiver.selector;
        selectors[10] = handler.rejectPermit.selector;
        selectors[11] = handler.rejectAdminCall.selector;
        selectors[12] = handler.advanceTime.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_supplyEqualsInitialSupplyMinusAuthorizedBurns() public view {
        assertLe(token.totalSupply(), SUPPLY, "supply grew after construction");
        assertEq(token.totalSupply() + handler.totalBurned(), SUPPLY, "unaccounted mint or burn");
    }

    function invariant_balancesMatchIndependentLedgerAndSumToSupply() public view {
        uint256 sum;
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.expectedBalance(actor), "holder balance differs from authorized movements");
            sum += balance;
        }
        // Tokens sent to the token contract are balances too. Do not silently
        // exclude this passive sink from the conservation equation.
        uint256 tokensHeldByToken = token.balanceOf(address(token));
        assertEq(tokensHeldByToken, handler.expectedBalance(address(token)));
        assertEq(sum + tokensHeldByToken, token.totalSupply(), "sum of balances differs from total supply");
        assertEq(token.balanceOf(address(0)), 0, "zero address has a balance");
        assertEq(token.balanceOf(address(handler)), 0, "deployer regained tokens");
    }

    function invariant_allowancesAndNoncesMatchAuthorizedOperations() public view {
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address owner = handler.actors(i);
            assertEq(token.nonces(owner), handler.expectedNonce(owner), "nonce changed outside successful permit");
            assertEq(token.allowance(owner, address(0)), 0);
            for (uint256 j; j < handler.ACTOR_COUNT(); ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.expectedAllowance(owner, spender),
                    "allowance differs from approvals and successful spending"
                );
            }
        }
    }

    // A fixed smoke sequence proves that the generators reach nonzero transfers,
    // delegated spending, burns, permits, donations, and the intentional reverts.
    // Random sequences above run these same actions in arbitrary orders.
    function test_handlerExercisesMeaningfulStateTransitions() public {
        handler.transfer(0, 1, 1);
        handler.approve(0, 1, 1); // infinite
        handler.transferFrom(0, 1, 2, 1);
        handler.burn(2, 1);
        handler.burnFrom(0, 1, 1);
        handler.permitAndReplay(1, 2, 3); // finite approval of three wei
        handler.transferFrom(1, 2, 3, 1);
        handler.burnFrom(1, 2, 1);
        handler.roundTrip(2, 3, 2); // full balance
        handler.transfer(3, 4, 1); // token contract is a passive recipient
        handler.rejectOverBalance(0, type(uint256).max, 0);
        handler.rejectOverBalance(1, type(uint256).max, 1);
        handler.rejectOverBalance(2, SUPPLY, 2);
        handler.rejectOverBalance(3, SUPPLY, 3);
        handler.rejectUnauthorized(0, 1, false);
        handler.rejectUnauthorized(1, 2, true);
        handler.rejectZeroReceiver(2, 3, 1);
        handler.rejectPermit(0, 1, 3, 0);
        handler.rejectPermit(1, 2, 3, 1);
        handler.rejectPermit(2, 3, 3, 2);
        handler.rejectAdminCall(0, 0);
        handler.rejectAdminCall(1, 1);
        handler.advanceTime(30 days);

        assertGt(handler.positiveTransfers(), 0);
        assertGt(handler.positiveBurns(), 0);
        assertEq(handler.successfulPermits(), 1);
        assertEq(handler.expectedReverts(), 13);
        invariant_supplyEqualsInitialSupplyMinusAuthorizedBurns();
        invariant_balancesMatchIndependentLedgerAndSumToSupply();
        invariant_allowancesAndNoncesMatchAuthorizedOperations();
    }
}
