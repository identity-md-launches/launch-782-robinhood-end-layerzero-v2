// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

/// @notice Robinhood's mint/burn OFT for the single Ethereum ZTO adapter.
/// @dev Endpoint verification and replay protection belong to LayerZero EndpointV2.
contract ZeroToOne is OFT {
    address public constant LZ_ENDPOINT = 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;
    uint32 public constant LOCAL_EID = 30416;
    uint32 public constant ETHEREUM_EID = 30101;
    address public constant ETHEREUM_ADAPTER = 0x68D443f419064B11Cc427B9b72fAA6c1CedF6378;
    address public constant INITIAL_OWNER = 0xcECc29B037f5064fCdF45a5C318F132ef76aA551;
    uint8 public constant LOCAL_DECIMALS = 18;

    error PeerIsImmutable();
    error MessageInspectorDisabled();

    /// @dev No mint and no external token reads. OAppCore registers the delegate
    /// only if endpoint code exists; otherwise the owner can call setDelegate later.
    constructor() OFT("Zero To One", "ZTO", LZ_ENDPOINT, INITIAL_OWNER) {
        _transferOwnership(INITIAL_OWNER);
        _setPeer(ETHEREUM_EID, bytes32(uint256(uint160(ETHEREUM_ADAPTER))));
    }

    function decimals() public pure override returns (uint8) {
        return LOCAL_DECIMALS;
    }

    /// @notice The sole peer cannot be changed, removed, or extended by the owner.
    function setPeer(uint32, bytes32) public view override onlyOwner {
        revert PeerIsImmutable();
    }

    /// @notice No optional external inspector can be installed to gate sends.
    function setMsgInspector(address) public view override onlyOwner {
        revert MessageInspectorDisabled();
    }

    /// @dev Reject empty peers even for unconfigured endpoint ids.
    function isPeer(uint32 eid, bytes32 peer) public pure override returns (bool) {
        return eid == ETHEREUM_EID && peer == bytes32(uint256(uint160(ETHEREUM_ADAPTER)));
    }

    function allowInitializePath(Origin calldata origin) public pure override returns (bool) {
        return isPeer(origin.srcEid, origin.sender);
    }
}
