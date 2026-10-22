// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {PortalGateway} from "../src/PortalGateway.sol";
import {WrappedToken} from "../src/WrappedToken.sol";

/// @dev Two gateways living in one EVM; `vm.chainId` switches which chain we "are" on, so the
///      EIP-712 domain (bound to block.chainid) behaves exactly as on two real chains.
abstract contract Base is Test {
    uint64 internal constant PORTALDOT = 420420777;
    uint64 internal constant MEZO = 31611;

    uint256[3] internal pks = [uint256(0xA11CE), uint256(0xB0B), uint256(0xC4A7)];
    address[] internal attesters;
    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    PortalGateway internal gwP; // on Portaldot: escrows tPOT, mints wBTC
    PortalGateway internal gwM; // on Mezo: escrows BTC, mints wPOT
    WrappedToken internal wPOT; // lives on Mezo
    WrappedToken internal wBTC; // lives on Portaldot

    uint128 internal constant MIN = 0.1 ether;
    uint128 internal constant MAX = 1_000 ether;
    uint128 internal constant CAP = 5_000 ether;

    function setUp() public virtual {
        for (uint256 i; i < 3; ++i) attesters.push(vm.addr(pks[i]));
        vm.chainId(PORTALDOT);
        gwP = new PortalGateway(admin, guardian, attesters, 2);
        wBTC = new WrappedToken("PortalLink Wrapped Mezo BTC", "wBTC.m", MEZO);
        wBTC.bindGateway(address(gwP));
        vm.chainId(MEZO);
        gwM = new PortalGateway(admin, guardian, attesters, 2);
        wPOT = new WrappedToken("PortalLink Wrapped tPOT", "wPOT", PORTALDOT);
        wPOT.bindGateway(address(gwM));
        vm.startPrank(admin);
        gwP.configureRoute(MEZO, address(gwM), wBTC, _cfg(), _cfg());
        gwM.configureRoute(PORTALDOT, address(gwP), wPOT, _cfg(), _cfg());
        vm.stopPrank();
        vm.chainId(PORTALDOT);
        vm.deal(alice, 10_000 ether);
        vm.deal(bob, 10_000 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _t(uint64 src, uint64 dst, uint64 nonce, PortalGateway.Kind kind, address from, address to, uint256 amt)
        internal
        pure
        returns (PortalGateway.Transfer memory)
    {
        return PortalGateway.Transfer(src, dst, nonce, kind, from, to, amt);
    }

    function _digest(PortalGateway gw, PortalGateway.Transfer memory t) internal view returns (bytes32) {
        return gw.transferDigest(t);
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Signs with the given key indexes and returns signatures sorted by signer address.
    function _sigs(bytes32 digest, uint256[] memory idx) internal view returns (bytes[] memory out) {
        out = new bytes[](idx.length);
        address[] memory who = new address[](idx.length);
        for (uint256 i; i < idx.length; ++i) {
            out[i] = _sign(pks[idx[i]], digest);
            who[i] = vm.addr(pks[idx[i]]);
        }
        for (uint256 i; i < who.length; ++i) {
            for (uint256 j = i + 1; j < who.length; ++j) {
                if (who[j] < who[i]) {
                    (who[i], who[j]) = (who[j], who[i]);
                    (out[i], out[j]) = (out[j], out[i]);
                }
            }
        }
    }

    function _two() internal pure returns (uint256[] memory a) {
        a = new uint256[](2);
        a[0] = 0;
        a[1] = 2;
    }

    function _lockedOut(PortalGateway gw, uint64 chainId) internal view returns (uint256 locked) {
        (,, locked) = gw.route(chainId);
    }

    function _cfg() internal pure returns (PortalGateway.LimitConfig memory) {
        return PortalGateway.LimitConfig(MIN, MAX, CAP);
    }

    function _cfg(uint128 mn, uint128 mx, uint128 cap) internal pure returns (PortalGateway.LimitConfig memory) {
        return PortalGateway.LimitConfig(mn, mx, cap);
    }

    /// @dev Lock on Portaldot and deliver to Mezo with 2 valid sigs. Leaves chainId = MEZO.
    function _bridgeToMezo(address from, address to, uint256 amt) internal returns (PortalGateway.Transfer memory t) {
        vm.chainId(PORTALDOT);
        uint64 n = gwP.outboundNonce() + 1;
        vm.prank(from);
        gwP.lockNative{value: amt}(MEZO, to);
        t = _t(PORTALDOT, MEZO, n, PortalGateway.Kind.NativeLocked, from, to, amt);
        vm.chainId(MEZO);
        gwM.receiveTransfer(t, _sigs(_digest(gwM, t), _two()));
    }

    /// @dev Burn wPOT on Mezo and deliver the release to Portaldot. Leaves chainId = PORTALDOT.
    function _bridgeBack(address from, address to, uint256 amt) internal returns (PortalGateway.Transfer memory t) {
        vm.chainId(MEZO);
        uint64 n = gwM.outboundNonce() + 1;
        vm.prank(from);
        gwM.burnWrapped(PORTALDOT, to, amt);
        t = _t(MEZO, PORTALDOT, n, PortalGateway.Kind.WrappedBurned, from, to, amt);
        vm.chainId(PORTALDOT);
        gwP.receiveTransfer(t, _sigs(_digest(gwP, t), _two()));
    }
}
