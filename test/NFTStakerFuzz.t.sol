// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";

/// @notice Fuzz over the M-03 / S-based APY-driven schedule. Two property
///         classes:
///           1. `_recomputeSchedule` never reverts across the stated input
///              bounds (totalStaked, growthBP, price, targetAPY, V).
///           2. Computed `rewardRate` matches the closed-form reference
///              EXACTLY (single mulDiv, no rpow — so no rounding tolerance
///              is needed).
///         Also keeps the legacy depletion-invariant harness as a
///         solvency smoke test: claimed + pending across 3 actors must
///         never exceed the seeded budget (plus a rounding buffer that
///         absorbs per-update floor-division drift).
contract NFTStakerFuzzTest is Test {
    using Math for uint256;

    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address[3] internal stakers;

    uint256 internal constant ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;
    uint256 internal constant APY_PRECISION = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant ROUNDING_BUFFER = 1_000_000;
    uint256 internal initialBudget;

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        // Uniform price for easier depletion math.
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 0, false);
        nftMinter.setTotalSupply(ID, 100);

        staker = new NFTStaker(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(nftMinter)), DISPATCHER_INDEX
        );

        initialBudget = 1_000_000 ether;
        phUSD.mint(owner, initialBudget);
        vm.prank(owner);
        phUSD.approve(address(staker), initialBudget);
        vm.prank(owner);
        staker.topUp(initialBudget);

        vm.prank(owner);
        staker.setTargetAPY(0.3e18);

        // Seed a rounding buffer that is NOT tracked in rewardBudget.
        phUSD.mint(address(staker), ROUNDING_BUFFER);

        stakers[0] = address(0xA1);
        stakers[1] = address(0xA2);
        stakers[2] = address(0xA3);
        for (uint256 i = 0; i < 3; i++) {
            nft.mint(stakers[i], ID, type(uint128).max);
            vm.prank(stakers[i]);
            nft.setApprovalForAll(address(staker), true);
        }
    }

    // -------------------------------------------------------------------
    // _recomputeSchedule fuzz — never reverts, matches closed form
    // -------------------------------------------------------------------

    function _closedFormRate(uint256 price, uint256 growthBP, uint256 totalStaked_, uint256 A)
        internal
        pure
        returns (uint256)
    {
        uint256 latestPrice;
        if (price == 0) {
            latestPrice = 0;
        } else if (growthBP == 0) {
            latestPrice = price;
        } else {
            uint256 r = APY_PRECISION + growthBP * 1e14;
            latestPrice = Math.mulDiv(price, APY_PRECISION, r);
        }
        uint256 S = (totalStaked_ == 0 || latestPrice == 0) ? 0 : totalStaked_ * latestPrice;
        uint256 F = Math.mulDiv(S, A, APY_PRECISION);
        return (F == 0) ? 0 : F / SECONDS_PER_YEAR;
    }

    /// @notice Closed-form fuzz: for any (totalStaked, latestPrice,
    ///         targetAPY) inside the stated bounds, the rate the contract
    ///         computes equals (totalStaked * latestPrice * targetAPY /
    ///         1e18) / SECONDS_PER_YEAR EXACTLY (single mulDiv, no rpow).
    function testFuzzRecomputeMatchesClosedForm(uint16 growthBPRaw, uint64 stakedRaw, uint128 priceSeed, uint16 apyBP)
        public
    {
        // Bound inputs to realistic ranges. With S = totalStaked *
        // latestPrice and latestPrice <= 1e6 ether (~1e24), totalStaked up
        // to 1e6 keeps S below 2^160 — comfortably below 2^256.
        uint256 growthBP = uint256(growthBPRaw) % 101; // 0..100 BP
        uint256 toStake = (uint256(stakedRaw) % 1_000_000) + 1; // 1..1_000_000
        uint256 price = (uint256(priceSeed) % (1_000_000 ether)) + 1;
        // apyBP 0..5000 basis points i.e. 0..50%
        uint256 A = (uint256(apyBP) % 5001) * 1e14;

        // Stand up a dedicated staker to isolate the recompute.
        MockNFTMinter m = new MockNFTMinter();
        m.setConfig(DISPATCHER_INDEX, address(0xBEEF), price, growthBP, false);
        m.setTotalSupply(ID, toStake);

        NFTStaker s = new NFTStaker(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(m)), DISPATCHER_INDEX
        );

        uint256 V = 123_456 ether;
        phUSD.mint(address(s), V);

        // Stake `toStake` to make S non-zero. Use a fresh staker actor
        // and mint + approve on the per-test staker `s`.
        nft.mint(stakers[0], ID, toStake);
        vm.prank(stakers[0]);
        nft.setApprovalForAll(address(s), true);
        vm.prank(stakers[0]);
        s.stake(toStake);

        // Setting the APY triggers _recomputeSchedule. Must not revert.
        vm.prank(owner);
        s.setTargetAPY(A);

        uint256 expected = _closedFormRate(price, growthBP, toStake, A);
        assertEq(s.rewardRate(), expected, "rate must match S-based closed form");
    }

    function testFuzzRecomputeDoesNotRevertWhenVZero(
        uint16 growthBPRaw,
        uint64 stakedRaw,
        uint128 priceSeed,
        uint16 apyBP
    ) public {
        uint256 growthBP = uint256(growthBPRaw) % 101; // 0..100 BP
        uint256 toStake = (uint256(stakedRaw) % 1_000_000) + 1;
        uint256 price = (uint256(priceSeed) % (1_000_000 ether)) + 1;
        uint256 A = (uint256(apyBP) % 5001) * 1e14;

        MockNFTMinter m = new MockNFTMinter();
        m.setConfig(DISPATCHER_INDEX, address(0xBEEF), price, growthBP, false);
        m.setTotalSupply(ID, toStake);

        NFTStaker s = new NFTStaker(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(m)), DISPATCHER_INDEX
        );

        // No V. Stake to make totalStaked non-zero.
        nft.mint(stakers[0], ID, toStake);
        vm.prank(stakers[0]);
        nft.setApprovalForAll(address(s), true);
        vm.prank(stakers[0]);
        s.stake(toStake);

        vm.prank(owner);
        s.setTargetAPY(A);
        // windowEnd must equal block.timestamp (runway = 0, V = 0).
        assertEq(s.windowEnd(), block.timestamp);
    }

    // -------------------------------------------------------------------
    // Solvency smoke — claimed + pending <= seeded budget (+ buffer)
    // -------------------------------------------------------------------

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

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(stakers[i]);
            staker.stake(amounts[i]);
            uint256 dt = uint256(warps[i]) % (1_000 days) + 1;
            vm.warp(block.timestamp + dt);
        }

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(stakers[i]);
            staker.claim();
        }

        vm.warp(block.timestamp + 30 days);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(stakers[i]);
            staker.claim();
        }

        uint256 totalClaimed;
        for (uint256 i = 0; i < 3; i++) {
            totalClaimed += phUSD.balanceOf(stakers[i]);
        }

        uint256 totalPending;
        for (uint256 i = 0; i < 3; i++) {
            totalPending += staker.pendingReward(stakers[i]);
        }

        assertLe(totalClaimed + totalPending, initialBudget + ROUNDING_BUFFER, "depletion invariant violated");
    }

    function testFuzzFullDrainStaysWithinBudget(uint64 amount0, uint64 amount1, uint64 amount2) public {
        uint256[3] memory amounts;
        amounts[0] = uint256(amount0) % 1_000_000 + 1;
        amounts[1] = uint256(amount1) % 1_000_000 + 1;
        amounts[2] = uint256(amount2) % 1_000_000 + 1;

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(stakers[i]);
            staker.stake(amounts[i]);
        }

        vm.warp(staker.windowEnd() + 365 days);

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(stakers[i]);
            staker.unstake(amounts[i]);
        }

        uint256 totalClaimed;
        for (uint256 i = 0; i < 3; i++) {
            totalClaimed += phUSD.balanceOf(stakers[i]);
        }

        assertLe(totalClaimed, initialBudget + ROUNDING_BUFFER, "drained more than initial budget");
        assertEq(
            phUSD.balanceOf(address(staker)) + totalClaimed,
            initialBudget + ROUNDING_BUFFER,
            "balance + claimed != initial + buffer"
        );
    }

    // -------------------------------------------------------------------
    // Strong solvency invariant: balance == rewardBudget + committedDebt
    // -------------------------------------------------------------------

    function _assertSolvency() internal view {
        assertEq(
            phUSD.balanceOf(address(staker)),
            staker.rewardBudget() + staker.committedDebt(),
            "balance != rewardBudget + committedDebt"
        );
    }

    /// @notice Drives a bounded random sequence of (stake / warp+claim /
    ///         unstake / topUp / pullAndRefresh / setTargetAPY) per actor
    ///         and asserts the strong invariant after every action. Audit
    ///         M-01 fix: pre-fix the invariant only held at recompute
    ///         boundaries; post-fix it holds always. Audit M-03 fix: the
    ///         tail recompute on stake/unstake doesn't touch budget
    ///         accounting (no pull, no _updatePool between head and tail),
    ///         so the invariant holds across the new code path too.
    function testFuzzSolvencyInvariantHoldsAcrossRandomActions(uint256 seed) public {
        // The setUp mints ROUNDING_BUFFER directly to the staker AFTER
        // the topUp's recompute, so balance temporarily exceeds
        // rewardBudget by that amount. Trigger a recompute up-front to
        // fold the buffer into rewardBudget so the strong invariant
        // applies from action 0.
        vm.prank(owner);
        staker.pullAndRefresh();
        _assertSolvency();

        uint256 actions = 32;
        // Each staker holds 1000 NFT units to start (plus they got
        // type(uint128).max in setUp). Use a small per-action stake to
        // keep accruals bounded.
        for (uint256 i = 0; i < actions; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 actor = (r >> 8) % 3;
            uint256 op = r % 7;
            uint256 dt = ((r >> 16) % (90 days)) + 1;

            // Always advance time to exercise accrual.
            vm.warp(block.timestamp + dt);

            if (op == 0) {
                // stake — small amount to avoid overflow with uint128 supply
                uint256 amt = ((r >> 32) % 100) + 1;
                vm.prank(stakers[actor]);
                staker.stake(amt);
            } else if (op == 1) {
                // unstake — only if the actor has stake
                (uint256 amt,) = staker.users(stakers[actor]);
                if (amt > 0) {
                    uint256 toUnstake = ((r >> 32) % amt) + 1;
                    vm.prank(stakers[actor]);
                    staker.unstake(toUnstake);
                }
            } else if (op == 2) {
                // claim — always safe even with zero stake (no-op)
                vm.prank(stakers[actor]);
                staker.claim();
            } else if (op == 3) {
                // topUp from owner
                uint256 amt = (((r >> 32) % 1000) + 1) * 1 ether;
                phUSD.mint(owner, amt);
                vm.prank(owner);
                phUSD.approve(address(staker), amt);
                vm.prank(owner);
                staker.topUp(amt);
            } else if (op == 4) {
                // pullAndRefresh
                vm.prank(owner);
                staker.pullAndRefresh();
            } else if (op == 5) {
                // setTargetAPY — bounded to MAX_TARGET_APY
                uint256 newAPY = ((r >> 32) % 5001) * 1e14;
                vm.prank(owner);
                staker.setTargetAPY(newAPY);
            } else {
                // op == 6: noop time advance, no action — invariant must
                // still hold without any state change.
            }

            _assertSolvency();
        }
    }
}
