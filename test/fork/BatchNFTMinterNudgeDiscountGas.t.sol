// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ITokenMinterV2} from "yield-claim-nft/interfaces/ITokenMinterV2.sol";
import {BatchNFTMinterNudgeDiscount} from "../../src/BatchNFTMinterNudgeDiscount.sol";
import {ISkyPSM} from "../../src/interfaces/ISkyPSM.sol";
import {IMintDebtRatio} from "../../src/interfaces/IMintDebtRatio.sol";

interface INFTMinterV2Live {
    function configs(uint256) external view returns (address, uint256, uint256, bool);
    function setAuthorizedMinter(address, bool) external;
    function authorizedMinters(address) external view returns (bool);
}

interface IUniPoolerV2Live {
    function setBatchMinter(address) external;
    function setBatchDonationSize(uint256) external;
}

interface INudgeStreamerLive {
    function registerStream(address, address, uint256) external;
}

/// @title BatchNFTMinterNudgeDiscount — fork gas boundary for the audit-27 M-01 cap
/// @notice Adapted from the run-27 PoC (`audits/phoenix-nft-staking/work/test/
///         PoC_Run27_M01_GasBrick.t.sol`), but deploying the NEW (capped) contract. Proves a
///         batch of exactly `maxFreePerBatch` at `MIN_DISCOUNT_PERCENT` fits under the EIP-7825
///         per-transaction gas cap (2^24) minus intrinsic gas, with >= 10% headroom, with the
///         UniPoolerV2 donation leg ON (primary) and OFF (secondary).
///
///         Source-only: the fork is local, nothing is broadcast. The wiring mirrors the
///         phStaging2 story-119 cutover with the owner impersonated. Skips cleanly when
///         `RPC_MAINNET` is unset, so a headless run without an RPC stays green; the unit suites
///         cover every logic path.
///
///         Gas is measured COLD: a warm-up call records every touched account, state is rolled
///         back, all touched accounts are `vm.cool`ed, then the metered call runs.
contract BatchNFTMinterNudgeDiscountGasForkTest is Test {
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant NFT_MINTER = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address constant UNI_POOLER = 0x56997ea45091CBc01DB8a09E60DEDB8b3706a3D2;
    address constant NUDGE_STREAMER = 0xF7e26179D6971985107AF66b078932D6484eBEAA;
    address constant NFT_STAKER = 0xc8514f821A3d801Fa8a8c435840a992A4365a13b;
    address constant MINT_DEBT_HOOK = 0x4A26ad83306a2F17155799fDD9449f77eb3F8bD7;
    address constant UNI_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant PAIR = 0x0b96b8ab66d40ba3C7501aa8C28Cdc37688F6F7f;
    address constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address constant PSM = 0xA188EEC8F81263234dA3622A406892F3D630f98c;
    address constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant KENDU = 0xaa95f26e30001251fb905d264Aa7b00eE9dF6C18;
    uint256 constant INDEX = 4;
    uint256 constant FORK_BLOCK = 26_389_634;

    /// @dev EIP-7825 per-transaction gas cap (Fusaka).
    uint256 constant TX_GAS_CAP = 16_777_216;
    uint256 constant TX_BASE = 21_000;
    /// @dev Required headroom below `TX_GAS_CAP - intrinsic`, in percent.
    uint256 constant HEADROOM_PCT = 10;

    BatchNFTMinterNudgeDiscount minter;
    address batcher = makeAddr("batcher");
    address donor = makeAddr("donor");
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);
        // Mainnet runs Osaka; the live UniPoolerV2 halts with NotActivated under shanghai.
        vm.setEvmVersion("osaka");
        forked = true;

        minter = new BatchNFTMinterNudgeDiscount(OWNER);

        vm.startPrank(OWNER);
        minter.setTokenMinter(ITokenMinterV2(NFT_MINTER));
        minter.setDispatcherIndex(INDEX);
        minter.setNudgeTokenWhitelist(USDC, true);
        minter.setNudgeTokenWhitelist(PHUSD, true);
        minter.setNudgeTokenWhitelist(KENDU, true);
        minter.setDiscountToken(USDC);
        minter.setDiscountPercent(minter.MIN_DISCOUNT_PERCENT());
        minter.setBurnPercent(100);
        minter.setNFTStaker(NFT_STAKER);
        minter.setMintDebtHook(IMintDebtRatio(MINT_DEBT_HOOK));
        minter.setPSM(ISkyPSM(PSM));
        minter.setSUSDS(IERC4626(SUSDS));
        minter.setSwapRoute(UNI_ROUTER, PAIR, PHUSD);
        INudgeStreamerLive(NUDGE_STREAMER).registerStream(address(minter), USDC, 10 days);
        INudgeStreamerLive(NUDGE_STREAMER).registerStream(address(minter), PHUSD, 30 days);
        INudgeStreamerLive(NUDGE_STREAMER).registerStream(address(minter), KENDU, 30 days);
        minter.setNudgeStreamer(NUDGE_STREAMER);
        INFTMinterV2Live(NFT_MINTER).setAuthorizedMinter(address(minter), true);
        IUniPoolerV2Live(UNI_POOLER).setBatchMinter(address(minter));
        vm.stopPrank();

        deal(USDS, batcher, 10_000_000e18);
        vm.prank(batcher);
        IERC20(USDS).approve(address(minter), type(uint256).max);
    }

    // ---- helpers ----

    function _p0() internal view returns (uint256 p0) {
        (, p0,,) = INFTMinterV2Live(NFT_MINTER).configs(INDEX);
    }

    /// @dev Push the pot to `k` free-equivalents (tin may be non-zero: add 1% and verify).
    function _fundTo(uint256 k) internal {
        uint256 usdc = (k * _p0() * 101) / 100 / 1e12 + 1;
        deal(USDC, donor, usdc);
        vm.prank(donor);
        IERC20(USDC).transfer(address(minter), usdc);
    }

    function _calldata(uint256 total, uint8 boost) internal view returns (bytes memory) {
        uint256[] memory mins = new uint256[](2);
        return abi.encodeCall(BatchNFTMinterNudgeDiscount.batchMint, (total, boost, batcher, 10_000_000e18, mins));
    }

    function _calldataGas(bytes memory data) internal pure returns (uint256 g) {
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    /// @dev Cold-measured execution gas of the batch the current pot forces.
    function _measureCold() internal returns (uint256 used, uint256 total, uint256 intrinsic) {
        (, total,,,,,) = minter.previewBatch();
        (, uint8 boost,,) = minter.previewBoost();
        bytes memory data = _calldata(total, boost);
        intrinsic = TX_BASE + _calldataGas(data);

        uint256 snap = vm.snapshotState();
        vm.startStateDiffRecording();
        vm.prank(batcher);
        (bool ok,) = address(minter).call{gas: 500_000_000}(data);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        require(ok, "warm-up batchMint failed");
        vm.revertToState(snap);
        for (uint256 i; i < acc.length; ++i) {
            vm.cool(acc[i].account);
            vm.cool(acc[i].accessor);
        }
        vm.prank(batcher);
        uint256 g0 = gasleft();
        (ok,) = address(minter).call{gas: TX_GAS_CAP - intrinsic}(data);
        used = g0 - gasleft();
        require(ok, "metered batchMint failed under the EIP-7825 cap");
    }

    function _assertCapFitsWithHeadroom(string memory label) internal {
        uint256 cap = minter.maxFreePerBatch();
        _fundTo(cap + 25); // past the cap: the batch is exactly `cap` free
        (uint256 free,,,,,,) = minter.previewBatch();
        assertEq(free, cap, "batch is exactly maxFreePerBatch");

        (uint256 used, uint256 total, uint256 intrinsic) = _measureCold();
        uint256 budget = ((TX_GAS_CAP - intrinsic) * (100 - HEADROOM_PCT)) / 100;
        emit log_named_uint(string.concat(label, " total NFTs"), total);
        emit log_named_uint(string.concat(label, " cold exec gas"), used);
        emit log_named_uint(string.concat(label, " tx gas incl. intrinsic"), used + intrinsic);
        emit log_named_uint(string.concat(label, " 90% budget"), budget);
        assertLe(used, budget, "cap batch fits under 2^24 - intrinsic with >= 10% headroom");
    }

    // ---- tests ----

    /// @dev PRIMARY: donation leg ON at `batchDonationSize = 10`, d = MIN_DISCOUNT_PERCENT.
    function test_Fork_capBatch_donationLegOn_fitsWithHeadroom() public {
        if (!forked) vm.skip(true);
        vm.prank(OWNER);
        IUniPoolerV2Live(UNI_POOLER).setBatchDonationSize(10);
        _assertCapFitsWithHeadroom("[donation on]");
    }

    /// @dev SECONDARY: donation leg OFF (the live configuration at the pinned block).
    function test_Fork_capBatch_donationLegOff_fitsWithHeadroom() public {
        if (!forked) vm.skip(true);
        _assertCapFitsWithHeadroom("[donation off]");
    }

    /// @dev A boost only removes paid mints: the max-boosted cap batch is cheaper still.
    function test_Fork_maxBoostedCapBatch_donationLegOn_fits() public {
        if (!forked) vm.skip(true);
        vm.startPrank(OWNER);
        IUniPoolerV2Live(UNI_POOLER).setBatchDonationSize(10);
        minter.setOverflowNFTsPerBoostPoint(3);
        minter.setMaxBoost(49);
        vm.stopPrank();
        _fundTo(minter.maxFreePerBatch() + 3 * 49 + 3);
        (, uint8 boost, uint8 eff,) = minter.previewBoost();
        assertEq(boost, 49);
        assertEq(eff, 99);
        (uint256 used,, uint256 intrinsic) = _measureCold();
        emit log_named_uint("[donation on, boost 49] cold exec gas", used);
        assertLe(used, ((TX_GAS_CAP - intrinsic) * (100 - HEADROOM_PCT)) / 100);
    }
}
