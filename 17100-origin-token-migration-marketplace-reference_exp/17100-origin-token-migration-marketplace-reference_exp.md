# OriginToken migration leaves V00 Marketplace escrow on the paused token

> **Vulnerability classes:** vuln/dependency/upgradeable-contract · vuln/logic/incorrect-state-transition · vuln/dos/lockup
>
> **Reproduction:** the test deploys the audited OriginToken, TokenMigration, and V00_Marketplace sources. It migrates the Marketplace's real escrow balance, pauses the old token, and then follows the real `finalize` path. The passing trace is in [output.txt](output.txt).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/17100-origintoken-contract-migration-breaks-marketplace-ofer-refer.md -->
<!-- date: 2022-01 -->

## Key info

| Field | Value |
|---|---|
| **Loss** | A 10-token listing deposit and a 20-token offer remain in the Marketplace after migration, but neither can be settled. |
| **Vulnerable contract** | `V00_Marketplace` from [src/contracts/marketplace/v00/Marketplace.sol](src/contracts/marketplace/v00/Marketplace.sol), specifically `tokenAddr`, `Offer.currency`, and `finalize`/`paySeller`. |
| **Migration contracts** | Exact [OriginToken](src/contracts/token/OriginToken.sol) and [TokenMigration](src/contracts/token/TokenMigration.sol) sources from Origin's repository. |
| **Attack transaction** | `PoC_17100.test_migrationLeavesMarketplacePointingAtPausedToken()` |
| **Chain / block / date** | Ethereum-compatible execution · local Foundry · 2022-01 report |
| **Compiler** | Solidity `^0.4.24` (the audited source pragma) |
| **Bug class** | Migration pauses the old token, but Marketplace has no migration hook for its token reference or existing offer currencies. |

## TL;DR

The Origin migration mints replacement balances in a new `OriginToken` and
leaves the old token paused. `V00_Marketplace` stores the old address in
`tokenAddr`, and every ERC20 offer stores the address supplied as
`Offer.currency`. An accepted offer therefore continues to call the paused
old token in `finalize`; the call reverts and the escrow remains in the
Marketplace. The test proves this with the actual migration contracts and
the actual Marketplace code.

## Source used by the test

The following files are vendored from the historical Origin source tree and
compiled without replacing their Marketplace logic:

- [V00 Marketplace](src/contracts/marketplace/v00/Marketplace.sol)
- [OriginToken](src/contracts/token/OriginToken.sol)
- [TokenMigration](src/contracts/token/TokenMigration.sol)
- [WhitelistedPausableToken](src/contracts/token/WhitelistedPausableToken.sol)

The OpenZeppelin Solidity `1.10.0` dependency required by those files is in
[`node_modules/openzeppelin-solidity`](node_modules/openzeppelin-solidity).

## Vulnerable code path

The exact Marketplace constructor records the token once:

```solidity
constructor(address _tokenAddr) public {
    owner = msg.sender;
    setTokenAddr(_tokenAddr);
}
```

An ERC20 offer separately records the address passed by the buyer:

```solidity
offers[listingID].push(Offer({
    ...,
    currency: _currency,
    value: _value,
    ...
}));
```

`finalize` then calls `paySeller`, which transfers through that stored old
currency. The paused `OriginToken` rejects the transfer, so the entire
settlement reverts. The test invokes the replacement token only through the
real migration contract; it does not replace the Marketplace logic.

## Reproduction walkthrough

1. Deploy the real `OriginToken` with a 30-token supply and the real
   `V00_Marketplace` pointing to it.
2. Create a listing with a 10-token deposit and an accepted 20-token offer
   denominated in the old token. The Marketplace now holds all 30 tokens.
3. Deploy the real `TokenMigration`, transfer the new token's minting
   ownership to it, pause the old token, and migrate the Marketplace holder.
   The new token receives 30 tokens, while the Marketplace still stores the
   old token address.
4. Call `finalize(0, 0, ...)`. `paySeller` invokes `oldToken.transfer`, which
   reverts because the old token is paused. The test confirms the old 30-token
   escrow, the replacement 30-token balance, and the listing deposit remain.

## Impact and remediation

Existing listings and offers cannot be completed after migration. Unpausing
the old token would settle against a token that is no longer the active OGN
contract, while the newly minted balance is ignored. Migration must update
the Marketplace token and every outstanding offer atomically, or provide a
validated escrow conversion/refund path before pausing the old token.

## How to reproduce

```bash
cd evm-hack-registry/17100-origin-token-migration-marketplace-reference_exp
forge test -vvvvv
```

## Sources

- [AuditVault finding #17100](https://github.com/Auditware/AuditVault/blob/main/findings/17100-origintoken-contract-migration-breaks-marketplace-ofer-refer.md)
- [Trail of Bits Origin review](https://github.com/trailofbits/publications/blob/master/reviews/origin.pdf)
- [Origin source repository](https://github.com/OriginProtocol/origin-js)
- [Real-source Forge test](test/17100-origin-token-migration-marketplace-reference_exp.sol)
