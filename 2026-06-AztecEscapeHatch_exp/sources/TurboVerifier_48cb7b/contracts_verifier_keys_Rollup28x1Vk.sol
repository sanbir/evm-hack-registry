// SPDX-License-Identifier: GPL-2.0-only
// Copyright 2020 Spilsbury Holdings Ltd

pragma solidity >=0.6.0 <0.8.0;
pragma experimental ABIEncoderV2;

import {Types} from '../cryptography/Types.sol';
import {Bn254Crypto} from '../cryptography/Bn254Crypto.sol';

library Rollup28x1Vk {
    using Bn254Crypto for Types.G1Point;
    using Bn254Crypto for Types.G2Point;

    function get_verification_key() internal pure returns (Types.VerificationKey memory) {
        Types.VerificationKey memory vk;

        assembly {
            mstore(add(vk, 0x00), 1048576) // vk.circuit_size
            mstore(add(vk, 0x20), 414) // vk.num_inputs
            mstore(add(vk, 0x40),0x26125da10a0ed06327508aba06d1e303ac616632dbed349f53422da953337857) // vk.work_root
            mstore(add(vk, 0x60),0x30644b6c9c4a72169e4daa317d25f04512ae15c53b34e8f5acd8e155d0a6c101) // vk.domain_inverse
            mstore(add(vk, 0x80),0x100c332d2100895fab6473bc2c51bfca521f45cb3baca6260852a8fde26c91f3) // vk.work_root_inverse
            mstore(mload(add(vk, 0xa0)), 0x2b1b1ba9bdb4c13b51da14521d51d2bb429ccffaaa8cc12a424401226da0b15f)//vk.Q1
            mstore(add(mload(add(vk, 0xa0)), 0x20), 0x012f22fc3acf659c5dc9a726b8cd66571e76dd218cffaf2ec920d5c7e73c1cd0)
            mstore(mload(add(vk, 0xc0)), 0x259ca639e5572bca4025719c3af60cf975c34cb1e90c2adbc00c901e7331af97)//vk.Q2
            mstore(add(mload(add(vk, 0xc0)), 0x20), 0x221deb0f25cbd2d23b8262c1eead83cb0686b0aed77b2ea1c52318e205092362)
            mstore(mload(add(vk, 0xe0)), 0x047388dfe085024f56b1818219cbc639a868c33bf8bca965f6ce9bcbc03dcd71)//vk.Q3
            mstore(add(mload(add(vk, 0xe0)), 0x20), 0x033198b4255a33ad5c87264851546612bcb7fadc604f4ea301dd01a054876a46)
            mstore(mload(add(vk, 0x100)), 0x0486c8388c66f900b81d60c77dc5692e6a20780d7300ca2f0f99c0b12a3455f7)//vk.Q4
            mstore(add(mload(add(vk, 0x100)), 0x20), 0x0410934bcdd4eadfa106d7441e26eda7f24ac47d99a812638f3877648a416da7)
            mstore(mload(add(vk, 0x120)), 0x03f6b7be57cf3eb7aac76efe0b608db6e10f1e92b5545f8290d5449aa08c9e8a)//vk.Q5
            mstore(add(mload(add(vk, 0x120)), 0x20), 0x2b3a43ce6528b6963f3c8a19cb580e47c762b53ea358b4443622edb0e2a94db4)
            mstore(mload(add(vk, 0x140)), 0x207f5ea8794d7a939c84a9597e5d01abfa587be9ca52c8f4df4230410072e896)//vk.QM
            mstore(add(mload(add(vk, 0x140)), 0x20), 0x2087a5615b6327a8f7b1b8f682534f071d8d9f4b1f9381f722456832654d6f09)
            mstore(mload(add(vk, 0x160)), 0x0bdb4f3fdfcf5e7591b78dcca7c8aff4febd3a073b0d1d64bc014ea9a364c6ed)//vk.QC
            mstore(add(mload(add(vk, 0x160)), 0x20), 0x1c9090a9224920046a6f3e6d100d933e30aea7a3dfbfd69975c505163b675f86)
            mstore(mload(add(vk, 0x180)), 0x2b3a1f36da1e33f26ff0252652f561fc944f1b5965a8773c8005e76f2085abec)//vk.QARITH
            mstore(add(mload(add(vk, 0x180)), 0x20), 0x218f55a07f1c4dfed8a235be71e33d9ffa92512b32b2bcf1e6702c48a3942e91)
            mstore(mload(add(vk, 0x1a0)), 0x01918717a8e6aef689bcc36fb8e3592412b87f95cb343c30a9a26bedc093ea75)//vk.QECC
            mstore(add(mload(add(vk, 0x1a0)), 0x20), 0x0f0ddff42d1b4399b203fca3f29e5fb2b2a2868b3d4e7391da749997b805861c)
            mstore(mload(add(vk, 0x1c0)), 0x01b1ced0aaf00ab6c58eb4bc4619d4d930d44605ab20c6b91a1b27a2e8b6badc)//vk.QRANGE
            mstore(add(mload(add(vk, 0x1c0)), 0x20), 0x0b606c182c30d0bdd656d88eb24c90fbb0e32f6d60974115c7a6f1fd3b9cc68e)
            mstore(mload(add(vk, 0x1e0)), 0x109b01ea2bfde695e0ba94225224af50d06e907206c1d7990447716b5e4a743e)//vk.QLOGIC
            mstore(add(mload(add(vk, 0x1e0)), 0x20), 0x2c3564edafae943b8b3bc7cd9e7a14ef02d605725bbbdc11d43c78265f920f2d)
            mstore(mload(add(vk, 0x200)), 0x2a705644136e545396bc1ef3b56c56cdad2170bfe7b53bcb9839433d13c8470b)//vk.SIGMA1
            mstore(add(mload(add(vk, 0x200)), 0x20), 0x10e18e3c8772f729bb9d32bc97e0e74328275c2ab3fc7fd952068e5942eb52cd)
            mstore(mload(add(vk, 0x220)), 0x163d080fd409b36a95b74ff08c886ad4108ba39fe131769cb5c325317b944d60)//vk.SIGMA2
            mstore(add(mload(add(vk, 0x220)), 0x20), 0x1774dc631178ed79039730c196728e8d6152d7990cbf151b9aaa60aebae68df9)
            mstore(mload(add(vk, 0x240)), 0x2de27f1acba460cb2ed304a14b65fbb0cc875ebef79b52fe5b97e215242cdb1f)//vk.SIGMA3
            mstore(add(mload(add(vk, 0x240)), 0x20), 0x1b5a86498410fb7e332bd84d076cd4556f22b717e335341730e4f0788a6b532e)
            mstore(mload(add(vk, 0x260)), 0x13fad58da00bf30f9d50bc7f90dde9a285e3d0668fe5f7df2ca9f28b921210ad)//vk.SIGMA4
            mstore(add(mload(add(vk, 0x260)), 0x20), 0x1245c1ec5242454a03eed7069c6572b2ec4f051bda580f78bab847c2da1b9cc6)
            mstore(add(vk, 0x280), 0x01) // vk.contains_recursive_proof
            mstore(add(vk, 0x2a0), 398) // vk.recursive_proof_public_input_indices
            mstore(mload(add(vk, 0x2c0)), 0x260e01b251f6f1c7e7ff4e580791dee8ea51d87a358e038b4efe30fac09383c1) // vk.g2_x.X.c1
            mstore(add(mload(add(vk, 0x2c0)), 0x20), 0x0118c4d5b837bcc2bc89b5b398b5974e9f5944073b32078b7e231fec938883b0) // vk.g2_x.X.c0
            mstore(add(mload(add(vk, 0x2c0)), 0x40), 0x04fc6369f7110fe3d25156c1bb9a72859cf2a04641f99ba4ee413c80da6a5fe4) // vk.g2_x.Y.c1
            mstore(add(mload(add(vk, 0x2c0)), 0x60), 0x22febda3c0c0632a56475b4214e5615e11e6dd3f96e6cea2854a87d4dacc5e55) // vk.g2_x.Y.c0
        }
        return vk;
    }
}
