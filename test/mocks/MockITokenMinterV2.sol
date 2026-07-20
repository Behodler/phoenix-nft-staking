// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITokenMinterV2} from "yield-claim-nft/interfaces/ITokenMinterV2.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC1155} from "./MockERC1155.sol";

/// @notice Test double for the subset of `NFTMinterV2` that
///         `BatchNFTMinter` interacts with. Implements the no-extraData
///         `mint(index, recipient)` overload plus `getPrice` and
///         enough mint-side machinery to drive the batch helper:
///
///         - `mint` pulls `price` of `_primeToken[index]` from
///           `msg.sender` via `safeTransferFrom`, mints 1 ERC1155 unit of
///           `index` to `recipient`, then bumps stored `price` by
///           `growthBasisPoints` (newPrice = price * (10_000 + g) / 10_000).
///         - `getPrice` reads the current stored price for an index.
///         - `setConfig` lets tests pin a price + growth factor per index.
///         - `setPrimeToken` pins the prime token a given index pulls
///           payment in (the V2 minter resolves this from the dispatcher
///           rather than trusting a caller-supplied address).
///         - `setStakedToken` tells the mock which ERC1155 it should mint
///           into for any subsequent `mint` call.
///         - `setRevertAtCall(k)` makes the (k+1)-th `mint` call revert,
///           used to exercise atomic-revert behaviour in the batch helper.
///
///         Funds pulled from `msg.sender` are kept on this contract — no
///         dispatcher routing — which is sufficient for batch-helper tests.
contract MockITokenMinterV2 is ITokenMinterV2 {
    using SafeERC20 for IERC20;

    struct Config {
        uint256 price;
        uint256 growthBasisPoints;
    }

    mapping(uint256 => Config) private _configs;
    mapping(uint256 => address) private _primeToken;
    mapping(uint256 => address) private _dispatcher;
    MockERC1155 public stakedToken;

    uint256 public mintCallCount;
    uint256 private _revertAtCall; // 0 = disabled
    bool private _revertEnabled;

    // Optional per-mint donations: on every `mint`, push
    // `_donationAmounts[i]` of `_donationTokens[i]` from this mock into
    // `msg.sender` (the batch helper). This mirrors `BalancerPoolerV2`
    // donating USDC into the configured `batchMinter` on every mint.
    //
    // Story-022 widened this from a single (token, amount) pair to a LIST, so
    // the multi-token §4.2 "donate forward" tests can prove that a batcher's
    // own mid-loop donations stay behind for the next claimant across SEVERAL
    // reward tokens at once, not just one. The mock must be pre-funded with
    // `count * amount` of each donation token.
    address[] private _donationTokens;
    uint256[] private _donationAmounts;

    error MockITokenMinterV2__DonationArrayLengthMismatch();

    error MockITokenMinterV2__ForcedRevert();

    // ---- ITokenMinterV2 (only the surfaces BatchNFTMinter touches) ----

    function mint(uint256 index, address recipient) external override returns (bool) {
        mintCallCount += 1;
        if (_revertEnabled && mintCallCount == _revertAtCall) {
            revert MockITokenMinterV2__ForcedRevert();
        }
        Config storage c = _configs[index];
        uint256 price = c.price;
        IERC20(_primeToken[index]).safeTransferFrom(msg.sender, address(this), price);
        stakedToken.mint(recipient, index, 1);
        c.price = price * (10_000 + c.growthBasisPoints) / 10_000;
        uint256 donations = _donationTokens.length;
        for (uint256 i; i < donations; ++i) {
            IERC20(_donationTokens[i]).safeTransfer(msg.sender, _donationAmounts[i]);
        }
        return true;
    }

    function getPrice(uint256 index) external view override returns (uint256) {
        return _configs[index].price;
    }

    // ---- ITokenMinterV2 (unused — keep stubs minimal) ----

    function mint(uint256, address, bytes calldata) external pure override returns (bool) {
        revert("MockITokenMinterV2: extraData mint not supported");
    }

    function registerDispatcher(address, uint256, uint256) external pure override {
        revert("MockITokenMinterV2: not implemented");
    }

    function setPrice(uint256 index, uint256 newPrice) external override {
        _configs[index].price = newPrice;
    }

    function setGrowthFactor(uint256 index, uint256 newGrowthBasisPoints) external override {
        _configs[index].growthBasisPoints = newGrowthBasisPoints;
    }

    // ---- Test helpers ----

    function setConfig(uint256 index, uint256 price, uint256 growthBasisPoints) external {
        _configs[index] = Config({price: price, growthBasisPoints: growthBasisPoints});
    }

    function setPrimeToken(uint256 index, address token) external {
        _primeToken[index] = token;
    }

    /// @notice Pin the dispatcher address returned by `configs(index)`.
    ///         `BatchNFTMinter` resolves the payment asset by reading
    ///         `configs(index).dispatcher` then `dispatcher.primeToken()`.
    function setDispatcher(uint256 index, address dispatcher) external {
        _dispatcher[index] = dispatcher;
    }

    /// @notice `INFTMinterV2.configs` shape. `BatchNFTMinter` casts
    ///         `address(tokenMinter)` to `INFTMinterV2` and reads the
    ///         dispatcher address from here. Price/growth mirror the mock's
    ///         own `Config` storage; `disabled` is always false.
    function configs(uint256 index)
        external
        view
        returns (address dispatcher, uint256 price, uint256 growthBasisPoints, bool disabled)
    {
        Config storage c = _configs[index];
        return (_dispatcher[index], c.price, c.growthBasisPoints, false);
    }

    function setStakedToken(MockERC1155 token) external {
        stakedToken = token;
    }

    /// @notice Configure the (1-indexed) mint call number that should
    ///         revert. Pass 0 (and `enabled=false`) to disable.
    function setRevertAtCall(uint256 callIndex, bool enabled) external {
        _revertAtCall = callIndex;
        _revertEnabled = enabled;
    }

    /// @notice Configure a single per-mint donation, replacing any previously
    ///         configured set. On every `mint`, the mock pushes
    ///         `amountPerMint` of `token` into `msg.sender` (the batch
    ///         helper), simulating `BalancerPoolerV2`'s per-mint USDC donation
    ///         into the configured `batchMinter`. Pass `token == address(0)`
    ///         or `amountPerMint == 0` to disable. The mock must be pre-funded
    ///         with `count * amountPerMint` of `token`.
    function setPerMintDonation(address token, uint256 amountPerMint) external {
        delete _donationTokens;
        delete _donationAmounts;
        if (token != address(0) && amountPerMint != 0) {
            _donationTokens.push(token);
            _donationAmounts.push(amountPerMint);
        }
    }

    /// @notice Multi-token form of {setPerMintDonation}: on every `mint` the
    ///         mock pushes `amounts[i]` of `tokens[i]` into `msg.sender`, for
    ///         every `i`. Replaces any previously configured set; pass empty
    ///         arrays to disable. The mock must be pre-funded with
    ///         `count * amounts[i]` of each `tokens[i]`.
    function setPerMintDonations(address[] calldata tokens, uint256[] calldata amounts) external {
        if (tokens.length != amounts.length) revert MockITokenMinterV2__DonationArrayLengthMismatch();
        delete _donationTokens;
        delete _donationAmounts;
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == address(0) || amounts[i] == 0) continue;
            _donationTokens.push(tokens[i]);
            _donationAmounts.push(amounts[i]);
        }
    }

    /// @notice Number of donation entries currently configured.
    function donationCount() external view returns (uint256) {
        return _donationTokens.length;
    }
}
