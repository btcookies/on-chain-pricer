// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.10;


import {IERC20} from "@oz/token/ERC20/IERC20.sol";
import {ERC20} from "@oz/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@oz/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@oz/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@oz/utils/Address.sol";

import "../interfaces/uniswap/IUniswapRouterV2.sol";
import "../interfaces/uniswap/IV3Pool.sol";
import "../interfaces/uniswap/IV2Pool.sol";
import "../interfaces/uniswap/IV3Quoter.sol";
import "../interfaces/curve/ICurveRouter.sol";
import "../interfaces/curve/ICurvePool.sol";
import "../interfaces/uniswap/IV3Simulator.sol";

import "@chainlink/src/v0.8/interfaces/FeedRegistryInterface.sol";
import "@chainlink/src/v0.8/interfaces/AggregatorV2V3Interface.sol";
import "@chainlink/src/v0.8/Denominations.sol";

enum SwapType { 
    CURVE, //0
    SWAPR, //1
    SUSHI, //2
    UNIV3, //3
    UNIV3WITHWETH, //4
    SWAPRWITHWETH, //5
    SUSHIWITHWETH, //6
    PRICEFEED //7
}

/// @title OnChainPricing
/// @author Alex the Entreprenerd for BadgerDAO
/// @author Camotelli @rayeaster
/// @author Cookies
/// @dev Arbitrum Version of Price Quoter, hardcoded for more efficiency
/// @notice To spin a variant, just change the constants and use the Component Functions at the end of the file
/// @notice Instead of upgrading in the future, just point to a new implementation
/// @notice TOC
/// UNIV2
/// UNIV3
/// CURVE
/// UTILS
/// PRICE FEED
///
/// @dev Supported Quote Sources 
/// @dev quote source with ^ mark means it will be included in findOptimalSwap() and findExecutableSwap()
/// @dev quote source with * mark means it will be included in findExecutableSwap() and unsafeFindExecutableSwap()
/// @dev note in some cases when there is no oracle feed, findOptimalSwap() might quote from * mark source as well.
/// -------------------------------------------------
///   SOURCE   |  In->Out   | In->Connector->Out|  
///
///  PRICE FEED|    Y^      |      Y^           | 
///    CURVE   |    Y*      |      -            |
///    SWAPR   |    Y*      |      -            |
///    UNIV3   |    Y*      |      Y*           |
///
///--------------------------------------------------
/// 
/// @dev Notes on Arbitrum implementation
/// * No Chainlink Feed Registry so known oracles hardcoded
/// * No WBTC / BTC feed on Arbitrum so assuming 1:1 ratio (could rekt)
///
contract OnChainPricingArbitrum {
    using Address for address;
    
    // Assumption #1 Most tokens liquid pair is WETH (WETH is tokenized ETH for that chain)
    // e.g on Fantom, WETH would be wFTM
    address public constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    /// == Uni V2 Like Routers || These revert on non-existent pair == //
    // Swapr
    address public constant SWAPR_ROUTER = 0x530476d5583724A89c8841eB6Da76E7Af4C0F17E;
    bytes32 public constant SWAPR_POOL_INITCODE = 0xd306a548755b9295ee49cc729e13ca4a45e00199bbd890fa146da43a50571776;
    address public constant SWAPR_FACTORY = 0x359F20Ad0F42D75a5077e65F30274cABe6f4F01a;
    // Sushi
    address public constant SUSHI_ROUTER = 0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506;
    bytes32 public constant SUSHI_POOL_INITCODE = hex"e18a34eb0e04b04f7a0ac29a6e80748dca96319b42c54d679cb821dca90c6303";
    address public constant SUSHI_FACTORY = 0xc35DADB65012eC5796536bD9864eD8773aBc74C4;

    // Curve / Doesn't revert on failure
    address public constant CURVE_ROUTER = 0xd78FC1F568411Aa87a8D7C4CDe638cde6E597a46; // Curve quote and swaps
		
    // UniV3 impl credit to https://github.com/1inch/spot-price-aggregator/blob/master/contracts/oracles/UniswapV3Oracle.sol
    address public constant UNIV3_QUOTER = 0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6;
    bytes32 public constant UNIV3_POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    address public constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    uint256 public constant CURVE_FEE_SCALE = 100000;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant USDC = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
    address public constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    address public constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address public constant CRV = 0x11cDb42B0EB46D95f990BeDD4695A6e3fA034978;
    address public constant SUSHI = 0xd4d42F0b6DEF4CE0383636770eF773390d85c61A;
    
    /// NOTE: Leave them as immutable
    /// Remove immutable for coverage
    /// @dev helper library to simulate Uniswap V3 swap
    address public immutable uniV3Simulator;
	
    /// @dev https://docs.chain.link/docs/feed-registry/
    /// NOTE: feed registry not on arbitrum, will return 0 for unsupported denominations
    /// TODO: handle not having feed_registry on arb
    address public constant FEED_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address public constant ETH_USD_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address public constant BTC_USD_FEED = 0x6ce185860a4963106506C203335A2910413708e9;
    /// TODO: handle not having wbtc_btc_feed on arb
    // address public constant WBTC_BTC_FEED = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
    address public constant USDC_USD_FEED = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address public constant DAI_USD_FEED = 0xc5C8E77B397E531B8EC06BFb0048328B30E9eCfB;
    address public constant USDT_USD_FEED = 0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7;
    address public constant BTC_ETH_FEED = 0xc5a90A6d7e4Af242dA238FFe279e9f2BA0c64B2e;
    address public constant CRV_USD_FEED = 0xaebDA2c976cfd1eE1977Eac079B4382acb849325;
    address public constant SUSHI_USD_FEED = 0xb2A8BA74cbca38508BA1632761b56C897060147C;
    
    uint256 private constant MAX_BPS = 10_000;
    uint256 private constant SECONDS_PER_HOUR = 3600;
    uint256 private constant SECONDS_PER_DAY = 86400;
    address private constant ADDRESS_ZERO = 0x0000000000000000000000000000000000000000;
    uint256 public feed_tolerance = 500; // 5% Initially

    /// UniV3, replaces an array
    /// @notice We keep above constructor, because this is a gas optimization
    ///     Saves storing fee ids in storage, saving 2.1k+ per call
    uint256 constant univ3_fees_length = 4;
    function univ3_fees(uint256 i) internal pure returns (uint24) {
        if(i == 0){
            return uint24(100);
        } else if (i == 1) {
            return uint24(500);
        } else if (i == 2) {
            return uint24(3000);
        } 
        // else if (i == 3) {
        return uint24(10000);
    }

    constructor(address _uniV3Simulator){
        uniV3Simulator = _uniV3Simulator;
    }

    /// === API FUNCTIONS === ///

    struct Quote {
        SwapType name;
        uint256 amountOut;
        bytes32[] pools; // specific pools involved in the optimal swap path
        uint256[] poolFees; // specific pool fees involved in the optimal swap path, typically in Uniswap V3
    }

    /// @dev holding results from oracle feed (and possibly query from on-chain dex source as well if required)
    struct FeedQuote {
        uint256 finalQuote;        // end-to-end quote from tokenIn to tokenOut for given amountIn
        uint256 tokenInToETH;      // bridging query from tokenIn to WETH using on-chain dex source
        SwapType tokenInToETHType; // indicate the on-chain dex source bridging from tokenIn to WETH		 
    }

    /// @dev holding query parameters for on-chain dex source quote 
    struct FindSwapQuery {
        address tokenIn;   
        address tokenOut;  
        uint256 amountIn; 
        address connector;               // connector token in between: tokenIn -> connector token -> tokenOut, mainly used for Uniswap V3 and Balancer with connector (like WETH)
        uint256 tokenInToETHViaUniV3;    // output ETH amount from tokenIn via Uniswap V3 pool, possibly pre-calculated, see findExecutableSwap()
    }

    /// @dev Given tokenIn, out and amountIn, returns true if a quote will be non-zero
    /// @notice Doesn't guarantee optimality, just non-zero
    function isPairSupported(address tokenIn, address tokenOut, uint256 amountIn) external view returns (bool) {
        // Sorted by "assumed" reverse worst case
        // Go for higher gas cost checks assuming they are offering best precision / good price

        // If Feed, return true
        uint256 feedRes = tryQuoteWithFeed(tokenIn, tokenOut, amountIn);

        if (feedRes > 0) {
            return true;
        }

        // If no pool this is fairly cheap, else highly likely there's a price
        if(checkUniV3PoolsExistence(tokenIn, tokenOut)) {
            return true;
        }

        // Highly likely to have any random token here
        if(getUniPrice(SWAPR_ROUTER, tokenIn, tokenOut, amountIn) > 0) {
            return true;
        }

        // Otherwise it's probably on Sushi
        if(getUniPrice(SUSHI_ROUTER, tokenIn, tokenOut, amountIn) > 0) {
            return true;
        }

        // Curve at this time has great execution prices but low selection
        (, uint256 curveQuote) = getCurvePrice(CURVE_ROUTER, tokenIn, tokenOut, amountIn);
        if (curveQuote > 0){
            return true;
        }

        return false;
    }

    /// @dev External function to provide swap quote which prioritize price feed over on-chain dex source, 
    /// @dev this is virtual so you can override, see Lenient Version
    /// @param tokenIn - The token you want to sell
    /// @param tokenOut - The token you want to buy
    /// @param amountIn - The amount of token you want to sell
    function findOptimalSwap(address tokenIn, address tokenOut, uint256 amountIn) public view virtual returns (Quote memory q) {
        uint256 _qFeed = tryQuoteWithFeed(tokenIn, tokenOut, amountIn);
        if (_qFeed > 0) {
            bytes32[] memory dummyPools;
            uint256[] memory dummyPoolFees;
            q = Quote(SwapType.PRICEFEED, _qFeed, dummyPools, dummyPoolFees);		
        } else {
            FindSwapQuery memory _query = FindSwapQuery(tokenIn, tokenOut, amountIn, WETH, 0);	
            q = _findOptimalSwap(_query);
        } 
    }

    /// @dev View function to provide EXECUTABLE quote from tokenIn to tokenOut with given amountIn
    /// @dev this is virtual so you can override, see Lenient Version
    /// @dev This function will use Price Feeds to confirm the quote from on-chain dex source is within acceptable slippage-range
    /// @dev a valid quote from on-chain dex source will return or just revert if it is NOT "good enough" compared to oracle feed
    function findExecutableSwap(address tokenIn, address tokenOut, uint256 amountIn) public view virtual returns (Quote memory q) {
        FeedQuote memory _qFeed = _feedWithPossibleETHConnector(tokenIn, tokenOut, amountIn);	
		
        FindSwapQuery memory _query = FindSwapQuery(tokenIn, tokenOut, amountIn, WETH, (_qFeed.tokenInToETHType == SwapType.UNIV3 ? _qFeed.tokenInToETH : 0));	
        q = _findOptimalSwap(_query);		
        
        require(q.amountOut >= (_qFeed.finalQuote * (MAX_BPS - feed_tolerance) / MAX_BPS), '!feedSlip');
    }	

    /// @dev View function to provide EXECUTABLE quote from tokenIn to tokenOut with given amountIn
    /// @dev this is virtual so you can override, see Lenient Version
    /// @dev This function will use directly the quote from on-chain dex source no matter how poorly bad (e.g., illiquid pair) it might be
    function unsafeFindExecutableSwap(address tokenIn, address tokenOut, uint256 amountIn) public view virtual returns (Quote memory q) {	
        FindSwapQuery memory _query = FindSwapQuery(tokenIn, tokenOut, amountIn, WETH, 0);	
        q = _findOptimalSwap(_query);
    }

    /// === COMPONENT FUNCTIONS === ///

    /// @dev View function for testing the routing of the strategy
    /// See {findOptimalSwap}
    function _findOptimalSwap(FindSwapQuery memory _query) internal view returns (Quote memory) {
        address tokenIn = _query.tokenIn;
        address tokenOut = _query.tokenOut;
        uint256 amountIn = _query.amountIn;
		
        bool wethInvolved = (tokenIn == WETH || tokenOut == WETH);
        uint256 length = wethInvolved ? 4 : 7; // Add length you need

        Quote[] memory quotes = new Quote[](length);
        bytes32[] memory dummyPools;
        uint256[] memory dummyPoolFees;

        (address curvePool, uint256 curveQuote) = getCurvePrice(CURVE_ROUTER, tokenIn, tokenOut, amountIn);
        if (curveQuote > 0){		   
            (bytes32[] memory curvePools, uint256[] memory curvePoolFees) = _getCurveFees(curvePool);
            quotes[0] = Quote(SwapType.CURVE, curveQuote, curvePools, curvePoolFees);		
        } else {
            quotes[0] = Quote(SwapType.CURVE, curveQuote, dummyPools, dummyPoolFees);         			
        }

        quotes[1] = Quote(SwapType.SWAPR, getUniPrice(SWAPR_ROUTER, tokenIn, tokenOut, amountIn), dummyPools, dummyPoolFees);

        quotes[2] = Quote(SwapType.SUSHI, getUniPrice(SUSHI_ROUTER, tokenIn, tokenOut, amountIn), dummyPools, dummyPoolFees);

        quotes[3] = Quote(SwapType.UNIV3, getUniV3Price(tokenIn, amountIn, tokenOut), dummyPools, dummyPoolFees);

        if (!wethInvolved){
            quotes[4] = Quote(SwapType.UNIV3WITHWETH, (_useSinglePoolInUniV3(tokenIn, tokenOut) > 0 ? 0 : getUniV3PriceWithConnector(_query)), dummyPools, dummyPoolFees);
            quotes[5] = Quote(SwapType.SWAPRWITHWETH, getUniPriceWithConnector(_query, SwapType.SWAPR), dummyPools, dummyPoolFees);
            quotes[6] = Quote(SwapType.SUSHIWITHWETH, getUniPriceWithConnector(_query, SwapType.SUSHI), dummyPools, dummyPoolFees);
        }

        // Because this is a generalized contract, it is best to just loop,
        // Ideally we have a hierarchy for each chain to save some extra gas, but I think it's ok
        // O(n) complexity and each check is like 9 gas
        Quote memory bestQuote = quotes[0];
        unchecked {
            for (uint256 x = 1; x < length; ++x) {
                if (quotes[x].amountOut > bestQuote.amountOut) {
                    bestQuote = quotes[x];
                }
            }
        }


        return bestQuote;
    }    

    /// === Component Functions === /// 
    /// Why bother?
    /// Because each chain is slightly different but most use similar tech / forks
    /// May as well use the separate functoions so each OnChain Pricing on different chains will be slightly different
    /// But ultimately will work in the same way

    /// === UNIV2 === ///

    /// @dev Given the address of the UniV2Like Router, the input amount, and the path, returns the quote for it
    function getUniPrice(address router, address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256) {
        bool _swapr = (router == SWAPR_ROUTER);
        (address _pool, address _token0, ) = pairForUniV2((_swapr ? SWAPR_FACTORY : SUSHI_FACTORY), tokenIn, tokenOut, (_swapr ? SWAPR_POOL_INITCODE : SUSHI_POOL_INITCODE));
        if (!_pool.isContract()) {
            return 0;
        }
		
        bool _zeroForOne = (_token0 == tokenIn);
        (uint256 _t0Balance, uint256 _t1Balance, ) = IUniswapV2Pool(_pool).getReserves();
        // Use dummy magic number as a quick-easy substitute for liquidity (to avoid one SLOAD) since we have pool reserve check in it
        bool _basicCheck = _checkPoolLiquidityAndBalances(1, (_zeroForOne ? _t0Balance : _t1Balance), amountIn);
        return _basicCheck ? getUniV2AmountOutAnalytically(amountIn, (_zeroForOne ? _t0Balance : _t1Balance), (_zeroForOne ? _t1Balance : _t0Balance)) : 0;
    }

    /// @dev Given the address of the input token & amount & the output token & connector token in between (input token ---> connector token ---> output token)
    /// @return the quote for it
    function getUniPriceWithConnector(FindSwapQuery memory _query, SwapType _type) public view returns (uint256) {
        // Skip if there is a mainstrem direct swap or connector pools not exist
        bool _swapr = (_type == SwapType.SWAPR);
        address factory = (_swapr ? SWAPR_FACTORY : SUSHI_FACTORY);
        bytes32 init_code = (_swapr ? SWAPR_POOL_INITCODE : SUSHI_POOL_INITCODE);
        address router = (_swapr ? SWAPR_ROUTER : SUSHI_ROUTER);
        bool _tokenInToConnectorPool = checkUniPoolsExistence(factory, _query.tokenIn, _query.connector, init_code);
        if (!_tokenInToConnectorPool || !checkUniPoolsExistence(factory, _query.connector, _query.tokenOut, init_code)) {
            return 0;
        }
		
        uint256 connectorAmount = getUniPrice(router, _query.tokenIn, _query.connector, _query.amountIn);	
        if (connectorAmount > 0) {	
            return getUniPrice(router, _query.connector, _query.tokenOut, connectorAmount);
        } else {
            return 0;
        }
    }
	
    /// @dev reference https://etherscan.io/address/0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F#code#L122
    function getUniV2AmountOutAnalytically(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256 amountOut) {
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
        return amountOut;
    }
	
    function pairForUniV2(address factory, address tokenA, address tokenB, bytes32 _initCode) public pure returns (address, address, address) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);		
        address pair = getAddressFromBytes32Lsb(
            keccak256(
                abi.encodePacked(
                    hex"ff",
                    factory,
                    keccak256(abi.encodePacked(token0, token1)),
                    _initCode // init code hash
                )
            )
        );
        return (pair, token0, token1);
    }

    /// @dev tell if there exists some Uniswap-esque pool for given token pair
    function checkUniPoolsExistence(address factory, address tokenIn, address tokenOut, bytes32 _initCode) public view returns (bool){	
        (address pair, address token0, address token1) = pairForUniV2(factory, tokenIn, tokenOut, _initCode);
        return pair.isContract();
    }
	
    /// === UNIV3 === ///
	
    /// @dev explore Uniswap V3 pools to check if there is a chance to resolve the swap with in-range liquidity (i.e., without crossing ticks)
    /// @dev check helper UniV3SwapSimulator for more
    /// @return maximum output (with current in-range liquidity & spot price) and according pool fee
    function sortUniV3Pools(address tokenIn, uint256 amountIn, address tokenOut) public view returns (uint256, uint24) {
        uint256 _maxQuote;
        uint24 _maxQuoteFee;
		
        {
            // Heuristic: If we already know high TVL Pools, use those
            uint24 _bestFee = _useSinglePoolInUniV3(tokenIn, tokenOut);
            (address token0, address token1, bool token0Price) = _ifUniV3Token0Price(tokenIn, tokenOut);
			
            {
                if (_bestFee > 0) {
                    (,uint256 _bestOutAmt) = _checkSimulationInUniV3(token0, token1, amountIn, _bestFee, token0Price);
                    return (_bestOutAmt, _bestFee);
                }
            }
			
            (uint256 _maxQAmt, uint24 _maxQFee) = _simLoopAllUniV3Pools(token0, token1, amountIn, token0Price); 
            _maxQuote = _maxQAmt;
            _maxQuoteFee = _maxQFee;
        }
		
        return (_maxQuote, _maxQuoteFee);
    }	
	
    /// @dev loop over all possible Uniswap V3 pools to find a proper quote
    function _simLoopAllUniV3Pools(address token0, address token1, uint256 amountIn, bool token0Price) internal view returns (uint256, uint24) {		
        uint256 _maxQuote;
        uint24 _maxQuoteFee;
        uint256 feeTypes = univ3_fees_length;		
	
        for (uint256 i = 0; i < feeTypes;){
            uint24 _fee = univ3_fees(i);
                
            {			 
                // TODO: Partial rewrite to perform initial comparison against all simulations based on "liquidity in range"
                // If liq is in range, then lowest fee auto-wins
                // Else go down fee range with liq in range 
                // NOTE: A tick is like a ratio, so technically X ticks can offset a fee
                // Meaning we prob don't need full quote in majority of cases, but can compare number of ticks
                // per pool per fee and pre-rank based on that
                (, uint256 _outAmt) = _checkSimulationInUniV3(token0, token1, amountIn, _fee, token0Price);
                if (_outAmt > _maxQuote){
                    _maxQuote = _outAmt;
                    _maxQuoteFee = _fee;
                }
                unchecked { ++i; }	
            }
        }
		
        return (_maxQuote, _maxQuoteFee);		
    }
	
    /// @dev tell if there exists some Uniswap V3 pool for given token pair
    function checkUniV3PoolsExistence(address tokenIn, address tokenOut) public view returns (bool){
        uint256 feeTypes = univ3_fees_length;	
        (address token0, address token1, ) = _ifUniV3Token0Price(tokenIn, tokenOut);
        bool _exist;
        {    
          for (uint256 i = 0; i < feeTypes;){
             address _pool = _getUniV3PoolAddress(token0, token1, univ3_fees(i));
             if (_pool.isContract()) {
                 _exist = true;
                 break;
             }
             unchecked { ++i; }	
          }				 
        }	
        return _exist;		
    }
	
    /// @dev Uniswap V3 pool in-range liquidity check
    /// @return true if cross-ticks full simulation required for the swap otherwise false (in-range liquidity would satisfy the swap)
    function checkUniV3InRangeLiquidity(address token0, address token1, uint256 amountIn, uint24 _fee, bool token0Price, address _pool) public view returns (bool, uint256) {
        {    
             if (!_pool.isContract()) {
                 return (false, 0);
             }
			 
             bool _basicCheck = _checkPoolLiquidityAndBalances(IUniswapV3Pool(_pool).liquidity(), IERC20(token0Price ? token0 : token1).balanceOf(_pool), amountIn);
             if (!_basicCheck) {
                 return (false, 0);
             }
			 
             UniV3SortPoolQuery memory _sortQuery = UniV3SortPoolQuery(_pool, token0, token1, _fee, amountIn, token0Price);
             try IUniswapV3Simulator(uniV3Simulator).checkInRangeLiquidity(_sortQuery) returns (bool _crossTicks, uint256 _inRangeSimOut) {
                 return (_crossTicks, _inRangeSimOut);
             } catch {
                 return (false, 0);			 
             }
        }
    }
	
    /// @dev internal function to avoid stack too deep for 1) check in-range liquidity in Uniswap V3 pool 2) full cross-ticks simulation in Uniswap V3
    function _checkSimulationInUniV3(address token0, address token1, uint256 amountIn, uint24 _fee, bool token0Price) internal view returns (bool, uint256) {
        bool _crossTick;
        uint256 _outAmt;
        
        address _pool = _getUniV3PoolAddress(token0, token1, _fee);		
        {
            // in-range swap check: find out whether the swap within current liquidity would move the price across next tick
            (bool _outOfInRange, uint256 _outputAmount) = checkUniV3InRangeLiquidity(token0, token1, amountIn, _fee, token0Price, _pool);
            _crossTick = _outOfInRange;
            _outAmt = _outputAmount;
        }
        {
            // unfortunately we need to do a full simulation to cross ticks
            if (_crossTick) {
                _outAmt = simulateUniV3Swap(token0, amountIn, token1, _fee, token0Price, _pool);
            }
        }
        return (_crossTick, _outAmt);
    }
	
    /// @dev internal function for a basic sanity check pool existence and balances
    /// @return true if basic check pass otherwise false
    function _checkPoolLiquidityAndBalances(uint256 _liq, uint256 _reserveIn, uint256 amountIn) internal pure returns (bool) {
	    
        {
            // heuristic check0: ensure the pool initiated with valid liquidity in place
            if (_liq == 0) {
                return false;
            }
        }
		
        {
            // TODO: In a later check, we check slot0 liquidity
            // Is there any change that slot0 gives us more information about the liquidity in range,
            // Such that optimistically it would immediately allow us to determine a winning pool?
            // Prob winning pool would be: Lowest Fee, with Liquidity covered within the tick
		
            // heuristic check1: ensure the pool tokenIn reserve makes sense in terms of [amountIn], i.e., the pool is liquid compared to swap amount
            // say if the pool got 100 tokenA, and you tried to swap another 100 tokenA into it for the other token, 
            // by the math of AMM, this will drastically imbalance the pool, so the quote won't be good for sure
            return _reserveIn > amountIn;
        }		
    }
	
    /// @dev simulate Uniswap V3 swap using its tick-based math for given parameters
    /// @dev check helper UniV3SwapSimulator for more
    function simulateUniV3Swap(address token0, uint256 amountIn, address token1, uint24 _fee, bool token0Price, address _pool) public view returns (uint256) {
        try IUniswapV3Simulator(uniV3Simulator).simulateUniV3Swap(_pool, token0, token1, token0Price, _fee, amountIn) returns (uint256 _simOut) {
            return _simOut;
        } catch {
            return 0;
        }
    }	
	
    /// @dev Given the address of the input token & amount & the output token
    /// @return the quote for it
    function getUniV3Price(address tokenIn, uint256 amountIn, address tokenOut) public view returns (uint256) {		
        (uint256 _maxInRangeQuote, ) = sortUniV3Pools(tokenIn, amountIn, tokenOut);		
        return _maxInRangeQuote;
    }
	
    /// @dev Given the address of the input token & amount & the output token & connector token in between (input token ---> connector token ---> output token)
    /// @return the quote for it
    function getUniV3PriceWithConnector(FindSwapQuery memory _query) public view returns (uint256) {
        // Skip if there is a mainstrem direct swap or connector pools not exist
        bool _tokenInToConnectorPool = (_query.connector != WETH) ? checkUniV3PoolsExistence(_query.tokenIn, _query.connector) : (_query.tokenInToETHViaUniV3 > 0 ? true : checkUniV3PoolsExistence(_query.tokenIn, _query.connector));
        if (!_tokenInToConnectorPool || !checkUniV3PoolsExistence(_query.connector, _query.tokenOut)) {
            return 0;
        }
		
        uint256 connectorAmount = (_query.tokenInToETHViaUniV3 > 0 && _query.connector == WETH) ? _query.tokenInToETHViaUniV3 : getUniV3Price(_query.tokenIn, _query.amountIn, _query.connector);	
        if (connectorAmount > 0) {	
            return getUniV3Price(_query.connector, connectorAmount, _query.tokenOut);
        } else {
            return 0;
        }
    }
	
    /// @dev return token0 & token1 and if token0 equals tokenIn
    function _ifUniV3Token0Price(address tokenIn, address tokenOut) internal pure returns (address, address, bool) {
        (address token0, address token1) = tokenIn < tokenOut ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
        return (token0, token1, token0 == tokenIn);
    }
	
    /// @dev query with the address of the token0 & token1 & the fee tier
    /// @return the uniswap v3 pool address
    function _getUniV3PoolAddress(address token0, address token1, uint24 fee) internal pure returns (address) {
        bytes32 addr = keccak256(abi.encodePacked(hex"ff", UNIV3_FACTORY, keccak256(abi.encode(token0, token1, fee)), UNIV3_POOL_INIT_CODE_HASH));
        return address(uint160(uint256(addr)));
    }
	
    /// @dev selected token pair which will try a chosen Uniswap V3 pool ONLY among all possible fees
    /// @dev picked from most traded pool (Volume 7D) in https://info.uniswap.org/#/pools
    /// @dev mainly 5 most-popular tokens WETH-WBTC-USDC-USDT-DAI (Volume 24H) https://info.uniswap.org/#/tokens
    /// @return 0 if all possible fees should be checked otherwise the ONLY pool fee we should go for
    function _useSinglePoolInUniV3(address tokenIn, address tokenOut) internal pure returns(uint24) {
        return 0;
    }

    /// === CURVE === ///

    /// @dev Given the address of the CurveLike Router, the input amount, and the path, returns the quote for it
    function getCurvePrice(address router, address tokenIn, address tokenOut, uint256 amountIn) public view returns (address, uint256) {
        try ICurveRouter(router).get_best_rate(tokenIn, tokenOut, amountIn) returns (address pool, uint256 curveQuote) {	
            return (pool, curveQuote);	
        } catch {	
            return (address(0), 0);	
        }
    }
	
    /// @return assembled curve pools and fees in required Quote struct for given pool
    // TODO: Decide if we need fees, as it costs more gas to compute
    function _getCurveFees(address _pool) internal view returns (bytes32[] memory, uint256[] memory) {	
        bytes32[] memory curvePools = new bytes32[](1);
        curvePools[0] = convertToBytes32(_pool);
        uint256[] memory curvePoolFees = new uint256[](1);
        curvePoolFees[0] = ICurvePool(_pool).fee() * CURVE_FEE_SCALE / 1e10; // https://curve.readthedocs.io/factory-pools.html?highlight=fee#StableSwap.fee
        return (curvePools, curvePoolFees);
    }

    // === ORACLE VIEW FUNCTIONS === //
	
    /// @dev try to convert from tokenIn to tokenOut using price feeds
    /// @dev note possible usage of on-chain dex sourcing if tokenIn or tokenOut got NO feed
    /// @return quote from oracle feed in output token decimal or 0 if there is no valid feed exist for both tokenIn and tokenOut
    function tryQuoteWithFeed(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256){	
        FeedQuote memory _feedQuote = _feedWithPossibleETHConnector(tokenIn, tokenOut, amountIn);	
        return _feedQuote.finalQuote;		
    }
	
    /// @dev try to convert from tokenIn to tokenOut using price feeds directly, 
    /// @dev possibly with ETH as connector in between for query with on-chain dex source
    /// @return {FeedQuote} or 0 if there is no feed exist for both tokenIn and tokenOut
    function _feedWithPossibleETHConnector(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (FeedQuote memory){
	
        // try short-circuit to ETH feeds if possible
        if (tokenIn == WETH) {
            uint256 pOutETH = getPriceInETH(tokenOut);
            if (pOutETH > 0) {
                return FeedQuote((amountIn * 1e18 / pOutETH) * _getDecimalsMultiplier(tokenOut) / 1e18, 0, SwapType.PRICEFEED);			
            }
        } else if (tokenOut == WETH) {
            uint256 pInETH = getPriceInETH(tokenIn);
            if (pInETH > 0) {
                return FeedQuote((amountIn * pInETH / 1e18) * 1e18 / _getDecimalsMultiplier(tokenIn), 0, SwapType.PRICEFEED);			
            }	
        }
        
        // fall-back to USD feeds as last resort
        (uint256 pInUSD, uint256 _ethUSDIn)  = _fetchUSDAndPiggybackETH(tokenIn, 0);
        (uint256 pOutUSD, uint256 _ethUSDOut) = _fetchUSDAndPiggybackETH(tokenOut, _ethUSDIn);
		
        if (pInUSD == 0 && pOutUSD == 0) {
            // CASE WHEN both tokenIn and tokenOut got NO feed
            return FeedQuote(0, 0, SwapType.PRICEFEED);		
        } else if (pInUSD == 0) {
            // CASE WHEN only tokenOut got feed and we have to resort on-chain dex source from tokenIn to ETH
            FindSwapQuery memory _query = FindSwapQuery(tokenIn, WETH, amountIn, WETH, 0);	
            Quote memory _tokenInToETHQuote = _findOptimalSwap(_query);
            if (_tokenInToETHQuote.amountOut > 0) {
                uint256 _ethUSD = _ethUSDOut > 0 ? _ethUSDOut : getEthUsdPrice();
                return FeedQuote((_tokenInToETHQuote.amountOut * _ethUSD / 1e18) * _getDecimalsMultiplier(tokenOut) / pOutUSD, _tokenInToETHQuote.amountOut, _tokenInToETHQuote.name);
            } else {
                return FeedQuote(0, 0, SwapType.PRICEFEED);					
            }
        } else if (pOutUSD == 0) {
            // CASE WHEN only tokenIn got feed and we have to resort on-chain dex source from ETH to tokenOut
            uint256 _ethUSD = _ethUSDOut > 0? _ethUSDOut : getEthUsdPrice();
            uint256 _inBtwETH = (pInUSD * amountIn / _getDecimalsMultiplier(tokenIn)) * 1e18 / _ethUSD; 
            FindSwapQuery memory _query = FindSwapQuery(WETH, tokenOut, _inBtwETH, WETH, 0);	
            Quote memory _ethToTokenOutQuote = _findOptimalSwap(_query);
            if (_ethToTokenOutQuote.amountOut > 0) {
                return FeedQuote(_ethToTokenOutQuote.amountOut, 0, SwapType.PRICEFEED);
            } else {
                return FeedQuote(0, 0, SwapType.PRICEFEED);					
            }
        }
		
        // CASE WHEN both tokenIn and tokenOut got feeds
        return FeedQuote((amountIn * pInUSD / pOutUSD) * _getDecimalsMultiplier(tokenOut) / _getDecimalsMultiplier(tokenIn), 0, SwapType.PRICEFEED);		
    }
	
    /// @dev try to find USD price for given token from feed
    /// @return USD feed value (scaled by 10^8) or 0 if no valid USD/ETH/BTC feed exist
    function fetchUSDFeed(address base) public view returns (uint256) {
        (uint256 pUSD, uint256 _ethUSD) = _fetchUSDAndPiggybackETH(base, 0);
        return pUSD;
    }
	
    /// @dev try to find USD price for given token from feed and piggyback ETH USD pricing if possible
    /// @return USD feed value (scaled by 10^8) or 0 if no valid USD/ETH/BTC feed exist 
    function _fetchUSDAndPiggybackETH(address base, uint256 _prefetchedETHUSD) internal view returns (uint256, uint256) {
        uint256 _ethUSD = _prefetchedETHUSD;
		
        if (_ifStablecoinForFeed(base)) {
            return (1e8, _ethUSD);  // shortcut for stablecoin https://defillama.com/stablecoins/Ethereum
        } else if (base == WBTC) {
            return (_fetchUSDPriceViaBTCFeed(base), _ethUSD);
        } else if (base == WETH) {
            _ethUSD = _ethUSD > 0 ? _ethUSD : getEthUsdPrice();
            return (_ethUSD, _ethUSD);
        }
		
        uint256 pUSD = getPriceInUSD(base);
        if (pUSD == 0) {
            uint256 pETH = getPriceInETH(base);
            if (pETH > 0) {
                _ethUSD = _ethUSD > 0 ? _ethUSD : getEthUsdPrice();
                pUSD = pETH * _ethUSD / 1e18;
            } else {			    
                pUSD = _fetchUSDPriceViaBTCFeed(base);	
            }
        }
        return (pUSD, _ethUSD);
    }
	
    /// @dev hardcoded stablecoin list for oracle feed optimization
    function _ifStablecoinForFeed(address token) internal view returns (bool) {
        if (token == USDC || token == USDT){
            return true;				
        } else {
            return false;				
        }
    }
	
    /// @dev hardcoded decimals() to save gas for some popular token
    function _getDecimalsMultiplier(address token) internal view returns (uint256) {
        if (token == USDC || token == USDT) {
            return 1e6;				
        } else if (token == WBTC) {
            return 1e8;				
        } else if (token == WETH) {
            return 1e18;				
        } else {
            return 10 ** ERC20(token).decimals();
        } 
    }
	
    /// @dev calculate USD pricing of base token via its BTC feed and BTC USD pricing
    function _fetchUSDPriceViaBTCFeed(address base) internal view returns (uint256) {
        uint256 pUSD = 0;
        uint256 pBTC = getPriceInBTC(base);
        if (pBTC > 0) {
            pUSD = pBTC * getBtcUsdPrice() / 1e8;				
        }
        return pUSD;
    }
	
    /// @dev Returns the price from given feed aggregator proxy
    /// @dev https://docs.chain.link/docs/ethereum-addresses/
    function _getPriceFromFeedAggregator(address _aggregator, uint256 _expire) internal view returns (uint256) {
        (uint80 roundID, int price, uint startedAt, uint timeStamp, uint80 answeredInRound) = AggregatorV2V3Interface(_aggregator).latestRoundData();
        require(_expire > block.timestamp - timeStamp, '!stale'); // Check for freshness of feed
        return uint256(price);
    }
	
    /// @dev Returns the price of BTC in USD from feed registry
    /// @return price value scaled by 10^8
    function getBtcUsdPrice() public view returns (uint256) {
        return _getPriceFromFeedAggregator(BTC_USD_FEED, SECONDS_PER_HOUR);
    }
	
    /// @dev Returns the price of BTC in USD from feed registry
    /// @return price value scaled by 10^8
    function getEthUsdPrice() public view returns (uint256) {
        return _getPriceFromFeedAggregator(ETH_USD_FEED, SECONDS_PER_HOUR);
    }

    /// @dev Returns the latest price of given base token in given Denominations
    function _getPriceInDenomination(address base, address _denom) internal view returns (uint256) {
        address aggregator = _getFeed(base, _denom);
        if (aggregator != ADDRESS_ZERO) {
            return _getPriceFromFeedAggregator(aggregator, SECONDS_PER_HOUR);
        } else {		
            return 0;		   
        }
    }

    /// @dev Returns appropriate data feed address, hardcoded switches because no registry
    /// @return Chainlink data feed address
    function _getFeed(address base, address _denom) internal view returns (address) {
        if (base == CRV && _denom == Denominations.USD) {
            return CRV_USD_FEED;
        } else if (base == SUSHI && _denom == Denominations.USD) {
            return SUSHI_USD_FEED;
        } else {
            return ADDRESS_ZERO;
        }
    }

    /// @dev Returns the latest price of given base token in USD
    /// @return price value scaled by 10^8 or 0 if no valid price feed is found
    function getPriceInUSD(address base) public view returns (uint256) {
        if (base == USDC) {
            return _getPriceFromFeedAggregator(USDC_USD_FEED, SECONDS_PER_DAY);
        } else if (base == DAI){
            return _getPriceFromFeedAggregator(DAI_USD_FEED, SECONDS_PER_HOUR);		
        } else if (base == USDT){
            return _getPriceFromFeedAggregator(USDT_USD_FEED, SECONDS_PER_DAY);		
        } else {
            return _getPriceInDenomination(base, Denominations.USD);
        }
    }

    /// @dev Returns the latest price of given base token in ETH
    /// @return price value scaled by 10^18 or 0 if no valid price feed is found
    function getPriceInETH(address base) public view returns (uint256) {
        if (base == WBTC) {
            /// NOTE: no wbtc/btc price feed on arb, assume 1:1
            uint256 pBTC = getPriceInBTC(base);
            uint256 btc2ETH = _getPriceFromFeedAggregator(BTC_ETH_FEED, SECONDS_PER_DAY);
            return pBTC * btc2ETH / 1e8;
        }
        return _getPriceInDenomination(base, Denominations.ETH);
    }

    /// @dev Returns the latest price of given base token in BTC (typically for WBTC)
    /// @return price value scaled by 10^8 or 0 if no valid price feed is found
    function getPriceInBTC(address base) public view returns (uint256) {
        /// NOTE: no wbtc/btc price feed on arb, assume 1:1
        if (base == WBTC) {
            return 1e8;
        } else {		
            return _getPriceInDenomination(base, Denominations.BTC);
        }
    }

    /// === UTILS === ///

    /// @dev Given a address input, return the bytes32 representation
    // TODO: Figure out if abi.encode is better -> Benchmark on GasLab
    function convertToBytes32(address _input) public pure returns (bytes32){
        return bytes32(uint256(uint160(_input)) << 96);
    }
	
    /// @dev Take for example the _input "0x111122223333444455556666777788889999AAAABBBBCCCCDDDDEEEEFFFFCCCC"
    /// @return the result of "0x111122223333444455556666777788889999aAaa"
    function getAddressFromBytes32Msb(bytes32 _input) public pure returns (address){
        return address(uint160(bytes20(_input)));
    }
	
    /// @dev Take for example the _input "0x111122223333444455556666777788889999AAAABBBBCCCCDDDDEEEEFFFFCCCC"
    /// @return the result of "0x777788889999AaAAbBbbCcccddDdeeeEfFFfCcCc"
    function getAddressFromBytes32Lsb(bytes32 _input) public pure returns (address){
        return address(uint160(uint256(_input)));
    }
}