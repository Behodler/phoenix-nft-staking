// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStakerDepletion} from "../src/NFTStakerDepletion.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {IUniboostMintDebtHook} from "yield-claim-nft/interfaces/IUniboostMintDebtHook.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";
import {MockUniboostMintDebtHook} from "./mocks/MockUniboostMintDebtHook.sol";

/// @notice TDD suite for `NFTStakerDepletion` — the depletion-window copy of
///         `NFTStaker`. Proves: constructor wiring, the owner-set
///         depletion-window setter + bounds, the inverted rate model
///         (`rewardRate = budget / windowSeconds`, `windowEnd = now +
///         windowSeconds`), the dropped dispatcher-price dependency, end-to-end
///         accrual/claim, full-window depletion-to-dust, `rescueERC20` (incl.
///         the rewardToken invariant guard), the Uniboost hook pull
///         integration, and owner-only permissions.
contract NFTStakerDepletionTest is Test {
    NFTStakerDepletion internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal pauser = address(0xBA5E);
    address internal stranger = address(0xCAFE);

    uint256 internal constant ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;
    uint256 internal constant SECONDS_PER_MONTH = 365 days / 12;
    uint256 internal constant MAX_DEPLETION_MONTHS = 120;

    // Locally-redeclared events/errors for expectEmit/expectRevert (solc 0.8.20
    // cannot reference `Contract.Event` / `Contract.Error` qualified members).
    event DepletionWindowChanged(uint256 previous, uint256 next);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error Rescue__ZeroRecipient();

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        // Config price is intentionally irrelevant to the depletion rate.
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100e6, 0, false);
        nftMinter.setTotalSupply(ID, 0);

        staker = new NFTStakerDepletion(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(nftMinter)), DISPATCHER_INDEX
        );
    }

    // ----- helpers -----

    function _stakeAs(address who, uint256 amount) internal {
        nft.mint(who, ID, amount);
        vm.prank(who);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(who);
        staker.stake(amount);
    }

    // -------------------------------------------------------------------
    // Constructor / wiring
    // -------------------------------------------------------------------

    function testConstructorWiresState() public view {
        assertEq(address(staker.stakedToken()), address(nft), "stakedToken");
        assertEq(staker.stakedId(), ID, "stakedId");
        assertEq(address(staker.rewardToken()), address(phUSD), "rewardToken");
        assertEq(address(staker.nftMinter()), address(nftMinter), "nftMinter");
        assertEq(staker.dispatcherIndex(), DISPATCHER_INDEX, "dispatcherIndex");
        assertEq(staker.owner(), owner, "owner");
        assertEq(staker.depletionWindowMonths(), 0, "depletionWindowMonths default");
        assertEq(staker.SECONDS_PER_MONTH(), 365 days / 12, "SECONDS_PER_MONTH constant");
        assertEq(staker.MAX_DEPLETION_MONTHS(), MAX_DEPLETION_MONTHS, "MAX_DEPLETION_MONTHS constant");
    }

    function testConstructorRejectsZeroStakedToken() public {
        vm.expectRevert(bytes("NFTStaker: zero staked token"));
        new NFTStakerDepletion(
            IERC1155(address(0)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(nftMinter)), DISPATCHER_INDEX
        );
    }

    function testConstructorRejectsZeroRewardToken() public {
        vm.expectRevert(bytes("NFTStaker: zero reward token"));
        new NFTStakerDepletion(
            IERC1155(address(nft)), ID, IERC20(address(0)), owner, INFTSupply(address(nftMinter)), DISPATCHER_INDEX
        );
    }

    function testConstructorRejectsZeroNFTMinter() public {
        vm.expectRevert(bytes("NFTStaker: zero nft minter"));
        new NFTStakerDepletion(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(0)), DISPATCHER_INDEX
        );
    }

    // -------------------------------------------------------------------
    // setDepletionWindow — bounds, ownership, event, rate model
    // -------------------------------------------------------------------

    function testSetDepletionWindowOnlyOwner() public {
        vm.expectRevert();
        vm.prank(stranger);
        staker.setDepletionWindow(12);
    }

    function testSetDepletionWindowRejectsZero() public {
        vm.expectRevert(bytes("NFTStaker: window out of range"));
        vm.prank(owner);
        staker.setDepletionWindow(0);
    }

    function testSetDepletionWindowRejectsAboveMax() public {
        vm.expectRevert(bytes("NFTStaker: window out of range"));
        vm.prank(owner);
        staker.setDepletionWindow(MAX_DEPLETION_MONTHS + 1);
    }

    function testSetDepletionWindowAcceptsBounds() public {
        vm.prank(owner);
        staker.setDepletionWindow(1);
        assertEq(staker.depletionWindowMonths(), 1, "min bound");

        vm.prank(owner);
        staker.setDepletionWindow(MAX_DEPLETION_MONTHS);
        assertEq(staker.depletionWindowMonths(), MAX_DEPLETION_MONTHS, "max bound");
    }

    function testSetDepletionWindowEmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(staker));
        emit DepletionWindowChanged(0, 12);
        vm.prank(owner);
        staker.setDepletionWindow(12);
    }

    // -------------------------------------------------------------------
    // Rate model — rewardRate = budget / windowSeconds, independent of price
    // -------------------------------------------------------------------

    function testRateDerivesFromBudgetOverWindow() public {
        uint256 budget = 1_000_000 ether;
        phUSD.mint(address(staker), budget);
        _stakeAs(alice, 5);

        uint256 months = 12;
        vm.prank(owner);
        staker.setDepletionWindow(months);

        uint256 windowSeconds = months * SECONDS_PER_MONTH;
        uint256 expectedRate = budget / windowSeconds;
        assertEq(staker.rewardRate(), expectedRate, "rate != budget/window");
        assertEq(staker.rewardBudget(), budget, "budget");
        assertEq(staker.windowEnd(), block.timestamp + windowSeconds, "windowEnd");
    }

    function testRateIndependentOfDispatcherPrice() public {
        uint256 budget = 1_000_000 ether;
        phUSD.mint(address(staker), budget);
        _stakeAs(alice, 5);

        vm.prank(owner);
        staker.setDepletionWindow(12);
        uint256 rateBefore = staker.rewardRate();

        // Swing the dispatcher price wildly — must not move the rate.
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 999_999e18, 5000, false);
        vm.prank(owner);
        staker.pullAndRefresh();
        assertEq(staker.rewardRate(), rateBefore, "rate moved with dispatcher price");
    }

    function testRateFloorsToZeroForTinyBudget() public {
        // budget=1 wei over a 120-month window floors to 0.
        phUSD.mint(address(staker), 1);
        _stakeAs(alice, 1);
        vm.prank(owner);
        staker.setDepletionWindow(MAX_DEPLETION_MONTHS);
        assertEq(staker.rewardRate(), 0, "tiny budget must floor rate to zero");
    }

    // -------------------------------------------------------------------
    // Accrual / claim end-to-end
    // -------------------------------------------------------------------

    function testAccrualAndClaim() public {
        uint256 budget = 1_000_000 ether;
        phUSD.mint(address(staker), budget);
        _stakeAs(alice, 10);

        vm.prank(owner);
        staker.setDepletionWindow(12);
        uint256 rate = staker.rewardRate();
        assertGt(rate, 0, "rate must be non-zero");

        assertEq(staker.pendingReward(alice), 0, "no accrual before warp");
        vm.warp(block.timestamp + 1 days);
        uint256 expected = rate * 1 days;
        assertEq(staker.pendingReward(alice), expected, "pending == rate*dt");

        uint256 before = phUSD.balanceOf(alice);
        vm.prank(alice);
        staker.claim();
        assertEq(phUSD.balanceOf(alice) - before, expected, "claim transfers accrual");
        assertEq(staker.pendingReward(alice), 0, "pending zeroed");
    }

    // -------------------------------------------------------------------
    // Invariant: balance == rewardBudget + committedDebt
    // -------------------------------------------------------------------

    function _assertInvariant() internal view {
        assertEq(
            phUSD.balanceOf(address(staker)),
            staker.rewardBudget() + staker.committedDebt(),
            "balance != rewardBudget + committedDebt"
        );
    }

    function testInvariantHoldsThroughLifecycle() public {
        phUSD.mint(address(staker), 500_000 ether);
        _stakeAs(alice, 4);
        // Post-M-01: a bare stake no longer recomputes, so a directly-minted
        // balance is not folded into `rewardBudget` until a genuine
        // budget/window change. The first recompute that reconciles the
        // injected funds is `setDepletionWindow` below.
        vm.prank(owner);
        staker.setDepletionWindow(6);
        _assertInvariant();

        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        staker.claim();
        _assertInvariant();

        _stakeAs(bob, 4);
        _assertInvariant();

        vm.warp(block.timestamp + 10 days);
        vm.prank(bob);
        staker.unstake(2);
        _assertInvariant();

        vm.prank(alice);
        staker.claim();
        _assertInvariant();
    }

    // -------------------------------------------------------------------
    // Full-window depletion to dust
    // -------------------------------------------------------------------

    function testDepletesToDustOverWindow() public {
        uint256 budget = 1_000_000 ether;
        phUSD.mint(address(staker), budget);
        _stakeAs(alice, 1);

        uint256 months = 12;
        vm.prank(owner);
        staker.setDepletionWindow(months);
        uint256 windowSeconds = months * SECONDS_PER_MONTH;
        uint256 rate = staker.rewardRate();

        // Warp past the full window.
        vm.warp(block.timestamp + windowSeconds + 1 days);
        vm.prank(alice);
        staker.claim();

        // Floor dust retained == budget - rate*windowSeconds (< windowSeconds).
        uint256 dust = budget - rate * windowSeconds;
        assertLt(dust, windowSeconds, "dust must be < windowSeconds wei");
        assertEq(phUSD.balanceOf(address(staker)), dust, "residual must equal floor dust");
        assertEq(phUSD.balanceOf(alice), rate * windowSeconds, "paid out the full emitted amount");
        // No further emissions after windowEnd.
        assertEq(staker.currentRewardRate(), 0, "rate zero past windowEnd");
    }

    // -------------------------------------------------------------------
    // dispatcherIndex / nftMinter identity setters (empty-pool gated)
    // -------------------------------------------------------------------

    function testSetDispatcherIndexGatedOnEmptyPool() public {
        _stakeAs(alice, 1);
        vm.expectRevert(bytes("NFTStaker: stake outstanding"));
        vm.prank(owner);
        staker.setDispatcherIndex(2);
    }

    function testSetDispatcherIndexWhenEmpty() public {
        vm.prank(owner);
        staker.setDispatcherIndex(2);
        assertEq(staker.dispatcherIndex(), 2, "dispatcherIndex updated");
    }

    function testSetNFTMinterGatedOnEmptyPool() public {
        _stakeAs(alice, 1);
        vm.expectRevert(bytes("NFTStaker: stake outstanding"));
        vm.prank(owner);
        staker.setNFTMinter(INFTSupply(address(nftMinter)));
    }

    // -------------------------------------------------------------------
    // Uniboost hook pull integration
    // -------------------------------------------------------------------

    function testHookPullFundsBudget() public {
        MockUniboostMintDebtHook hook = new MockUniboostMintDebtHook(phUSD, address(staker));
        vm.prank(owner);
        staker.setDispatcherHook(IUniboostMintDebtHook(address(hook)));

        _stakeAs(alice, 1);
        vm.prank(owner);
        staker.setDepletionWindow(12);

        // Pending mint debt at the hook is swept by _syncBudget on interaction.
        hook.setPendingMint(100_000 ether);
        assertEq(staker.totalBudget(), 100_000 ether, "totalBudget includes mintDebt");

        vm.prank(owner);
        staker.pullAndRefresh();
        assertEq(phUSD.balanceOf(address(staker)), 100_000 ether, "pull minted phUSD into staker");
        assertEq(staker.rewardBudget(), 100_000 ether, "budget reflects pulled funds");
        assertEq(hook.mintDebt(), 0, "mintDebt zeroed after pull");
    }

    function testRecomputeIncludesMintDebtInBudget() public {
        MockUniboostMintDebtHook hook = new MockUniboostMintDebtHook(phUSD, address(staker));
        vm.prank(owner);
        staker.setDispatcherHook(IUniboostMintDebtHook(address(hook)));
        _stakeAs(alice, 1);

        hook.setPendingMint(120_000 ether); // unpulled mint debt counts in V
        vm.prank(owner);
        staker.setDepletionWindow(12);
        uint256 windowSeconds = 12 * SECONDS_PER_MONTH;
        assertEq(staker.rewardRate(), uint256(120_000 ether) / windowSeconds, "rate must include mintDebt in V");
    }

    // -------------------------------------------------------------------
    // rescueERC20
    // -------------------------------------------------------------------

    function testRescueNonRewardTokenFree() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        other.mint(address(staker), 1_000 ether);

        vm.prank(owner);
        staker.rescueERC20(IERC20(address(other)), bob, 1_000 ether);
        assertEq(other.balanceOf(bob), 1_000 ether, "non-reward token rescued");
    }

    function testRescueOnlyOwner() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        other.mint(address(staker), 1_000 ether);
        vm.expectRevert();
        vm.prank(stranger);
        staker.rescueERC20(IERC20(address(other)), bob, 1_000 ether);
    }

    function testRescueZeroRecipientReverts() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        other.mint(address(staker), 1_000 ether);
        vm.expectRevert(Rescue__ZeroRecipient.selector);
        vm.prank(owner);
        staker.rescueERC20(IERC20(address(other)), address(0), 1_000 ether);
    }

    function testRescueRewardTokenSurplusAllowed() public {
        // Stake + accrue some committedDebt, then rescue only surplus.
        uint256 budget = 1_000_000 ether;
        phUSD.mint(address(staker), budget);
        _stakeAs(alice, 1);
        vm.prank(owner);
        staker.setDepletionWindow(12);

        vm.warp(block.timestamp + 5 days);
        // Settle accrual so committedDebt > 0.
        vm.prank(owner);
        staker.pullAndRefresh();
        uint256 committed = staker.committedDebt();
        assertGt(committed, 0, "expected some committed debt");

        // Rescue an amount that keeps balance >= committedDebt.
        uint256 rescueAmt = budget - committed - 1 ether;
        vm.prank(owner);
        staker.rescueERC20(IERC20(address(phUSD)), bob, rescueAmt);

        assertEq(phUSD.balanceOf(bob), rescueAmt, "surplus rescued");
        // Invariant re-derived from reduced balance.
        _assertInvariant();
        assertGe(phUSD.balanceOf(address(staker)), staker.committedDebt(), "balance must cover committedDebt");
    }

    function testRescueRewardTokenCannotBreachCommittedDebt() public {
        uint256 budget = 1_000_000 ether;
        phUSD.mint(address(staker), budget);
        _stakeAs(alice, 1);
        vm.prank(owner);
        staker.setDepletionWindow(12);

        vm.warp(block.timestamp + 5 days);
        vm.prank(owner);
        staker.pullAndRefresh();
        uint256 committed = staker.committedDebt();
        assertGt(committed, 0, "expected some committed debt");

        // Attempt to rescue more than surplus -> must revert.
        uint256 tooMuch = budget - committed + 1;
        vm.expectRevert(bytes("NFTStaker: rescue breaches committedDebt"));
        vm.prank(owner);
        staker.rescueERC20(IERC20(address(phUSD)), bob, tooMuch);
    }

    function testRescueEmitsEvent() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        other.mint(address(staker), 1_000 ether);
        vm.expectEmit(true, true, false, true, address(staker));
        emit Rescued(address(other), bob, 1_000 ether);
        vm.prank(owner);
        staker.rescueERC20(IERC20(address(other)), bob, 1_000 ether);
    }

    // -------------------------------------------------------------------
    // Pausable wiring
    // -------------------------------------------------------------------

    function testPauseBlocksStake() public {
        vm.prank(owner);
        staker.setPauser(pauser);
        vm.prank(pauser);
        staker.pause();

        nft.mint(alice, ID, 1);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
        vm.expectRevert();
        vm.prank(alice);
        staker.stake(1);
    }
}
