// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BridgeFixture} from "./helpers/BridgeFixture.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {Errors} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/Errors.sol";
import {OAppReceiver} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppReceiver.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {
    IOAppPreCrimeSimulator,
    InboundPacket
} from "@layerzerolabs/oapp-evm/contracts/precrime/interfaces/IOAppPreCrimeSimulator.sol";

contract ReceiveTest is BridgeFixture {
    event OFTReceived(bytes32 indexed guid, uint32 srcEid, address indexed toAddress, uint256 amountReceivedLD);

    function testVerifiedMessageMintsAndEmitsReceipt() public {
        Origin memory origin = _origin(1);
        bytes32 guid = keccak256("verified");
        bytes memory message = _message(ALICE, 12_345_678);
        _verify(origin, guid, message);
        vm.expectEmit(true, true, false, true, address(token));
        emit OFTReceived(guid, ETHEREUM_EID, ALICE, 12_345_678 * RATE);
        endpoint.lzReceive(origin, address(token), guid, message, "");
        assertEq(token.balanceOf(ALICE), 12_345_678 * RATE);
        assertEq(token.totalSupply(), 12_345_678 * RATE);
    }

    function testFuzzVerifiedCreditsScaleExactly(uint64 amountSD) public {
        _deliver(ALICE, amountSD);
        assertEq(token.balanceOf(ALICE), uint256(amountSD) * RATE);
        assertEq(token.totalSupply(), uint256(amountSD) * RATE);
    }

    function testOnlyEndpointCanDeliverIncludingOwner() public {
        bytes memory message = _message(ALICE, 1e6);
        vm.expectRevert(abi.encodeWithSelector(OAppReceiver.OnlyEndpoint.selector, address(this)));
        token.lzReceive(_origin(1), bytes32(0), message, EXECUTOR, "");
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(OAppReceiver.OnlyEndpoint.selector, OWNER));
        token.lzReceive(_origin(1), bytes32(0), message, EXECUTOR, "");
        assertEq(token.totalSupply(), 0);
    }

    function testEndpointCannotMintFromWrongPeer() public {
        Origin memory origin = Origin(ETHEREUM_EID, bytes32(uint256(123)), 1);
        vm.prank(ENDPOINT);
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.OnlyPeer.selector, ETHEREUM_EID, origin.sender));
        token.lzReceive(origin, bytes32(0), _message(ALICE, 1), EXECUTOR, "");
        assertEq(token.totalSupply(), 0);
    }

    function testEndpointCannotMintFromWrongChainOrEmptyPeer() public {
        Origin memory origin = Origin(LOCAL_EID, PEER, 1);
        vm.prank(ENDPOINT);
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.NoPeer.selector, LOCAL_EID));
        token.lzReceive(origin, bytes32(0), _message(ALICE, 1), EXECUTOR, "");
        origin.sender = bytes32(0);
        assertFalse(token.allowInitializePath(origin));
        assertFalse(token.isPeer(LOCAL_EID, bytes32(0)));
        assertEq(token.totalSupply(), 0);
    }

    function testUnverifiedPacketCannotBeExecuted() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.LZ_InvalidNonce.selector, uint64(1)));
        endpoint.lzReceive(_origin(1), address(token), bytes32(0), _message(ALICE, 1e6), "");
        assertEq(token.totalSupply(), 0);
    }

    function testUnconfiguredLibraryCannotVerify() public {
        vm.expectRevert(Errors.LZ_InvalidReceiveLibrary.selector);
        endpoint.verify(_origin(1), address(token), keccak256("fabricated"));
        assertEq(token.totalSupply(), 0);
    }

    function testWrongPeerCannotInitializeEndpointPath() public {
        Origin memory origin = Origin(ETHEREUM_EID, bytes32(uint256(999)), 1);
        vm.expectRevert(Errors.LZ_PathNotInitializable.selector);
        messageLib.verify(origin, address(token), keccak256("fabricated"));
    }

    function testEndpointRejectsReplayAndReverificationAfterDelivery() public {
        bytes32 guid = _deliver(ALICE, 1e6);
        bytes memory message = _message(ALICE, 1e6);
        bytes32 hash = keccak256(abi.encodePacked(guid, message));
        vm.expectRevert(abi.encodeWithSelector(Errors.LZ_PayloadHashNotFound.selector, bytes32(0), hash));
        endpoint.lzReceive(_origin(1), address(token), guid, message, "");
        vm.expectRevert(Errors.LZ_PathNotVerifiable.selector);
        messageLib.verify(_origin(1), address(token), hash);
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(token.totalSupply(), 1 ether);
    }

    function testPayloadAndGuidAreBoundToVerification() public {
        bytes32 guid = keccak256("good");
        bytes memory message = _message(ALICE, 1e6);
        bytes32 hash = keccak256(abi.encodePacked(guid, message));
        _verify(_origin(1), guid, message);
        bytes memory altered = _message(BOB, 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.LZ_PayloadHashNotFound.selector, hash, keccak256(abi.encodePacked(guid, altered))
            )
        );
        endpoint.lzReceive(_origin(1), address(token), guid, altered, "");
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.LZ_PayloadHashNotFound.selector, hash, keccak256(abi.encodePacked(bytes32(0), message))
            )
        );
        endpoint.lzReceive(_origin(1), address(token), bytes32(0), message, "");
        assertEq(token.totalSupply(), 0);
        // Failed execution preserves the verified packet for a correct retry.
        endpoint.lzReceive(_origin(1), address(token), guid, message, "");
        assertEq(token.balanceOf(ALICE), 1 ether);
    }

    function testUnorderedDeliveryAfterBothPacketsVerified() public {
        _verify(_origin(1), bytes32(uint256(1)), _message(ALICE, 2e6));
        _verify(_origin(2), bytes32(uint256(2)), _message(BOB, 3e6));
        endpoint.lzReceive(_origin(2), address(token), bytes32(uint256(2)), _message(BOB, 3e6), "");
        endpoint.lzReceive(_origin(1), address(token), bytes32(uint256(1)), _message(ALICE, 2e6), "");
        assertEq(token.totalSupply(), 5 ether);
        assertEq(token.balanceOf(ALICE), 2 ether);
        assertEq(token.balanceOf(BOB), 3 ether);
    }

    function testMalformedVerifiedPayloadRevertsWithoutConsumingMessage() public {
        bytes memory malformed = hex"1234";
        bytes32 hash = keccak256(abi.encodePacked(bytes32(0), malformed));
        _verify(_origin(1), bytes32(0), malformed);
        vm.expectRevert();
        endpoint.lzReceive(_origin(1), address(token), bytes32(0), malformed, "");
        assertEq(token.totalSupply(), 0);
        assertEq(endpoint.inboundPayloadHash(address(token), ETHEREUM_EID, PEER, 1), hash);
    }

    function testZeroRecipientUsesStandardOftDeadAddress() public {
        _deliver(address(0), 1e6);
        assertEq(token.balanceOf(address(0xdead)), 1 ether);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), 1 ether);
    }

    function testComposedReceiveMintsAndQueuesStandardPayload() public {
        bytes32 guid = keccak256("compose");
        bytes memory tail = abi.encodePacked(bytes32(uint256(uint160(BOB))), hex"abcdef");
        bytes memory message = bytes.concat(_message(ALICE, 42), tail);
        _verify(_origin(1), guid, message);
        endpoint.lzReceive(_origin(1), address(token), guid, message, "");
        bytes memory expected = abi.encodePacked(uint64(1), ETHEREUM_EID, uint256(42 * RATE), tail);
        assertEq(endpoint.composeQueue(address(token), ALICE, guid, 0), keccak256(expected));
        assertEq(token.balanceOf(ALICE), 42 * RATE);
    }

    function testSimulationCannotPersistMint() public {
        vm.expectRevert(IOAppPreCrimeSimulator.OnlySelf.selector);
        token.lzReceiveSimulate(_origin(1), bytes32(0), _message(ALICE, 1e6), EXECUTOR, "");
        InboundPacket[] memory packets = new InboundPacket[](1);
        packets[0] =
            InboundPacket(_origin(1), LOCAL_EID, address(token), bytes32(0), 0, EXECUTOR, _message(ALICE, 1e6), "");
        vm.expectRevert(abi.encodeWithSelector(IOAppPreCrimeSimulator.SimulationResult.selector, hex"1234"));
        token.lzReceiveAndRevert(packets);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function buildSimulationResult() external pure returns (bytes memory) {
        return hex"1234";
    }
}
