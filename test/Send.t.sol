// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BridgeFixture, MessageLibFixture, FeeTokenFixture, Packet} from "./helpers/BridgeFixture.sol";
import {
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt,
    OFTLimit,
    OFTFeeDetail,
    IOFT
} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {OAppSender} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {Errors} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/Errors.sol";
import {ZeroToOne} from "../src/ZeroToOne.sol";

contract RefundReentry {
    ZeroToOne private immutable token;
    bool public attempted;
    bool public succeeded;
    bytes public failure;

    constructor(ZeroToOne token_) {
        token = token_;
    }

    receive() external payable {
        attempted = true;
        SendParam memory p = SendParam(30101, bytes32(uint256(uint160(address(this)))), 1 ether, 1 ether, "", "", "");
        (succeeded, failure) = address(token).call{value: 0.001 ether}(
            abi.encodeCall(token.send, (p, MessagingFee(0.001 ether, 0), address(this)))
        );
    }
}

contract SendTest is BridgeFixture {
    event OFTSent(
        bytes32 indexed guid, uint32 dstEid, address indexed fromAddress, uint256 amountSentLD, uint256 amountReceivedLD
    );

    function testSendBurnsCallerAndEncodesPeerRecipientAndSharedAmount() public {
        _deliver(ALICE, 10e6);
        SendParam memory p = _params(3 ether, 3 ether);
        MessagingFee memory fee = token.quoteSend(p, false);
        assertEq(fee.nativeFee, FEE);
        assertEq(fee.lzTokenFee, 0);
        assertEq(token.allowance(ALICE, address(token)), 0);
        vm.prank(ALICE);
        (MessagingReceipt memory receipt, OFTReceipt memory oftReceipt) = token.send{value: FEE}(p, fee, ALICE);
        assertEq(token.balanceOf(ALICE), 7 ether);
        assertEq(token.totalSupply(), 7 ether);
        assertEq(token.balanceOf(OWNER), 0);
        assertEq(oftReceipt.amountSentLD, 3 ether);
        assertEq(oftReceipt.amountReceivedLD, 3 ether);
        Packet memory packet = messageLib.packet();
        assertEq(packet.receiver, PEER);
        assertEq(packet.dstEid, ETHEREUM_EID);
        assertEq(packet.srcEid, LOCAL_EID);
        assertEq(packet.sender, address(token));
        assertEq(packet.message, _message(BOB, 3e6));
        assertEq(receipt.guid, packet.guid);
        assertEq(receipt.nonce, 1);
        assertEq(address(messageLib).balance, FEE);
        assertEq(address(token).balance, 0);
    }

    function testDustRemainsWithSenderAndNoTokenFeeIsTaken() public {
        _deliver(ALICE, 10e6);
        SendParam memory p = _params(3 ether + 123, 3 ether);
        (OFTLimit memory limit, OFTFeeDetail[] memory fees, OFTReceipt memory quote) = token.quoteOFT(p);
        assertEq(limit.minAmountLD, 0);
        assertEq(limit.maxAmountLD, 10 ether);
        assertEq(fees.length, 0);
        assertEq(quote.amountSentLD, 3 ether);
        assertEq(quote.amountReceivedLD, 3 ether);
        vm.prank(ALICE);
        token.send{value: FEE}(p, MessagingFee(FEE, 0), ALICE);
        assertEq(token.balanceOf(ALICE), 7 ether);
        assertEq(token.totalSupply(), 7 ether);
    }

    function testFuzzRoundTripConservesSupplyAndDust(uint64 amountSD, uint256 requested) public {
        _deliver(ALICE, amountSD);
        uint256 initial = uint256(amountSD) * RATE;
        requested = bound(requested, 0, initial);
        uint256 burned = requested / RATE * RATE;
        vm.prank(ALICE);
        (, OFTReceipt memory receipt) = token.send{value: FEE}(_params(requested, burned), MessagingFee(FEE, 0), ALICE);
        assertEq(receipt.amountSentLD, burned);
        assertEq(receipt.amountReceivedLD, burned);
        assertEq(token.balanceOf(ALICE), initial - burned);
        assertEq(token.totalSupply() + burned, initial);
        assertEq(messageLib.packet().message, _message(BOB, uint64(burned / RATE)));
    }

    function testMinimumAmountIncludesDustRemoval() public {
        _deliver(ALICE, 1e6);
        SendParam memory p = _params(1 ether - 1, 1 ether - 1);
        bytes memory err = abi.encodeWithSelector(IOFT.SlippageExceeded.selector, 1 ether - RATE, 1 ether - 1);
        vm.expectRevert(err);
        token.quoteSend(p, false);
        vm.prank(ALICE);
        vm.expectRevert(err);
        token.send{value: FEE}(p, MessagingFee(FEE, 0), ALICE);
        assertEq(token.totalSupply(), 1 ether);
    }

    function testSendCannotBurnSomeoneElsesBalance() public {
        _deliver(ALICE, 1e6);
        vm.prank(BOB);
        vm.expectRevert("ERC20: burn amount exceeds balance");
        token.send{value: FEE}(_params(1 ether, 1 ether), MessagingFee(FEE, 0), BOB);
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(token.totalSupply(), 1 ether);
    }

    function testUnknownDestinationRevertsQuoteAndRollsBackBurn() public {
        _deliver(ALICE, 1e6);
        SendParam memory p = _params(1 ether, 1 ether);
        p.dstEid = LOCAL_EID;
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.NoPeer.selector, LOCAL_EID));
        token.quoteSend(p, false);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.NoPeer.selector, LOCAL_EID));
        token.send{value: FEE}(p, MessagingFee(FEE, 0), ALICE);
        assertEq(token.totalSupply(), 1 ether);
        assertEq(token.balanceOf(ALICE), 1 ether);
    }

    function testNativeFeeMustMatchMsgValueAndBurnRollsBack() public {
        _deliver(ALICE, 1e6);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(OAppSender.NotEnoughNative.selector, FEE - 1));
        token.send{value: FEE - 1}(_params(1 ether, 1 ether), MessagingFee(FEE, 0), ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(OAppSender.NotEnoughNative.selector, FEE + 1));
        token.send{value: FEE + 1}(_params(1 ether, 1 ether), MessagingFee(FEE, 0), ALICE);
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(token.totalSupply(), 1 ether);
    }

    function testUnderpaidEndpointFeeRevertsAndRestoresBurnAndNonce() public {
        _deliver(ALICE, 1e6);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Errors.LZ_InsufficientFee.selector, FEE, FEE - 1, 0, 0));
        token.send{value: FEE - 1}(_params(1 ether, 1 ether), MessagingFee(FEE - 1, 0), ALICE);
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(token.totalSupply(), 1 ether);
        assertEq(endpoint.outboundNonce(address(token), ETHEREUM_EID, PEER), 0);
    }

    function testMessageLibraryFailureRollsBackBurn() public {
        _deliver(ALICE, 1e6);
        messageLib.setFailSend(true);
        vm.prank(ALICE);
        vm.expectRevert(MessageLibFixture.SendFailed.selector);
        token.send{value: FEE}(_params(1 ether, 1 ether), MessagingFee(FEE, 0), ALICE);
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(token.totalSupply(), 1 ether);
        assertEq(ALICE.balance, 10 ether);
    }

    function testExcessQuotedNativeFeeIsRefundedByEndpoint() public {
        _deliver(ALICE, 1e6);
        uint256 before = BOB.balance;
        vm.prank(ALICE);
        token.send{value: FEE * 2}(_params(1 ether, 1 ether), MessagingFee(FEE * 2, 0), BOB);
        assertEq(BOB.balance, before + FEE);
        assertEq(address(messageLib).balance, FEE);
        assertEq(address(token).balance, 0);
    }

    function testRefundReentrancyCannotReenterEndpointAndNestedBurnRollsBack() public {
        RefundReentry recipient = new RefundReentry(token);
        _deliver(ALICE, 1e6);
        _deliver(address(recipient), 1e6);
        vm.prank(ALICE);
        token.send{value: FEE * 2}(_params(1 ether, 1 ether), MessagingFee(FEE * 2, 0), address(recipient));
        assertTrue(recipient.attempted());
        assertFalse(recipient.succeeded());
        assertEq(recipient.failure(), abi.encodeWithSelector(Errors.LZ_SendReentrancy.selector));
        assertEq(token.balanceOf(address(recipient)), 1 ether);
        assertEq(token.totalSupply(), 1 ether);
        assertEq(endpoint.outboundNonce(address(token), ETHEREUM_EID, PEER), 1);
    }

    function testLzTokenPaymentAndExcessRefund() public {
        FeeTokenFixture feeToken = new FeeTokenFixture();
        endpoint.setLzToken(address(feeToken));
        feeToken.mint(ALICE, 2 ether);
        _deliver(ALICE, 1e6);
        MessagingFee memory fee = token.quoteSend(_params(1 ether, 1 ether), true);
        assertEq(fee.lzTokenFee, 1 ether);
        vm.startPrank(ALICE);
        feeToken.approve(address(token), 2 ether);
        token.send{value: FEE}(_params(1 ether, 1 ether), MessagingFee(FEE, 2 ether), BOB);
        vm.stopPrank();
        assertEq(feeToken.balanceOf(address(messageLib)), 1 ether);
        assertEq(feeToken.balanceOf(BOB), 1 ether);
        assertEq(feeToken.balanceOf(address(token)), 0);
        assertEq(token.totalSupply(), 0);
    }

    function testLzTokenPaymentWithoutAllowanceRollsBackBurn() public {
        FeeTokenFixture feeToken = new FeeTokenFixture();
        endpoint.setLzToken(address(feeToken));
        feeToken.mint(ALICE, 1 ether);
        _deliver(ALICE, 1e6);
        vm.prank(ALICE);
        vm.expectRevert("ERC20: insufficient allowance");
        token.send{value: FEE}(_params(1 ether, 1 ether), MessagingFee(FEE, 1 ether), ALICE);
        assertEq(token.totalSupply(), 1 ether);
        assertEq(token.balanceOf(ALICE), 1 ether);
    }

    function testUnavailableLzTokenFailsQuoteAndSend() public {
        _deliver(ALICE, 1e6);
        vm.expectRevert(Errors.LZ_LzTokenUnavailable.selector);
        token.quoteSend(_params(1 ether, 1 ether), true);
        vm.prank(ALICE);
        vm.expectRevert(OAppSender.LzTokenUnavailable.selector);
        token.send{value: FEE}(_params(1 ether, 1 ether), MessagingFee(FEE, 1 ether), ALICE);
        assertEq(token.totalSupply(), 1 ether);
    }

    function testSharedDecimalOverflowRevertsQuoteAndSendWithoutTruncation() public {
        _deliver(ALICE, type(uint64).max);
        _deliver(ALICE, 1);
        uint256 amountSD = uint256(type(uint64).max) + 1;
        SendParam memory p = _params(amountSD * RATE, 0);
        vm.expectRevert(abi.encodeWithSelector(IOFT.AmountSDOverflowed.selector, amountSD));
        token.quoteSend(p, false);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IOFT.AmountSDOverflowed.selector, amountSD));
        token.send{value: FEE}(p, MessagingFee(FEE, 0), ALICE);
        assertEq(token.totalSupply(), amountSD * RATE);
        assertEq(token.balanceOf(ALICE), amountSD * RATE);
    }

    function testMaximumSharedAmountCanBeBurned() public {
        _deliver(ALICE, type(uint64).max);
        uint256 amount = uint256(type(uint64).max) * RATE;
        vm.prank(ALICE);
        token.send{value: FEE}(_params(amount, amount), MessagingFee(FEE, 0), ALICE);
        assertEq(token.totalSupply(), 0);
        assertEq(messageLib.packet().message, _message(BOB, type(uint64).max));
    }

    function testZeroAndSubDustSendsPreserveStandardOftBehavior() public {
        _deliver(ALICE, 1);
        vm.prank(ALICE);
        token.send{value: FEE}(_params(RATE - 1, 0), MessagingFee(FEE, 0), ALICE);
        assertEq(token.totalSupply(), RATE);
        assertEq(messageLib.packet().message, _message(BOB, 0));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IOFT.SlippageExceeded.selector, 0, 1));
        token.send{value: FEE}(_params(RATE - 1, 1), MessagingFee(FEE, 0), ALICE);
    }
}
