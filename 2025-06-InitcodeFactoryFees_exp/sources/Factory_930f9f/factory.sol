
pragma solidity >=0.8.9;

interface IToken {
    function creator() external view returns (address);
}

interface IWETH {
    function withdraw(uint256 amount) external;
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function factory() external view returns (address);
    function WETH9() external view returns (address);

    function positions(uint256 tokenId) external view returns (
        uint96 nonce,
        address operator,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    );

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external returns (address pool);

    function mint(MintParams calldata params) external returns (
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function collect(CollectParams calldata params) external payable returns (
        uint256 amount0,
        uint256 amount1
    );

    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function ownerOf(uint256 tokenId) external view returns (address);
}


contract Factory {
    event ERC20TokenCreated(address tokenAddress);

    struct TokenInfo {
        address tokenAddress;
        string name;
        string symbol;
        address deployer;
        uint256 time;
        string metadata;
        uint256 marketCapInETH;
    }

    mapping(uint256 => TokenInfo) public deployedTokens;
    uint256 public tokenCount = 0;
    address public platformController;

    address public constant POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    uint256 constant Q96 = 2 ** 96;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant SWAP_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45; // SwapRouter02

    uint24 private constant FEE_TIER = 10000;
    uint256 private constant VIRTUAL_ETH = 1.5 ether;

    event TokenPurchased(address buyer, address tokenOut, uint256 ethSpent, uint256 tokensReceived);

    constructor() {
        platformController = msg.sender;
    }

    receive() external payable {}

    function deployCoin(string memory _name, string memory _symbol, string memory _metadata, bytes32 salt) public payable {
        Token t = new Token{salt: salt}(
            _name,
            _symbol,
            msg.sender,
            address(this)
        );
        emit ERC20TokenCreated(address(t));

        address coin_address = address(t);
        provideLiquidity(coin_address, WETH);

        if (msg.value > 0) {
            uint256 taxBps = getPenalty(msg.value); // in basis points (e.g., 2500 = 25%)
            uint256 tax = (msg.value * taxBps) / 10000;
            uint256 amountAfterTax = msg.value - tax;

            // Retain the tax inside the contract
            // Note: address(this) already received msg.value, we only use part for swap

            ISwapRouter02(SWAP_ROUTER).exactInputSingle{ value: amountAfterTax }(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: WETH,
                    tokenOut: coin_address,
                    fee: 10000,
                    recipient: msg.sender,
                    amountIn: amountAfterTax,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        deployedTokens[tokenCount] = TokenInfo({
            tokenAddress: coin_address,
            name: _name,
            symbol: _symbol,
            deployer: msg.sender,
            time: block.timestamp,
            metadata: _metadata,
            marketCapInETH: 0
        });

        tokenCount++;
    }

    function getTokenBytecode(
        string memory _name,
        string memory _symbol,
        address creator
    ) public view returns (bytes memory bytecode) {
        bytecode = abi.encodePacked(
            type(Token).creationCode,
            abi.encode(_name, _symbol, creator, address(this))
        );
    }

    

   function getPenalty(uint256 ethAmount) public pure returns (uint256) {
        if (ethAmount < 0.08 ether) return 0;
        if (ethAmount >= 0.5 ether) return 2500; // max 25%

        // Normalize: x in [0, 1e18]
        uint256 x = ((ethAmount - 0.08 ether) * 1e18) / (0.42 ether);
        uint256 xHigh = x * 1e18; // 1e36 scale

        uint256 sqrt1 = sqrt(xHigh);       // ~1e18
        uint256 sqrt2 = sqrt(sqrt1);       // ~1e9
        uint256 power = (xHigh * sqrt2) / 1e18; // ~1e27

        return (power * 2500) / 1e27; // Final result in basis points
    }

    /// @notice Babylonian square root
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y == 0) return 0;
        z = y;
        uint256 x = (y / 2) + 1;
        while (x < z) {
            z = x;
            x = (y / x + x) / 2;
        }
    } 

    function getDeploysByPage(uint256 page, uint256 order) public view returns (TokenInfo[] memory) {
        uint256 itemsPerPage = 50;
        require(tokenCount > 0, "No tokens deployed");

        uint256 totalPages = (tokenCount + itemsPerPage - 1) / itemsPerPage;
        require(page < totalPages, "Page out of range");

        uint256 start;
        uint256 end;
        uint256 j = 0;

        if (order == 0) {
            // Newest first
            start = tokenCount > (page + 1) * itemsPerPage ? tokenCount - (page + 1) * itemsPerPage : 0;
            end = tokenCount - page * itemsPerPage;
            if (end > tokenCount) end = tokenCount;
        } else {
            // Oldest first
            start = page * itemsPerPage;
            end = start + itemsPerPage;
            if (end > tokenCount) end = tokenCount;
        }

        TokenInfo[] memory tokens = new TokenInfo[](end - start);
        address weth = INonfungiblePositionManager(POSITION_MANAGER).WETH9();
        address factory = INonfungiblePositionManager(POSITION_MANAGER).factory();

        for (uint256 i = start; i < end; i++) {
            uint256 index = order == 0 ? end - 1 - (i - start) : i;
            TokenInfo memory info = deployedTokens[index];

            uint256 marketCap = 0;
            address pool = IUniswapV3Factory(factory).getPool(info.tokenAddress, weth, 10000);
            if (pool != address(0)) {
                uint256 wethInPool = IERC20(weth).balanceOf(pool);
                uint256 tokenInPool = IERC20(info.tokenAddress).balanceOf(pool);
                uint256 totalSupply = IERC20(info.tokenAddress).totalSupply();

                if (tokenInPool > 0) {
                    marketCap = ((wethInPool + 1.5 ether) * totalSupply) / tokenInPool;
                }
            }

            tokens[j++] = TokenInfo({
                tokenAddress: info.tokenAddress,
                name: info.name,
                symbol: info.symbol,
                deployer: info.deployer,
                time: info.time,
                metadata: info.metadata,
                marketCapInETH: marketCap
            });
        }

        return tokens;
    }



    function withdrawFeesWETH() external {
        require(msg.sender == platformController, "Caller is not controller");
        uint256 wethBalance = IERC20(WETH).balanceOf(address(this));
        require(wethBalance > 0, "No WETH to withdraw");

        IWETH(WETH).withdraw(wethBalance);

        (bool success, ) = msg.sender.call{ value: wethBalance }("");
        require(success, "ETH transfer failed");
    }

    function withdrawFeesETH() external {
        require(msg.sender == platformController, "Caller is not controller");

        uint256 ethBalance = address(this).balance;
        require(ethBalance > 0, "No ETH to withdraw");

        (bool success, ) = msg.sender.call{ value: ethBalance }("");
        require(success, "ETH transfer failed");
    }


    function provideLiquidity(address tokenA, address tokenB) internal {
        bool tokenAIsToken0 = tokenA < tokenB;
        
        address token0 = tokenAIsToken0 ? tokenA : tokenB;
        address token1 = tokenAIsToken0 ? tokenB : tokenA;

        IERC20(token0).approve(POSITION_MANAGER, type(uint256).max);
        IERC20(token1).approve(POSITION_MANAGER, type(uint256).max);

        INonfungiblePositionManager manager = INonfungiblePositionManager(POSITION_MANAGER);

        uint160 sqrtPriceX96 = tokenAIsToken0
            ? 3068365595550320841079178
            : 2045645379722529521098596513701367;

        int24 tickLower = tokenAIsToken0 ? int24(-203000) : int24(-887200);
        int24 tickUpper = tokenAIsToken0 ? int24(887200) : int24(203000);

        uint256 amount0Desired = tokenAIsToken0 ? 1000000000000000000000000000 : 0;
        uint256 amount1Desired = tokenAIsToken0 ? 0 : 1000000000000000000000000000;

        manager.createAndInitializePoolIfNecessary(token0, token1, 10000, sqrtPriceX96);

        manager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: 10000,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }



    function collectFees(uint256 tokenId) external returns (uint256 amount0, uint256 amount1) {
        (
            , // nonce
            , // operator
            address token0Raw,
            address token1Raw,
            , , , , , , , 
        ) = INonfungiblePositionManager(POSITION_MANAGER).positions(tokenId);

        // Ensure token1 is always WETH
        address token0 = token0Raw;
        address token1 = token1Raw;

        if (token0Raw == WETH && token1Raw != WETH) {
            token0 = token1Raw;
            token1 = token0Raw;
        }

        address creator = IToken(token0).creator();
        require(msg.sender == creator || msg.sender == platformController, "Not authorized");

        uint256 beforeToken0 = IERC20(token0).balanceOf(address(this));
        uint256 beforeToken1 = IERC20(token1).balanceOf(address(this));

        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        INonfungiblePositionManager(POSITION_MANAGER).collect(params);

        uint256 collected0 = IERC20(token0).balanceOf(address(this)) - beforeToken0;
        uint256 collected1 = IERC20(token1).balanceOf(address(this)) - beforeToken1;

        if (collected0 > 0) {
            IERC20(token0).transfer(address(0x000000000000000000000000000000000000dEaD), collected0); // burn tokens
        }
        if (collected1 > 0) {
            uint256 half = collected1 / 2;

            // weth to eth
            IWETH(token1).withdraw(half);

            // pay creator, no matter who calls the function
            (bool success, ) = payable(creator).call{value: half}("");
            require(success, "ETH transfer to creator failed");
        }

        return (collected0, collected1);
    }

}


// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Token is ERC20, ERC20Burnable {
    address public platform;
    address public creator;

    constructor(
        string memory _name,
        string memory _symbol,
        address _creator,
        address _platform
    ) ERC20(_name, _symbol) {
        platform = _platform;
        creator = _creator;
        _mint(_platform, 1000000000 * 10 ** decimals());
    }
}