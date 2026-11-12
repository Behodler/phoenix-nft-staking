// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ITokenMinterV2} from "yield-claim-nft/interfaces/ITokenMinterV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {BatchNFTMinterNudgeDiscount} from "../src/BatchNFTMinterNudgeDiscount.sol";
import {ISkyPSM} from "../src/interfaces/ISkyPSM.sol";
import {IMintDebtRatio} from "../src/interfaces/IMintDebtRatio.sol";
import {MockNFTMinterV2MintFor} from "./mocks/MockNFTMinterV2MintFor.sol";
import {MockTokenDispatcherV2} from "./mocks/MockTokenDispatcherV2.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockSkyPSM} from "./mocks/MockSkyPSM.sol";
import {MockSUSDS} from "./mocks/MockSUSDS.sol";
import {MockBurnablePhUSD} from "./mocks/MockBurnablePhUSD.sol";
import {MockMintDebtRatioHook} from "./mocks/MockMintDebtRatioHook.sol";
import {MockUniV2AmmPair, MockUniV2AmmRouter} from "./mocks/MockUniV2Amm.sol";
import {MockFeeOnTransferERC20} from "./mocks/MockFeeOnTransferERC20.sol";
import {MockDonatingOnPullERC20} from "./mocks/MockDonatingOnPullERC20.sol";

/// @notice Shared fixture for every `BatchNFTMinterNudgeDiscount` suite (unit, buy, stream,
///         invariant). Mocks only: NFTMinterV2 with `mintFor`, Sky PSM, sUSDS, a faithful
///         UniV2 sUSDS/phUSD pair + router, allowance-burn phUSD and a settable-ratio hook.
abstract contract NudgeDiscountFixture is Test {
    BatchNFTMinterNudgeDiscount internal batch;
    MockNFTMinterV2MintFor internal minter;
    MockTokenDispatcherV2 internal disp;
    MockERC1155 internal nft;
    MockERC20 internal usds;
    MockUSDC internal usdc;
    MockSkyPSM internal psm;
    MockSUSDS internal sUSDS;
    MockBurnablePhUSD internal phUSD;
    MockERC20 internal kendu;
    MockUniV2AmmPair internal pair;
    MockUniV2AmmRouter internal router;
    MockMintDebtRatioHook internal hook;

    address internal owner = makeAddr("owner");
    address internal caller = makeAddr("caller");
    address internal recipient = makeAddr("recipient");
    address internal buyer = makeAddr("buyer");
    address internal pauser = makeAddr("pauser");
    address internal nftStaker = makeAddr("nftStaker");

    uint256 internal constant IDX = 4;
    uint256 internal constant P0 = 10e18;
    uint256 internal constant GROWTH_BPS = 1;
    uint256 internal constant CONV = 1e12;
    uint256 internal constant SEED = 1_000_000e18;
    uint256 internal constant CALLER_USDS = 1_000_000e18;
    uint256 internal constant DUST = 1e6;

    function setUp() public virtual {
        usds = new MockERC20("USDS", "USDS");
        usdc = new MockUSDC();
        kendu = new MockERC20("Kendu", "KENDU");
        phUSD = new MockBurnablePhUSD();
        nft = new MockERC1155();
        disp = new MockTokenDispatcherV2(address(usds));
        minter = new MockNFTMinterV2MintFor();
        minter.setStakedToken(nft);
        minter.setConfig(IDX, P0, GROWTH_BPS);
        minter.setPrimeToken(IDX, address(usds));
        minter.setDispatcher(IDX, address(disp));

        psm = new MockSkyPSM(address(usds), address(usdc), CONV);
        usds.mint(address(psm), 100_000_000e18); // USDS reserve paid out by sellGem
        sUSDS = new MockSUSDS(IERC20(address(usds)));
        hook = new MockMintDebtRatioHook();

        // sUSDS/phUSD pair seeded 1:1 (phUSD at $1 against a fresh 1:1 sUSDS).
        pair = new MockUniV2AmmPair(address(sUSDS), address(phUSD));
        router = new MockUniV2AmmRouter(pair);
        usds.mint(address(this), SEED);
        usds.approve(address(sUSDS), SEED);
        uint256 shares = sUSDS.deposit(SEED, address(this));
        IERC20(address(sUSDS)).transfer(address(pair), shares);
        phUSD.mint(address(pair), SEED);
        pair.mint(address(this));

        batch = new BatchNFTMinterNudgeDiscount(owner);
        minter.setAuthorizedMinter(address(batch), true);

        vm.startPrank(owner);
        batch.setTokenMinter(ITokenMinterV2(address(minter)));
        batch.setDispatcherIndex(IDX);
        batch.setPauser(pauser);
        batch.setNudgeTokenWhitelist(address(usdc), true);
        batch.setNudgeTokenWhitelist(address(phUSD), true);
        batch.setNudgeTokenWhitelist(address(kendu), true);
        batch.setDiscountToken(address(usdc));
        batch.setPSM(ISkyPSM(address(psm)));
        batch.setSUSDS(IERC4626(address(sUSDS)));
        batch.setSwapRoute(address(router), address(pair), address(phUSD));
        batch.setNFTStaker(nftStaker);
        batch.setMintDebtHook(IMintDebtRatio(address(hook)));
        batch.setAuthorizedBuyer(buyer, true);
        vm.stopPrank();

        usds.mint(caller, CALLER_USDS);
        vm.prank(caller);
        usds.approve(address(batch), type(uint256).max);
    }

    // ---- helpers ----

    /// @dev Cost of `n` sequential paid mints from `start`, term-for-term with the ramp.
    function _ramp(uint256 start, uint256 n) internal pure returns (uint256 cost) {
        uint256 price = start;
        for (uint256 i; i < n; ++i) {
            cost += price;
            price = price + (price * GROWTH_BPS) / 10_000;
        }
    }

    function _priceAfter(uint256 start, uint256 n) internal pure returns (uint256 price) {
        price = start;
        for (uint256 i; i < n; ++i) {
            price = price + (price * GROWTH_BPS) / 10_000;
        }
    }

    function _fundPot(uint256 usdcAmount) internal {
        usdc.mint(address(batch), usdcAmount);
    }

    /// @dev Bonus-floor array of the fixture's bonus count (phUSD, Kendu). Deliberately makes
    ///      NO external call, so it can sit inside a call that follows `vm.prank`/`expectRevert`.
    function _zeros() internal pure returns (uint256[] memory) {
        return new uint256[](2);
    }

    /// @dev The fixture's live `getBonusTokens()` order, `[phUSD, Kendu]`, built from fixture
    ///      STORAGE. Like `_zeros()` it makes NO external call, so it can sit inside a call that
    ///      follows `vm.prank`/`expectRevert` without consuming either (story 035, audit-27 L-01).
    function _bonusTokens() internal view returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = address(phUSD);
        tokens[1] = address(kendu);
    }

    function _setDiscount(uint8 d) internal {
        vm.prank(owner);
        batch.setDiscountPercent(d);
    }

    function _previewTotal() internal view returns (uint256 total, uint256 paidCost) {
        (, total,, paidCost,,,) = batch.previewBatch();
    }

    /// @dev Batch at the previewed total and LIVE boost with `maxPayment = paidCost`.
    function _batch() internal returns (uint256 totalPaid, uint256 free, uint256 paid) {
        (uint256 total, uint256 paidCost) = _previewTotal();
        (, uint8 boost,,) = batch.previewBoost();
        vm.prank(caller);
        return batch.batchMint(total, boost, recipient, paidCost, _bonusTokens(), _zeros());
    }
}

/// @title BatchNFTMinterNudgeDiscount — batch-side unit tests (story 033)
contract BatchNFTMinterNudgeDiscountTest is NudgeDiscountFixture {
    event DiscountTokenSet(address indexed token);
    event DiscountPercentSet(uint8 percent);
    event BurnPercentSet(uint8 percent);
    event NFTStakerSet(address indexed nftStaker);
    event MintDebtHookSet(address indexed hook);
    event PSMSet(address indexed psm);
    event SUSDSSet(address indexed sUSDS);
    event SwapRouteSet(address indexed router, address indexed pair, address indexed phUSD);
    event BuyerAuthorized(address indexed buyer, uint256 version);
    event BuyerDeauthorized(address indexed buyer);
    event AuthVersionIncremented(uint256 newVersion);
    event BatchMinted(
        address indexed recipient,
        uint256 free,
        uint256 paid,
        uint256 paidCost,
        uint256 potReservedUSDC,
        uint256 owedAdded
    );

    // =====================================================================
    // 1. Every spec Math example, verbatim (P0 = 10e18, tin = 0)
    // =====================================================================

    function _assertExample(uint8 d, uint256 pot, uint256 expFree, uint256 expPaid, uint256 expOwed) internal {
        _setDiscount(d);
        _fundPot(pot);
        uint256 callerBefore = usds.balanceOf(caller);

        (uint256 totalPaid, uint256 free, uint256 paid) = _batch();

        assertEq(free, expFree, "free");
        assertEq(paid, expPaid, "paid");
        assertEq(nft.balanceOf(recipient, IDX), expFree + expPaid, "recipient NFT count == total");
        uint256 cost = _ramp(P0, expPaid);
        assertEq(totalPaid, cost, "totalPaid == paidCost");
        assertEq(callerBefore - usds.balanceOf(caller), cost, "caller spent exactly paidCost");
        assertEq(batch.pendingBuyUSDC(), pot, "whole pot reserved");
        assertEq(batch.pendingStakerPhUSD(), expOwed, "owed");
        assertEq(usdc.balanceOf(address(batch)), pot, "reserved USDC stays on the contract");
        assertEq(batch.availablePotUSDC(), 0, "live pot empty after the batch");
    }

    function test_Example_d50_pot10_oneFreeOnePaid() public {
        _assertExample(50, 10e6, 1, 1, 5e18);
    }

    function test_Example_d50_pot15_wholePotReserved() public {
        _assertExample(50, 15e6, 1, 1, 5e18);
    }

    function test_Example_d50_pot20_twoFreeTwoPaid() public {
        _assertExample(50, 20e6, 2, 2, 10e18);
    }

    function test_Example_d50_pot100_total20() public {
        _assertExample(50, 100e6, 10, 10, 50e18);
    }

    function test_Example_d75_pot30_threeFreeOnePaid() public {
        // audit-27: the percent floor is 50, so the old d=25 example becomes d=75.
        _assertExample(75, 30e6, 3, 1, 15e18);
    }

    /// @dev audit-27 L-04: the old d=100 all-free example is gone. At the new maximum, 99, every
    ///      batch still has a paid mint, so the caller is pulled and the paid loop runs.
    function test_Example_d99_pot20_stillOnePaidMint() public {
        _setDiscount(99);
        _fundPot(20e6);
        (uint256 free, uint256 total, uint256 paid, uint256 paidCost,,,) = batch.previewBatch();
        assertEq(free, 2);
        assertEq(total, 3, "ceil(200/99) = 3");
        assertEq(paid, 1, "paid >= 1 at the maximum percent");
        // A caller with NO approval cannot take the batch: the pull is NOT skipped.
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        batch.batchMint(total, 0, recipient, paidCost, _bonusTokens(), _zeros());
        // The approved caller pays for the paid mint, and the paid mint runs first.
        vm.prank(caller);
        (uint256 totalPaid, uint256 f, uint256 p) =
            batch.batchMint(total, 0, recipient, paidCost, _bonusTokens(), _zeros());
        assertEq(f, 2);
        assertEq(p, 1);
        assertEq(totalPaid, P0);
        assertEq(minter.mintCallCount(), 1, "one paid mint");
        assertEq(nft.balanceOf(recipient, IDX), 3);
    }

    function test_TotalRoundsUp_d60() public {
        // Planner decision: ceil, so the effective discount never exceeds discountPercent.
        _setDiscount(60);
        _fundPot(10e6);
        (uint256 free, uint256 total, uint256 paid,,,,) = batch.previewBatch();
        assertEq(free, 1);
        assertEq(total, 2, "ceil(100/60) = 2, i.e. 50% off, not 60%");
        assertEq(paid, 1);
    }

    // =====================================================================
    // 2. No batch without a discount
    // =====================================================================

    function test_Revert_FreeZero_potBelowP0() public {
        _fundPot(5e6);
        vm.prank(caller);
        vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__NoDiscountAvailable.selector);
        batch.batchMint(1, 0, recipient, type(uint256).max, _bonusTokens(), _zeros());
    }

    function test_Revert_DiscountPercentZero() public {
        _setDiscount(0);
        _fundPot(100e6);
        vm.prank(caller);
        vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__NoDiscountAvailable.selector);
        batch.batchMint(1, 0, recipient, type(uint256).max, _bonusTokens(), _zeros());
    }

    function test_Revert_EmptyPot() public {
        vm.prank(caller);
        vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__NoDiscountAvailable.selector);
        batch.batchMint(1, 0, recipient, type(uint256).max, _bonusTokens(), _zeros());
    }

    function test_Revert_ExpectedTotalZero() public {
        _fundPot(10e6);
        vm.prank(caller);
        vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__ZeroCount.selector);
        batch.batchMint(0, 0, recipient, type(uint256).max, _bonusTokens(), _zeros());
    }

    // =====================================================================
    // 3. expectedTotal mismatch / front-running
    // =====================================================================

    function test_Revert_TotalMismatch_direct() public {
        _fundPot(10e6);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__TotalMismatch.selector, 2, 3));
        batch.batchMint(3, 0, recipient, type(uint256).max, _bonusTokens(), _zeros());
    }

    function test_FrontRun_potGrowsPastStep_revertsTotalMismatch_noBalancesMoved() public {
        _fundPot(10e6);
        (uint256 quotedTotal,) = _previewTotal();
        assertEq(quotedTotal, 2);
        // Someone tops the pot past the next step before the victim lands.
        _fundPot(10e6);
        uint256 callerBefore = usds.balanceOf(caller);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__TotalMismatch.selector, 4, 2));
        batch.batchMint(quotedTotal, 0, recipient, type(uint256).max, _bonusTokens(), _zeros());
        assertEq(usds.balanceOf(caller), callerBefore);
        assertEq(batch.pendingBuyUSDC(), 0);
        assertEq(nft.balanceOf(recipient, IDX), 0);
    }

    /// @dev A front-runner who consumes the whole pot leaves `free == 0`, so the victim reverts
    ///      `NoDiscountAvailable` (step 6 checks it before the total) — still clean, nothing moves.
    function test_FrontRun_potConsumedFirst_victimRevertsCleanly() public {
        _fundPot(10e6);
        (uint256 quotedTotal, uint256 quotedCost) = _previewTotal();

        address frontRunner = makeAddr("frontRunner");
        usds.mint(frontRunner, 100e18);
        vm.startPrank(frontRunner);
        usds.approve(address(batch), type(uint256).max);
        batch.batchMint(quotedTotal, 0, frontRunner, quotedCost, _bonusTokens(), _zeros());
        vm.stopPrank();

        uint256 callerBefore = usds.balanceOf(caller);
        uint256 reserveBefore = batch.pendingBuyUSDC();
        vm.prank(caller);
        vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__NoDiscountAvailable.selector);
        batch.batchMint(quotedTotal, 0, recipient, type(uint256).max, _bonusTokens(), _zeros());
        assertEq(usds.balanceOf(caller), callerBefore);
        assertEq(batch.pendingBuyUSDC(), reserveBefore);
        assertEq(nft.balanceOf(recipient, IDX), 0);
    }

    function test_FrontRun_partialConsumption_revertsTotalMismatch() public {
        _fundPot(20e6); // total 4
        (uint256 quotedTotal,) = _previewTotal();
        assertEq(quotedTotal, 4);
        // Victim quoted 4; then the pot is consumed and refilled to a 1-step pot (11 USDC: the
        // front-runner's paid mints ramped P0 just above 10).
        _batch();
        _fundPot(11e6);
        uint256 callerBefore = usds.balanceOf(caller);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__TotalMismatch.selector, 2, 4));
        batch.batchMint(quotedTotal, 0, recipient, type(uint256).max, _bonusTokens(), _zeros());
        assertEq(usds.balanceOf(caller), callerBefore);
    }

    // =====================================================================
    // 4. maxPayment
    // =====================================================================

    function test_Revert_MaxPaymentExceeded_beforeAnyTransfer() public {
        _fundPot(10e6);
        uint256 callerBefore = usds.balanceOf(caller);
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__MaxPaymentExceeded.selector, P0, P0 - 1)
        );
        batch.batchMint(2, 0, recipient, P0 - 1, _bonusTokens(), _zeros());
        assertEq(usds.balanceOf(caller), callerBefore);
        assertEq(batch.pendingBuyUSDC(), 0);
    }

    // =====================================================================
    // 5. mintFor does not move the price
    // =====================================================================

    function test_MintForDoesNotMovePrice() public {
        _fundPot(100e6); // 10 free + 10 paid
        _batch();
        (, uint256 priceAfter,,) = minter.configs(IDX);
        assertEq(priceAfter, _priceAfter(P0, 10), "price ramped exactly `paid` times");
        assertEq(minter.mintForCallCount(), 10, "free count == mintFor calls");
        assertEq(minter.mintCallCount(), 10, "paid count == mint calls");
    }

    function test_FreeMintsRequireMintForAuthorisation() public {
        minter.setAuthorizedMinter(address(batch), false);
        _fundPot(10e6);
        vm.prank(caller);
        vm.expectRevert();
        batch.batchMint(2, 0, recipient, P0, _bonusTokens(), _zeros());
    }

    // =====================================================================
    // 6. Bonus paid on every batch
    // =====================================================================

    function test_GetBonusTokens_excludesDiscountToken_inWhitelistOrder() public view {
        address[] memory bonus = batch.getBonusTokens();
        assertEq(bonus.length, 2);
        assertEq(bonus[0], address(phUSD));
        assertEq(bonus[1], address(kendu));
    }

    function test_BonusPaidInFullOnTwoNftBatch_discountTokenNeverPaid() public {
        _fundPot(10e6);
        phUSD.mint(address(batch), 7e18);
        kendu.mint(address(batch), 1234e18);
        uint256[] memory mins = new uint256[](2);
        mins[0] = 7e18;
        mins[1] = 1234e18;
        vm.prank(caller);
        batch.batchMint(2, 0, recipient, P0, _bonusTokens(), mins);
        assertEq(phUSD.balanceOf(recipient), 7e18);
        assertEq(kendu.balanceOf(recipient), 1234e18);
        assertEq(usdc.balanceOf(recipient), 0, "discount token is never paid out");
        assertEq(usdc.balanceOf(caller), 0);
        assertEq(phUSD.balanceOf(address(batch)), 0);
    }

    function test_Revert_BonusLengthMismatch() public {
        _fundPot(10e6);
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__ArrayLengthMismatch.selector, 2, 3)
        );
        batch.batchMint(2, 0, recipient, P0, _bonusTokens(), new uint256[](3));
    }

    function test_Revert_BonusFloor() public {
        _fundPot(10e6);
        kendu.mint(address(batch), 5e18);
        uint256[] memory mins = new uint256[](2);
        mins[1] = 6e18;
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterNudgeDiscount.BatchMint__RewardBelowMinimum.selector, address(kendu), 6e18, 5e18
            )
        );
        batch.batchMint(2, 0, recipient, P0, _bonusTokens(), mins);
    }

    function test_BonusOrderFollowsSwapAndPop() public {
        // Unwhitelisting phUSD moves the last entry (kendu) into its slot.
        vm.prank(owner);
        batch.setNudgeTokenWhitelist(address(phUSD), false);
        address[] memory bonus = batch.getBonusTokens();
        assertEq(bonus.length, 1);
        assertEq(bonus[0], address(kendu));
    }

    // ---- 6b. Bonus floors bind to token ADDRESSES (story 035, audit-27 L-01) ----

    /// @dev Remove phUSD (swap-and-pop moves kendu into its slot) and re-add it: same bonus
    ///      count, order flipped from `[phUSD, kendu]` to `[kendu, phUSD]`.
    function _reorderBonusByRemoveThenReadd() internal {
        vm.startPrank(owner);
        batch.setNudgeTokenWhitelist(address(phUSD), false);
        batch.setNudgeTokenWhitelist(address(phUSD), true);
        vm.stopPrank();
        address[] memory bonus = batch.getBonusTokens();
        assertEq(bonus.length, 2, "length unchanged");
        assertEq(bonus[0], address(kendu), "kendu moved into slot 0");
        assertEq(bonus[1], address(phUSD), "phUSD re-added at the tail");
    }

    function _tokens2(address a, address b) internal pure returns (address[] memory t) {
        t = new address[](2);
        t[0] = a;
        t[1] = b;
    }

    function test_Revert_BonusTokenMismatch_removeThenReadd() public {
        address[] memory stale = _bonusTokens(); // [phUSD, kendu], fetched before the reorder
        _reorderBonusByRemoveThenReadd();
        _fundPot(10e6);
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterNudgeDiscount.BatchMint__BonusTokenMismatch.selector, 0, address(phUSD), address(kendu)
            )
        );
        batch.batchMint(2, 0, recipient, P0, stale, _zeros());
    }

    function test_Revert_BonusTokenMismatch_discountTokenSwitch() public {
        MockERC20 x = new MockERC20("X", "X");
        vm.prank(owner);
        batch.setNudgeTokenWhitelist(address(x), true);
        address[] memory stale = batch.getBonusTokens(); // [phUSD, kendu, x]
        assertEq(stale.length, 3);
        assertEq(stale[0], address(phUSD));

        // Reserve is empty, so the switch is allowed in normal operation.
        vm.prank(owner);
        batch.setDiscountToken(address(phUSD));
        address[] memory live = batch.getBonusTokens(); // [usdc, kendu, x]
        assertEq(live.length, 3, "length unchanged");
        assertEq(live[0], address(usdc));

        _fundPot(10e6);
        vm.prank(caller);
        // The mismatch fires at step 4, BEFORE the step-5 config checks that a phUSD discount
        // token would otherwise trip (phUSD is not the PSM gem).
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterNudgeDiscount.BatchMint__BonusTokenMismatch.selector, 0, address(phUSD), address(usdc)
            )
        );
        batch.batchMint(2, 0, recipient, P0, stale, new uint256[](3));
    }

    function test_FreshBonusTokens_afterReorder_payoutUnchanged() public {
        _reorderBonusByRemoveThenReadd();
        _fundPot(10e6);
        phUSD.mint(address(batch), 7e18);
        kendu.mint(address(batch), 1234e18);
        address[] memory fresh = batch.getBonusTokens(); // [kendu, phUSD]
        uint256[] memory mins = new uint256[](2);
        mins[0] = 1234e18; // kendu
        mins[1] = 7e18; // phUSD
        vm.prank(caller);
        batch.batchMint(2, 0, recipient, P0, fresh, mins);
        assertEq(phUSD.balanceOf(recipient), 7e18, "phUSD bonus paid in full");
        assertEq(kendu.balanceOf(recipient), 1234e18, "kendu bonus paid in full");
        assertEq(usdc.balanceOf(recipient), 0, "discount token is never paid out");
        assertEq(phUSD.balanceOf(address(batch)), 0);
        assertEq(kendu.balanceOf(address(batch)), 0);
    }

    function test_FreshBonusTokens_afterReorder_floorFiresOnCorrectToken() public {
        _reorderBonusByRemoveThenReadd();
        _fundPot(10e6);
        phUSD.mint(address(batch), 5e18);
        kendu.mint(address(batch), 1000e18);
        uint256[] memory mins = new uint256[](2);
        mins[1] = 6e18; // slot 1 is now phUSD
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterNudgeDiscount.BatchMint__RewardBelowMinimum.selector, address(phUSD), 6e18, 5e18
            )
        );
        batch.batchMint(2, 0, recipient, P0, _tokens2(address(kendu), address(phUSD)), mins);
    }

    function test_Revert_BonusTokensLengthMismatch_tooLong() public {
        _fundPot(10e6);
        address[] memory tokens = new address[](3);
        tokens[0] = address(phUSD);
        tokens[1] = address(kendu);
        tokens[2] = address(usdc);
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__ArrayLengthMismatch.selector, 2, 3)
        );
        batch.batchMint(2, 0, recipient, P0, tokens, _zeros());
    }

    function test_Revert_BonusTokensLengthMismatch_tooShort() public {
        _fundPot(10e6);
        address[] memory tokens = new address[](1);
        tokens[0] = address(phUSD);
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__ArrayLengthMismatch.selector, 2, 1)
        );
        batch.batchMint(2, 0, recipient, P0, tokens, _zeros());
    }

    function test_BonusTokenMismatch_leavesStateUntouched() public {
        address[] memory stale = _bonusTokens();
        _reorderBonusByRemoveThenReadd();
        _fundPot(10e6);
        phUSD.mint(address(batch), 7e18);
        kendu.mint(address(batch), 1234e18);

        uint256 callerUsds = usds.balanceOf(caller);
        uint256 batchUsdc = usdc.balanceOf(address(batch));

        vm.prank(caller);
        (bool ok, bytes memory err) = address(batch)
            .call(abi.encodeCall(BatchNFTMinterNudgeDiscount.batchMint, (2, 0, recipient, P0, stale, _zeros())));
        assertFalse(ok, "stale order reverts");
        assertEq(
            err,
            abi.encodeWithSelector(
                BatchNFTMinterNudgeDiscount.BatchMint__BonusTokenMismatch.selector, 0, address(phUSD), address(kendu)
            )
        );
        assertEq(nft.balanceOf(recipient, IDX), 0, "no NFTs minted");
        assertEq(minter.mintCallCount(), 0, "no paid mint");
        assertEq(usds.balanceOf(caller), callerUsds, "no payment pulled");
        assertEq(usdc.balanceOf(address(batch)), batchUsdc, "pot untouched");
        assertEq(batch.pendingBuyUSDC(), 0, "nothing reserved");
        assertEq(batch.pendingStakerPhUSD(), 0, "nothing owed");
        assertEq(phUSD.balanceOf(address(batch)), 7e18, "phUSD bonus untouched");
        assertEq(kendu.balanceOf(address(batch)), 1234e18, "kendu bonus untouched");
        assertEq(phUSD.balanceOf(recipient), 0);
        assertEq(kendu.balanceOf(recipient), 0);
    }

    // =====================================================================
    // 7. Owed reads ratio() live
    // =====================================================================

    function test_OwedFollowsLiveRatio() public {
        hook.setRatio(30);
        _fundPot(10e6);
        (,,,, uint256 owed,,) = batch.previewBatch();
        assertEq(owed, 3e18);
        _batch();
        assertEq(batch.pendingStakerPhUSD(), 3e18);
    }

    // =====================================================================
    // 8. tin > 0 never over-grants
    // =====================================================================

    function test_TinOnePercent_pot10_reverts() public {
        psm.setTin(0.01e18);
        _fundPot(10e6);
        (,,,,, uint256 potUSD,) = batch.previewBatch();
        assertEq(potUSD, 9.9e18);
        vm.prank(caller);
        vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__NoDiscountAvailable.selector);
        batch.batchMint(2, 0, recipient, P0, _bonusTokens(), _zeros());
    }

    function testFuzz_TinNeverOverGrants(uint256 tin, uint256 pot) public {
        tin = bound(tin, 0, 0.2e18);
        pot = bound(pot, 0, 1_000e6);
        psm.setTin(tin);
        _fundPot(pot);
        (uint256 free, uint256 total, uint256 paid, uint256 paidCost,, uint256 potUSD,) = batch.previewBatch();
        uint256 gross = pot * CONV;
        assertEq(potUSD, gross - (gross * tin) / 1e18, "potUSD mirrors the PSM sell maths");
        assertLe(free * P0, potUSD, "free never exceeds what the pot can cover");
        uint256 cap = batch.maxFreePerBatch();
        if (free < cap) assertLt(potUSD, (free + 1) * P0, "free is the floor");
        else assertEq(free, cap, "free is capped");
        if (free == 0) {
            vm.prank(caller);
            vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__NoDiscountAvailable.selector);
            batch.batchMint(1, 0, recipient, type(uint256).max, _bonusTokens(), _zeros());
        } else {
            vm.prank(caller);
            (, uint256 f, uint256 p) = batch.batchMint(total, 0, recipient, paidCost, _bonusTokens(), _zeros());
            assertEq(f, free);
            assertEq(p, paid);
        }
    }

    // =====================================================================
    // 9. Discount-token guards
    // =====================================================================

    function test_Revert_SetDiscountToken_notWhitelisted() public {
        MockERC20 other = new MockERC20("X", "X");
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterNudgeDiscount.BatchMint__DiscountTokenNotWhitelisted.selector, address(other)
            )
        );
        batch.setDiscountToken(address(other));
    }

    function test_Revert_UnwhitelistActiveDiscountToken() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__DiscountTokenIsActive.selector, address(usdc))
        );
        batch.setNudgeTokenWhitelist(address(usdc), false);
    }

    function test_Revert_SetDiscountToken_whileReservePending() public {
        _fundPot(10e6);
        _batch();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__ReservePending.selector, 10e6));
        batch.setDiscountToken(address(0));
    }

    function test_ClearDiscountTokenThenUnwhitelist() public {
        vm.startPrank(owner);
        batch.setDiscountToken(address(0));
        batch.setNudgeTokenWhitelist(address(usdc), false);
        vm.stopPrank();
        assertEq(address(batch.discountToken()), address(0));
        // With no discount token, minting is disabled. Removing usdc swap-and-pops kendu into
        // slot 0, so the live bonus order is now [kendu, phUSD]; pass it so the call reaches
        // the step-5 config check instead of the step-4 order check.
        address[] memory live = _tokens2(address(kendu), address(phUSD));
        vm.prank(caller);
        vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__DiscountNotConfigured.selector);
        batch.batchMint(1, 0, recipient, P0, live, new uint256[](2));
    }

    function test_Revert_GemMismatch() public {
        MockSkyPSM otherPsm = new MockSkyPSM(address(usds), address(kendu), 1);
        vm.prank(owner);
        batch.setPSM(ISkyPSM(address(otherPsm)));
        _fundPot(10e6);
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterNudgeDiscount.BatchMint__DiscountTokenNotGem.selector, address(usdc), address(kendu)
            )
        );
        batch.batchMint(2, 0, recipient, P0, _bonusTokens(), _zeros());
    }

    function test_Revert_DiscountNotConfigured_psmOrHookUnset() public {
        _fundPot(10e6);
        vm.prank(owner);
        batch.setMintDebtHook(IMintDebtRatio(address(0)));
        vm.prank(caller);
        vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__DiscountNotConfigured.selector);
        batch.batchMint(2, 0, recipient, P0, _bonusTokens(), _zeros());

        vm.startPrank(owner);
        batch.setMintDebtHook(IMintDebtRatio(address(hook)));
        batch.setPSM(ISkyPSM(address(0)));
        vm.stopPrank();
        vm.prank(caller);
        vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__DiscountNotConfigured.selector);
        batch.batchMint(2, 0, recipient, P0, _bonusTokens(), _zeros());
    }

    // =====================================================================
    // 10. Setters: events, onlyOwner, bounds, pair validation
    // =====================================================================

    function test_Defaults() public {
        BatchNFTMinterNudgeDiscount fresh = new BatchNFTMinterNudgeDiscount(owner);
        assertEq(fresh.discountPercent(), 50);
        assertEq(fresh.burnPercent(), 100);
        assertEq(fresh.authVersion(), 1);
    }

    function test_SetterEvents() public {
        vm.startPrank(owner);
        vm.expectEmit(address(batch));
        emit DiscountPercentSet(60);
        batch.setDiscountPercent(60);
        vm.expectEmit(address(batch));
        emit BurnPercentSet(60);
        batch.setBurnPercent(60);
        vm.expectEmit(address(batch));
        emit NFTStakerSet(address(0x1234));
        batch.setNFTStaker(address(0x1234));
        vm.expectEmit(address(batch));
        emit MintDebtHookSet(address(0x2345));
        batch.setMintDebtHook(IMintDebtRatio(address(0x2345)));
        vm.expectEmit(address(batch));
        emit SwapRouteSet(address(0), address(0), address(0));
        batch.setSwapRoute(address(0), address(0), address(0));
        vm.expectEmit(address(batch));
        emit PSMSet(address(0x3456));
        batch.setPSM(ISkyPSM(address(0x3456)));
        vm.expectEmit(address(batch));
        emit SUSDSSet(address(0x4567));
        batch.setSUSDS(IERC4626(address(0x4567)));
        vm.expectEmit(address(batch));
        emit DiscountTokenSet(address(0));
        batch.setDiscountToken(address(0));
        vm.expectEmit(address(batch));
        emit BuyerAuthorized(address(0x5678), 1);
        batch.setAuthorizedBuyer(address(0x5678), true);
        vm.expectEmit(address(batch));
        emit BuyerDeauthorized(address(0x5678));
        batch.setAuthorizedBuyer(address(0x5678), false);
        vm.expectEmit(address(batch));
        emit AuthVersionIncremented(2);
        batch.incrementAuthVersion();
        vm.stopPrank();
    }

    function test_SetSwapRoute_event() public {
        vm.prank(owner);
        vm.expectEmit(address(batch));
        emit SwapRouteSet(address(router), address(pair), address(phUSD));
        batch.setSwapRoute(address(router), address(pair), address(phUSD));
    }

    function test_SetDiscountToken_event() public {
        vm.startPrank(owner);
        batch.setDiscountToken(address(0));
        vm.expectEmit(address(batch));
        emit DiscountTokenSet(address(usdc));
        batch.setDiscountToken(address(usdc));
        vm.stopPrank();
    }

    function test_OnlyOwner_everyNewSetter() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller);
        vm.startPrank(caller);
        vm.expectRevert(err);
        batch.setDiscountToken(address(usdc));
        vm.expectRevert(err);
        batch.setDiscountPercent(10);
        vm.expectRevert(err);
        batch.setBurnPercent(10);
        vm.expectRevert(err);
        batch.setNFTStaker(caller);
        vm.expectRevert(err);
        batch.setMintDebtHook(IMintDebtRatio(address(hook)));
        vm.expectRevert(err);
        batch.setPSM(ISkyPSM(address(psm)));
        vm.expectRevert(err);
        batch.setSUSDS(IERC4626(address(sUSDS)));
        vm.expectRevert(err);
        batch.setSwapRoute(address(router), address(pair), address(phUSD));
        vm.expectRevert(err);
        batch.setAuthorizedBuyer(caller, true);
        vm.expectRevert(err);
        batch.incrementAuthVersion();
        vm.stopPrank();
    }

    function test_Revert_PercentTooHigh() public {
        vm.startPrank(owner);
        // audit-27 L-04: 100 is no longer a legal discount.
        vm.expectRevert(abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__PercentTooHigh.selector, 100));
        batch.setDiscountPercent(100);
        vm.expectRevert(abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__PercentTooHigh.selector, 101));
        batch.setDiscountPercent(101);
        vm.expectRevert(abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__PercentTooHigh.selector, 101));
        batch.setBurnPercent(101);
        batch.setDiscountPercent(99);
        assertEq(batch.discountPercent(), 99);
        batch.setBurnPercent(100);
        batch.setBurnPercent(0);
        vm.stopPrank();
    }

    function test_Revert_PercentTooLow() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__PercentTooLow.selector, 1));
        batch.setDiscountPercent(1);
        vm.expectRevert(abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__PercentTooLow.selector, 49));
        batch.setDiscountPercent(49);
        batch.setDiscountPercent(50);
        assertEq(batch.discountPercent(), 50);
        batch.setDiscountPercent(0);
        assertEq(batch.discountPercent(), 0, "0 still disables");
        vm.stopPrank();
    }

    function testFuzz_SetDiscountPercent_bounds(uint8 percent) public {
        vm.prank(owner);
        if (percent > 99) {
            vm.expectRevert(
                abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__PercentTooHigh.selector, percent)
            );
        } else if (percent != 0 && percent < 50) {
            vm.expectRevert(
                abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__PercentTooLow.selector, percent)
            );
        }
        batch.setDiscountPercent(percent);
    }

    function test_Revert_SetSwapRoute_pairMismatch() public {
        MockUniV2AmmPair wrong = new MockUniV2AmmPair(address(usds), address(phUSD));
        vm.prank(owner);
        vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__PairMismatch.selector);
        batch.setSwapRoute(address(router), address(wrong), address(phUSD));
    }

    function test_Revert_SetSwapRoute_sUSDSUnset() public {
        vm.startPrank(owner);
        batch.setSUSDS(IERC4626(address(0)));
        vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__PairMismatch.selector);
        batch.setSwapRoute(address(router), address(pair), address(phUSD));
        vm.stopPrank();
    }

    function test_Revert_SetAuthorizedBuyer_zero() public {
        vm.prank(owner);
        vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__ZeroBuyer.selector);
        batch.setAuthorizedBuyer(address(0), true);
    }

    // =====================================================================
    // 11. Refund
    // =====================================================================

    function test_Refund_overpayingCallerGetsExactUnspentBudget() public {
        _fundPot(20e6); // 2 free + 2 paid
        uint256 cost = _ramp(P0, 2);
        uint256 callerBefore = usds.balanceOf(caller);
        vm.prank(caller);
        (uint256 totalPaid,,) = batch.batchMint(4, 0, recipient, cost + 500e18, _bonusTokens(), _zeros());
        assertEq(totalPaid, cost);
        assertEq(callerBefore - usds.balanceOf(caller), cost);
        assertEq(usds.balanceOf(address(batch)), 0, "no budget left behind");
        assertEq(usdc.balanceOf(caller), 0, "the pot never contributes");
    }

    // =====================================================================
    // 12. previewBatch parity + nextStepUSDC
    // =====================================================================

    function test_PreviewParity_acrossPotsAndDiscounts() public {
        uint8[4] memory ds = [uint8(50), 75, 99, 66];
        uint256[4] memory pots = [uint256(10e6), 37e6, 100e6, 15e6];
        for (uint256 i; i < 4; ++i) {
            _setDiscount(ds[i]);
            _fundPot(pots[i]);
            (uint256 free, uint256 total, uint256 paid, uint256 paidCost, uint256 owed,,) = batch.previewBatch();
            uint256 owedBefore = batch.pendingStakerPhUSD();
            uint256 callerBefore = usds.balanceOf(caller);
            vm.prank(caller);
            (uint256 totalPaid, uint256 f, uint256 p) =
                batch.batchMint(total, 0, recipient, paidCost, _bonusTokens(), _zeros());
            assertEq(f, free, "free parity");
            assertEq(p, paid, "paid parity");
            assertEq(f + p, total, "total parity");
            assertEq(totalPaid, paidCost, "paidCost parity");
            assertEq(callerBefore - usds.balanceOf(caller), paidCost);
            assertEq(batch.pendingStakerPhUSD() - owedBefore, owed, "owed parity");
        }
    }

    function test_NextStepUSDC_exact() public {
        uint256[3] memory tins = [uint256(0), 0.01e18, 0.0033e18];
        uint256[3] memory pots = [uint256(15e6), 9e6, 123_456_789];
        for (uint256 i; i < 3; ++i) {
            setUp();
            psm.setTin(tins[i]);
            _fundPot(pots[i]);
            (uint256 free,,,,,, uint256 step) = batch.previewBatch();
            assertGt(step, 0);
            // One unit short does not reach the next step...
            _fundPot(step - 1);
            (uint256 freeShort,,,,,,) = batch.previewBatch();
            assertEq(freeShort, free, "1 wei less does not raise free");
            // ...exactly `step` does, by exactly one.
            _fundPot(1);
            (uint256 freeAt,,,,,,) = batch.previewBatch();
            assertEq(freeAt, free + 1, "nextStepUSDC raises free by exactly 1");
        }
    }

    function test_Preview_misconfigured_returnsZerosButPotUSD() public {
        _fundPot(5e6);
        (uint256 free, uint256 total,,,, uint256 potUSD, uint256 step) = batch.previewBatch();
        assertEq(free, 0);
        assertEq(total, 0);
        assertEq(potUSD, 5e18);
        assertEq(step, 5e6, "needs 5 USDC more to reach the first free NFT");

        vm.prank(owner);
        batch.setMintDebtHook(IMintDebtRatio(address(0)));
        _fundPot(100e6);
        (free, total,,,, potUSD,) = batch.previewBatch();
        assertEq(free, 0, "unconfigured hook: batch fields zero");
        assertEq(total, 0);
        assertEq(potUSD, 105e18, "potUSD still reported");
    }

    function test_AvailablePotUSDC() public {
        _fundPot(15e6);
        assertEq(batch.availablePotUSDC(), 15e6);
        _batch();
        assertEq(batch.availablePotUSDC(), 0);
        _fundPot(3e6);
        assertEq(batch.availablePotUSDC(), 3e6, "post-batch funds are live pot, not reserve");
        assertEq(batch.pendingBuyUSDC(), 15e6);
    }

    // =====================================================================
    // 13. Pause
    // =====================================================================

    function test_Pause() public {
        _fundPot(10e6);
        vm.prank(caller);
        vm.expectRevert("BatchNFTMinter: caller is not pauser");
        batch.pause();

        vm.prank(pauser);
        batch.pause();
        vm.prank(caller);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        batch.batchMint(2, 0, recipient, P0, _bonusTokens(), _zeros());

        vm.prank(owner);
        vm.expectRevert("BatchNFTMinter: caller is not pauser");
        batch.unpause();

        vm.prank(pauser);
        batch.unpause();
        _batch();
        assertEq(nft.balanceOf(recipient, IDX), 2);
    }

    // =====================================================================
    // 14. rescueERC20
    // =====================================================================

    function test_Rescue_cannotTakeReservedUSDC() public {
        _fundPot(10e6);
        _batch();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.Rescue__ReservedFunds.selector, 1, 0));
        batch.rescueERC20(IERC20(address(usdc)), owner, 1);
    }

    function test_Rescue_canTakeUnreservedUSDCAboveReserve() public {
        _fundPot(10e6);
        _batch();
        _fundPot(4e6);
        vm.startPrank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.Rescue__ReservedFunds.selector, 4e6 + 1, 4e6)
        );
        batch.rescueERC20(IERC20(address(usdc)), owner, 4e6 + 1);
        batch.rescueERC20(IERC20(address(usdc)), owner, 4e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(owner), 4e6);
        assertEq(usdc.balanceOf(address(batch)), 10e6);
    }

    function test_Rescue_arbitraryToken() public {
        MockERC20 junk = new MockERC20("J", "J");
        junk.mint(address(batch), 9e18);
        kendu.mint(address(batch), 1e18);
        vm.startPrank(owner);
        batch.rescueERC20(IERC20(address(junk)), owner, 9e18);
        batch.rescueERC20(IERC20(address(kendu)), owner, 1e18);
        vm.stopPrank();
        assertEq(junk.balanceOf(owner), 9e18);
        assertEq(kendu.balanceOf(owner), 1e18);
    }

    // =====================================================================
    // 15. Copied regressions
    // =====================================================================

    function test_Revert_ZeroRecipient() public {
        _fundPot(10e6);
        vm.prank(caller);
        vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__ZeroRecipient.selector);
        batch.batchMint(2, 0, address(0), P0, _bonusTokens(), _zeros());
    }

    function test_Revert_MinterNotConfigured() public {
        _fundPot(10e6);
        vm.prank(owner);
        batch.setTokenMinter(ITokenMinterV2(address(0)));
        vm.prank(caller);
        vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__MinterNotConfigured.selector);
        batch.batchMint(2, 0, recipient, P0, _bonusTokens(), _zeros());
    }

    function test_Revert_DispatcherNotConfigured() public {
        _fundPot(10e6);
        vm.prank(owner);
        batch.setDispatcherIndex(0);
        vm.prank(caller);
        vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__DispatcherNotConfigured.selector);
        batch.batchMint(2, 0, recipient, P0, _bonusTokens(), _zeros());

        vm.prank(owner);
        batch.setDispatcherIndex(99); // resolves to a zero dispatcher
        vm.prank(caller);
        vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__DispatcherNotConfigured.selector);
        batch.batchMint(2, 0, recipient, P0, _bonusTokens(), _zeros());
    }

    /// @dev Pattern of `test_DonationDuringPullCannotInflateBudget`: a payment token whose pull
    ///      drags a third party's funds in. The caller gets back only their own unspent budget.
    function test_DonationDuringPullCannotInflateBudget() public {
        MockDonatingOnPullERC20 hooked = new MockDonatingOnPullERC20("Hooked", "HOOK");
        disp.setPrimeToken(address(hooked));
        minter.setPrimeToken(IDX, address(hooked));
        address benefactor = makeAddr("benefactor");
        uint256 donation = 4_321e18;
        hooked.mint(benefactor, donation);
        hooked.setDonation(benefactor, donation);

        _fundPot(20e6); // 2 free + 2 paid
        uint256 cost = _ramp(P0, 2);
        uint256 a = cost + 500e18;
        hooked.mint(caller, a);
        vm.startPrank(caller);
        hooked.approve(address(batch), a);
        (uint256 totalPaid,,) = batch.batchMint(4, 0, recipient, a, _bonusTokens(), _zeros());
        vm.stopPrank();

        assertEq(totalPaid, cost);
        assertEq(hooked.balanceOf(caller), a - cost, "only the caller's own unspent budget comes back");
        assertEq(hooked.balanceOf(address(batch)), donation, "the donation stays behind");
    }

    /// @dev Fee-on-transfer payment token: the shortfall is the caller's, never the pot's.
    function test_FeeOnTransferPaymentToken_budgetIsMeasured() public {
        MockFeeOnTransferERC20 taxed = new MockFeeOnTransferERC20("Taxed", "TAX", 500);
        disp.setPrimeToken(address(taxed));
        minter.setPrimeToken(IDX, address(taxed));
        _fundPot(10e6); // 1 free + 1 paid, cost P0
        taxed.mint(caller, 100e18);

        // Quoting exactly paidCost under-funds after the 5% skim: reverts cleanly.
        vm.startPrank(caller);
        taxed.approve(address(batch), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterNudgeDiscount.BatchMint__PaymentBudgetExhausted.selector, 0, P0, (P0 * 9500) / 10_000
            )
        );
        batch.batchMint(2, 0, recipient, P0, _bonusTokens(), _zeros());

        // Over-quoting works; the refund is bounded by what was credited.
        uint256 a = 20e18;
        uint256 callerBefore = taxed.balanceOf(caller);
        (uint256 totalPaid,,) = batch.batchMint(2, 0, recipient, a, _bonusTokens(), _zeros());
        vm.stopPrank();
        uint256 credited = (a * 9500) / 10_000;
        uint256 refund = credited - P0;
        assertEq(totalPaid, a - refund);
        assertEq(taxed.balanceOf(address(batch)), 0, "nothing left on the contract to be drained");
        assertEq(callerBefore - taxed.balanceOf(caller), a - (refund - (refund * 500) / 10_000));
        assertEq(batch.pendingBuyUSDC(), 10e6, "the pot is untouched by the shortfall");
    }

    // =====================================================================
    // BatchMinted event
    // =====================================================================

    function test_BatchMintedEvent() public {
        _fundPot(15e6);
        vm.expectEmit(address(batch));
        emit BatchMinted(recipient, 1, 1, P0, 15e6, 5e18);
        vm.prank(caller);
        batch.batchMint(2, 0, recipient, P0, _bonusTokens(), _zeros());
    }

    // =====================================================================
    // Paid-mint-donated USDC is live pot (donate-forward), not reserve
    // =====================================================================

    function test_DonationsDuringPaidLoop_stayAsLivePot() public {
        usdc.mint(address(minter), 1_000e6);
        minter.setPerMintDonation(address(usdc), 3e6);
        _fundPot(20e6); // 2 free + 2 paid -> 2 donations of 3e6
        _batch();
        assertEq(batch.pendingBuyUSDC(), 20e6, "only the pre-batch pot is reserved");
        assertEq(batch.availablePotUSDC(), 6e6, "this batch's own donations seed the next pot");
    }
}
