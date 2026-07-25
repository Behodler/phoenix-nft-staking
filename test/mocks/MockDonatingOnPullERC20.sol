// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC20 whose `transferFrom` ALSO moves a third party's tokens to the
///         same recipient, in the same call.
///
/// This is the adversarial witness for the credited-delta measurement in
/// `batchMint` step 5. A callback-bearing token (ERC777-style hooks, or any
/// token with a transfer callback) lets an unrelated party push funds into the
/// recipient DURING the pull. `nonReentrant` does not prevent this: it blocks
/// re-entering `batchMint`, not a plain inbound transfer landing mid-call.
///
/// A bare `balanceAfter - balanceBefore` would therefore credit the caller's
/// budget with someone else's money — the donate-forward pool `D` in miniature,
/// and the same conflation `ycn19h1` exploited, merely reached through a
/// narrower window. `budget = min(credited, paymentAmount)` is what closes it,
/// which is why the measurement is a floor on nothing and a ceiling on
/// `paymentAmount`.
contract MockDonatingOnPullERC20 is ERC20 {
    /// @dev Whose tokens get dragged along. Set to a funded third party.
    address public donor;
    /// @dev How much of the donor's balance rides along with each `transferFrom`.
    uint256 public donationPerPull;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setDonation(address donor_, uint256 amount) external {
        donor = donor_;
        donationPerPull = amount;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        bool ok = super.transferFrom(from, to, value);
        uint256 donation = donationPerPull;
        if (donation != 0 && donor != address(0) && balanceOf(donor) >= donation) {
            // Not routed through `transferFrom`: no allowance, no recursion.
            _transfer(donor, to, donation);
        }
        return ok;
    }
}
