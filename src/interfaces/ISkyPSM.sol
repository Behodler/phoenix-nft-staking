// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  ISkyPSM (minimal)
/// @notice Minimal local copy of yield-claim-nft's `ISkyPSM` — only the surface
///         `BatchNFTMinterNudgeDiscount` reads. Kept local (rather than importing the
///         vendored interface) by the human's direction: mutable siblings expose
///         interfaces only, and this contract needs the sell side alone.
///
/// @dev Provenance (copied from yield-claim-nft `src/interfaces/ISkyPSM.sol`, verified
///      on-chain / from canonical source 2026-06-04):
///   - Live contract: Sky `UsdsPsmWrapper` ("LitePSMWrapper-USDS-USDC")
///         0xA188EEC8F81263234dA3622A406892F3D630f98c  (Ethereum mainnet),
///     which proxies the Maker `DssLitePsm`; fee/decimal conventions are identical.
///   - `sellGem(address usr, uint256 gemAmt) returns (uint256 usdsOutWad)`: pulls `gemAmt`
///     USDC (6dp) from msg.sender and delivers USDS (18dp) to `usr`:
///        usdsOutWad = gemAmt * to18ConversionFactor;
///        if (tin > 0) usdsOutWad -= usdsOutWad * tin / WAD;          (WAD = 1e18)
///     (source: makerdao/dss-lite-psm DssLitePsm._sellGem.)
///   - `to18ConversionFactor` is an immutable = 10**(18 - gem.decimals()) = 1e12 for USDC.
///   - `tin` is a governance-settable WAD fee (currently 0; raisable).
///   - `gem()` = USDC (0xA0b8...eB48), `usds()` = USDS.
interface ISkyPSM {
    /// @notice Sell `gemAmt` USDC (6dp) from msg.sender, receiving USDS to `usr`.
    /// @return usdsOutWad USDS (18dp) delivered net of the `tin` fee.
    function sellGem(address usr, uint256 gemAmt) external returns (uint256 usdsOutWad);

    /// @notice Sell-side fee, WAD-scaled (1e18 == 100%). Applied on `sellGem`.
    function tin() external view returns (uint256);

    /// @notice 10**(18 - gem.decimals()); 1e12 for 6-decimal USDC.
    function to18ConversionFactor() external view returns (uint256);

    /// @notice The gem token sold (USDC).
    function gem() external view returns (address);

    /// @notice The Sky stablecoin received (USDS).
    function usds() external view returns (address);
}
