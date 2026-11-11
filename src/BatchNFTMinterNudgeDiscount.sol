// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITokenMinterV2} from "yield-claim-nft/interfaces/ITokenMinterV2.sol";
import {INFTMinterV2} from "yield-claim-nft/interfaces/INFTMinterV2.sol";
import {ITokenDispatcherV2} from "yield-claim-nft/interfaces/ITokenDispatcherV2.sol";
import {IUniswapV2Router02} from "yield-claim-nft/interfaces/uniswap/IUniswapV2Router02.sol";
import {IUniswapV2Pair} from "yield-claim-nft/interfaces/uniswap/IUniswapV2Pair.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPausable} from "pauser/interfaces/IPausable.sol";
import {INudgeStreamer} from "./INudgeStreamer.sol";
import {ISkyPSM} from "./interfaces/ISkyPSM.sol";
import {IPhusdBurnable} from "./interfaces/IPhusdBurnable.sol";
import {IMintDebtRatio} from "./interfaces/IMintDebtRatio.sol";

/// @title BatchNFTMinterNudgeDiscount
/// @notice Successor to `BatchNFTMinterMultiToken` (story 033, design revision 2). The USDC
///         nudge pot no longer pays out to a winner-take-all batcher; instead it SETS a
///         discrete, pot-sized discount batch, and the pot itself is reserved to buy phUSD
///         in a later, authorised `buyAndBurn`.
///
/// ### Why this contract exists (the loophole)
///
/// Under the multi-token minter a whale whose past mints earned large NFTStaker phUSD
/// rewards could sell that phUSD to fund a qualifying `nudgeSize` batch and walk off with
/// the whole USDC pot — extracting the pot without bringing in new liquidity. The fix is
/// to make the pot buy discounted NFTs rather than pay cash, and to spend the pot itself on
/// the open market for phUSD that goes to stakers or is burned.
///
/// ### The rev 2 model
///
/// - **The USDC pot sets the batch.** With `P0` the next-NFT price at batch start and the
///   pot converted to USD with the PSM's own sell maths (`tin` included):
///   `free = potUSD / P0` (floor), `total = ceilDiv(free * 100, discountPercent)`,
///   `paid = total - free`. The caller cannot choose the count: they confirm the previewed
///   `expectedTotal`, and a mismatch reverts. Price 10, discount 50: pot 10 → 2 for 1;
///   pot 15 → still 2 for 1; pot 20 → 4 for 2; pot 100 → the batch MUST be 20.
/// - **Paid NFTs** go through `ITokenMinterV2.mint` exactly as before: full price to the
///   dispatcher, price growth, and mint-debt accrual.
/// - **Free NFTs** come from `INFTMinterV2.mintFor`: no payment, no dispatch, no price
///   growth. This contract must be an authorised minter on NFTMinterV2.
/// - **The pot never reaches the user and is never pooled.** `batchMint` only RESERVES the
///   whole pot (partial-step remainder included): `pendingBuyUSDC += pot` and
///   `pendingStakerPhUSD += owed`, `owed = free * P0 * ratio / 100`, `ratio` read live from
///   the mint-debt hook. `owed` balances the books for the hook the free NFTs skipped; it
///   is BOUGHT phUSD, not minted, so there is no new supply.
/// - **Deferred buy.** An authorised buyer calls `buyAndBurn(usdcIn, minPhusdOut, deadline)`
///   with an off-chain floor: USDC → PSM → USDS → sUSDS → UniV2 → phUSD. A swap inside the
///   user's own transaction could be sandwiched, hence the deferral (the MEV rule of
///   phase-2-staging `docs/NFT/UniV2PriceTilting.md`, mirroring `UniPoolerV2.pool`). The
///   phUSD out pays the owed balance to NFTStaker first; the extra is split by
///   `burnPercent` between a burn and NFTStaker. If phUSD has rallied and the buy returns
///   less than owed, it all goes to NFTStaker and the shortfall carries forward.
/// - **Bonus tokens** (every whitelisted token except the discount token) are paid IN FULL
///   on EVERY batch. `nudgeSize` is gone; every batch contains at least one free NFT, so a
///   bonus always accompanies a discounted mint.
/// - **No batch without a discount**: `free == 0` or `discountPercent == 0` reverts.
///
/// ### Inherited from `BatchNFTMinterMultiToken`
///
/// The NFT minter is a **trusted, owner-configured** contract (`tokenMinter`), NOT a call
/// parameter; the dispatcher index is pinned; the payment asset is DERIVED from the pinned
/// dispatcher's `primeToken()`.
///
/// **Whitelist-selected multi-token nudge (story-025).** The owner controls the set of
/// reward assets through an owner-managed whitelist (`setNudgeTokenWhitelist`); the caller
/// supplies only a per-token floor. Vetting the token set at admin time removes the
/// weird-token attack surface that attacker-chosen addresses opened — anything odd that
/// lands here is simply left to `rescueERC20`. Here the whitelist also carries the
/// discount token, because `NudgeStreamer.registerStream` requires it, but the discount
/// token is excluded from the bonus (`getBonusTokens`).
///
/// **The payment token MAY be a bonus token (story-029).** The refund is sourced from a
/// locally-tracked `budget`, never from `balanceOf`, so `refund <= budget <= maxPayment`
/// holds BY CONSTRUCTION. A single absolute balance conflates three pools — the standing
/// pot `P`, the caller's unspent budget `A - C`, and this batch's own donations `D` — and
/// handing `P + (A - C) + D` back as "residual" let a one-wei batch walk off with the whole
/// pot (yield-claim-nft submission `ycn19h1`). `budget` is **measured across the pull, not
/// quoted**: `min(balance delta over the pull, maxPayment)`. The lower side charges a
/// fee-on-transfer shortfall to the caller instead of the pot; the upper side (the `min`)
/// stops a callback token from crediting a third party's mid-pull donation to the caller.
/// Story-032 then removed the admin-time rejection of the payment token from the
/// whitelist; nothing changes here.
///
/// Pausing is wired into the Phoenix global `Pauser` via the hybrid OZ `Pausable` +
/// `IPausable` pattern: a settable `pauser` may `pause()`/`unpause()`, and only `batchMint`
/// is gated by `whenNotPaused`. `buyAndBurn` is deliberately NOT pause-gated (its kill
/// switch is `incrementAuthVersion`), so pausing stops new reservations but still lets the
/// reserve drain into phUSD. Admin setters and `rescueERC20` stay callable while paused.
///
/// @dev **AUDIT-CRITICAL — `mintFor` power.** This contract holds unlimited free-mint power
///      over its dispatcher index, bounded only by its own logic. `NFTMinterV2.mintFor`
///      ignores the NFTMinter pause, so THIS contract's pause is the only kill switch for
///      free mints, and the authorisation must be revoked (`setAuthorizedMinter(this,
///      false)`) when this minter is retired.
///
///      **Two balances share one USDC holding.** The reserve (`pendingBuyUSDC`) and the live
///      pot are both `discountToken.balanceOf(this)`. Every pot read subtracts the reserve;
///      `rescueERC20` cannot take reserved USDC; reserved USDC leaves only via `buyAndBurn`.
///
///      **phUSD is both a bonus token and the buy output.** Buy output is measured by a
///      narrow balance delta bracketed around the swap, never by an absolute balance.
contract BatchNFTMinterNudgeDiscount is Ownable, Pausable, ReentrancyGuard, IPausable {
    using SafeERC20 for IERC20;

    constructor(address initialOwner) Ownable(initialOwner) {
        discountPercent = 50;
        burnPercent = 100;
        // LOAD-BEARING (UniPoolerV2 :231 pattern): the `buyerAuthVersion` mapping defaults to
        // 0, so a zero `authVersion` would authorise EVERY address as a buyer.
        authVersion = 1;
    }

    /// @dev Residual payment-token balance below this threshold is kept
    ///      in the contract rather than refunded, absorbing JS rounding
    ///      slack. For an 18-decimal token this is ~10^-12 of a unit.
    uint256 internal constant DUST_THRESHOLD = 1e6;

    /// @dev WAD scale of the PSM `tin` fee.
    uint256 internal constant WAD = 1e18;

    /// @notice Trusted, owner-configured NFT minter every `batchMint` forwards
    ///         to. `address(0)` disables `batchMint`.
    ITokenMinterV2 public tokenMinter;

    /// @notice The only dispatcher index `batchMint` mints. Owner-set;
    ///         `0` = unconfigured and disables `batchMint`.
    uint256 public dispatcherIndex;

    /// @notice Address authorised to pause/unpause via the global pauser.
    ///         Settable by the owner; `address(0)` disables pausing.
    address public pauser;

    /// @dev Ordered whitelist of nudge tokens (discount token + bonus tokens). Maintained as a
    ///      manual swap-remove set because OZ EnumerableSet requires solc ^0.8.24 while this
    ///      repo targets 0.8.20.
    address[] private _nudgeTokens;

    /// @dev 1-based index into `_nudgeTokens`; `0` == not whitelisted.
    mapping(address => uint256) private _nudgeTokenIndex;

    /// @notice Optional linear streamer that meters bursty donations into this
    ///         contract. `batchMint` flushes each whitelisted token's accrued stream
    ///         (via `pullPendingStream`) BEFORE it snapshots bonuses and reads the pot.
    ///         `address(0)` disables the integration.
    address public nudgeStreamer;

    // ---------------------------------------------------------------- rev 2 state

    /// @notice The pot token (USDC). Must stay whitelisted (NudgeStreamer requires it) and
    ///         is excluded from the bonus. `address(0)` disables batch minting.
    IERC20 public discountToken;
    /// @notice 0..100; 25 means a 25% discount. Default 50.
    uint8 public discountPercent;
    /// @notice 0..100 share of the buy's EXTRA phUSD (beyond owed) that is burned. Default 100.
    uint8 public burnPercent;
    /// @notice phUSD recipient for owed + unburned extra.
    address public nftStaker;
    /// @notice Live `ratio()` source (BalancerPoolerMintDebtHook).
    IMintDebtRatio public mintDebtHook;
    /// @notice Sky USDS↔USDC PSM used to price the pot and to sell USDC in `buyAndBurn`.
    ISkyPSM public psm;
    /// @notice sUSDS (ERC4626 over USDS).
    IERC4626 public sUSDS;
    /// @notice UniV2 Router02.
    address public router;
    /// @notice phUSD/sUSDS UniV2 pair (validated on set; the swap path is `[sUSDS, phUSD]`).
    address public pair;
    /// @notice phUSD.
    address public phUSD;

    /// @notice Reserved USDC awaiting `buyAndBurn` (6dp). NOT pot.
    uint256 public pendingBuyUSDC;
    /// @notice phUSD still owed to NFTStaker (18dp); carries forward across buys.
    uint256 public pendingStakerPhUSD;

    /// @notice Current buyer auth version; `incrementAuthVersion` mass-revokes. Starts at 1.
    uint256 public authVersion;
    /// @notice A buyer is authorised iff `buyerAuthVersion[buyer] == authVersion`.
    mapping(address => uint256) public buyerAuthVersion;

    /// @dev Per-batch working set, held in MEMORY: `batchMint` sits at the legacy code
    ///      generator's stack limit (via_ir stays off — tests rely on `vm.warp`).
    struct BatchCtx {
        ITokenMinterV2 nftMinter;
        uint256 dispatcherIndex;
        IERC20 paymentToken;
        uint256 p0;
        uint256 growthBps;
        uint256 potUSDC;
        uint256 potUSD;
        uint256 free;
        uint256 total;
        uint256 paid;
        uint256 paidCost;
        uint256 owed;
    }

    /// @dev Reverted when `expectedTotal == 0`.
    error BatchMint__ZeroCount();
    /// @dev Reverted when `recipient == address(0)`.
    error BatchMint__ZeroRecipient();
    /// @dev Reverted when `bonusMinRewards.length != getBonusTokens().length`.
    error BatchMint__ArrayLengthMismatch(uint256 tokensLength, uint256 minsLength);
    /// @dev Reverted when `batchMint` is called while `tokenMinter` is unset.
    error BatchMint__MinterNotConfigured();
    /// @dev Reverted when `dispatcherIndex` is unset (`0`) or resolves to a zero dispatcher.
    error BatchMint__DispatcherNotConfigured();
    /// @dev Reverted when `setNudgeTokenWhitelist` is given the zero address to whitelist.
    error BatchMint__ZeroNudgeToken();
    /// @dev Reverted when whitelisting a token that is already whitelisted.
    error BatchMint__NudgeTokenAlreadyWhitelisted(address token);
    /// @dev Reverted when unwhitelisting a token that is not whitelisted.
    error BatchMint__NudgeTokenNotWhitelisted(address token);
    /// @dev Reverted when `rescueERC20` is given a zero destination.
    error Rescue__ZeroRecipient();
    /// @dev Reverted when a bonus token's pre-pull balance is below the caller's floor.
    error BatchMint__RewardBelowMinimum(address token, uint256 minReward, uint256 actualReward);
    /// @dev Reverted when the caller's remaining budget cannot cover the next paid mint.
    error BatchMint__PaymentBudgetExhausted(uint256 mintIndex, uint256 price, uint256 remaining);

    error BatchMint__PercentTooHigh(uint8 percent);
    error BatchMint__DiscountTokenNotWhitelisted(address token);
    /// @dev Unwhitelisting the active discount token. Clear `discountToken` first.
    error BatchMint__DiscountTokenIsActive(address token);
    /// @dev `setDiscountToken` while reserved USDC is pending (no re-denomination).
    error BatchMint__ReservePending(uint256 pendingBuyUSDC);
    /// @dev `discountToken`, `psm` or `mintDebtHook` unset at `batchMint`.
    error BatchMint__DiscountNotConfigured();
    error BatchMint__DiscountTokenNotGem(address discount, address gem);
    /// @dev `free == 0` or `discountPercent == 0`.
    error BatchMint__NoDiscountAvailable();
    error BatchMint__TotalMismatch(uint256 total, uint256 expectedTotal);
    error BatchMint__MaxPaymentExceeded(uint256 paidCost, uint256 maxPayment);
    error BatchMint__BuyNotConfigured();
    error BatchMint__BuyExceedsReserve(uint256 usdcIn, uint256 reserve);
    /// @dev A zero floor is an unbounded-slippage swap.
    error BatchMint__ZeroMinOut();
    error BatchMint__Expired(uint256 deadline);
    error BatchMint__SUSDSAssetMismatch(address asset, address usds);
    error BatchMint__PairMismatch();
    error BatchMint__ZeroBuyer();
    error BatchMint__UnauthorizedBuyer(address caller);
    error Rescue__ReservedFunds(uint256 requested, uint256 unreserved);

    event NudgeTokenWhitelistChanged(address indexed token, bool allowed);
    event NudgePaid(address indexed recipient, address indexed token, uint256 amount);
    event TokenMinterSet(address indexed newMinter);
    event DispatcherIndexSet(uint256 indexed dispatcherIndex);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event PauserChanged(address indexed previousPauser, address indexed newPauser);
    event NudgeStreamerChanged(address indexed previousStreamer, address indexed newStreamer);

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
    event BoughtAndBurned(
        address indexed buyer,
        uint256 usdcIn,
        uint256 phusdOut,
        uint256 toStakerOwed,
        uint256 toStakerExtra,
        uint256 burned,
        uint256 owedRemaining
    );

    modifier onlyPauser() {
        require(msg.sender == pauser, "BatchNFTMinter: caller is not pauser");
        _;
    }

    /// @dev UniPoolerV2 `onlyAuthorizedPooler` shape. Safe only because `authVersion >= 1`.
    modifier onlyAuthorizedBuyer() {
        if (buyerAuthVersion[msg.sender] != authVersion) revert BatchMint__UnauthorizedBuyer(msg.sender);
        _;
    }

    // =====================================================================
    // Inherited admin surface
    // =====================================================================

    /// @notice Owner-gated update of the trusted NFT minter. `address(0)` disables `batchMint`.
    function setTokenMinter(ITokenMinterV2 newMinter) external onlyOwner {
        tokenMinter = newMinter;
        emit TokenMinterSet(address(newMinter));
    }

    /// @notice Owner-gated update of the only dispatcher index `batchMint` mints.
    ///         `0` disables `batchMint`. Stays callable while paused.
    function setDispatcherIndex(uint256 newIndex) external onlyOwner {
        dispatcherIndex = newIndex;
        emit DispatcherIndexSet(newIndex);
    }

    /// @notice Ordered whitelist (discount token included). Swap-and-pop REORDERS it.
    function getNudgeTokens() external view returns (address[] memory) {
        return _nudgeTokens;
    }

    /// @notice The bonus tokens, in `getNudgeTokens()` order with `discountToken` skipped.
    ///         `bonusMinRewards` in `batchMint` binds to THIS order. Unwhitelisting uses
    ///         swap-and-pop, which REORDERS the list — fetch immediately before calling.
    function getBonusTokens() public view returns (address[] memory bonus) {
        address dt = address(discountToken);
        uint256 n = _nudgeTokens.length;
        bonus = new address[](_bonusCount());
        uint256 j;
        for (uint256 i; i < n; ++i) {
            address t = _nudgeTokens[i];
            if (t == dt) continue;
            bonus[j++] = t;
        }
    }

    /// @notice O(1) whitelist membership. `NudgeStreamer.registerStream` relies on it.
    function isNudgeToken(address token) external view returns (bool) {
        return _nudgeTokenIndex[token] != 0;
    }

    /// @notice Owner-gated update of the optional nudge streamer.
    function setNudgeStreamer(address newStreamer) external onlyOwner {
        emit NudgeStreamerChanged(nudgeStreamer, newStreamer);
        nudgeStreamer = newStreamer;
    }

    /// @notice Owner-gated add/remove of a whitelisted token. Stays callable while paused.
    /// @dev    Adding rejects only the zero address and a duplicate. Removal is swap-and-pop
    ///         (reorders) and REVERTS for the active discount token: clear `discountToken`
    ///         first (which in turn needs an empty reserve). That avoids a silent flip of the
    ///         bonus ordering and keeps NudgeStreamer's registration precondition true.
    function setNudgeTokenWhitelist(address token, bool allowed) external onlyOwner {
        if (allowed) {
            if (token == address(0)) revert BatchMint__ZeroNudgeToken();
            if (_nudgeTokenIndex[token] != 0) {
                revert BatchMint__NudgeTokenAlreadyWhitelisted(token);
            }
            _nudgeTokens.push(token);
            _nudgeTokenIndex[token] = _nudgeTokens.length;
        } else {
            uint256 oneBasedIndex = _nudgeTokenIndex[token];
            if (oneBasedIndex == 0) revert BatchMint__NudgeTokenNotWhitelisted(token);
            if (token == address(discountToken)) revert BatchMint__DiscountTokenIsActive(token);
            uint256 length = _nudgeTokens.length;
            if (oneBasedIndex != length) {
                address lastToken = _nudgeTokens[length - 1];
                _nudgeTokens[oneBasedIndex - 1] = lastToken;
                _nudgeTokenIndex[lastToken] = oneBasedIndex;
            }
            _nudgeTokens.pop();
            delete _nudgeTokenIndex[token];
        }
        emit NudgeTokenWhitelistChanged(token, allowed);
    }

    /// @notice Owner-gated update of the pauser address. `address(0)` disables pausing.
    function setPauser(address newPauser) external onlyOwner {
        emit PauserChanged(pauser, newPauser);
        pauser = newPauser;
    }

    /// @notice Pause `batchMint` (and with it every free mint). Pauser only.
    function pause() external override onlyPauser {
        _pause();
    }

    /// @notice Resume `batchMint`. Pauser only.
    function unpause() external override onlyPauser {
        _unpause();
    }

    /// @notice Owner-only recovery of an arbitrary ERC20.
    /// @dev    For the discount token only the UNRESERVED balance (`balance - pendingBuyUSDC`)
    ///         can be rescued; reserved USDC leaves only through `buyAndBurn`. If the buy route
    ///         ever breaks permanently the reserve is stuck until the route is repointed with
    ///         `setPSM`/`setSUSDS`/`setSwapRoute` — deliberately, there is no owner escape for
    ///         it. All other tokens are unrestricted. Stays callable while paused.
    function rescueERC20(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert Rescue__ZeroRecipient();
        if (address(token) == address(discountToken) && address(token) != address(0)) {
            uint256 unreserved = token.balanceOf(address(this)) - pendingBuyUSDC;
            if (amount > unreserved) revert Rescue__ReservedFunds(amount, unreserved);
        }
        token.safeTransfer(to, amount);
        emit Rescued(address(token), to, amount);
    }

    // =====================================================================
    // Rev 2 admin surface
    // =====================================================================

    /// @notice Set the pot token. Must be whitelisted, or `address(0)` (disables batch
    ///         minting). Reverts while a reserve is pending, so reserved USDC can never be
    ///         re-denominated into a different token.
    function setDiscountToken(address token) external onlyOwner {
        uint256 reserve = pendingBuyUSDC;
        if (reserve != 0) revert BatchMint__ReservePending(reserve);
        if (token != address(0) && _nudgeTokenIndex[token] == 0) {
            revert BatchMint__DiscountTokenNotWhitelisted(token);
        }
        discountToken = IERC20(token);
        emit DiscountTokenSet(token);
    }

    /// @notice 0..100. `0` disables batch minting (`NoDiscountAvailable`).
    function setDiscountPercent(uint8 percent) external onlyOwner {
        if (percent > 100) revert BatchMint__PercentTooHigh(percent);
        discountPercent = percent;
        emit DiscountPercentSet(percent);
    }

    /// @notice 0..100. `0` = all extra phUSD to NFTStaker; `100` = burn all of it.
    function setBurnPercent(uint8 percent) external onlyOwner {
        if (percent > 100) revert BatchMint__PercentTooHigh(percent);
        burnPercent = percent;
        emit BurnPercentSet(percent);
    }

    /// @notice `address(0)` = unset (legal at rest; `buyAndBurn` reverts).
    function setNFTStaker(address newStaker) external onlyOwner {
        nftStaker = newStaker;
        emit NFTStakerSet(newStaker);
    }

    /// @notice `address(0)` = unset (legal at rest; `batchMint` reverts).
    function setMintDebtHook(IMintDebtRatio newHook) external onlyOwner {
        mintDebtHook = newHook;
        emit MintDebtHookSet(address(newHook));
    }

    /// @notice `address(0)` = unset (legal at rest; `batchMint` and `buyAndBurn` revert).
    function setPSM(ISkyPSM newPsm) external onlyOwner {
        psm = newPsm;
        emit PSMSet(address(newPsm));
    }

    /// @notice `address(0)` = unset. Set BEFORE `setSwapRoute`, which validates against it.
    ///         Repointing it leaves the stored pair stale; `buyAndBurn` re-validates the pair
    ///         and reverts `PairMismatch` until `setSwapRoute` is called again.
    function setSUSDS(IERC4626 newSUSDS) external onlyOwner {
        sUSDS = newSUSDS;
        emit SUSDSSet(address(newSUSDS));
    }

    /// @notice Set the buy route. `(0, 0, 0)` = unset. Otherwise requires a non-zero router and
    ///         `{pair.token0(), pair.token1()} == {sUSDS, phUSD}` (so `sUSDS` must be set
    ///         first). The swap path is always `[sUSDS, phUSD]`; `pair` exists for this
    ///         validation and for off-chain floor computation.
    function setSwapRoute(address newRouter, address newPair, address newPhUSD) external onlyOwner {
        if (newRouter != address(0) || newPair != address(0) || newPhUSD != address(0)) {
            if (newRouter == address(0)) revert BatchMint__BuyNotConfigured();
            if (!_pairMatches(newPair, address(sUSDS), newPhUSD)) revert BatchMint__PairMismatch();
        }
        router = newRouter;
        pair = newPair;
        phUSD = newPhUSD;
        emit SwapRouteSet(newRouter, newPair, newPhUSD);
    }

    /// @notice Authorise (at the current `authVersion`) or revoke a `buyAndBurn` caller.
    function setAuthorizedBuyer(address buyer, bool authorized) external onlyOwner {
        if (buyer == address(0)) revert BatchMint__ZeroBuyer();
        if (authorized) {
            uint256 version = authVersion;
            buyerAuthVersion[buyer] = version;
            emit BuyerAuthorized(buyer, version);
        } else {
            delete buyerAuthVersion[buyer];
            emit BuyerDeauthorized(buyer);
        }
    }

    /// @notice Mass-revoke every buyer. The `buyAndBurn`-only kill switch; minting is unaffected.
    function incrementAuthVersion() external onlyOwner {
        uint256 version = authVersion + 1;
        authVersion = version;
        emit AuthVersionIncremented(version);
    }

    // =====================================================================
    // Views
    // =====================================================================

    /// @notice Live pot: discount-token balance minus the reserve. `0` if no discount token.
    function availablePotUSDC() external view returns (uint256) {
        IERC20 dt = discountToken;
        if (address(dt) == address(0)) return 0;
        return dt.balanceOf(address(this)) - pendingBuyUSDC;
    }

    /// @notice Preview the batch the next `batchMint` would execute, through the SAME maths.
    /// @dev    AN ESTIMATE. The pot here is `balance - pendingBuyUSDC + pendingStream(this,
    ///         discountToken)`; front-running and further stream accrual can change it, which
    ///         is exactly why `batchMint` takes `expectedTotal` and `maxPayment`. When
    ///         misconfigured, or when `free == 0`, the batch fields are zero rather than a
    ///         revert, while `potUSD` and `nextStepUSDC` are still returned where computable so
    ///         a UI can render "pot too small".
    /// @return free         NFTs minted via `mintFor`.
    /// @return total        The `expectedTotal` to pass.
    /// @return paid         NFTs minted via `mint`.
    /// @return paidCost     The caller's cost (18dp prime token); a sound `maxPayment` floor.
    /// @return owed         phUSD added to `pendingStakerPhUSD`.
    /// @return potUSD       The pot in USD (18dp), net of the PSM `tin`.
    /// @return nextStepUSDC Additional USDC (6dp, rounded up) needed for `free` to reach
    ///                      `free + 1`.
    function previewBatch()
        external
        view
        returns (
            uint256 free,
            uint256 total,
            uint256 paid,
            uint256 paidCost,
            uint256 owed,
            uint256 potUSD,
            uint256 nextStepUSDC
        )
    {
        (BatchCtx memory c, uint256 step, bool batchable) = _preview();
        potUSD = c.potUSD;
        nextStepUSDC = step;
        if (batchable && c.free != 0) {
            (free, total, paid, paidCost, owed) = (c.free, c.total, c.paid, c.paidCost, c.owed);
        }
    }

    /// @dev `previewBatch` body, split out for the legacy code generator's stack limit.
    function _preview() private view returns (BatchCtx memory c, uint256 nextStepUSDC, bool batchable) {
        uint256 conv;
        uint256 tin;
        uint256 ratio;
        (c, conv, tin, ratio, batchable) = _previewInputs();
        if (conv == 0) return (c, 0, false);
        _computeBatch(c, conv, tin, discountPercent, ratio);
        nextStepUSDC = _nextStepUSDC(c.potUSDC, c.potUSD, c.p0, conv, tin);
    }

    // =====================================================================
    // batchMint
    // =====================================================================

    /// @notice Mint the pot-sized discounted batch to `recipient`: `free` NFTs via `mintFor`
    ///         and `paid` NFTs via `mint`, paid by `msg.sender` in the dispatcher's prime token.
    ///         Reserves the whole pot for `buyAndBurn` and pays every bonus balance.
    ///
    /// @dev    NORMATIVE EXECUTION ORDER (story 033; mirrored in `docs/multi-token-nudge.md` §9):
    ///          1. Validate inputs.             8. Pull the caller's payment (skip if paid == 0).
    ///          2. Resolve the payment path.    9. Paid mint loop (`mint`).
    ///          3. Flush ALL streams.          10. Revoke the minter allowance.
    ///          4. Bonus snapshot + floors.    11. Free mint loop (`mintFor`).
    ///          5. Read the pot, check config. 12. Refund unspent budget.
    ///          6. Maths + total/maxPayment.   13. Emit `BatchMinted`.
    ///          7. Reserve (effects).          14. Bonus payout of the step-4 snapshot.
    ///
    ///         ORDER IS LOAD-BEARING at six points, (a)–(f), each commented inline below.
    ///
    ///         **Reentrancy:** whitelisted tokens and the minter are external code this
    ///         function calls; `nonReentrant` removes the need to reason about interleaving.
    ///
    /// @param  expectedTotal    The previewed `total`. A mismatch reverts `TotalMismatch`.
    /// @param  recipient        ERC1155 and bonus recipient (non-zero).
    /// @param  maxPayment       Payment-token ceiling. Reverts `MaxPaymentExceeded` up front if
    ///                          the batch costs more. Pulled in full (when `paid > 0`); unspent
    ///                          budget >= `DUST_THRESHOLD` is refunded.
    /// @param  bonusMinRewards  Per-bonus-token floor, parallel to `getBonusTokens()`.
    /// @return totalPaid        The caller's own spend (pulled budget - refund). The pot never
    ///                          contributes.
    /// @return free             NFTs minted for free.
    /// @return paid             NFTs minted at full price.
    function batchMint(uint256 expectedTotal, address recipient, uint256 maxPayment, uint256[] calldata bonusMinRewards)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 totalPaid, uint256 free, uint256 paid)
    {
        // --- 1. Validate the caller's inputs. ---
        if (expectedTotal == 0) revert BatchMint__ZeroCount();
        if (recipient == address(0)) revert BatchMint__ZeroRecipient();
        {
            uint256 bonusCount = _bonusCount();
            if (bonusCount != bonusMinRewards.length) {
                revert BatchMint__ArrayLengthMismatch(bonusCount, bonusMinRewards.length);
            }
        }

        // --- 2. Resolve the owner-pinned minter/dispatcher and DERIVE the payment asset. ---
        BatchCtx memory c;
        (c.nftMinter, c.dispatcherIndex, c.paymentToken) = _resolvePaymentPath();

        // --- 3. Flush every whitelisted stream, the discount token included. ---
        //
        // ORDER IS LOAD-BEARING (c): the flush comes BEFORE the pot read at step 5, so the pot
        // includes the accrued USDC stream and the batch size reflects it. It also comes before
        // the bonus snapshot, so accrued bonus streams are counted for this batch.
        _flushStreams();

        // --- 4. Bonus snapshot + per-token floors. ---
        //
        // ORDER IS LOAD-BEARING (a) — inherited: the snapshot stays BEFORE the pull at step 8,
        // so the caller's own payment is never visible to the payout. It is also taken BEFORE
        // the mint loops, so this batch's own per-mint donations stay behind for the next
        // batch ("donate forward", §4.2). Do not move this read to the payout site.
        uint256[] memory snapshot = _snapshotBonus(bonusMinRewards);

        // --- 5 + 6. Pot read, config checks, maths, and the caller's guards. ---
        //
        // ORDER IS LOAD-BEARING (d): the pot read, the maths and the `expectedTotal` and
        // `maxPayment` checks ALL happen before any value moves, so a front-run caller (pot
        // consumed, or grown past a step) reverts cleanly having paid nothing.
        _prepareBatch(c);
        if (c.total != expectedTotal) revert BatchMint__TotalMismatch(c.total, expectedTotal);
        if (c.paidCost > maxPayment) revert BatchMint__MaxPaymentExceeded(c.paidCost, maxPayment);

        // --- 7. Reserve (effects before interactions). ---
        //
        // ORDER IS LOAD-BEARING (e): the reserve is written BEFORE the external mint calls, so
        // a re-entrant or later read sees this pot already consumed. `nonReentrant` also
        // covers this. The USDC does not move; it is now reserved on this contract.
        pendingBuyUSDC += c.potUSDC;
        pendingStakerPhUSD += c.owed;

        // --- 8 – 12. Pull, paid loop, revoke, free loop, refund. ---
        if (c.paid != 0) {
            uint256 budget = _pullPayment(c.paymentToken, maxPayment);
            // ORDER IS LOAD-BEARING (f): the paid mints come BEFORE the free mints, so
            // `mintFor` cannot affect the paid prices. `mintFor` does not move the price
            // anyway; the order is fixed for auditability.
            budget = _paidMintLoop(c, recipient, budget);
            _freeMintLoop(c, recipient);
            // ORDER IS LOAD-BEARING (b) — inherited: the refund comes BEFORE the bonus
            // payout, so neither transfer can be funded out of the other.
            totalPaid = _refund(c.paymentToken, budget, maxPayment);
        } else {
            // `discountPercent == 100`: every NFT is free. Nothing is pulled or refunded.
            _freeMintLoop(c, recipient);
        }

        // --- 13. Emit. ---
        emit BatchMinted(recipient, c.free, c.paid, c.paidCost, c.potUSDC, c.owed);

        // --- 14. Bonus payout of the step-4 snapshot (NOT re-read). ---
        _payBonus(recipient, snapshot);

        free = c.free;
        paid = c.paid;
    }

    // =====================================================================
    // buyAndBurn
    // =====================================================================

    /// @notice Authorised, deferred buy: spend `usdcIn` of the reserve on phUSD along
    ///         USDC →(PSM sellGem)→ USDS →(sUSDS deposit)→ sUSDS →(UniV2)→ phUSD, then pay the
    ///         owed balance to NFTStaker first and split the extra by `burnPercent`.
    /// @dev    Not pause-gated; the kill switch is `incrementAuthVersion` (as `UniPoolerV2.pool`).
    ///         Partial buys are allowed so a large reserve can be chunked to limit price impact.
    ///         `minPhusdOut` is the end-to-end floor (PSM fee included); the router enforces it.
    /// @return phusdOut phUSD bought, measured as a balance delta around the swap.
    /// @return toStaker phUSD sent to NFTStaker (owed + unburned extra).
    /// @return burned   phUSD burned. `phusdOut == toStaker + burned` exactly.
    function buyAndBurn(uint256 usdcIn, uint256 minPhusdOut, uint256 deadline)
        external
        nonReentrant
        onlyAuthorizedBuyer
        returns (uint256 phusdOut, uint256 toStaker, uint256 burned)
    {
        // --- 1. Guards. ---
        if (block.timestamp > deadline) revert BatchMint__Expired(deadline);
        uint256 reserve = pendingBuyUSDC;
        if (usdcIn == 0 || usdcIn > reserve) revert BatchMint__BuyExceedsReserve(usdcIn, reserve);
        if (minPhusdOut == 0) revert BatchMint__ZeroMinOut();
        _checkBuyConfig();

        // --- 2. Effects. ---
        pendingBuyUSDC = reserve - usdcIn;

        // --- 3 + 4. Route, with the phUSD output measured as a narrow delta. ---
        phusdOut = _buyPhusd(usdcIn, minPhusdOut, deadline);

        // --- 5 – 7. Split, pay, burn, emit. ---
        (toStaker, burned) = _splitAndPay(usdcIn, phusdOut);
    }

    // =====================================================================
    // Internals — batch
    // =====================================================================

    /// @dev Shared resolution of the owner-pinned minter/dispatcher and the DERIVED payment
    ///      token (`batchMint` step 2).
    function _resolvePaymentPath()
        private
        view
        returns (ITokenMinterV2 nftMinter, uint256 _dispatcherIndex, IERC20 paymentToken)
    {
        nftMinter = tokenMinter;
        if (address(nftMinter) == address(0)) {
            revert BatchMint__MinterNotConfigured();
        }

        _dispatcherIndex = dispatcherIndex;
        if (_dispatcherIndex == 0) revert BatchMint__DispatcherNotConfigured();

        (address dispatcher,,,) = INFTMinterV2(address(nftMinter)).configs(_dispatcherIndex);
        if (dispatcher == address(0)) revert BatchMint__DispatcherNotConfigured();
        paymentToken = IERC20(ITokenDispatcherV2(dispatcher).primeToken());
    }

    /// @dev Step 3: settle each whitelisted token's linearly-metered stream into this contract.
    ///      Unregistered tokens are a cheap no-op on the streamer side.
    function _flushStreams() private {
        address _nudgeStreamer = nudgeStreamer;
        if (_nudgeStreamer != address(0)) {
            uint256 nudgeCount = _nudgeTokens.length;
            for (uint256 i; i < nudgeCount; ++i) {
                INudgeStreamer(_nudgeStreamer).pullPendingStream(_nudgeTokens[i]);
            }
        }
    }

    /// @dev Number of bonus tokens: the whitelist minus the discount token (which, when set,
    ///      is always whitelisted — `setDiscountToken` requires it and unwhitelisting it reverts).
    function _bonusCount() private view returns (uint256) {
        uint256 n = _nudgeTokens.length;
        address dt = address(discountToken);
        return (dt != address(0) && _nudgeTokenIndex[dt] != 0) ? n - 1 : n;
    }

    /// @dev Step 4: the PRE-PULL, PRE-LOOP snapshot of every bonus balance, iterating the
    ///      whitelist in storage order with the discount token skipped (`bonusMinRewards[j]`
    ///      binds to `getBonusTokens()[j]`), plus the per-token floor check. There is no
    ///      `nudgeSize` threshold: every successful batch pays every bonus balance.
    ///
    ///      **These balances are read BEFORE the mint loops and paid out after them (§4.2).**
    ///      Moving this read next to the transfer looks cleaner and silently hands the batcher
    ///      the donations their own mints just produced.
    function _snapshotBonus(uint256[] calldata bonusMinRewards) private view returns (uint256[] memory snapshot) {
        address dt = address(discountToken);
        uint256 n = _nudgeTokens.length;
        snapshot = new uint256[](bonusMinRewards.length);
        uint256 j;
        for (uint256 i; i < n; ++i) {
            address t = _nudgeTokens[i];
            if (t == dt) continue;
            uint256 available = IERC20(t).balanceOf(address(this));
            uint256 minReward = bonusMinRewards[j];
            if (available < minReward) revert BatchMint__RewardBelowMinimum(t, minReward, available);
            snapshot[j++] = available;
        }
    }

    /// @dev Step 14: pay the step-4 snapshot, walking the same filtered order. A zero entry is
    ///      a silent no-op. `NudgePaid` is emitted once per token actually transferred.
    function _payBonus(address recipient, uint256[] memory snapshot) private {
        address dt = address(discountToken);
        uint256 n = _nudgeTokens.length;
        uint256 j;
        for (uint256 i; i < n; ++i) {
            address t = _nudgeTokens[i];
            if (t == dt) continue;
            uint256 amount = snapshot[j++];
            if (amount == 0) continue;
            IERC20(t).safeTransfer(recipient, amount);
            emit NudgePaid(recipient, t, amount);
        }
    }

    /// @dev Steps 5 + 6: config checks, the pot read NET OF THE RESERVE, and the shared maths.
    function _prepareBatch(BatchCtx memory c) private view {
        IERC20 dt = discountToken;
        ISkyPSM _psm = psm;
        IMintDebtRatio hook = mintDebtHook;
        if (address(dt) == address(0) || address(_psm) == address(0) || address(hook) == address(0)) {
            revert BatchMint__DiscountNotConfigured();
        }
        address gem = _psm.gem();
        if (gem != address(dt)) revert BatchMint__DiscountTokenNotGem(address(dt), gem);

        // The reserved USDC is NOT pot: two balances share one holding.
        c.potUSDC = dt.balanceOf(address(this)) - pendingBuyUSDC;
        (, c.p0, c.growthBps,) = INFTMinterV2(address(c.nftMinter)).configs(c.dispatcherIndex);
        _computeBatch(c, _psm.to18ConversionFactor(), _psm.tin(), discountPercent, hook.ratio());
        if (c.free == 0) revert BatchMint__NoDiscountAvailable();
    }

    /// @dev Gather `previewBatch`'s inputs WITHOUT reverting on misconfiguration. `conv == 0`
    ///      signals "no discount token or PSM": nothing is computable. `batchable` is false when
    ///      `batchMint` would revert on configuration (so the batch fields must read zero).
    function _previewInputs()
        private
        view
        returns (BatchCtx memory c, uint256 conv, uint256 tin, uint256 ratio, bool batchable)
    {
        IERC20 dt = discountToken;
        ISkyPSM _psm = psm;
        if (address(dt) == address(0) || address(_psm) == address(0)) return (c, 0, 0, 0, false);

        c.potUSDC = dt.balanceOf(address(this)) - pendingBuyUSDC;
        address streamer = nudgeStreamer;
        if (streamer != address(0)) {
            c.potUSDC += INudgeStreamer(streamer).pendingStream(address(this), address(dt));
        }
        conv = _psm.to18ConversionFactor();
        tin = _psm.tin();

        batchable = _psm.gem() == address(dt) && address(mintDebtHook) != address(0);
        ITokenMinterV2 nftMinter = tokenMinter;
        uint256 idx = dispatcherIndex;
        if (address(nftMinter) != address(0) && idx != 0) {
            address dispatcher;
            (dispatcher, c.p0, c.growthBps,) = INFTMinterV2(address(nftMinter)).configs(idx);
            if (dispatcher == address(0)) batchable = false;
        } else {
            batchable = false;
        }
        if (batchable) ratio = mintDebtHook.ratio();
    }

    /// @dev The shared maths (`batchMint` and `previewBatch`). All rounding favours the protocol:
    ///      `potUSD` mirrors the PSM's own floor, `free` floors, `total` rounds UP (so the
    ///      effective discount never exceeds `discountPercent`; the spec's literal floor agrees
    ///      for every worked example), `owed` floors.
    function _computeBatch(BatchCtx memory c, uint256 conv, uint256 tin, uint256 percent, uint256 ratio) private pure {
        c.potUSD = _netUSD(c.potUSDC, conv, tin);
        if (percent == 0 || c.p0 == 0) return; // free = total = paid = paidCost = owed = 0
        uint256 free = c.potUSD / c.p0;
        if (free == 0) return;
        c.free = free;
        c.total = Math.ceilDiv(free * 100, percent);
        c.paid = c.total - free;
        // Sum the `paid` rising prices term-for-term with NFTMinterV2's ramp. Free NFTs never
        // move the price, so the paid/free interleaving does not change the cost.
        uint256 price = c.p0;
        uint256 g = c.growthBps;
        uint256 cost;
        for (uint256 i; i < c.paid; ++i) {
            cost += price;
            price = price + (price * g) / 10000;
        }
        c.paidCost = cost;
        c.owed = (free * c.p0 * ratio) / 100;
    }

    /// @dev USDC (gem decimals) → USD (18dp) exactly as `DssLitePsm._sellGem` delivers it.
    ///      A `tin` at or above 100% delivers nothing.
    function _netUSD(uint256 potUSDC, uint256 conv, uint256 tin) private pure returns (uint256) {
        if (tin >= WAD) return 0;
        uint256 gross = potUSDC * conv;
        return gross - (gross * tin) / WAD;
    }

    /// @dev Smallest additional USDC that lifts `potUSD / p0` by one step, with `tin` inverted
    ///      and rounded up, then corrected downward to the exact minimum (the PSM's fee floor
    ///      can make the closed-form inverse overshoot by one unit).
    function _nextStepUSDC(uint256 potUSDC, uint256 potUSD, uint256 p0, uint256 conv, uint256 tin)
        private
        pure
        returns (uint256)
    {
        if (p0 == 0 || conv == 0 || tin >= WAD) return 0;
        uint256 target = (potUSD / p0 + 1) * p0;
        uint256 gross = Math.mulDiv(target, WAD, WAD - tin, Math.Rounding.Ceil);
        uint256 x = Math.ceilDiv(gross, conv);
        while (x > potUSDC + 1 && _netUSD(x - 1, conv, tin) >= target) {
            --x;
        }
        return x - potUSDC;
    }

    /// @dev Step 8: pull `maxPayment` and MEASURE what arrived (verbatim from the multi-token
    ///      minter's step 5).
    ///
    ///      `budget` is the caller's credit and the ONLY thing the refund may draw on:
    ///
    ///          budget = min(balanceAfterPull - balanceBeforePull, maxPayment)
    ///
    ///      This is NOT the forbidden `balanceOf` derivation: a DIFFERENCE of two readings
    ///      immediately either side of ONE transfer sees only that transfer — `P` cancels and
    ///      `D` has not happened yet. Widen the bracket to span the mint loop and it swallows
    ///      `D`.
    ///
    ///      The `min` carries TWO INDEPENDENT OBLIGATIONS. Both must survive any future edit:
    ///        1. DONATION ROUTING. A transfer landing inside the pull window must not be
    ///           credited to `msg.sender` and refunded to them. Pinned by
    ///           `test_DonationDuringPullCannotInflateBudget`.
    ///        2. UNDERFLOW SAFETY IN THE REFUND. `totalPaid = maxPayment - refund` is BARE; it
    ///           is safe SOLELY because `refund <= budget <= maxPayment`, and the right-hand
    ///           inequality is established here and nowhere else.
    ///      The LOWER side (measuring at all) charges a fee-on-transfer shortfall to the caller
    ///      instead of the pot. Pinned by `test_FeeOnTransferPaymentToken_budgetIsMeasured`.
    function _pullPayment(IERC20 paymentToken, uint256 maxPayment) private returns (uint256 budget) {
        uint256 heldBeforePull = paymentToken.balanceOf(address(this));
        paymentToken.safeTransferFrom(msg.sender, address(this), maxPayment);
        uint256 credited = paymentToken.balanceOf(address(this)) - heldBeforePull;
        budget = credited < maxPayment ? credited : maxPayment;
    }

    /// @dev Steps 9 + 10: the paid mint loop, allowance held at the EXACT next mint price,
    ///      then the revoke.
    ///
    ///      DO NOT RE-DERIVE `budget` FROM `balanceOf`, here or at the refund. `budget` is THIS
    ///      CALLER'S money; it is decremented by the authoritative price the minter is about to
    ///      charge, so it never observes the pot or this batch's own donations.
    ///
    ///      The price is RE-READ every iteration: `NFTMinterV2._executeMint` charges exactly
    ///      `config.price` and THEN ramps it, so a pre-mint read returns exactly this mint's
    ///      charge. Every `forceApprove` sets an ABSOLUTE target, never a delta.
    function _paidMintLoop(BatchCtx memory c, address recipient, uint256 budget) private returns (uint256) {
        ITokenMinterV2 nftMinter = c.nftMinter;
        uint256 idx = c.dispatcherIndex;
        IERC20 paymentToken = c.paymentToken;
        uint256 paid = c.paid;
        for (uint256 i; i < paid; ++i) {
            (, uint256 price,,) = INFTMinterV2(address(nftMinter)).configs(idx);
            if (price > budget) revert BatchMint__PaymentBudgetExhausted(i, price, budget);
            budget -= price;
            paymentToken.forceApprove(address(nftMinter), price);
            nftMinter.mint(idx, recipient);
        }
        // Revoke. Absolute and idempotent.
        paymentToken.forceApprove(address(nftMinter), 0);
        return budget;
    }

    /// @dev Step 11: `free` authorised free mints. No payment, no dispatch, no price growth.
    function _freeMintLoop(BatchCtx memory c, address recipient) private {
        INFTMinterV2 nftMinter = INFTMinterV2(address(c.nftMinter));
        uint256 idx = c.dispatcherIndex;
        uint256 free = c.free;
        for (uint256 i; i < free; ++i) {
            nftMinter.mintFor(idx, recipient);
        }
    }

    /// @dev Step 12: refund the caller's UNSPENT BUDGET (not a balance sweep). `refund <= budget
    ///      <= maxPayment` by construction. The `available` cap is belt-and-braces (non-binding on
    ///      every constructible path; it only degrades the refund against an erosion of our
    ///      payment-token holdings, e.g. a negative rebase). Sub-`DUST_THRESHOLD` surplus stays.
    function _refund(IERC20 paymentToken, uint256 budget, uint256 maxPayment) private returns (uint256 totalPaid) {
        uint256 available = paymentToken.balanceOf(address(this));
        uint256 refund = budget > available ? available : budget;
        if (refund / DUST_THRESHOLD != 0) {
            paymentToken.safeTransfer(msg.sender, refund);
            totalPaid = maxPayment - refund;
        } else {
            totalPaid = maxPayment;
        }
    }

    // =====================================================================
    // Internals — buy
    // =====================================================================

    function _pairMatches(address _pair, address _sUSDS, address _phUSD) private view returns (bool) {
        if (_pair == address(0) || _sUSDS == address(0) || _phUSD == address(0)) return false;
        address t0 = IUniswapV2Pair(_pair).token0();
        address t1 = IUniswapV2Pair(_pair).token1();
        return (t0 == _sUSDS && t1 == _phUSD) || (t0 == _phUSD && t1 == _sUSDS);
    }

    /// @dev `buyAndBurn` step 1, configuration half.
    function _checkBuyConfig() private view {
        ISkyPSM _psm = psm;
        IERC4626 _sUSDS = sUSDS;
        if (
            address(_psm) == address(0) || address(_sUSDS) == address(0) || router == address(0) || phUSD == address(0)
                || nftStaker == address(0)
        ) revert BatchMint__BuyNotConfigured();
        address gem = _psm.gem();
        if (gem != address(discountToken)) revert BatchMint__DiscountTokenNotGem(address(discountToken), gem);
        address asset = _sUSDS.asset();
        address usds = _psm.usds();
        if (asset != usds) revert BatchMint__SUSDSAssetMismatch(asset, usds);
        // Re-validated here because `setSUSDS` can leave the stored pair stale.
        if (!_pairMatches(pair, address(_sUSDS), phUSD)) revert BatchMint__PairMismatch();
    }

    /// @dev `buyAndBurn` steps 3 + 4, modelled on `PromotionUniV2_Eth._legA` /
    ///      `_swapSusdsForPhusd`: every allowance exact and reset to 0. phUSD out is the
    ///      balance DELTA bracketed around the swap alone — phUSD is also a bonus token held
    ///      here, so an absolute `balanceOf` would sweep the bonus pot.
    function _buyPhusd(uint256 usdcIn, uint256 minPhusdOut, uint256 deadline) private returns (uint256 phusdOut) {
        uint256 shares = _usdcToSUSDS(usdcIn);
        phusdOut = _swapSusdsForPhusd(shares, minPhusdOut, deadline);
    }

    /// @dev USDC →(PSM sellGem)→ USDS →(ERC4626 deposit)→ sUSDS. The PSM has no slippage; its
    ///      `tin` fee is covered by the caller's end-to-end `minPhusdOut` floor.
    function _usdcToSUSDS(uint256 usdcIn) private returns (uint256 shares) {
        ISkyPSM _psm = psm;
        IERC20 usdc = discountToken;
        usdc.forceApprove(address(_psm), usdcIn);
        uint256 usdsOut = _psm.sellGem(address(this), usdcIn);
        usdc.forceApprove(address(_psm), 0);

        IERC4626 _sUSDS = sUSDS;
        IERC20 usds = IERC20(_psm.usds());
        usds.forceApprove(address(_sUSDS), usdsOut);
        shares = _sUSDS.deposit(usdsOut, address(this));
        usds.forceApprove(address(_sUSDS), 0);
    }

    /// @dev Router02 `swapExactTokensForTokens` of `sharesIn` sUSDS along `[sUSDS, phUSD]`. The
    ///      router enforces `minPhusdOut` (`INSUFFICIENT_OUTPUT_AMOUNT`) and `deadline`.
    function _swapSusdsForPhusd(uint256 sharesIn, uint256 minPhusdOut, uint256 deadline)
        private
        returns (uint256 phusdOut)
    {
        address _router = router;
        IERC20 s = IERC20(address(sUSDS));
        IERC20 ph = IERC20(phUSD);
        address[] memory path = new address[](2);
        path[0] = address(s);
        path[1] = address(ph);
        s.forceApprove(_router, sharesIn);
        // Narrow bracket: this swap and nothing else.
        uint256 before = ph.balanceOf(address(this));
        IUniswapV2Router02(_router).swapExactTokensForTokens(sharesIn, minPhusdOut, path, address(this), deadline);
        phusdOut = ph.balanceOf(address(this)) - before;
        s.forceApprove(_router, 0);
    }

    /// @dev `buyAndBurn` steps 5 – 7. Owed first; `burned` floors so burn dust goes to
    ///      NFTStaker. phUSD's burn is allowance-based (transferFrom-style), so the contract
    ///      approves ITSELF for exactly `burned` per call — not infinite at construction as
    ///      PromotionUniV2_Eth does, because `phUSD` is settable here.
    function _splitAndPay(uint256 usdcIn, uint256 phusdOut) private returns (uint256 toStaker, uint256 burned) {
        uint256 owedPending = pendingStakerPhUSD;
        uint256 toStakerOwed = phusdOut < owedPending ? phusdOut : owedPending;
        uint256 owedRemaining = owedPending - toStakerOwed;
        pendingStakerPhUSD = owedRemaining;

        uint256 extra = phusdOut - toStakerOwed;
        burned = (extra * burnPercent) / 100;
        uint256 toStakerExtra = extra - burned;
        toStaker = toStakerOwed + toStakerExtra;

        IERC20 ph = IERC20(phUSD);
        if (toStaker != 0) ph.safeTransfer(nftStaker, toStaker);
        if (burned != 0) {
            ph.forceApprove(address(this), burned);
            IPhusdBurnable(address(ph)).burn(address(this), burned);
            ph.forceApprove(address(this), 0);
        }

        emit BoughtAndBurned(msg.sender, usdcIn, phusdOut, toStakerOwed, toStakerExtra, burned, owedRemaining);
    }
}
