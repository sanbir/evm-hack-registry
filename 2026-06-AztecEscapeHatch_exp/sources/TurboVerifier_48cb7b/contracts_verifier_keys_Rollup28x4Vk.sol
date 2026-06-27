// SPDX-License-Identifier: GPL-2.0-only
// Copyright 2020 Spilsbury Holdings Ltd

pragma solidity >=0.6.0 <0.8.0;
pragma experimental ABIEncoderV2;

import {Types} from '../cryptography/Types.sol';
import {Bn254Crypto} from '../cryptography/Bn254Crypto.sol';

library Rollup28x4Vk {
    using Bn254Crypto for Types.G1Point;
    using Bn254Crypto for Types.G2Point;

    function get_verification_key() internal pure returns (Types.VerificationKey memory) {
        Types.VerificationKey memory vk;

        assembly {
            mstore(add(vk, 0x00), 4194304) // vk.circuit_size
            mstore(add(vk, 0x20), 1566) // vk.num_inputs
            mstore(add(vk, 0x40),0x1ad92f46b1f8d9a7cda0ceb68be08215ec1a1f05359eebbba76dde56a219447e) // vk.work_root
            mstore(add(vk, 0x60),0x30644db14ff7d4a4f1cf9ed5406a7e5722d273a7aa184eaa5e1fb0846829b041) // vk.domain_inverse
            mstore(add(vk, 0x80),0x2eb584390c74a876ecc11e9c6d3c38c3d437be9d4beced2343dc52e27faa1396) // vk.work_root_inverse
            mstore(mload(add(vk, 0xa0)), 0x09efdf9b9fe83913fdf99592313c3d6118d7d55ce442df69b145ea27bd57eac6)//vk.Q1
            mstore(add(mload(add(vk, 0xa0)), 0x20), 0x2d179f8f2b33403f3d029aef858e5dcc645b001f19e05d1b04c195874d276457)
            mstore(mload(add(vk, 0xc0)), 0x1f880e4e7c86c4a75b809278cabf9ad6374c435be8de6cabe6eddf8d24b1ff56)//vk.Q2
            mstore(add(mload(add(vk, 0xc0)), 0x20), 0x1d317997115f6dba144d81e18f6c984ce7f876cc001ebd0f0c6e04bed0edfcbb)
            mstore(mload(add(vk, 0xe0)), 0x26354239ba9c50608050ab3c88413b8296c796bce64a6a87b3fdcd7c81eaac47)//vk.Q3
            mstore(add(mload(add(vk, 0xe0)), 0x20), 0x25dc7864dd54ef92e8efca62f3751577faeeb2a4689d0b54adb083683ab8cd3a)
            mstore(mload(add(vk, 0x100)), 0x020aff05b719f61953e694a684f95d4ce61fc1d700770beed1c7702c5e070a3e)//vk.Q4
            mstore(add(mload(add(vk, 0x100)), 0x20), 0x1ff796a79304d9b065d2403e28649bce3612b7000ba12bda946726e51c7d9277)
            mstore(mload(add(vk, 0x120)), 0x01b63037b3e2264bcfb6606a7d82b40b6d17a97705d6ae7c8bf8a08df0acd785)//vk.Q5
            mstore(add(mload(add(vk, 0x120)), 0x20), 0x198c1ae77e07fa910358a7e6889a25bc58b4b5b2d9c419f431d45c8c1536a838)
            mstore(mload(add(vk, 0x140)), 0x07bf31eab28d9db82086fed706109051fdec65f96736c465b9d7fadd627d0a76)//vk.QM
            mstore(add(mload(add(vk, 0x140)), 0x20), 0x2b492161c3577ab9f5dd72760f08f177855e6a03736af0fdf4725bec18bc1d11)
            mstore(mload(add(vk, 0x160)), 0x1b0c2a385f0b2f5e70e3f4528a2d3f9e77bd0be87e9a33d58955776840353942)//vk.QC
            mstore(add(mload(add(vk, 0x160)), 0x20), 0x20c291fa3e291db5b4be8457f4404565ff61a785b2964bb4302975d0cba00693)
            mstore(mload(add(vk, 0x180)), 0x2f7a8c3b19b6dec01305028e1bf34276e81c33487920f1717ac63f73780e7e51)//vk.QARITH
            mstore(add(mload(add(vk, 0x180)), 0x20), 0x26c44ec471f26b9d0a943c37b07c3606496e8ff5de32d6657b4e99db61140868)
            mstore(mload(add(vk, 0x1a0)), 0x2c13a77ba53ac802f357cd28c7d62caaf11449321a1845c448b2ec355def0525)//vk.QECC
            mstore(add(mload(add(vk, 0x1a0)), 0x20), 0x0d5a1044508ae384633e5d71e701020e7e97f753e2c553f8bcb023e4d98202d0)
            mstore(mload(add(vk, 0x1c0)), 0x0da3d811ef93a6da61b68e75377837c76888983c3e21c789d764846a9553ed9d)//vk.QRANGE
            mstore(add(mload(add(vk, 0x1c0)), 0x20), 0x2e1b1052b5e1dd725e0d68e8e19b8dd798177488205a316d1035de6088ae728c)
            mstore(mload(add(vk, 0x1e0)), 0x0437557bedfb574d4c3082f1acbe88af20839b2c63cfb443b6fe8de58bcc7621)//vk.QLOGIC
            mstore(add(mload(add(vk, 0x1e0)), 0x20), 0x0e0a6bcdcbde5decbe0622b61216a85ebf15f895d41ed60110b09e8cdd140ce4)
            mstore(mload(add(vk, 0x200)), 0x036e971b68242f1a40a5f042ddf097ba61908e1f7ee02d37a87d90b0e11b0b6c)//vk.SIGMA1
            mstore(add(mload(add(vk, 0x200)), 0x20), 0x305ac36c480df7ebcf06239e399f18d22064fed17ef073f4501f5063b9eabcee)
            mstore(mload(add(vk, 0x220)), 0x2e9d09864aa5aef0815931943da75ca245ce0f7512667eeb575d92e1c48feaa4)//vk.SIGMA2
            mstore(add(mload(add(vk, 0x220)), 0x20), 0x1779f7f835fae32cd7f698e5ebaaafe7b56cdce3ea4a76efc9aeedfee9d35d86)
            mstore(mload(add(vk, 0x240)), 0x27b85392d2633c754fac8af7e06ba26d8731811bf65504ab5b63c63db5bf0cee)//vk.SIGMA3
            mstore(add(mload(add(vk, 0x240)), 0x20), 0x04fdb454d59933fda7956c5d20f8cf0db0cd500b2eb85b73bd559e71a141ca87)
            mstore(mload(add(vk, 0x260)), 0x0d69b165f0e91f72766030128a57eb6daaf8598f9e27488601a4454c4bced2dd)//vk.SIGMA4
            mstore(add(mload(add(vk, 0x260)), 0x20), 0x08224d27061e604f40b6356d84dc8893691c0eddcac4ff1c15062e3175a59ca5)
            mstore(add(vk, 0x280), 0x01) // vk.contains_recursive_proof
            mstore(add(vk, 0x2a0), 1550) // vk.recursive_proof_public_input_indices
            mstore(mload(add(vk, 0x2c0)), 0x260e01b251f6f1c7e7ff4e580791dee8ea51d87a358e038b4efe30fac09383c1) // vk.g2_x.X.c1
            mstore(add(mload(add(vk, 0x2c0)), 0x20), 0x0118c4d5b837bcc2bc89b5b398b5974e9f5944073b32078b7e231fec938883b0) // vk.g2_x.X.c0
            mstore(add(mload(add(vk, 0x2c0)), 0x40), 0x04fc6369f7110fe3d25156c1bb9a72859cf2a04641f99ba4ee413c80da6a5fe4) // vk.g2_x.Y.c1
            mstore(add(mload(add(vk, 0x2c0)), 0x60), 0x22febda3c0c0632a56475b4214e5615e11e6dd3f96e6cea2854a87d4dacc5e55) // vk.g2_x.Y.c0
        }
        return vk;
    }
}
