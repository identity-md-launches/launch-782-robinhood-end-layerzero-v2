// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ZeroToOne} from "../src/ZeroToOne.sol";

contract DelegateRecorder {
    mapping(address => address) public delegates;

    function setDelegate(address delegate) external {
        delegates[msg.sender] = delegate;
    }
}

contract RejectAllCalls {
    error UnexpectedCall();

    fallback() external {
        revert UnexpectedCall();
    }
}

contract ApplicationFactory {
    function deploy(bytes32 salt) external returns (ZeroToOne) {
        return new ZeroToOne{salt: salt}();
    }
}

contract DeploymentTest is Test {
    address private constant ENDPOINT = 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;
    address private constant OWNER = 0xcECc29B037f5064fCdF45a5C318F132ef76aA551;
    address private constant ADAPTER = 0x68D443f419064B11Cc427B9b72fAA6c1CedF6378;

    function testFreshEvmCreate2DeploymentHasNoSupplyAndFixedConfiguration() public {
        assertEq(ENDPOINT.code.length, 0);
        assertEq(ADAPTER.code.length, 0);
        ApplicationFactory factory = new ApplicationFactory();
        ZeroToOne token = factory.deploy(bytes32(uint256(1)));
        assertEq(token.name(), "Zero To One");
        assertEq(token.symbol(), "ZTO");
        assertEq(token.decimals(), 18);
        assertEq(token.sharedDecimals(), 6);
        assertEq(token.decimalConversionRate(), 1e12);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(OWNER), 0);
        assertEq(token.owner(), OWNER);
        assertEq(address(token.endpoint()), ENDPOINT);
        assertEq(token.peers(30101), bytes32(uint256(uint160(ADAPTER))));
        assertEq(token.peers(30416), bytes32(0));
        assertEq(token.LOCAL_EID(), 30416);
        assertEq(token.token(), address(token));
        assertFalse(token.approvalRequired());
    }

    function testConstructorRegistersDelegateWhenEndpointHasCode() public {
        DelegateRecorder implementation = new DelegateRecorder();
        vm.etch(ENDPOINT, address(implementation).code);
        ZeroToOne token = new ApplicationFactory().deploy(bytes32(0));
        assertEq(DelegateRecorder(ENDPOINT).delegates(address(token)), OWNER);
        assertEq(token.owner(), OWNER);
        assertEq(token.totalSupply(), 0);
    }

    function testDeferredDelegateRegistrationIsOwnerOnly() public {
        ZeroToOne token = new ZeroToOne();
        DelegateRecorder implementation = new DelegateRecorder();
        vm.etch(ENDPOINT, address(implementation).code);
        assertEq(DelegateRecorder(ENDPOINT).delegates(address(token)), address(0));
        vm.expectRevert("Ownable: caller is not the owner");
        token.setDelegate(address(this));
        vm.prank(OWNER);
        token.setDelegate(OWNER);
        assertEq(DelegateRecorder(ENDPOINT).delegates(address(token)), OWNER);
    }

    function testDelegateRegistrationFailsUntilEndpointExists() public {
        ZeroToOne token = new ZeroToOne();
        vm.prank(OWNER);
        vm.expectRevert();
        token.setDelegate(OWNER);
    }

    function testConstructorDoesNotReadRemoteTokenDecimals() public {
        RejectAllCalls implementation = new RejectAllCalls();
        vm.etch(ADAPTER, address(implementation).code);
        ZeroToOne token = new ZeroToOne();
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 0);
    }

    function testConstructorDoesNotSwallowLiveEndpointFailure() public {
        RejectAllCalls implementation = new RejectAllCalls();
        vm.etch(ENDPOINT, address(implementation).code);
        vm.expectRevert(RejectAllCalls.UnexpectedCall.selector);
        new ZeroToOne();
    }

    function testRuntimeMeetsProtectedDeploymentConstraints() public {
        ZeroToOne token = new ZeroToOne();
        assertLe(type(ZeroToOne).creationCode.length, 49_152);
        bytes memory code = address(token).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden opcode");
        }
    }
}
