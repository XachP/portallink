// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {PortalGateway} from "../src/PortalGateway.sol";

/// @dev Random sequences of lock -> relay and burn -> relay across both chains.
contract Handler is Base {
    uint256 public ghostLocked;
    uint256 public ghostReleased;

    constructor(Base) {}

    function init() external {
        setUp();
    }

    function lockAndRelay(uint96 raw) external {
        uint256 amt = bound(raw, MIN, MAX);
        vm.chainId(PORTALDOT);
        if (gwM.windowRemaining(PORTALDOT, true) < amt) return;
        if (alice.balance < amt) vm.deal(alice, amt);
        _bridgeToMezo(alice, bob, amt);
        ghostLocked += amt;
    }

    function burnAndRelay(uint96 raw) external {
        uint256 bal = wPOT.balanceOf(bob);
        if (bal < MIN) return;
        uint256 amt = bound(raw, MIN, bal < MAX ? bal : MAX);
        vm.chainId(PORTALDOT);
        if (gwP.windowRemaining(MEZO, false) < amt) return;
        _bridgeBack(bob, alice, amt);
        ghostReleased += amt;
    }

    function passTime(uint32 s) external {
        vm.warp(block.timestamp + bound(s, 1 hours, 2 days));
    }

    function gateways() external view returns (PortalGateway, PortalGateway, address) {
        return (gwP, gwM, address(wPOT));
    }

    function lockedOut() external view returns (uint256) {
        return _lockedOut(gwP, MEZO);
    }

    function wSupply() external view returns (uint256) {
        return wPOT.totalSupply();
    }
}

contract BridgeInvariantTest is Base {
    Handler internal h;

    function setUp() public override {
        h = new Handler(this);
        h.init();
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](3);
        sel[0] = Handler.lockAndRelay.selector;
        sel[1] = Handler.burnAndRelay.selector;
        sel[2] = Handler.passTime.selector;
        targetSelector(FuzzSelector(address(h), sel));
    }

    /// wrapped supply on Mezo is always fully backed by tPOT escrowed on Portaldot
    function invariant_WrappedFullyBacked() public view {
        assertEq(h.wSupply(), h.lockedOut());
        (PortalGateway p,,) = h.gateways();
        assertGe(address(p).balance, h.lockedOut() + p.totalOwed());
    }

    function invariant_GhostAccounting() public view {
        assertEq(h.ghostLocked() - h.ghostReleased(), h.wSupply());
    }
}
