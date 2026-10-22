// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {PortalGateway} from "../src/PortalGateway.sol";
import {AttesterSet} from "../src/AttesterSet.sol";

contract AttesterSetTest is Base {
    uint256[3] internal next = [uint256(0xD00D), uint256(0xE11E), uint256(0xF00F)];

    function _rotateDigest(PortalGateway gw, address[] memory list, uint8 t) internal view returns (bytes32) {
        bytes32 sh = keccak256(abi.encode(gw.ROTATE_TYPEHASH(), keccak256(abi.encodePacked(list)), t, gw.epoch()));
        return gw.hashTypedData(sh);
    }

    function _newSet() internal view returns (address[] memory list) {
        list = new address[](3);
        for (uint256 i; i < 3; ++i) list[i] = vm.addr(next[i]);
    }

    function test_InitialCommittee() public view {
        address[] memory a = gwP.attesters();
        assertEq(a.length, 3);
        assertEq(gwP.threshold(), 2);
        assertTrue(gwP.isAttester(vm.addr(pks[1])));
    }

    function test_RotateWithCurrentCommittee_OldKeysStopWorking() public {
        address[] memory list = _newSet();
        vm.chainId(MEZO);
        bytes[] memory s = _sigs(_rotateDigest(gwM, list, 2), _two());
        gwM.rotateAttesters(list, 2, s);
        assertEq(gwM.epoch(), 1);
        assertFalse(gwM.isAttester(vm.addr(pks[0])));
        assertTrue(gwM.isAttester(list[0]));

        // old committee can no longer mint
        PortalGateway.Transfer memory t = _t(PORTALDOT, MEZO, 1, PortalGateway.Kind.NativeLocked, alice, bob, 1 ether);
        bytes[] memory old = _sigs(_digest(gwM, t), _two());
        vm.expectPartialRevert(AttesterSet.UnknownSigner.selector);
        gwM.receiveTransfer(t, old);
    }

    function test_RevertWhen_RotationReplayed() public {
        vm.chainId(MEZO);
        address[] memory list = _newSet();
        bytes[] memory s = _sigs(_rotateDigest(gwM, list, 2), _two());
        gwM.rotateAttesters(list, 2, s);
        vm.expectRevert(); // epoch moved on and signers changed
        gwM.rotateAttesters(list, 2, s);
    }

    function test_RevertWhen_RotationSignedByOutsiders() public {
        vm.chainId(MEZO);
        address[] memory list = _newSet();
        bytes32 d = _rotateDigest(gwM, list, 2);
        bytes[] memory s = new bytes[](2);
        (bytes memory a, bytes memory b) = (_sign(next[0], d), _sign(next[1], d));
        (s[0], s[1]) = list[0] < list[1] ? (a, b) : (b, a);
        vm.expectPartialRevert(AttesterSet.UnknownSigner.selector);
        gwM.rotateAttesters(list, 2, s);
    }

    function test_RevertWhen_MinorityThreshold() public {
        vm.chainId(MEZO);
        address[] memory list = _newSet();
        bytes[] memory s = _sigs(_rotateDigest(gwM, list, 1), _two());
        vm.expectRevert(AttesterSet.BadThreshold.selector);
        gwM.rotateAttesters(list, 1, s); // 1-of-3 is not a majority
    }

    function test_RevertWhen_DuplicateOrZeroAttester() public {
        address[] memory dup = new address[](3);
        dup[0] = alice;
        dup[1] = alice;
        dup[2] = bob;
        vm.expectRevert(AttesterSet.BadAttester.selector);
        new PortalGateway(admin, guardian, dup, 2);
        dup[1] = address(0);
        vm.expectRevert(AttesterSet.BadAttester.selector);
        new PortalGateway(admin, guardian, dup, 2);
    }

    function test_RevertWhen_TooManyAttesters() public {
        address[] memory many = new address[](17);
        for (uint256 i; i < 17; ++i) many[i] = address(uint160(i + 1));
        vm.expectRevert(AttesterSet.BadThreshold.selector);
        new PortalGateway(admin, guardian, many, 9);
    }

    function test_DomainSeparatorBindsChainAndContract() public {
        vm.chainId(PORTALDOT);
        bytes32 a = gwP.domainSeparator();
        vm.chainId(MEZO);
        bytes32 b = gwP.domainSeparator();
        assertTrue(a != b, "chain id is in the domain");
        assertTrue(gwM.domainSeparator() != b, "contract address is in the domain");
    }
}
