// SPDX-License-Identifier: GPL-2.0-only
// Copyright 2020 Spilsbury Holdings Ltd

pragma solidity >=0.6.0 <0.8.0;
pragma experimental ABIEncoderV2;

import {Types} from '../cryptography/Types.sol';
import {Bn254Crypto} from '../cryptography/Bn254Crypto.sol';

library Rollup28x2Vk {
    using Bn254Crypto for Types.G1Point;
    using Bn254Crypto for Types.G2Point;

    function get_verification_key() internal pure returns (Types.VerificationKey memory) {
        Types.VerificationKey memory vk;

        assembly {
            mstore(add(vk, 0x00), 2097152) // vk.circuit_size
            mstore(add(vk, 0x20), 798) // vk.num_inputs
            mstore(add(vk, 0x40),0x1ded8980ae2bdd1a4222150e8598fc8c58f50577ca5a5ce3b2c87885fcd0b523) // vk.work_root
            mstore(add(vk, 0x60),0x30644cefbebe09202b4ef7f3ff53a4511d70ff06da772cc3785d6b74e0536081) // vk.domain_inverse
            mstore(add(vk, 0x80),0x19c6dfb841091b14ab14ecc1145f527850fd246e940797d3f5fac783a376d0f0) // vk.work_root_inverse
            mstore(mload(add(vk, 0xa0)), 0x116dc4ce834283a0591c264a2eeb86de2e03bac841db0b38778d8d06cd36bf6c)//vk.Q1
            mstore(add(mload(add(vk, 0xa0)), 0x20), 0x1e99a2759d3912e7f6a1014de47262e847512e199e79ba0abeab77c2f9bf027a)
            mstore(mload(add(vk, 0xc0)), 0x07a6479dd45aab8c2852e64c2155ae1119ba1666083776ccba6dee24033bbbc8)//vk.Q2
            mstore(add(mload(add(vk, 0xc0)), 0x20), 0x0e1b7c35f32ab2628e7dead93bc58b075cf9c023c1a0801cd14593c98bd89719)
            mstore(mload(add(vk, 0xe0)), 0x05f82e4d627c3e266976d9de8532e70af06858af43d237396309f5d1b090d4a0)//vk.Q3
            mstore(add(mload(add(vk, 0xe0)), 0x20), 0x1b88661b71b33ab2ca5e12e332e18278043f85efbdec5d7e97555ea7a782f98c)
            mstore(mload(add(vk, 0x100)), 0x279bd855fced62801f382edc091c5a51bfa7e2469d9875f69091f59c2c47dad0)//vk.Q4
            mstore(add(mload(add(vk, 0x100)), 0x20), 0x09cd3e79b3710b22f8a255b7bba630bc478a5054919cee73493d6a7fcca4fb33)
            mstore(mload(add(vk, 0x120)), 0x120437fc734c525490776252e829087fb80cabaede21ae24576c94810c92f3ee)//vk.Q5
            mstore(add(mload(add(vk, 0x120)), 0x20), 0x17bbce1f4bd885fdb70ffb87bf70d82162c2f5456ee8b7f6b4031ef68c091dab)
            mstore(mload(add(vk, 0x140)), 0x23c891d89639f3155ee9fe702a1ca200f550695fc2207bf91ab222acc031efbb)//vk.QM
            mstore(add(mload(add(vk, 0x140)), 0x20), 0x12ceb98da5c5ffd4ed45875ddb5b27cfd6eba7a76ef8503e578ccd5791ac45b6)
            mstore(mload(add(vk, 0x160)), 0x14d951d45e459d1bdd2859dbb99cbbee6e47c4b0537e60fa1338bb0473971788)//vk.QC
            mstore(add(mload(add(vk, 0x160)), 0x20), 0x2eba7504a39d347c164d6a015148a4c155860af06cd1220c453651303f80cffa)
            mstore(mload(add(vk, 0x180)), 0x0d3ccb89371c022c2db38316282b05ddb5d2ff942243b3ecd36e71a9391bcfb9)//vk.QARITH
            mstore(add(mload(add(vk, 0x180)), 0x20), 0x08a2edb8c39cb8795ae37c0321dc807f3b6f485bb7f62a3072d542bf56f0313f)
            mstore(mload(add(vk, 0x1a0)), 0x0c93e9c60ab2dfa04dfc16900a89a7efbb31429715fc64fe3234de05422a1bcd)//vk.QECC
            mstore(add(mload(add(vk, 0x1a0)), 0x20), 0x2a22b9176662a87aaa093240d1581a95c6e6d9012183c384d729e67be4b63fcc)
            mstore(mload(add(vk, 0x1c0)), 0x0c8a16a5699ad46f7bc19a08aa40924f783a9fe09543a4b526a60d82bdfdff67)//vk.QRANGE
            mstore(add(mload(add(vk, 0x1c0)), 0x20), 0x25eb13ae70fba7c2da9fad06cdcc812c4feaf48cb3d3688fd44452a438645eb5)
            mstore(mload(add(vk, 0x1e0)), 0x2ab2af1d2c8b7685a0221d7650fafcc9488a72f944e48806f268a27a7127623c)//vk.QLOGIC
            mstore(add(mload(add(vk, 0x1e0)), 0x20), 0x10f73555442aaf95e1933f531bd627bc672fea275d2ee998540a3cf1a593cc60)
            mstore(mload(add(vk, 0x200)), 0x2ba6e0b899c10219f1629c00b76beb1c3c0216c78834d483c37bbddb90f85a6c)//vk.SIGMA1
            mstore(add(mload(add(vk, 0x200)), 0x20), 0x0440c0b9a534237e8f974febbf6696eabe5be232700eb40babda3e66df528b38)
            mstore(mload(add(vk, 0x220)), 0x2de3fae7c36ae6a4db862650cd7edc824cfbe3852fb6118f522bc0f7786b4fb3)//vk.SIGMA2
            mstore(add(mload(add(vk, 0x220)), 0x20), 0x1336cbca7c66556ed6abfaa805bf7ee78ec2a74778e4d5276fdc770a71757066)
            mstore(mload(add(vk, 0x240)), 0x27b696a37730f9e474d2504c2b26da9db0c13a4e6e506b68af606b036f735245)//vk.SIGMA3
            mstore(add(mload(add(vk, 0x240)), 0x20), 0x113c878e8690a3e362a4ab2ea0cef0e7be79691aab0b53afd3367c80b0c70e0a)
            mstore(mload(add(vk, 0x260)), 0x278fedf47e57c79f91f9b0be0942ec196c417b37281007e6236d07fff9fe85ad)//vk.SIGMA4
            mstore(add(mload(add(vk, 0x260)), 0x20), 0x0d96058b2121b5c54067223536679a96683db3508d047ed074f59bd6c3ab5991)
            mstore(add(vk, 0x280), 0x01) // vk.contains_recursive_proof
            mstore(add(vk, 0x2a0), 782) // vk.recursive_proof_public_input_indices
            mstore(mload(add(vk, 0x2c0)), 0x260e01b251f6f1c7e7ff4e580791dee8ea51d87a358e038b4efe30fac09383c1) // vk.g2_x.X.c1
            mstore(add(mload(add(vk, 0x2c0)), 0x20), 0x0118c4d5b837bcc2bc89b5b398b5974e9f5944073b32078b7e231fec938883b0) // vk.g2_x.X.c0
            mstore(add(mload(add(vk, 0x2c0)), 0x40), 0x04fc6369f7110fe3d25156c1bb9a72859cf2a04641f99ba4ee413c80da6a5fe4) // vk.g2_x.Y.c1
            mstore(add(mload(add(vk, 0x2c0)), 0x60), 0x22febda3c0c0632a56475b4214e5615e11e6dd3f96e6cea2854a87d4dacc5e55) // vk.g2_x.Y.c0
        }
        return vk;
    }
}
