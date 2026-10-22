// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {PortalGateway} from "../src/PortalGateway.sol";
import {AttesterSet} from "../src/AttesterSet.sol";
import {WrappedToken} from "../src/WrappedToken.sol";

contract RevertingReceiver {
    receive() external payable {
        revert("nope");
    }
}

/// @dev Tries to re-enter the gateway while receiving its payout.
contract ReentrantReceiver {
    PortalGateway public gw;
    bool public tried;

    constructor(PortalGateway g) {
        gw = g;
    }

    receive() external payable {
        tried = true;
        gw.withdrawOwed();
    }

    function pull() external {
        gw.withdrawOwed();
    }
}

contract PortalGatewayTest is Base {
    event TransferSent(
        bytes32 indexed id,
        uint64 indexed dstChainId,
        uint64 nonce,
        PortalGateway.Kind kind,
        address indexed sender,
        address recipient,
        uint256 amount
    );

    // ------------------------------------------------------------------ happy paths

    function test_LockMintBurnRelease_RoundTrip() public {
        _bridgeToMezo(alice, bob, 3 ether);
        assertEq(wPOT.balanceOf(bob), 3 ether);
        assertEq(wPOT.totalSupply(), 3 ether);
        assertEq(address(gwP).balance, 3 ether);
        assertEq(_lockedOut(gwP, MEZO), 3 ether);

        uint256 before = alice.balance;
        _bridgeBack(bob, alice, 2 ether);
        assertEq(wPOT.balanceOf(bob), 1 ether);
        assertEq(alice.balance, before + 2 ether);
        assertEq(_lockedOut(gwP, MEZO), 1 ether);
        assertEq(address(gwP).balance, 1 ether);
    }

    function test_ReverseRoute_MezoBtcToPortaldot() public {
        vm.chainId(MEZO);
        vm.prank(alice);
        gwM.lockNative{value: 0.5 ether}(PORTALDOT, bob);
        PortalGateway.Transfer memory t = _t(MEZO, PORTALDOT, 1, PortalGateway.Kind.NativeLocked, alice, bob, 0.5 ether);
        vm.chainId(PORTALDOT);
        gwP.receiveTransfer(t, _sigs(_digest(gwP, t), _two()));
        assertEq(wBTC.balanceOf(bob), 0.5 ether);
        assertEq(wBTC.originChainId(), MEZO);
    }

    function test_EventIdEqualsTransferId() public {
        PortalGateway.Transfer memory t = _t(PORTALDOT, MEZO, 1, PortalGateway.Kind.NativeLocked, alice, bob, 1 ether);
        bytes32 id = gwP.transferId(t);
        vm.expectEmit(true, true, true, true, address(gwP));
        emit TransferSent(id, MEZO, 1, PortalGateway.Kind.NativeLocked, alice, bob, 1 ether);
        vm.prank(alice);
        bytes32 got = gwP.lockNative{value: 1 ether}(MEZO, bob);
        assertEq(got, id);
        assertEq(gwM.transferId(t), id, "id is chain independent");
    }

    function test_AnyoneCanRelay_ExtraSignaturesIgnored() public {
        vm.prank(alice);
        gwP.lockNative{value: 1 ether}(MEZO, bob);
        PortalGateway.Transfer memory t = _t(PORTALDOT, MEZO, 1, PortalGateway.Kind.NativeLocked, alice, bob, 1 ether);
        vm.chainId(MEZO);
        uint256[] memory all = new uint256[](3);
        all[0] = 0;
        all[1] = 1;
        all[2] = 2;
        vm.prank(makeAddr("randomRelayer"));
        gwM.receiveTransfer(t, _sigs(_digest(gwM, t), all));
        assertEq(wPOT.balanceOf(bob), 1 ether);
    }

    // ------------------------------------------------------------------ signature checks

    function test_RevertWhen_OnlyOneSignature() public {
        PortalGateway.Transfer memory t = _t(PORTALDOT, MEZO, 1, PortalGateway.Kind.NativeLocked, alice, bob, 1 ether);
        vm.chainId(MEZO);
        uint256[] memory one = new uint256[](1);
        bytes[] memory s = _sigs(_digest(gwM, t), one);
        vm.expectRevert(AttesterSet.NotEnoughSignatures.selector);
        gwM.receiveTransfer(t, s);
    }

    function test_RevertWhen_SameSignerTwice() public {
        PortalGateway.Transfer memory t = _t(PORTALDOT, MEZO, 1, PortalGateway.Kind.NativeLocked, alice, bob, 1 ether);
        vm.chainId(MEZO);
        bytes32 d = _digest(gwM, t);
        bytes[] memory s = new bytes[](2);
        s[0] = _sign(pks[0], d);
        s[1] = _sign(pks[0], d);
        vm.expectRevert(AttesterSet.SignersNotSorted.selector);
        gwM.receiveTransfer(t, s);
    }

    function test_RevertWhen_SignaturesUnsorted() public {
        PortalGateway.Transfer memory t = _t(PORTALDOT, MEZO, 1, PortalGateway.Kind.NativeLocked, alice, bob, 1 ether);
        vm.chainId(MEZO);
        bytes[] memory s = _sigs(_digest(gwM, t), _two());
        (s[0], s[1]) = (s[1], s[0]);
        vm.expectRevert(AttesterSet.SignersNotSorted.selector);
        gwM.receiveTransfer(t, s);
    }

    function test_RevertWhen_UnknownSigner() public {
        PortalGateway.Transfer memory t = _t(PORTALDOT, MEZO, 1, PortalGateway.Kind.NativeLocked, alice, bob, 1 ether);
        vm.chainId(MEZO);
        bytes32 d = _digest(gwM, t);
        uint256 evil = 0xBAD;
        bytes[] memory s = new bytes[](2);
        (bytes memory a, bytes memory b) = (_sign(pks[0], d), _sign(evil, d));
        (s[0], s[1]) = vm.addr(pks[0]) < vm.addr(evil) ? (a, b) : (b, a);
        vm.expectPartialRevert(AttesterSet.UnknownSigner.selector);
        gwM.receiveTransfer(t, s);
    }

    function test_RevertWhen_MalleableHighS() public {
        PortalGateway.Transfer memory t = _t(PORTALDOT, MEZO, 1, PortalGateway.Kind.NativeLocked, alice, bob, 1 ether);
        vm.chainId(MEZO);
        bytes32 d = _digest(gwM, t);
        (uint8 v, bytes32 r, bytes32 sv) = vm.sign(pks[0], d);
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory flipped = abi.encodePacked(r, bytes32(n - uint256(sv)), v == 27 ? uint8(28) : uint8(27));
        bytes[] memory s = new bytes[](2);
        s[0] = flipped;
        s[1] = _sign(pks[1], d);
        vm.expectRevert(AttesterSet.BadSignature.selector);
        gwM.receiveTransfer(t, s);
    }

    function test_RevertWhen_SignatureLengthWrong() public {
        PortalGateway.Transfer memory t = _t(PORTALDOT, MEZO, 1, PortalGateway.Kind.NativeLocked, alice, bob, 1 ether);
        vm.chainId(MEZO);
        bytes[] memory s = new bytes[](2);
        s[0] = hex"1234";
        s[1] = hex"5678";
        vm.expectRevert(AttesterSet.BadSignature.selector);
        gwM.receiveTransfer(t, s);
    }

    function test_RevertWhen_TamperedAmount() public {
        PortalGateway.Transfer memory t = _t(PORTALDOT, MEZO, 1, PortalGateway.Kind.NativeLocked, alice, bob, 1 ether);
        vm.chainId(MEZO);
        bytes[] memory s = _sigs(_digest(gwM, t), _two());
        t.amount = 999 ether; // recovered signers change -> unknown / unsorted
        vm.expectRevert();
        gwM.receiveTransfer(t, s);
        assertEq(wPOT.totalSupply(), 0);
    }

    // ------------------------------------------------------------------ replay & domain

    function test_RevertWhen_Replayed() public {
        PortalGateway.Transfer memory t = _bridgeToMezo(alice, bob, 1 ether);
        bytes[] memory s = _sigs(_digest(gwM, t), _two());
        vm.expectRevert(abi.encodeWithSelector(PortalGateway.AlreadyProcessed.selector, gwM.transferId(t)));
        gwM.receiveTransfer(t, s);
    }

    function test_RevertWhen_WrongDestinationChain() public {
        PortalGateway.Transfer memory t = _t(PORTALDOT, MEZO, 1, PortalGateway.Kind.NativeLocked, alice, bob, 1 ether);
        vm.chainId(PORTALDOT); // delivered to the wrong chain
        vm.expectRevert(PortalGateway.WrongDestination.selector);
        gwP.receiveTransfer(t, new bytes[](0));
    }

    function test_RevertWhen_SignaturesForAnotherGateway() public {
        // A second gateway on the same chain with the same committee must not accept gwM's sigs.
        vm.chainId(MEZO);
        PortalGateway other = new PortalGateway(admin, guardian, attesters, 2);
        WrappedToken w2 = new WrappedToken("x", "x", PORTALDOT);
        w2.bindGateway(address(other));
        vm.prank(admin);
        other.configureRoute(PORTALDOT, address(gwP), w2, _cfg(), _cfg());
        PortalGateway.Transfer memory t = _t(PORTALDOT, MEZO, 1, PortalGateway.Kind.NativeLocked, alice, bob, 1 ether);
        bytes[] memory s = _sigs(_digest(gwM, t), _two());
        vm.expectRevert();
        other.receiveTransfer(t, s);
    }

    function test_RevertWhen_UnknownSourceRoute() public {
        vm.chainId(MEZO);
        PortalGateway.Transfer memory t = _t(1, MEZO, 1, PortalGateway.Kind.NativeLocked, alice, bob, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(PortalGateway.UnknownRoute.selector, uint64(1)));
        gwM.receiveTransfer(t, new bytes[](0));
    }

    // ------------------------------------------------------------------ economic rails

    function test_RevertWhen_ReleaseExceedsEscrow_EvenWithValidSigs() public {
        _bridgeToMezo(alice, bob, 1 ether);
        // A fully compromised committee forges a 50 ether release; escrow only holds 1.
        vm.deal(address(gwP), 100 ether); // unrelated funds sitting in the contract
        PortalGateway.Transfer memory t = _t(MEZO, PORTALDOT, 77, PortalGateway.Kind.WrappedBurned, bob, bob, 50 ether);
        vm.chainId(PORTALDOT);
        bytes[] memory s = _sigs(_digest(gwP, t), _two());
        vm.expectRevert(PortalGateway.EscrowShortfall.selector);
        gwP.receiveTransfer(t, s);
    }

    function test_RateLimit_ThenWindowResets() public {
        vm.chainId(MEZO);
        vm.prank(admin);
        gwM.setLimits(PORTALDOT, true, _cfg(MIN, 2 ether, 3 ether)); // wPOT mints
        _bridgeToMezo(alice, bob, 2 ether);
        assertEq(gwM.windowRemaining(PORTALDOT, true), 1 ether);
        assertEq(gwM.windowRemaining(PORTALDOT, false), CAP, "native release window untouched");

        vm.chainId(PORTALDOT);
        vm.prank(alice);
        gwP.lockNative{value: 2 ether}(MEZO, bob);
        PortalGateway.Transfer memory t = _t(PORTALDOT, MEZO, 2, PortalGateway.Kind.NativeLocked, alice, bob, 2 ether);
        vm.chainId(MEZO);
        bytes[] memory s = _sigs(_digest(gwM, t), _two());
        vm.expectRevert(PortalGateway.RateLimited.selector);
        gwM.receiveTransfer(t, s);

        vm.warp(block.timestamp + 1 days);
        gwM.receiveTransfer(t, s); // same signatures stay valid once capacity frees up
        assertEq(wPOT.balanceOf(bob), 4 ether);
    }

    function test_RevertWhen_AmountOutOfBounds() public {
        vm.startPrank(alice);
        vm.expectRevert(PortalGateway.AmountOutOfBounds.selector);
        gwP.lockNative{value: 0.01 ether}(MEZO, bob);
        vm.expectRevert(PortalGateway.AmountOutOfBounds.selector);
        gwP.lockNative{value: 1_001 ether}(MEZO, bob);
        vm.stopPrank();
    }

    function test_RevertWhen_LockToUnknownChainOrZeroRecipient() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(PortalGateway.UnknownRoute.selector, uint64(5)));
        gwP.lockNative{value: 1 ether}(5, bob);
        vm.expectRevert(PortalGateway.ZeroAddress.selector);
        gwP.lockNative{value: 1 ether}(MEZO, address(0));
        vm.stopPrank();
    }

    function test_AssetLimitsAreIndependent() public {
        // BTC-sized bounds on the wrapped side must not constrain tPOT locks, and vice versa.
        vm.prank(admin);
        gwP.setLimits(MEZO, true, _cfg(0.0001 ether, 0.5 ether, 2 ether)); // wBTC.m
        vm.prank(alice);
        gwP.lockNative{value: 900 ether}(MEZO, bob); // tPOT bound still 1,000
        PortalGateway.Limits memory l = gwP.limits(MEZO, true);
        assertEq(l.maxAmount, 0.5 ether);
        assertEq(gwP.limits(MEZO, false).maxAmount, MAX);
    }

    function test_RevertWhen_BurnMoreThanBalance() public {
        _bridgeToMezo(alice, bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(WrappedToken.InsufficientBalance.selector);
        gwM.burnWrapped(PORTALDOT, bob, 2 ether);
    }

    // ------------------------------------------------------------------ payouts

    function test_RevertingRecipient_PayoutParked_ThenWithdrawn() public {
        RevertingReceiver rr = new RevertingReceiver();
        _bridgeToMezo(alice, bob, 1 ether);
        _bridgeBack(bob, address(rr), 1 ether); // does not revert: relayer queue keeps moving
        assertEq(gwP.owed(address(rr)), 1 ether);
        assertEq(gwP.totalOwed(), 1 ether);
        assertEq(address(gwP).balance, 1 ether);
    }

    function test_ReentrantRecipient_CannotDoubleWithdraw() public {
        ReentrantReceiver re = new ReentrantReceiver(gwP);
        _bridgeToMezo(alice, bob, 1 ether);
        _bridgeBack(bob, address(re), 1 ether);
        // push payout re-entered withdrawOwed -> reverted inside the call -> parked
        assertEq(gwP.owed(address(re)), 1 ether);
        vm.expectRevert(PortalGateway.PayoutFailed.selector); // its receive() re-enters and fails
        re.pull();
        assertEq(gwP.owed(address(re)), 1 ether, "state rolled back, nothing lost");
    }

    function test_WithdrawOwed_RevertsWhenNothingOwed() public {
        vm.expectRevert(PortalGateway.NothingOwed.selector);
        vm.prank(alice);
        gwP.withdrawOwed();
    }

    // ------------------------------------------------------------------ pause & admin

    function test_GuardianPauses_OnlyAdminUnpauses() public {
        vm.prank(guardian);
        gwP.pause();
        vm.prank(alice);
        vm.expectRevert(PortalGateway.IsPaused.selector);
        gwP.lockNative{value: 1 ether}(MEZO, bob);

        vm.prank(guardian);
        vm.expectRevert(PortalGateway.NotAdmin.selector);
        gwP.unpause();

        vm.prank(admin);
        gwP.unpause();
        vm.prank(alice);
        gwP.lockNative{value: 1 ether}(MEZO, bob);
    }

    function test_PausedGatewayRejectsInbound() public {
        vm.chainId(MEZO);
        vm.prank(guardian);
        gwM.pause();
        PortalGateway.Transfer memory t = _t(PORTALDOT, MEZO, 1, PortalGateway.Kind.NativeLocked, alice, bob, 1 ether);
        bytes[] memory s = _sigs(_digest(gwM, t), _two());
        vm.expectRevert(PortalGateway.IsPaused.selector);
        gwM.receiveTransfer(t, s);
    }

    function test_RevertWhen_StrangerPausesOrConfigures() public {
        vm.startPrank(alice);
        vm.expectRevert(PortalGateway.NotGuardian.selector);
        gwP.pause();
        vm.expectRevert(PortalGateway.NotAdmin.selector);
        gwP.setLimits(MEZO, false, _cfg(1, 2, 3));
        vm.expectRevert(PortalGateway.NotAdmin.selector);
        gwP.setGuardian(alice);
        vm.stopPrank();
    }

    function test_RoutesAreWriteOnce() public {
        vm.prank(admin);
        vm.expectRevert(PortalGateway.RouteExists.selector);
        gwP.configureRoute(MEZO, alice, wBTC, _cfg(), _cfg());
        uint64[] memory ids = gwP.routeIds();
        assertEq(ids.length, 1);
        assertEq(ids[0], MEZO);
    }

    function test_RevertWhen_LimitsInconsistent() public {
        vm.startPrank(admin);
        vm.expectRevert(PortalGateway.AmountOutOfBounds.selector);
        gwP.setLimits(MEZO, false, _cfg(0, 1, 1));
        vm.expectRevert(PortalGateway.AmountOutOfBounds.selector);
        gwP.setLimits(MEZO, true, _cfg(2, 1, 5));
        vm.expectRevert(PortalGateway.AmountOutOfBounds.selector);
        gwP.setLimits(MEZO, false, _cfg(1, 10, 5));
        vm.stopPrank();
    }

    function test_AdminTransferIsTwoStep() public {
        vm.prank(admin);
        gwP.proposeAdmin(alice);
        assertEq(gwP.admin(), admin);
        vm.prank(bob);
        vm.expectRevert(PortalGateway.NotAdmin.selector);
        gwP.acceptAdmin();
        vm.prank(alice);
        gwP.acceptAdmin();
        assertEq(gwP.admin(), alice);
        assertEq(gwP.pendingAdmin(), address(0));
    }

    function test_ConstructorRejectsZeroRoles() public {
        vm.expectRevert(PortalGateway.ZeroAddress.selector);
        new PortalGateway(address(0), guardian, attesters, 2);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_RoundTripConservesValue(uint96 rawIn, uint96 rawOut) public {
        uint256 amtIn = bound(rawIn, MIN, MAX);
        uint256 amtOut = bound(rawOut, MIN, amtIn);
        uint256 a0 = alice.balance;
        _bridgeToMezo(alice, bob, amtIn);
        _bridgeBack(bob, alice, amtOut);
        assertEq(alice.balance, a0 - amtIn + amtOut);
        assertEq(wPOT.totalSupply(), amtIn - amtOut);
        assertEq(_lockedOut(gwP, MEZO), wPOT.totalSupply());
        assertEq(address(gwP).balance, wPOT.totalSupply());
    }

    function testFuzz_RejectsAnySingleSigner(uint8 which, uint96 amt) public {
        uint256 a = bound(amt, MIN, MAX);
        PortalGateway.Transfer memory t = _t(PORTALDOT, MEZO, 1, PortalGateway.Kind.NativeLocked, alice, bob, a);
        vm.chainId(MEZO);
        uint256[] memory one = new uint256[](1);
        one[0] = which % 3;
        bytes[] memory s = _sigs(_digest(gwM, t), one);
        vm.expectRevert(AttesterSet.NotEnoughSignatures.selector);
        gwM.receiveTransfer(t, s);
    }
}
