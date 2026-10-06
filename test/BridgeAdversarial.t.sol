// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BridgeFixture, FeeTokenFixture} from "./helpers/BridgeFixture.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {Errors} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/Errors.sol";
import {Transfer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/Transfer.sol";
import {SendParam, MessagingFee, OFTReceipt, IOFT} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {
    IOAppPreCrimeSimulator,
    InboundPacket
} from "@layerzerolabs/oapp-evm/contracts/precrime/interfaces/IOAppPreCrimeSimulator.sol";

contract RejectBridgeRefund {
    receive() external payable {
        revert("refund rejected");
    }
}

/// forge-config: default.fuzz.runs = 1000
contract BridgeAdversarialTest is BridgeFixture {
    function testFuzzPeerComparisonUsesAllBytes(uint96 prefix) public {
        prefix = uint96(bound(prefix, 1, type(uint96).max));
        bytes32 disguisedPeer = PEER | bytes32(uint256(prefix) << 160);
        Origin memory origin = Origin(ETHEREUM_EID, disguisedPeer, 1);
        assertFalse(token.isPeer(ETHEREUM_EID, disguisedPeer));
        assertFalse(token.allowInitializePath(origin));
        vm.prank(ENDPOINT);
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.OnlyPeer.selector, ETHEREUM_EID, disguisedPeer));
        token.lzReceive(origin, bytes32(0), _message(ALICE, 1), EXECUTOR, "");
        vm.expectRevert(Errors.LZ_PathNotInitializable.selector);
        messageLib.verify(origin, address(token), keccak256("forged peer"));
        assertEq(token.totalSupply(), 0);
    }

    function testFuzzEveryOtherEndpointIdRejectsReceiveAndSend(uint32 eid) public {
        if (eid == ETHEREUM_EID) eid = 0;
        Origin memory origin = Origin(eid, PEER, 1);
        assertFalse(token.allowInitializePath(origin));
        assertFalse(token.isPeer(eid, PEER));
        assertFalse(token.isPeer(eid, bytes32(0)));
        vm.prank(ENDPOINT);
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.NoPeer.selector, eid));
        token.lzReceive(origin, bytes32(0), _message(ALICE, 1), EXECUTOR, "");
        _deliver(ALICE, 1);
        SendParam memory p = _params(RATE, RATE);
        p.dstEid = eid;
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.NoPeer.selector, eid));
        token.quoteSend(p, false);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.NoPeer.selector, eid));
        token.send{value: FEE}(p, MessagingFee(FEE, 0), ALICE);
        assertEq(token.balanceOf(ALICE), RATE);
        assertEq(token.totalSupply(), RATE);
        assertEq(endpoint.outboundNonce(address(token), eid, bytes32(0)), 0);
    }

    function testFuzzTruncatedVerifiedPayloadPreservesCreditAndCanBeReverified(uint8 length, bytes32 contents) public {
        _deliver(BOB, 7);
        length = uint8(bound(length, 0, 39));
        bytes memory malformed = new bytes(length);
        for (uint256 i; i < length; ++i) {
            malformed[i] = contents[i % 32];
        }
        bytes32 guid = keccak256("truncated packet");
        bytes32 payloadHash = keccak256(abi.encodePacked(guid, malformed));
        _verify(_origin(2), guid, malformed);
        vm.expectRevert(); // Solidity calldata slicing rejects every payload shorter than 40 bytes.
        endpoint.lzReceive(_origin(2), address(token), guid, malformed, "");
        assertEq(token.totalSupply(), 7 * RATE);
        assertEq(token.balanceOf(BOB), 7 * RATE);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(endpoint.lazyInboundNonce(address(token), ETHEREUM_EID, PEER), 1);
        assertEq(endpoint.inboundPayloadHash(address(token), ETHEREUM_EID, PEER, 2), payloadHash);

        bytes memory corrected = _message(ALICE, 1);
        _verify(_origin(2), guid, corrected);
        endpoint.lzReceive(_origin(2), address(token), guid, corrected, "");
        assertEq(token.totalSupply(), 8 * RATE);
        assertEq(token.balanceOf(ALICE), RATE);
        assertEq(endpoint.inboundPayloadHash(address(token), ETHEREUM_EID, PEER, 2), bytes32(0));
    }

    function testFuzzDustSplitRecombineAndBurnConservesAllCredits(uint64 amountSD, uint256 dust) public {
        amountSD = uint64(bound(amountSD, 1, type(uint64).max));
        dust = bound(dust, 1, RATE - 1);
        uint256 initial = uint256(amountSD) * RATE;
        _deliver(ALICE, amountSD);
        vm.prank(ALICE);
        token.transfer(BOB, dust);

        SendParam memory p = _params(initial - dust, 0);
        (,, OFTReceipt memory quoted) = token.quoteOFT(p);
        vm.prank(ALICE);
        (, OFTReceipt memory first) = token.send{value: FEE}(p, MessagingFee(FEE, 0), ALICE);
        assertEq(first.amountSentLD, quoted.amountSentLD);
        assertEq(first.amountReceivedLD, first.amountSentLD);
        assertEq(first.amountSentLD, uint256(amountSD - 1) * RATE);
        assertEq(token.balanceOf(ALICE), RATE - dust);
        assertEq(token.balanceOf(BOB), dust);

        vm.prank(BOB);
        (, OFTReceipt memory subUnit) = token.send{value: FEE}(_params(dust, 0), MessagingFee(FEE, 0), BOB);
        assertEq(subUnit.amountSentLD, 0);
        assertEq(token.balanceOf(BOB), dust, "sub-unit send lost dust");
        vm.prank(BOB);
        token.transfer(ALICE, dust);
        vm.prank(ALICE);
        (, OFTReceipt memory last) = token.send{value: FEE}(_params(RATE, RATE), MessagingFee(FEE, 0), ALICE);
        assertEq(first.amountSentLD + subUnit.amountSentLD + last.amountSentLD, initial);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(OWNER), 0);
    }

    function testFuzzMinimumOneWeiAboveRepresentableAmountAlwaysReverts(uint64 amountSD, uint256 dust) public {
        dust = bound(dust, 1, RATE - 1);
        uint256 representable = uint256(amountSD) * RATE;
        _deliver(ALICE, amountSD);
        _deliver(ALICE, 1);
        SendParam memory p = _params(representable + dust, representable + 1);
        bytes memory reason = abi.encodeWithSelector(IOFT.SlippageExceeded.selector, representable, representable + 1);
        vm.expectRevert(reason);
        token.quoteOFT(p);
        vm.expectRevert(reason);
        token.quoteSend(p, false);
        vm.prank(ALICE);
        vm.expectRevert(reason);
        token.send{value: FEE}(p, MessagingFee(FEE, 0), ALICE);
        assertEq(token.totalSupply(), representable + RATE);
        assertEq(token.balanceOf(ALICE), representable + RATE);
        assertEq(endpoint.outboundNonce(address(token), ETHEREUM_EID, PEER), 0);
    }

    function testFuzzOversizedQuoteNeverTruncatesSharedAmount(uint256 amount) public {
        amount = bound(amount, (uint256(type(uint64).max) + 1) * RATE, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IOFT.AmountSDOverflowed.selector, amount / RATE));
        token.quoteSend(_params(amount, 0), false);
        assertEq(token.totalSupply(), 0);
    }

    function testMaximumSharedAmountPlusDustDoesNotOverflowOrBurnDust() public {
        _deliver(ALICE, type(uint64).max);
        _deliver(ALICE, 1);
        uint256 maximum = uint256(type(uint64).max) * RATE;
        SendParam memory p = _params(maximum + RATE - 1, maximum);
        MessagingFee memory fee = token.quoteSend(p, false);
        vm.prank(ALICE);
        (, OFTReceipt memory receipt) = token.send{value: FEE}(p, fee, ALICE);
        assertEq(receipt.amountSentLD, maximum);
        assertEq(receipt.amountReceivedLD, maximum);
        assertEq(messageLib.packet().message, _message(BOB, type(uint64).max));
        assertEq(token.balanceOf(ALICE), RATE);
        assertEq(token.totalSupply(), RATE);
    }

    function testZeroAndOneWeiSendsCannotCreateSupply() public {
        for (uint256 amount; amount <= 1; ++amount) {
            vm.prank(ALICE);
            (, OFTReceipt memory receipt) = token.send{value: FEE}(_params(amount, 0), MessagingFee(FEE, 0), ALICE);
            assertEq(receipt.amountSentLD, 0);
            assertEq(receipt.amountReceivedLD, 0);
            assertEq(messageLib.packet().message, _message(BOB, 0));
            assertEq(token.totalSupply(), 0);
            assertEq(token.balanceOf(ALICE), 0);
        }
        assertEq(endpoint.outboundNonce(address(token), ETHEREUM_EID, PEER), 2);
        assertEq(address(messageLib).balance, 2 * FEE);
    }

    function testRejectedRefundRollsBackBurnFeeNonceAndPacketThenAllowsRetry() public {
        RejectBridgeRefund refund = new RejectBridgeRefund();
        _deliver(ALICE, 1e6);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Transfer.Transfer_NativeFailed.selector, address(refund), FEE));
        token.send{value: 2 * FEE}(_params(1 ether, 1 ether), MessagingFee(2 * FEE, 0), address(refund));
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(token.totalSupply(), 1 ether);
        assertEq(ALICE.balance, 10 ether);
        assertEq(address(messageLib).balance, 0);
        assertEq(ENDPOINT.balance, 0);
        assertEq(address(token).balance, 0);
        assertEq(endpoint.outboundNonce(address(token), ETHEREUM_EID, PEER), 0);
        assertEq(messageLib.packet().nonce, 0);
        assertEq(messageLib.packet().message.length, 0);
        vm.prank(ALICE);
        token.send{value: 2 * FEE}(_params(1 ether, 1 ether), MessagingFee(2 * FEE, 0), ALICE);
        assertEq(token.totalSupply(), 0);
        assertEq(ALICE.balance, 10 ether - FEE);
        assertEq(endpoint.outboundNonce(address(token), ETHEREUM_EID, PEER), 1);
    }

    function testUnderpaidLzTokenRestoresFeeBalanceAllowanceAndBurn() public {
        FeeTokenFixture feeToken = new FeeTokenFixture();
        endpoint.setLzToken(address(feeToken));
        feeToken.mint(ALICE, 1 ether);
        _deliver(ALICE, 1e6);
        vm.prank(ALICE);
        feeToken.approve(address(token), 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Errors.LZ_InsufficientFee.selector, FEE, FEE, 1 ether, 1 ether - 1));
        token.send{value: FEE}(_params(1 ether, 1 ether), MessagingFee(FEE, 1 ether - 1), BOB);
        assertEq(feeToken.balanceOf(ALICE), 1 ether);
        assertEq(feeToken.allowance(ALICE, address(token)), 1 ether);
        assertEq(feeToken.balanceOf(ENDPOINT), 0);
        assertEq(feeToken.balanceOf(address(messageLib)), 0);
        assertEq(feeToken.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(token.totalSupply(), 1 ether);
        assertEq(ALICE.balance, 10 ether);
        assertEq(endpoint.outboundNonce(address(token), ETHEREUM_EID, PEER), 0);
        vm.prank(ALICE);
        token.send{value: FEE}(_params(1 ether, 1 ether), MessagingFee(FEE, 1 ether), ALICE);
        assertEq(feeToken.balanceOf(address(messageLib)), 1 ether);
        assertEq(token.totalSupply(), 0);
    }

    function testRejectedTransferFromRestoresFiniteAllowance() public {
        _deliver(ALICE, 1);
        vm.prank(ALICE);
        token.approve(BOB, 2 * RATE);
        vm.prank(BOB);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        token.transferFrom(ALICE, BOB, RATE + 1);
        assertEq(token.allowance(ALICE, BOB), 2 * RATE);
        assertEq(token.balanceOf(ALICE), RATE);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), RATE);
        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, RATE);
        assertEq(token.allowance(ALICE, BOB), RATE);
        assertEq(token.balanceOf(BOB), RATE);
    }

    function testSimulationRollsBackCreditAndComposeQueueWithoutConsumingVerifiedPacket() public {
        bytes32 guid = keccak256("simulation compose");
        bytes memory message = bytes.concat(_message(address(this), 3), abi.encodePacked(PEER, hex"cafe"));
        _verify(_origin(1), guid, message);
        InboundPacket[] memory packets = new InboundPacket[](1);
        packets[0] = InboundPacket(_origin(1), LOCAL_EID, address(token), guid, 0, EXECUTOR, message, "");
        vm.expectRevert(abi.encodeWithSelector(IOAppPreCrimeSimulator.SimulationResult.selector, hex"beef"));
        token.lzReceiveAndRevert(packets);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(endpoint.composeQueue(address(token), address(this), guid, 0), bytes32(0));
        assertEq(endpoint.outboundNonce(address(token), ETHEREUM_EID, PEER), 0);
        assertEq(address(messageLib).balance, 0);
        assertEq(address(this).balance, 10 ether);
        assertEq(endpoint.lazyInboundNonce(address(token), ETHEREUM_EID, PEER), 0);
        assertEq(
            endpoint.inboundPayloadHash(address(token), ETHEREUM_EID, PEER, 1),
            keccak256(abi.encodePacked(guid, message))
        );
        endpoint.lzReceive(_origin(1), address(token), guid, message, "");
        assertEq(token.balanceOf(address(this)), 3 * RATE);
        assertEq(token.totalSupply(), 3 * RATE);
        assertEq(endpoint.inboundPayloadHash(address(token), ETHEREUM_EID, PEER, 1), bytes32(0));
    }

    function buildSimulationResult() external view returns (bytes memory) {
        assertEq(msg.sender, address(token));
        assertEq(token.balanceOf(address(this)), 3 * RATE, "simulation must reach the credit");
        bytes memory expected = abi.encodePacked(uint64(1), ETHEREUM_EID, uint256(3 * RATE), PEER, hex"cafe");
        assertEq(
            endpoint.composeQueue(address(token), address(this), keccak256("simulation compose"), 0),
            keccak256(expected),
            "simulation must reach the compose queue"
        );
        return hex"beef";
    }
}
