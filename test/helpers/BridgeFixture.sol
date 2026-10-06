// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ZeroToOne} from "../../src/ZeroToOne.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/EndpointV2.sol";
import {Origin, MessagingFee} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {
    IMessageLib,
    MessageLibType,
    SetConfigParam
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLib.sol";
import {ISendLib, Packet} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ISendLib.sol";
import {PacketV1Codec} from "@layerzerolabs/lz-evm-protocol-v2/contracts/messagelib/libs/PacketV1Codec.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

/// @dev Test-only stand-in for DVN verification and the fee-charging message library.
/// The endpoint itself is upstream EndpointV2; this is not a production verifier.
contract MessageLibFixture is ISendLib {
    EndpointV2 public immutable endpoint;
    Packet private lastPacket;
    bytes public lastOptions;
    bool public failSend;
    uint256 public constant NATIVE_FEE = 0.001 ether;
    uint256 public constant TOKEN_FEE = 1 ether;
    error SendFailed();

    constructor(EndpointV2 endpoint_) {
        endpoint = endpoint_;
    }

    function verify(Origin calldata origin, address receiver, bytes32 payloadHash) external {
        endpoint.verify(origin, receiver, payloadHash);
    }

    function setFailSend(bool value) external {
        failSend = value;
    }

    function packet() external view returns (Packet memory) {
        return lastPacket;
    }

    function send(Packet calldata packet_, bytes calldata options_, bool payInLzToken)
        external
        returns (MessagingFee memory, bytes memory)
    {
        require(msg.sender == address(endpoint), "endpoint only");
        if (failSend) revert SendFailed();
        lastPacket = packet_;
        lastOptions = options_;
        return (_fee(payInLzToken), PacketV1Codec.encode(packet_));
    }

    function quote(Packet calldata, bytes calldata, bool payInLzToken) external pure returns (MessagingFee memory) {
        return _fee(payInLzToken);
    }

    function _fee(bool payInLzToken) private pure returns (MessagingFee memory) {
        return MessagingFee(NATIVE_FEE, payInLzToken ? TOKEN_FEE : 0);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IMessageLib).interfaceId || id == 0x01ffc9a7;
    }

    function isSupportedEid(uint32 eid) external pure returns (bool) {
        return eid == 30101;
    }

    function version() external pure returns (uint64, uint8, uint8) {
        return (1, 0, 2);
    }

    function messageLibType() external pure returns (MessageLibType) {
        return MessageLibType.SendAndReceive;
    }
    function setConfig(address, SetConfigParam[] calldata) external {}

    function getConfig(uint32, address, uint32) external pure returns (bytes memory) {
        return "";
    }
    function setTreasury(address) external {}

    function withdrawFee(address, uint256) external pure {
        revert("unused fixture function");
    }

    function withdrawLzTokenFee(address, address, uint256) external pure {
        revert("unused fixture function");
    }
    receive() external payable {}
}

contract FeeTokenFixture is ERC20 {
    constructor() ERC20("Fee token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

abstract contract BridgeFixture is Test {
    address internal constant ENDPOINT = 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;
    address internal constant OWNER = 0xcECc29B037f5064fCdF45a5C318F132ef76aA551;
    address internal constant ADAPTER = 0x68D443f419064B11Cc427B9b72fAA6c1CedF6378;
    bytes32 internal constant PEER = bytes32(uint256(uint160(ADAPTER)));
    uint32 internal constant ETHEREUM_EID = 30101;
    uint32 internal constant LOCAL_EID = 30416;
    uint256 internal constant RATE = 1e12;
    uint256 internal constant FEE = 0.001 ether;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant EXECUTOR = address(0xE1EC);
    ZeroToOne internal token;
    EndpointV2 internal endpoint;
    MessageLibFixture internal messageLib;
    uint64 internal receivedNonce;

    function setUp() public virtual {
        vm.record();
        EndpointV2 implementation = new EndpointV2(LOCAL_EID, address(this));
        (, bytes32[] memory writes) = vm.accesses(address(implementation));
        vm.etch(ENDPOINT, address(implementation).code);
        // Copy constructor storage too, including the send-context sentinel and
        // registered blocked library. This preserves the real endpoint behavior.
        for (uint256 i; i < writes.length; ++i) {
            vm.store(ENDPOINT, writes[i], vm.load(address(implementation), writes[i]));
        }
        endpoint = EndpointV2(ENDPOINT);
        messageLib = new MessageLibFixture(endpoint);
        endpoint.registerLibrary(address(messageLib));
        endpoint.setDefaultSendLibrary(ETHEREUM_EID, address(messageLib));
        endpoint.setDefaultReceiveLibrary(ETHEREUM_EID, address(messageLib), 0);
        token = new ZeroToOne();
        vm.deal(ALICE, 10 ether);
        vm.deal(BOB, 10 ether);
        vm.deal(address(this), 10 ether);
    }

    function _params(uint256 amount, uint256 minAmount) internal pure returns (SendParam memory) {
        return SendParam(ETHEREUM_EID, bytes32(uint256(uint160(BOB))), amount, minAmount, "", "", "");
    }

    function _origin(uint64 nonce) internal pure returns (Origin memory) {
        return Origin(ETHEREUM_EID, PEER, nonce);
    }

    function _message(address to, uint64 amountSD) internal pure returns (bytes memory) {
        // Deliberately encode independently of the OFT codec under test.
        return abi.encodePacked(bytes32(uint256(uint160(to))), amountSD);
    }

    function _verify(Origin memory origin, bytes32 guid, bytes memory message) internal {
        messageLib.verify(origin, address(token), keccak256(abi.encodePacked(guid, message)));
    }

    function _deliver(address to, uint64 amountSD) internal returns (bytes32 guid) {
        uint64 nonce = ++receivedNonce;
        guid = keccak256(abi.encode(nonce, to, amountSD));
        Origin memory origin = _origin(nonce);
        bytes memory message = _message(to, amountSD);
        _verify(origin, guid, message);
        vm.prank(EXECUTOR);
        endpoint.lzReceive(origin, address(token), guid, message, "");
    }
}
