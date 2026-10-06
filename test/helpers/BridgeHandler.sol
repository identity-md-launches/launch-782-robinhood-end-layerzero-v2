// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ZeroToOne} from "src/ZeroToOne.sol";
import {EndpointV2, MessageLibFixture, Packet} from "./BridgeFixture.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {Errors} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/Errors.sol";
import {
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt,
    IOFT
} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {OAppReceiver} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppReceiver.sol";
import {OAppSender} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";

/// @dev The message library stands in for successful DVN verification; EndpointV2
/// still authenticates, checks payload hashes and consumes nonces. No token deal,
/// storage edits, direct mint harness, or swallowed unexpected reverts are used.
contract BridgeHandler is Test {
    uint256 public constant RATE = 1e12;
    uint256 public constant FEE = 0.001 ether;
    uint256 private constant MAX_SEND = uint256(type(uint64).max) * RATE;
    address private constant OWNER = 0xcECc29B037f5064fCdF45a5C318F132ef76aA551;
    bytes32 private constant PEER = bytes32(uint256(uint160(0x68D443f419064B11Cc427B9b72fAA6c1CedF6378)));
    ZeroToOne private immutable token;
    EndpointV2 private immutable endpoint;
    MessageLibFixture private immutable messageLib;

    // Only these four users originate transactions. Custody at the token itself
    // and the OFT dead-address recipient are included in the accounting universe.
    address[6] public accounts;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public credited;
    uint256 public burned;
    uint256 public sends;

    struct Inbound {
        address to;
        uint64 amountSD;
        bytes32 guid;
        bool composed;
        bool executed;
    }

    Inbound[] private inbound;

    constructor(ZeroToOne token_, EndpointV2 endpoint_, MessageLibFixture messageLib_) {
        token = token_;
        endpoint = endpoint_;
        messageLib = messageLib_;
        accounts = [address(0xA11CE), address(0xB0B), address(0xCA401), OWNER, address(token_), address(0xdead)];
        for (uint256 i; i < 4; ++i) {
            vm.deal(accounts[i], 100 ether);
        }
    }

    function packetCount() external view returns (uint256) {
        return inbound.length;
    }

    function verifyInbound(uint256 recipientSeed, uint64 amountSD, bool composed) public {
        uint256 index = recipientSeed % 7;
        address to = index == 6 ? address(0) : accounts[index];
        uint64 nonce = uint64(inbound.length + 1);
        bytes32 guid = keccak256(abi.encode(nonce, to, amountSD, composed));
        inbound.push(Inbound(to, amountSD, guid, composed, false));
        bytes memory message = _message(inbound[inbound.length - 1]);
        messageLib.verify(_origin(nonce), address(token), keccak256(abi.encodePacked(guid, message)));
        // Verification alone grants no credit. Only successful execution does.
        assertEq(token.totalSupply(), credited - burned, "verification minted tokens");
    }

    function executeInbound(uint256 packetSeed) public {
        uint256 index = packetSeed % inbound.length;
        Inbound storage packet = inbound[index];
        bytes memory message = _message(packet);
        Origin memory origin = _origin(uint64(index + 1));
        if (packet.executed) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    Errors.LZ_PayloadHashNotFound.selector,
                    bytes32(0),
                    keccak256(abi.encodePacked(packet.guid, message))
                )
            );
            endpoint.lzReceive(origin, address(token), packet.guid, message, "");
        } else {
            endpoint.lzReceive(origin, address(token), packet.guid, message, "");
            packet.executed = true;
            uint256 amount = uint256(packet.amountSD) * RATE;
            credited += amount;
            expectedBalance[packet.to == address(0) ? address(0xdead) : packet.to] += amount;
            if (packet.composed) {
                bytes memory expected = abi.encodePacked(origin.nonce, uint32(30101), amount, _composeTail());
                assertEq(endpoint.composeQueue(address(token), packet.to, packet.guid, 0), keccak256(expected));
            }
        }
        assertEq(endpoint.inboundPayloadHash(address(token), 30101, PEER, origin.nonce), bytes32(0));
    }

    function tamperInbound(uint256 packetSeed, uint256 bitSeed) external {
        uint256 index = packetSeed % inbound.length;
        Inbound storage packet = inbound[index];
        bytes memory message = _message(packet);
        bytes32 storedHash = packet.executed ? bytes32(0) : keccak256(abi.encodePacked(packet.guid, message));
        bytes32 changedGuid = packet.guid ^ bytes32(uint256(1) << (bitSeed % 256));
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.LZ_PayloadHashNotFound.selector, storedHash, keccak256(abi.encodePacked(changedGuid, message))
            )
        );
        endpoint.lzReceive(_origin(uint64(index + 1)), address(token), changedGuid, message, "");
        assertEq(endpoint.inboundPayloadHash(address(token), 30101, PEER, uint64(index + 1)), storedHash);
    }

    function unverifiedReceive(uint64 amountSD) external {
        uint64 nonce = uint64(inbound.length + 1);
        vm.expectRevert(abi.encodeWithSelector(Errors.LZ_InvalidNonce.selector, nonce));
        endpoint.lzReceive(
            _origin(nonce), address(token), bytes32(0), abi.encodePacked(bytes32(uint256(1)), amountSD), ""
        );
    }

    function unauthorizedReceive(uint256 actorSeed, uint64 amountSD) external {
        address actor = accounts[actorSeed % 4];
        vm.prank(actor);
        vm.expectRevert(abi.encodeWithSelector(OAppReceiver.OnlyEndpoint.selector, actor));
        token.lzReceive(_origin(1), bytes32(0), abi.encodePacked(bytes32(uint256(uint160(actor))), amountSD), actor, "");
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = accounts[fromSeed % 4];
        address to = accounts[toSeed % 6];
        amount = bound(amount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint256 fromSeed, uint256 spenderSeed, uint256 amount, bool unlimited) public {
        address from = accounts[fromSeed % 4];
        address spender = accounts[spenderSeed % 4];
        amount = unlimited ? type(uint256).max : bound(amount, 0, MAX_SEND);
        vm.prank(from);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[from][spender] = amount;
    }

    function transferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) public {
        address from = accounts[fromSeed % 4];
        address spender = accounts[spenderSeed % 4];
        address to = accounts[toSeed % 6];
        uint256 allowance = expectedAllowance[from][spender];
        uint256 maximum = expectedBalance[from] < allowance ? expectedBalance[from] : allowance;
        amount = bound(amount, 0, maximum);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        if (allowance != type(uint256).max) expectedAllowance[from][spender] -= amount;
    }

    function send(uint256 actorSeed, uint256 requested, bool fullBalance, bool composed) public {
        address actor = accounts[actorSeed % 4];
        uint256 maximum = expectedBalance[actor] < MAX_SEND ? expectedBalance[actor] : MAX_SEND;
        requested = fullBalance ? maximum : bound(requested, 0, maximum);
        uint256 amount = requested - requested % RATE;
        SendParam memory p = _params(requested, amount);
        if (composed) p.composeMsg = hex"f00d";
        vm.prank(actor);
        (MessagingReceipt memory receipt, OFTReceipt memory oft) =
            token.send{value: FEE}(p, MessagingFee(FEE, 0), actor);
        expectedBalance[actor] -= amount;
        burned += amount;
        ++sends;
        assertEq(oft.amountSentLD, amount);
        assertEq(oft.amountReceivedLD, amount);
        assertEq(receipt.nonce, sends);
        Packet memory packet = messageLib.packet();
        bytes memory expected = abi.encodePacked(p.to, uint64(amount / RATE));
        if (composed) expected = bytes.concat(expected, abi.encodePacked(bytes32(uint256(uint160(actor))), hex"f00d"));
        assertEq(packet.message, expected, "wire amount must match the burn");
        assertEq(packet.sender, address(token));
        assertEq(packet.receiver, PEER);
        assertEq(packet.srcEid, 30416);
        assertEq(packet.dstEid, 30101);
        assertEq(receipt.guid, packet.guid);
    }

    function rejectedSend(uint256 actorSeed, uint256 requested, uint8 modeSeed) public {
        address actor = accounts[actorSeed % 4];
        uint256 maximum = expectedBalance[actor] < MAX_SEND ? expectedBalance[actor] : MAX_SEND;
        requested = bound(requested, 0, maximum);
        uint256 amount = requested - requested % RATE;
        SendParam memory p = _params(requested, amount);
        uint256 value = FEE;
        bytes memory reason;
        uint8 mode = modeSeed % 5;
        if (mode == 0) {
            p.minAmountLD = amount + 1;
            reason = abi.encodeWithSelector(IOFT.SlippageExceeded.selector, amount, amount + 1);
        } else if (mode == 1) {
            p.dstEid = 30416;
            reason = abi.encodeWithSelector(IOAppCore.NoPeer.selector, uint32(30416));
        } else if (mode == 2) {
            value = FEE - 1;
            reason = abi.encodeWithSelector(OAppSender.NotEnoughNative.selector, value);
        } else if (mode == 3) {
            messageLib.setFailSend(true);
            reason = abi.encodeWithSelector(MessageLibFixture.SendFailed.selector);
        } else {
            p.amountLD = expectedBalance[actor] - expectedBalance[actor] % RATE + RATE;
            reason = abi.encodeWithSignature("Error(string)", "ERC20: burn amount exceeds balance");
        }
        uint256 nativeBefore = actor.balance;
        vm.prank(actor);
        vm.expectRevert(reason);
        token.send{value: value}(p, MessagingFee(FEE, 0), actor);
        if (mode == 3) messageLib.setFailSend(false);
        assertEq(actor.balance, nativeBefore, "failed send charged a fee");
    }

    function rejectedTransferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed) external {
        address from = accounts[fromSeed % 4];
        address spender = accounts[spenderSeed % 4];
        vm.prank(from);
        token.approve(spender, 0);
        expectedAllowance[from][spender] = 0;
        vm.prank(spender);
        vm.expectRevert("ERC20: insufficient allowance");
        token.transferFrom(from, accounts[toSeed % 6], 1);
    }

    function rejectedAdministration(uint32 eid, bytes32 peer) external {
        vm.prank(OWNER);
        vm.expectRevert(ZeroToOne.PeerIsImmutable.selector);
        token.setPeer(eid, peer);
        vm.prank(accounts[0]);
        vm.expectRevert("Ownable: caller is not the owner");
        token.setDelegate(accounts[0]);
        assertEq(token.peers(eid), eid == 30101 ? PEER : bytes32(0));
    }

    function _origin(uint64 nonce) private pure returns (Origin memory) {
        return Origin(30101, PEER, nonce);
    }

    function _params(uint256 amount, uint256 minimum) private pure returns (SendParam memory) {
        return SendParam(30101, bytes32(uint256(uint160(address(0xB0B)))), amount, minimum, "", "", "");
    }

    function _composeTail() private pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(OWNER))), hex"cafe");
    }

    function _message(Inbound storage packet) private view returns (bytes memory message) {
        message = abi.encodePacked(bytes32(uint256(uint160(packet.to))), packet.amountSD);
        if (packet.composed) message = bytes.concat(message, _composeTail());
    }
}
