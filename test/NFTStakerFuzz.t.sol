// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Fuzz harness for the depletion invariant. With three users
///         taking arbitrary stake amounts and arbitrary time warps between
///         interactions (no top-ups, no dispatcher hook), the sum of all
///         claimed phUSD plus the sum of all currently-pending rewards must
///         never exceed the initial budget seeded via topUp.
contract NFTStakerFuzzTest is Test {
    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;

    address internal owner = address(0xD1);
    address[3] internal stakers;

    uint256 internal constant ID = 1;
    uint256 internal initialBudget;

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        staker = new NFTStaker(IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner);

        // Pick a tidy initial budget that divides cleanly by windowDuration
        initialBudget = staker.windowDuration() * 1_000_000;
        phUSD.mint(owner, initialBudget);
        vm.prank(owner);
        phUSD.approve(address(staker), initialBudget);
        vm.prank(owner);
        staker.topUp(initialBudget);

        stakers[0] = address(0xA1);
        stakers[1] = address(0xA2);
        stakers[2] = address(0xA3);
        for (uint256 i = 0; i < 3; i++) {
            nft.mint(stakers[i], ID, type(uint128).max);
            vm.prank(stakers[i]);
            nft.setApprovalForAll(address(staker), true);
        }
    }

    /// Fuzz: 3 actors, each with a (bounded) stake amount and warp interval.
    /// At each step the actor either stakes, claims, or unstakes a fraction.
    /// Final invariant: total phUSD distributed (claimed + still-pending) <= initialBudget.
    function testFuzzDepletionInvariant(
        uint64 amount0,
        uint64 amount1,
        uint64 amount2,
        uint32 warp0,
        uint32 warp1,
        uint32 warp2
    ) public {
        uint256[3] memory amounts;
        amounts[0] = uint256(amount0) % 1_000_000 + 1;
        amounts[1] = uint256(amount1) % 1_000_000 + 1;
        amounts[2] = uint256(amount2) % 1_000_000 + 1;

        uint32[3] memory warps = [warp0, warp1, warp2];

        // Each actor stakes an arbitrary amount, warp arbitrary time
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(stakers[i]);
            staker.stake(amounts[i]);
            // Bound warp to keep it reasonable but able to span past windowEnd
            uint256 dt = uint256(warps[i]) % (1_000 days) + 1;
            vm.warp(block.timestamp + dt);
        }

        // Each actor claims
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(stakers[i]);
            staker.claim();
        }

        // Sanity warp + claim round 2
        vm.warp(block.timestamp + 30 days);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(stakers[i]);
            staker.claim();
        }

        // Sum claimed (== phUSD balance of each staker, since none was minted to them)
        uint256 totalClaimed;
        for (uint256 i = 0; i < 3; i++) {
            totalClaimed += phUSD.balanceOf(stakers[i]);
        }

        // Sum pending across all three
        uint256 totalPending;
        for (uint256 i = 0; i < 3; i++) {
            totalPending += staker.pendingReward(stakers[i]);
        }

        // The depletion invariant
        assertLe(totalClaimed + totalPending, initialBudget, "depletion invariant violated");
    }

    /// Tighter check: drain everyone fully (warp far past windowEnd, all
    /// users claim, then unstake) and assert claimed total <= initialBudget.
    function testFuzzFullDrainStaysWithinBudget(uint64 amount0, uint64 amount1, uint64 amount2) public {
        uint256[3] memory amounts;
        amounts[0] = uint256(amount0) % 1_000_000 + 1;
        amounts[1] = uint256(amount1) % 1_000_000 + 1;
        amounts[2] = uint256(amount2) % 1_000_000 + 1;

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(stakers[i]);
            staker.stake(amounts[i]);
        }

        // Warp far past windowEnd
        vm.warp(staker.windowEnd() + 365 days);

        // Each actor unstakes their full amount (which also pays pending)
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(stakers[i]);
            staker.unstake(amounts[i]);
        }

        uint256 totalClaimed;
        for (uint256 i = 0; i < 3; i++) {
            totalClaimed += phUSD.balanceOf(stakers[i]);
        }

        assertLe(totalClaimed, initialBudget, "drained more than initial budget");
        // Plus the pool's leftover phUSD must reconcile: leftover == initialBudget - claimed
        assertEq(phUSD.balanceOf(address(staker)) + totalClaimed, initialBudget, "balance + claimed != initial");
    }
}
