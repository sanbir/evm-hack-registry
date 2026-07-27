# Beanstalk BIP-39 upgrade omits modified facets and dependencies

Source status: the exact Beanstalk revisions named by the report are
available (`76066733bcddb944b9af8f29acf150c02a5b8437` and
`dfb418d185cd93eef08168ccaffe9de86bc1f062`). The finding is a deployment
script/diamond-cut omission in `protocol/scripts/bips.js`, not an isolated
Solidity call that can be faithfully reproduced by a standalone Forge test.
The earlier fabricated reduction has been removed; no Forge reproduction is
claimed.

Sources: [AuditVault finding #31275](https://github.com/Auditware/AuditVault/blob/main/findings/31275-failure-to-add-modified-facets-and-facets-with-modified-depe.md), [Cyfrin report](https://github.com/solodit/solodit_content/blob/main/reports/Cyfrin/2023-12-05-cyfrin-beanstalk-bip-39.md), [pre-upgrade Beanstalk source](https://github.com/BeanstalkFarms/Beanstalk/tree/76066733bcddb944b9af8f29acf150c02a5b8437), [BIP-39 source](https://github.com/BeanstalkFarms/Beanstalk/tree/dfb418d185cd93eef08168ccaffe9de86bc1f062).
