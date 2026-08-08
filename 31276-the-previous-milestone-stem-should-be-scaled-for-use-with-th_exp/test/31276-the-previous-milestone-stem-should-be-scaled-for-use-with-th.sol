// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
contract BeanstalkSilo { int256 public milestoneStem; int256 public stalkEarnedPerSeason; int256 public currentSeason; int256 public milestoneSeason;
 function seedLegacy() external {milestoneStem=100;stalkEarnedPerSeason=1_000_000;currentSeason=2;milestoneSeason=1;}
 function stemTipForToken() external view returns(int256 tip){tip = milestoneStem + stalkEarnedPerSeason * (currentSeason - milestoneSeason); } // @> VULN: legacy truncated milestoneStem is added to untruncated gauge points without multiplying it by 1e6.
 function correctTip() external view returns(int256){return milestoneStem*1e6+stalkEarnedPerSeason*(currentSeason-milestoneSeason);}
}
contract Exploit {BeanstalkSilo public silo;constructor(){silo=new BeanstalkSilo();}function run() external{silo.seedLegacy();int256 broken=silo.stemTipForToken();int256 correct=silo.correctTip();require(broken!=correct,"decimal mismatch absent");require(correct-broken==99_999_900,"wrong grown stalk loss");}}
