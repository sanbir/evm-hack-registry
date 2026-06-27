// SPDX-License-Identifier: GPL-2.0-only
// Copyright 2020 Spilsbury Holdings Ltd

pragma solidity >=0.6.0 <0.8.0;
pragma experimental ABIEncoderV2;

import {Types} from '../cryptography/Types.sol';
import {Bn254Crypto} from '../cryptography/Bn254Crypto.sol';

library Rollup1x2Vk {
    using Bn254Crypto for Types.G1Point;
    using Bn254Crypto for Types.G2Point;

    function get_verification_key() internal pure returns (Types.VerificationKey memory) {
        Types.VerificationKey memory vk;

        assembly {
            mstore(add(vk, 0x00), 2097152) // vk.circuit_size
            mstore(add(vk, 0x20), 54) // vk.num_inputs
            mstore(add(vk, 0x40),0x1ded8980ae2bdd1a4222150e8598fc8c58f50577ca5a5ce3b2c87885fcd0b523) // vk.work_root
            mstore(add(vk, 0x60),0x30644cefbebe09202b4ef7f3ff53a4511d70ff06da772cc3785d6b74e0536081) // vk.domain_inverse
            mstore(add(vk, 0x80),0x19c6dfb841091b14ab14ecc1145f527850fd246e940797d3f5fac783a376d0f0) // vk.work_root_inverse
            mstore(mload(add(vk, 0xa0)), 0x089f2f9ec5574f247773cd9524de9354ffc410256f7891268554be1f8e693b9c)//vk.Q1
            mstore(add(mload(add(vk, 0xa0)), 0x20), 0x28e755fed74eb9acd5c5900a9b7aa497798c3df9e9b551b4340a2cc8d46e4776)
            mstore(mload(add(vk, 0xc0)), 0x0f79cc629042ff5600c1c3979e84b759d8ec474a84b0e5e8f047ff7a1ce4f762)//vk.Q2
            mstore(add(mload(add(vk, 0xc0)), 0x20), 0x131812d4812b7ee0f51384d629197b310730de8c98e48e01dc4edbb8ce720b2a)
            mstore(mload(add(vk, 0xe0)), 0x0a2948d28a087675efc040ca3f6e766be85ffedd0bbaf938191a58735b919f53)//vk.Q3
            mstore(add(mload(add(vk, 0xe0)), 0x20), 0x04d38cfc53a8f14dcf6502dbe6825433d406991a6f95fdb9c2381707bebfffce)
            mstore(mload(add(vk, 0x100)), 0x02c8ee464d10fba2a0cd3f8321ecfcae53e57bc084e9dd91632ecd4fce44530d)//vk.Q4
            mstore(add(mload(add(vk, 0x100)), 0x20), 0x300b913e993f0096ade289ac782a180052f21c942f89020fe25117d9b897a434)
            mstore(mload(add(vk, 0x120)), 0x1cc6610e4d901c1b2efb78baf39ca7cee2f3f743258496d8224f7326798e8f3f)//vk.Q5
            mstore(add(mload(add(vk, 0x120)), 0x20), 0x2e12ff9cc38afe510a994a8e3ef09388d8c6545bffa7b8fdf2f012e18d9eae9a)
            mstore(mload(add(vk, 0x140)), 0x193d4da24dc0f90c290bb59b11fb994ed3c6fb60de96e8005fdc38f5794b80a2)//vk.QM
            mstore(add(mload(add(vk, 0x140)), 0x20), 0x2bea3d5fd1e75ecaa32e0ac12ae67c5057bafa7a75934f60371180ebd748ff95)
            mstore(mload(add(vk, 0x160)), 0x23ca5ab5f424086cc312747a8e0ded34433aa1b20b8ff707ec262c123a9ebbcc)//vk.QC
            mstore(add(mload(add(vk, 0x160)), 0x20), 0x147012494df90245696c6049ee1628634364822775754f56ad215b667fb765b6)
            mstore(mload(add(vk, 0x180)), 0x191146a2d3e59c3d31e7444e0268ae4b0334fc7eeac82a8f021b4c6adec16d04)//vk.QARITH
            mstore(add(mload(add(vk, 0x180)), 0x20), 0x2f10d806e39139a68a26e230fc0e24a2e79ebe498e348ba7ebb5cb76333ce3c8)
            mstore(mload(add(vk, 0x1a0)), 0x21a24c79e6557a8fa1a8b081f7049e0f6fd9b4b37688d74de89f1ede6f70e374)//vk.QECC
            mstore(add(mload(add(vk, 0x1a0)), 0x20), 0x1a0681b516ba78c81d029b3c3c29d380522b284d17b0b964f42501650bb8323c)
            mstore(mload(add(vk, 0x1c0)), 0x056992c7641b978b45eb1cf2b8139432b52227069c109d9051302bdc6bfcdbe5)//vk.QRANGE
            mstore(add(mload(add(vk, 0x1c0)), 0x20), 0x27da97af3721c5a55db4cd6bc4eb5da13903a98d0881dbab1e5efc1794755a75)
            mstore(mload(add(vk, 0x1e0)), 0x1a1d899e69c719d5d2eba27a959ab7d74c9aa2b56d00753c652aa03e0a85e1ea)//vk.QLOGIC
            mstore(add(mload(add(vk, 0x1e0)), 0x20), 0x0ae467c4b14330c34b83af5dda62db9947c6b7fe9c8a0c0909309262be6461dd)
            mstore(mload(add(vk, 0x200)), 0x09921c1b8d19f13dbbad801b4bf56e1050d3988c625c3bd4d4102d319afdad30)//vk.SIGMA1
            mstore(add(mload(add(vk, 0x200)), 0x20), 0x022f296f130c153f4d60df226b6b7ed644937a82604d5c07b83254784275c960)
            mstore(mload(add(vk, 0x220)), 0x11bc1c01feb6c3f47e1649ac55a8418ee8db28d15f139c11e86c866b6a0baf61)//vk.SIGMA2
            mstore(add(mload(add(vk, 0x220)), 0x20), 0x14fda391fcb5e17ec2f102533af8dd7215df6fdbad577d38dcb81e2a0677920a)
            mstore(mload(add(vk, 0x240)), 0x21de16dbcb85d2434db275d447c2d5414a286833790a2269c3b3bfd2ce994ac6)//vk.SIGMA3
            mstore(add(mload(add(vk, 0x240)), 0x20), 0x2197dd265117b03d019b8d9523de628f21a1e4d31c63130ed61a984ebeba060d)
            mstore(mload(add(vk, 0x260)), 0x281a7bb70c708f81a2403175e43f306a38bb62c01460923d2f456a5dd69f1a99)//vk.SIGMA4
            mstore(add(mload(add(vk, 0x260)), 0x20), 0x1f4613a6e7b2830ecd0ef205b363dea6765f56697dee470ae0438a5f87669ca7)
            mstore(add(vk, 0x280), 0x01) // vk.contains_recursive_proof
            mstore(add(vk, 0x2a0), 38) // vk.recursive_proof_public_input_indices
            mstore(mload(add(vk, 0x2c0)), 0x260e01b251f6f1c7e7ff4e580791dee8ea51d87a358e038b4efe30fac09383c1) // vk.g2_x.X.c1
            mstore(add(mload(add(vk, 0x2c0)), 0x20), 0x0118c4d5b837bcc2bc89b5b398b5974e9f5944073b32078b7e231fec938883b0) // vk.g2_x.X.c0
            mstore(add(mload(add(vk, 0x2c0)), 0x40), 0x04fc6369f7110fe3d25156c1bb9a72859cf2a04641f99ba4ee413c80da6a5fe4) // vk.g2_x.Y.c1
            mstore(add(mload(add(vk, 0x2c0)), 0x60), 0x22febda3c0c0632a56475b4214e5615e11e6dd3f96e6cea2854a87d4dacc5e55) // vk.g2_x.Y.c0
        }
        return vk;
    }
}
