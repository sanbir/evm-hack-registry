// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Harmonix FundContract — withdrawal uses the management fee as the trading fee
    (Shieldify, 2025-04, H-05).
    SYNTHETIC, cheatcode-free. The audited line is verbatim (@> VULN).

    Configured rates are the published ones: management 1%, trading 0.035%.
    Nobody changes them. _withdraw multiplies by userWithdraw.managementFee,
    so a 10_000-asset withdrawal is charged 100 instead of 3.5. */

contract Asset {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract FundContract {
    struct WithdrawData {
        uint256 shares;
        uint256 managementFee;
        uint256 withdrawAmount;
    }

    uint256 public constant MANAGEMENT_PPM = 10_000; // 1%
    uint256 public constant TRADING_PPM = 350; // 0.035%
    uint256 public constant PPM = 1_000_000;

    Asset public asset;
    address public feeReceiver;
    mapping(address => WithdrawData) public userWithdrawOf;
    mapping(address => uint256) public sharesOf;

    constructor(Asset asset_, address feeReceiver_) {
        asset = asset_;
        feeReceiver = feeReceiver_;
    }

    function fairTradingFee(uint256 shares) public pure returns (uint256) {
        return shares * TRADING_PPM / PPM;
    }

    function initiateWithdrawal(uint256 _shares) external virtual {
        uint256 withdrawAmount = _shares;
        uint256 managementFee = _shares * MANAGEMENT_PPM / PPM;
        sharesOf[msg.sender] = _shares;
        userWithdrawOf[msg.sender] = WithdrawData({
            shares: _shares,
            managementFee: managementFee,
            withdrawAmount: withdrawAmount
        });
    }

    function _sharesTradingFee(WithdrawData memory userWithdraw, uint256 _shares) internal view virtual returns (uint256) {
        // @> VULN: trading fee is computed from managementFee, which is 1% of shares, not 0.035%
        return (_shares * userWithdraw.managementFee) / userWithdraw.shares;
    }

    function _withdraw(address user, uint256 _shares) internal {
        WithdrawData memory userWithdraw = userWithdrawOf[user];
        uint256 sharesTradingFee = _sharesTradingFee(userWithdraw, _shares);
        uint256 gross = userWithdraw.withdrawAmount * _shares / userWithdraw.shares;
        asset.transfer(feeReceiver, sharesTradingFee);
        asset.transfer(user, gross - sharesTradingFee);
        userWithdrawOf[user].shares = 0;
    }

    function withdraw(uint256 _shares) external {
        _withdraw(msg.sender, _shares);
    }

    function chargedTradingFee(address user, uint256 shares) external view returns (uint256) {
        WithdrawData memory userWithdraw = userWithdrawOf[user];
        return (shares * userWithdraw.managementFee) / userWithdraw.shares;
    }
}

contract FundContractFixed is FundContract {
    constructor(Asset asset_, address feeReceiver_) FundContract(asset_, feeReceiver_) {}

    function _sharesTradingFee(WithdrawData memory, uint256 _shares) internal view override returns (uint256) {
        return fairTradingFee(_shares);
    }
}

contract Exploit {
    uint256 public constant SHARES = 10_000 ether;
    uint256 public constant CHARGED = 100 ether;
    uint256 public constant FAIR = 3.5 ether;
    uint256 public constant OVERCHARGE = 96.5 ether;

    Asset public asset; // nonce 1
    FundContract public fund; // nonce 2
    address public feeReceiver; // not a CREATE; a constant sink

    uint256 public charged;
    uint256 public fair;
    uint256 public userGot;
    uint256 public feeGot;

    constructor() {
        asset = new Asset();
        feeReceiver = address(0xFEE);
        fund = new FundContract(asset, feeReceiver);
    }

    function run() external {
        fund.initiateWithdrawal(SHARES);
        asset.mint(address(fund), SHARES);
        charged = fund.chargedTradingFee(address(this), SHARES);
        fair = fund.fairTradingFee(SHARES);
        fund.withdraw(SHARES);
        userGot = asset.balanceOf(address(this));
        feeGot = asset.balanceOf(feeReceiver);
        require(charged == CHARGED, "charged 100");
        require(fair == FAIR, "fair 3.5");
        require(charged - fair == OVERCHARGE, "overcharge 96.5");
        require(feeGot == CHARGED, "fee receiver got 100");
        require(userGot == SHARES - CHARGED, "user short 100");
    }
}
