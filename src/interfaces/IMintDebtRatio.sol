// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice The one getter `BatchNFTMinterNudgeDiscount` reads off yield-claim-nft's
///         `BalancerPoolerMintDebtHook` (`uint8 public ratio;`, default 50): the percentage of
///         each gross dispatched mint price the hook accrues as phUSD mint debt.
/// @dev    Local because the vendored `IBalancerPoolerMintDebtHook` exposes only
///         `mintDebt()`/`pull()`, and `lib/mutable` must not change.
interface IMintDebtRatio {
    function ratio() external view returns (uint8);
}
