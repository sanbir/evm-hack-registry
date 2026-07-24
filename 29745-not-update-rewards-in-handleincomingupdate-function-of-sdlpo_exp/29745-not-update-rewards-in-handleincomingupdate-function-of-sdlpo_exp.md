# Stake.Link rewards — incoming bridge update makes rewards insolvent
<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/29745-not-update-rewards-in-handleincomingupdate-function-of-sdlpo.md -->
<!-- date: 2023-12 -->
> **Vulnerability classes:** vuln/logic/reward-calculation · vuln/dos/frozen-funds
## Key info
| Field | Value |
|---|---|
| Impact | Secondary-chain reward distribution reverts |
| Chain | Local synthetic |
## TL;DR
The controller's effective balance is increased before its already accrued rewards are checkpointed. It then claims old rewards on newly added stake, exceeding the funded reward pool.
## The vulnerable code
```solidity
effectiveBalances[CONTROLLER] += uint256(change); // @> VULN: effective balance changes without first settling controller rewards at the old rewardPerToken.
```
## Attack walkthrough
The PoC funds 1000 rewards at reward-per-token one, grows controller effective balance from 1000 to 2000, and catches the resulting 2000-unit withdrawal revert.
## Diagrams
```mermaid
flowchart LR
    U[Incoming update] --> B[Controller balance doubles]
    B --> C[Old reward checkpoint remains]
    C --> D[Claim exceeds reward pool]
```
## Remediation
Call the reward update/checkpoint routine for the controller before changing its effective balance.
## Sources
- [AuditVault finding #29745](https://github.com/Auditware/AuditVault/blob/main/findings/29745-not-update-rewards-in-handleincomingupdate-function-of-sdlpo.md)
- [Stake.Link SDLPoolPrimary](https://github.com/Cyfrin/2023-12-stake-link/blob/main/contracts/core/sdlPool/SDLPoolPrimary.sol)
