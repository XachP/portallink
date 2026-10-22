// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WrappedToken} from "../src/WrappedToken.sol";

contract WrappedTokenTest is Test {
    WrappedToken internal w;
    address internal gw = makeAddr("gateway");
    address internal a = makeAddr("a");
    address internal b = makeAddr("b");

    function setUp() public {
        w = new WrappedToken("PortalLink Wrapped tPOT", "wPOT", 420420777);
        w.bindGateway(gw);
        vm.prank(gw);
        w.mint(a, 10 ether);
    }

    function test_Metadata() public view {
        assertEq(w.symbol(), "wPOT");
        assertEq(w.decimals(), 18);
        assertEq(w.originChainId(), 420420777);
        assertEq(w.gateway(), gw);
    }

    function test_BindOnlyOnceAndOnlyByDeployer() public {
        vm.expectRevert(WrappedToken.AlreadyBound.selector);
        w.bindGateway(a);
        WrappedToken w2 = new WrappedToken("x", "x", 1);
        vm.prank(a);
        vm.expectRevert(WrappedToken.NotGateway.selector);
        w2.bindGateway(a);
    }

    function test_OnlyGatewayMintsAndBurns() public {
        vm.startPrank(a);
        vm.expectRevert(WrappedToken.NotGateway.selector);
        w.mint(a, 1);
        vm.expectRevert(WrappedToken.NotGateway.selector);
        w.burnFrom(a, 1);
        vm.stopPrank();
    }

    function test_TransferApproveTransferFrom() public {
        vm.prank(a);
        w.transfer(b, 4 ether);
        assertEq(w.balanceOf(b), 4 ether);
        vm.prank(b);
        w.approve(a, 1 ether);
        vm.prank(a);
        w.transferFrom(b, a, 1 ether);
        assertEq(w.allowance(b, a), 0);
        vm.prank(a);
        vm.expectRevert(WrappedToken.InsufficientAllowance.selector);
        w.transferFrom(b, a, 1);
    }

    function test_InfiniteAllowanceNotDecremented() public {
        vm.prank(a);
        w.approve(b, type(uint256).max);
        vm.prank(b);
        w.transferFrom(a, b, 1 ether);
        assertEq(w.allowance(a, b), type(uint256).max);
    }

    function test_RevertWhen_TransferToZeroOrOverBalance() public {
        vm.startPrank(a);
        vm.expectRevert(WrappedToken.ZeroAddress.selector);
        w.transfer(address(0), 1);
        vm.expectRevert(WrappedToken.InsufficientBalance.selector);
        w.transfer(b, 11 ether);
        vm.stopPrank();
    }

    function testFuzz_SupplyTracksMintBurn(uint128 m, uint128 x) public {
        uint256 burn = bound(x, 0, uint256(m));
        vm.startPrank(gw);
        w.mint(b, m);
        w.burnFrom(b, burn);
        vm.stopPrank();
        assertEq(w.totalSupply(), 10 ether + uint256(m) - burn);
        assertEq(w.balanceOf(b), uint256(m) - burn);
    }
}
