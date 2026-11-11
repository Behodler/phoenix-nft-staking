// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISkyPSM} from "../../src/interfaces/ISkyPSM.sol";

/// @dev Faithful mock of the Sky USDS↔USDC PSM (UsdsPsmWrapper over Maker LitePSM).
///      Replicates the real `buyGem` semantics so a wrong contract-side assumption
///      cannot pass tests yet fail on mainnet:
///
///        usdsInWad = gemAmt * to18ConversionFactor;
///        if (tout > 0) usdsInWad += usdsInWad * tout / WAD;
///        usds.transferFrom(msg.sender, this, usdsInWad);   // pull USDS (18dp)
///        usdc.transfer(usr, gemAmt);                       // deliver USDC (6dp) from reserve
///
///      Matches makerdao/dss-lite-psm DssLitePsm._buyGem (verified 2026-06-04).
///      REVERTS — never silently succeeds — when:
///        - gemAmt == 0                            (mirrors a no-op / dust donation)
///        - the finite USDC reserve is insufficient
///        - USDS allowance or balance from msg.sender is short
///      These drive the contract's silent try/catch fallback tests.
contract MockSkyPSM is ISkyPSM {
    /// @dev 1e18 fixed-point scale for fees (matches the real PSM WAD).
    uint256 internal constant WAD = 1e18;

    IERC20 public immutable usdsToken; // USDS (18dp)
    IERC20 public immutable gemToken; // USDC (6dp)

    uint256 public immutable to18ConversionFactor; // 1e12 for USDC
    uint256 public tout; // buy fee, WAD-scaled
    uint256 public tin; // sell fee, WAD-scaled

    constructor(address usds_, address gem_, uint256 to18ConversionFactor_) {
        usdsToken = IERC20(usds_);
        gemToken = IERC20(gem_);
        to18ConversionFactor = to18ConversionFactor_;
    }

    function usds() external view returns (address) {
        return address(usdsToken);
    }

    function gem() external view returns (address) {
        return address(gemToken);
    }

    /// @notice USDS→USDC. Pulls `usdsInWad` USDS from caller, sends `gemAmt` USDC to `usr`.
    function buyGem(address usr, uint256 gemAmt) external returns (uint256 usdsInWad) {
        require(gemAmt > 0, "MockSkyPSM/zero-gem");

        usdsInWad = gemAmt * to18ConversionFactor;
        if (tout > 0) {
            usdsInWad += (usdsInWad * tout) / WAD;
        }

        // Finite reserve: revert (do not silently succeed) when it can't be paid.
        require(gemToken.balanceOf(address(this)) >= gemAmt, "MockSkyPSM/insufficient-reserve");

        // Pull USDS; transferFrom reverts on short allowance/balance (USDS reverts on failure).
        require(usdsToken.transferFrom(msg.sender, address(this), usdsInWad), "MockSkyPSM/usds-pull-failed");
        require(gemToken.transfer(usr, gemAmt), "MockSkyPSM/usdc-send-failed");
    }

    /// @notice USDC→USDS. Provided for interface fidelity; unused by the pooler.
    function sellGem(address usr, uint256 gemAmt) external returns (uint256 usdsOutWad) {
        require(gemAmt > 0, "MockSkyPSM/zero-gem");
        usdsOutWad = gemAmt * to18ConversionFactor;
        if (tin > 0) {
            usdsOutWad -= (usdsOutWad * tin) / WAD;
        }
        require(gemToken.transferFrom(msg.sender, address(this), gemAmt), "MockSkyPSM/usdc-pull-failed");
        require(usdsToken.transfer(usr, usdsOutWad), "MockSkyPSM/usds-send-failed");
    }

    // ---- test helpers ----

    /// @dev Fund the finite USDC reserve this PSM pays `buyGem` out of.
    function fundReserve(uint256 usdcAmount) external {
        // Caller must hold + approve USDC; mirrors a real pocket being seeded.
        require(gemToken.transferFrom(msg.sender, address(this), usdcAmount), "MockSkyPSM/fund-failed");
    }

    function setTout(uint256 newTout) external {
        tout = newTout;
    }

    function setTin(uint256 newTin) external {
        tin = newTin;
    }
}
