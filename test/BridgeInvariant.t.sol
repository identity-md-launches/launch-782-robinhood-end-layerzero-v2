// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BridgeFixture} from "./helpers/BridgeFixture.sol";
import {BridgeHandler} from "./helpers/BridgeHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract BridgeInvariantTest is BridgeFixture {
    BridgeHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new BridgeHandler(token, endpoint, messageLib);
        // Seed via verified packets so transfers/burns are reachable from call one.
        for (uint256 i; i < 4; ++i) {
            handler.verifyInbound(i, 10e6, false);
            handler.executeInbound(i);
        }
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.verifyInbound.selector;
        selectors[1] = handler.executeInbound.selector;
        selectors[2] = handler.tamperInbound.selector;
        selectors[3] = handler.unverifiedReceive.selector;
        selectors[4] = handler.unauthorizedReceive.selector;
        selectors[5] = handler.transfer.selector;
        selectors[6] = handler.approve.selector;
        selectors[7] = handler.transferFrom.selector;
        selectors[8] = handler.send.selector;
        selectors[9] = handler.rejectedSend.selector;
        selectors[10] = handler.rejectedTransferFrom.selector;
        selectors[11] = handler.rejectedAdministration.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantSupplyEqualsExecutedCreditsLessSuccessfulBurns() public view {
        assertLe(handler.burned(), handler.credited());
        assertEq(token.totalSupply() + handler.burned(), handler.credited());
        assertEq(token.totalSupply() % RATE, 0);
    }

    function invariantEveryBalanceAndAllowanceMatchesIndependentLedger() public view {
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            address account = handler.accounts(i);
            uint256 balance = token.balanceOf(account);
            assertEq(balance, handler.expectedBalance(account), "account balance differs from ledger");
            sum += balance;
            if (i < 4) {
                for (uint256 j; j < 4; ++j) {
                    address spender = handler.accounts(j);
                    assertEq(token.allowance(account, spender), handler.expectedAllowance(account, spender));
                }
            }
        }
        assertEq(sum, token.totalSupply(), "supply escaped the accounting universe");
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariantOnlySuccessfulSendsAdvanceNonceAndPayFees() public view {
        assertEq(endpoint.outboundNonce(address(token), ETHEREUM_EID, PEER), handler.sends());
        assertEq(address(messageLib).balance, handler.sends() * FEE);
        // This campaign supplies ETH only as send fees, never as receive value
        // or forced donations, so neither the OFT nor endpoint should retain it.
        assertEq(address(token).balance, 0);
        assertEq(ENDPOINT.balance, 0);
        assertFalse(messageLib.failSend());
    }

    function invariantSinglePeerAndVerifiedPathRemainIntact() public view {
        assertEq(token.owner(), OWNER);
        assertEq(endpoint.delegates(address(token)), OWNER);
        assertEq(token.peers(ETHEREUM_EID), PEER);
        assertEq(token.peers(LOCAL_EID), bytes32(0));
        assertTrue(token.isPeer(ETHEREUM_EID, PEER));
        assertFalse(token.isPeer(LOCAL_EID, bytes32(0)));
        assertEq(token.msgInspector(), address(0));
        assertEq(endpoint.inboundNonce(address(token), ETHEREUM_EID, PEER), handler.packetCount());
    }

    // Deterministic reachability check for the handler: positive transfers,
    // finite/infinite approvals, a dust balance, both compose directions,
    // out-of-order execution, replay, and all send failure branches.
    function testHandlerExercisesFundedSequencesAndFailureModes() public {
        handler.verifyInbound(0, type(uint64).max, true);
        handler.verifyInbound(6, 1, true);
        handler.executeInbound(5);
        handler.executeInbound(4);
        handler.executeInbound(4);
        handler.transfer(0, 1, 123);
        handler.approve(1, 2, 456, false);
        handler.transferFrom(1, 2, 3, 456);
        handler.approve(0, 1, 0, true);
        handler.transferFrom(0, 1, 0, 789);
        handler.send(1, 0, true, true);
        handler.send(0, 0, true, false);
        for (uint8 mode; mode < 5; ++mode) {
            handler.rejectedSend(2, 1 ether, mode);
        }
        this.invariantSupplyEqualsExecutedCreditsLessSuccessfulBurns();
        this.invariantEveryBalanceAndAllowanceMatchesIndependentLedger();
        this.invariantOnlySuccessfulSendsAdvanceNonceAndPayFees();
        this.invariantSinglePeerAndVerifiedPathRemainIntact();
        assertEq(handler.sends(), 2);
        assertGt(handler.burned(), 0);
        assertEq(token.balanceOf(BOB), RATE - 333);
    }
}
