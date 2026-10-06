// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BridgeFixture} from "./helpers/BridgeFixture.sol";
import {ZeroToOne} from "../src/ZeroToOne.sol";
import {SendParam, MessagingFee, IOFT} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {
    EnforcedOptionParam,
    IOAppOptionsType3
} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";

contract ControlsTest is BridgeFixture {
    function testVersionsAndLiveEndpointDelegate() public view {
        assertEq(endpoint.delegates(address(token)), OWNER);
        (bytes4 interfaceId, uint64 version) = token.oftVersion();
        assertEq(interfaceId, type(IOFT).interfaceId);
        assertEq(version, 1);
        (uint64 senderVersion, uint64 receiverVersion) = token.oAppVersion();
        assertEq(senderVersion, 1);
        assertEq(receiverVersion, 2);
        assertEq(token.nextNonce(ETHEREUM_EID, PEER), 0);
        assertTrue(token.allowInitializePath(_origin(1)));
        assertTrue(token.isComposeMsgSender(_origin(1), "", address(token)));
        assertFalse(token.isComposeMsgSender(_origin(1), "", OWNER));
    }

    function testEvenOwnerCannotReplaceRemoveOrAddPeer() public {
        vm.startPrank(OWNER);
        vm.expectRevert(ZeroToOne.PeerIsImmutable.selector);
        token.setPeer(ETHEREUM_EID, bytes32(uint256(uint160(BOB))));
        vm.expectRevert(ZeroToOne.PeerIsImmutable.selector);
        token.setPeer(ETHEREUM_EID, bytes32(0));
        vm.expectRevert(ZeroToOne.PeerIsImmutable.selector);
        token.setPeer(LOCAL_EID, PEER);
        vm.stopPrank();
        assertEq(token.peers(ETHEREUM_EID), PEER);
        assertEq(token.peers(LOCAL_EID), bytes32(0));
    }

    function testOwnerCannotInstallExternalSendGate() public {
        vm.prank(OWNER);
        vm.expectRevert(ZeroToOne.MessageInspectorDisabled.selector);
        token.setMsgInspector(BOB);
        assertEq(token.msgInspector(), address(0));
    }

    function testAllAvailableAdministrationIsOwnerOnly() public {
        vm.startPrank(ALICE);
        vm.expectRevert("Ownable: caller is not the owner");
        token.setDelegate(ALICE);
        vm.expectRevert("Ownable: caller is not the owner");
        token.setPeer(ETHEREUM_EID, PEER);
        vm.expectRevert("Ownable: caller is not the owner");
        token.setMsgInspector(ALICE);
        vm.expectRevert("Ownable: caller is not the owner");
        token.setPreCrime(ALICE);
        vm.expectRevert("Ownable: caller is not the owner");
        token.setEnforcedOptions(new EnforcedOptionParam[](0));
        vm.expectRevert("Ownable: caller is not the owner");
        token.transferOwnership(ALICE);
        vm.expectRevert("Ownable: caller is not the owner");
        token.renounceOwnership();
        vm.stopPrank();
    }

    function testOwnershipTransferDoesNotAutomaticallyChangeEndpointDelegate() public {
        vm.prank(OWNER);
        token.transferOwnership(BOB);
        assertEq(token.owner(), BOB);
        assertEq(endpoint.delegates(address(token)), OWNER);
        vm.prank(OWNER);
        vm.expectRevert("Ownable: caller is not the owner");
        token.setDelegate(ALICE);
        vm.prank(BOB);
        token.setDelegate(BOB);
        assertEq(endpoint.delegates(address(token)), BOB);
        assertEq(token.peers(ETHEREUM_EID), PEER);
    }

    function testEnforcedOptionsCombineAndComposeUsesSeparateMessageType() public {
        _deliver(ALICE, 2e6);
        bytes memory receiveOption = abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), uint128(200_000));
        bytes memory composeOption =
            abi.encodePacked(uint16(3), uint8(1), uint16(19), uint8(3), uint16(0), uint128(100_000));
        EnforcedOptionParam[] memory enforced = new EnforcedOptionParam[](2);
        enforced[0] = EnforcedOptionParam(ETHEREUM_EID, 1, receiveOption);
        enforced[1] = EnforcedOptionParam(ETHEREUM_EID, 2, bytes.concat(receiveOption, _dropType(composeOption)));
        vm.prank(OWNER);
        token.setEnforcedOptions(enforced);
        SendParam memory p = _params(1 ether, 1 ether);
        p.extraOptions = receiveOption;
        vm.prank(ALICE);
        token.send{value: FEE}(p, MessagingFee(FEE, 0), ALICE);
        assertEq(messageLib.lastOptions(), bytes.concat(receiveOption, _dropType(receiveOption)));
        p.extraOptions = "";
        p.composeMsg = hex"abcdef";
        vm.prank(ALICE);
        token.send{value: FEE}(p, MessagingFee(FEE, 0), ALICE);
        assertEq(messageLib.lastOptions(), bytes.concat(receiveOption, _dropType(composeOption)));
        assertEq(
            messageLib.packet().message,
            abi.encodePacked(bytes32(uint256(uint160(BOB))), uint64(1e6), bytes32(uint256(uint160(ALICE))), hex"abcdef")
        );
    }

    function testInvalidOptionsAreRejectedBeforeSendCommits() public {
        _deliver(ALICE, 1e6);
        EnforcedOptionParam[] memory enforced = new EnforcedOptionParam[](1);
        enforced[0] = EnforcedOptionParam(ETHEREUM_EID, 1, hex"0002");
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IOAppOptionsType3.InvalidOptions.selector, hex"0002"));
        token.setEnforcedOptions(enforced);
        enforced[0].options = hex"0003";
        vm.prank(OWNER);
        token.setEnforcedOptions(enforced);
        SendParam memory p = _params(1 ether, 1 ether);
        p.extraOptions = hex"0002";
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IOAppOptionsType3.InvalidOptions.selector, hex"0002"));
        token.send{value: FEE}(p, MessagingFee(FEE, 0), ALICE);
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(token.totalSupply(), 1 ether);
    }

    function testErc20TransfersAndAllowancesPreserveSupply() public {
        _deliver(ALICE, 10e6);
        vm.prank(ALICE);
        token.transfer(BOB, 2 ether + 123);
        assertEq(token.balanceOf(BOB), 2 ether + 123);
        vm.prank(ALICE);
        token.approve(BOB, 3 ether);
        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, 3 ether);
        assertEq(token.allowance(ALICE, BOB), 0);
        assertEq(token.balanceOf(BOB), 5 ether + 123);
        assertEq(token.totalSupply(), 10 ether);
        vm.prank(BOB);
        vm.expectRevert("ERC20: insufficient allowance");
        token.transferFrom(ALICE, BOB, 1);
        vm.prank(ALICE);
        vm.expectRevert("ERC20: transfer to the zero address");
        token.transfer(address(0), 1);
        vm.prank(ALICE);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        token.transfer(BOB, 10 ether);
    }

    function testNoMintPauseRescueOrUpgradeEntrypointsForOwner() public {
        bytes[] memory calls = new bytes[](7);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", OWNER, 1 ether);
        calls[1] = abi.encodeWithSignature("burn(address,uint256)", ALICE, 1 ether);
        calls[2] = abi.encodeWithSignature("pause()");
        calls[3] = abi.encodeWithSignature("unpause()");
        calls[4] = abi.encodeWithSignature("rescueToken(address,address,uint256)", address(token), OWNER, 1 ether);
        calls[5] = abi.encodeWithSignature("upgradeTo(address)", OWNER);
        calls[6] = abi.encodeWithSignature("initialize(address)", OWNER);
        vm.startPrank(OWNER);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok);
        }
        vm.stopPrank();
        assertEq(token.totalSupply(), 0);
    }

    function _dropType(bytes memory data) private pure returns (bytes memory output) {
        output = new bytes(data.length - 2);
        for (uint256 i; i < output.length; ++i) {
            output[i] = data[i + 2];
        }
    }
}
