// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Faithful-maths Uniswap V2 pair for unit tests: constant-product reserves, 0.30% fee,
///      MINIMUM_LIQUIDITY lock on first mint, `min(a*ts/r0, b*ts/r1)` LP mint thereafter. It
///      omits flash-swap callbacks, TWAP accumulators and the protocol-fee mint (`feeTo` off),
///      none of which the pooler touches. Tokens are sorted exactly as the real factory does.
contract MockUniV2AmmPair is ERC20 {
    using SafeERC20 for IERC20;

    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    address public immutable token0;
    address public immutable token1;

    uint112 private reserve0;
    uint112 private reserve1;

    constructor(address tokenA, address tokenB) ERC20("Uniswap V2", "UNI-V2") {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function getReserves() public view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function _update() private {
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        require(b0 <= type(uint112).max && b1 <= type(uint112).max, "UniswapV2: OVERFLOW");
        // forge-lint: disable-next-line(unsafe-typecast)
        reserve0 = uint112(b0);
        // forge-lint: disable-next-line(unsafe-typecast)
        reserve1 = uint112(b1);
    }

    function mint(address to) external returns (uint256 liquidity) {
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = b0 - reserve0;
        uint256 amount1 = b1 - reserve1;
        uint256 ts = totalSupply();
        if (ts == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0xdead), MINIMUM_LIQUIDITY);
        } else {
            liquidity = Math.min((amount0 * ts) / reserve0, (amount1 * ts) / reserve1);
        }
        require(liquidity > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);
        _update();
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        require(amount0Out > 0 || amount1Out > 0, "UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT");
        require(amount0Out < reserve0 && amount1Out < reserve1, "UniswapV2: INSUFFICIENT_LIQUIDITY");
        if (amount0Out > 0) IERC20(token0).safeTransfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).safeTransfer(to, amount1Out);
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 in0 = b0 > reserve0 - amount0Out ? b0 - (reserve0 - amount0Out) : 0;
        uint256 in1 = b1 > reserve1 - amount1Out ? b1 - (reserve1 - amount1Out) : 0;
        require(in0 > 0 || in1 > 0, "UniswapV2: INSUFFICIENT_INPUT_AMOUNT");
        uint256 adj0 = b0 * 1000 - in0 * 3;
        uint256 adj1 = b1 * 1000 - in1 * 3;
        require(adj0 * adj1 >= uint256(reserve0) * uint256(reserve1) * 1000 ** 2, "UniswapV2: K");
        _update();
    }

    /// @dev Uniswap V2 `skim`: transfers each token's `balance - reserve` to `to`.
    function skim(address to) external {
        IERC20(token0).safeTransfer(to, IERC20(token0).balanceOf(address(this)) - reserve0);
        IERC20(token1).safeTransfer(to, IERC20(token1).balanceOf(address(this)) - reserve1);
    }

    /// @dev Uniswap V2 `sync`: sets the reserves to the current balances.
    function sync() external {
        _update();
    }
}

/// @dev Minimal Uniswap V2 factory: the `getPair` registry (both token orders), plus
///      `createPair` (deploys a `MockUniV2AmmPair`) and an unguarded `setPair` so tests can
///      register an arbitrary contract as the canonical pair.
contract MockUniV2AmmFactory {
    mapping(address => mapping(address => address)) public getPair;

    function createPair(address tokenA, address tokenB) external returns (address p) {
        require(getPair[tokenA][tokenB] == address(0), "UniswapV2: PAIR_EXISTS");
        p = address(new MockUniV2AmmPair(tokenA, tokenB));
        setPair(tokenA, tokenB, p);
    }

    function setPair(address tokenA, address tokenB, address p) public {
        getPair[tokenA][tokenB] = p;
        getPair[tokenB][tokenA] = p;
    }
}

/// @dev Faithful-maths Uniswap V2 Router02 subset for a single known pair: the real
///      `getAmountOut`, `quote` and `_addLiquidity` optimal-amount logic. Like the real router,
///      `addLiquidity` pulls only the optimal amounts — the surplus side is never pulled, so it
///      stays with the caller (this is the "refund" the closed-form zap is designed to avoid).
contract MockUniV2AmmRouter {
    using SafeERC20 for IERC20;

    MockUniV2AmmPair public immutable pair;
    /// @dev The router's factory. Deployed here with `pair` registered as the canonical pair for
    ///      its two tokens, mirroring a pair created through the real router's factory.
    MockUniV2AmmFactory public immutable factory;

    bool public swapCalled;
    bool public addLiquidityCalled;

    constructor(MockUniV2AmmPair pair_) {
        pair = pair_;
        factory = new MockUniV2AmmFactory();
        factory.setPair(pair_.token0(), pair_.token1(), address(pair_));
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) public pure returns (uint256) {
        require(amountA > 0, "UniswapV2Library: INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        return (amountA * reserveB) / reserveA;
    }

    function _reservesFor(address tokenA) internal view returns (uint256 rA, uint256 rB) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (rA, rB) = tokenA == pair.token0() ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "UniswapV2Router: EXPIRED");
        require(path.length == 2, "MockUniV2AmmRouter: single hop only");
        swapCalled = true;
        (uint256 rIn, uint256 rOut) = _reservesFor(path[0]);
        uint256 amountOut = getAmountOut(amountIn, rIn, rOut);
        require(amountOut >= amountOutMin, "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT");
        IERC20(path[0]).safeTransferFrom(msg.sender, address(pair), amountIn);
        (uint256 out0, uint256 out1) = path[0] == pair.token0() ? (uint256(0), amountOut) : (amountOut, uint256(0));
        pair.swap(out0, out1, to, "");
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        require(deadline >= block.timestamp, "UniswapV2Router: EXPIRED");
        require(
            (tokenA == pair.token0() && tokenB == pair.token1())
                || (tokenA == pair.token1() && tokenB == pair.token0()),
            "MockUniV2AmmRouter: unknown pair"
        );
        addLiquidityCalled = true;
        (amountA, amountB) = _optimal(tokenA, amountADesired, amountBDesired, amountAMin, amountBMin);
        IERC20(tokenA).safeTransferFrom(msg.sender, address(pair), amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, address(pair), amountB);
        liquidity = pair.mint(to);
    }

    function _optimal(
        address tokenA,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal view returns (uint256 amountA, uint256 amountB) {
        (uint256 rA, uint256 rB) = _reservesFor(tokenA);
        if (rA == 0 && rB == 0) return (amountADesired, amountBDesired);
        uint256 amountBOptimal = quote(amountADesired, rA, rB);
        if (amountBOptimal <= amountBDesired) {
            require(amountBOptimal >= amountBMin, "UniswapV2Router: INSUFFICIENT_B_AMOUNT");
            return (amountADesired, amountBOptimal);
        }
        uint256 amountAOptimal = quote(amountBDesired, rB, rA);
        assert(amountAOptimal <= amountADesired);
        require(amountAOptimal >= amountAMin, "UniswapV2Router: INSUFFICIENT_A_AMOUNT");
        return (amountAOptimal, amountBDesired);
    }
}
