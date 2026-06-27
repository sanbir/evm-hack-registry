// SPDX-License-Identifier: GPL-2.0-only
// Copyright 2020 Spilsbury Holdings Ltd

pragma solidity >=0.6.0 <0.8.0;
pragma experimental ABIEncoderV2;

import {Types} from '../cryptography/Types.sol';
import {Bn254Crypto} from '../cryptography/Bn254Crypto.sol';

library Rollup1x1Vk {
    using Bn254Crypto for Types.G1Point;
    using Bn254Crypto for Types.G2Point;

    function get_verification_key() internal pure returns (Types.VerificationKey memory) {
        Types.VerificationKey memory vk;

        assembly {
            mstore(add(vk, 0x00), 1048576) // vk.circuit_size
            mstore(add(vk, 0x20), 42) // vk.num_inputs
            mstore(add(vk, 0x40),0x26125da10a0ed06327508aba06d1e303ac616632dbed349f53422da953337857) // vk.work_root
            mstore(add(vk, 0x60),0x30644b6c9c4a72169e4daa317d25f04512ae15c53b34e8f5acd8e155d0a6c101) // vk.domain_inverse
            mstore(add(vk, 0x80),0x100c332d2100895fab6473bc2c51bfca521f45cb3baca6260852a8fde26c91f3) // vk.work_root_inverse
            mstore(mload(add(vk, 0xa0)), 0x11797eccfd6948ebfc31afcae58930ea392337e5dc9dd3bcf4e3c2bd56e93617)//vk.Q1
            mstore(add(mload(add(vk, 0xa0)), 0x20), 0x2241a91ef11a8173f3e4951b3c7e1ae419fafe6c869e99738d5b14ee9989126f)
            mstore(mload(add(vk, 0xc0)), 0x14941ea5cba4b68b71f3105ffd4a5b368a9d67fe2f176918431a57badfebeb20)//vk.Q2
            mstore(add(mload(add(vk, 0xc0)), 0x20), 0x19e546e36f96d9a0de8f24fec0cbac99d1e55ad548359b2d4bfa6b9a98d7e94b)
            mstore(mload(add(vk, 0xe0)), 0x1e497dfcad85ad059aa922a72ef84b002a3706ef0192ba76a5a8c95d0c5f80b3)//vk.Q3
            mstore(add(mload(add(vk, 0xe0)), 0x20), 0x218bb9281146172901d8eaf2d6c9b44be64109a78af3ec85eb43a953d0ca0d71)
            mstore(mload(add(vk, 0x100)), 0x0f3d169152411947e43142d14f99b4ed497e2e4d87d9a69d39cb5e487419488b)//vk.Q4
            mstore(add(mload(add(vk, 0x100)), 0x20), 0x0b180333dae40cda462fa5cf97820a124004b615fd5d974d5f4f7bd01f83a685)
            mstore(mload(add(vk, 0x120)), 0x18d77b498bdc6785b2d248cbe17dfcd9d9e7190839d53502840d63a45ae747cd)//vk.Q5
            mstore(add(mload(add(vk, 0x120)), 0x20), 0x144df1986c1495d4d0a2fb235afb43e6fa39acf571e3626e0be6b91234efd3cd)
            mstore(mload(add(vk, 0x140)), 0x0f2527eec40ef83b72f2775a15e0919a95a2d45bdf4e62936bd429152294948c)//vk.QM
            mstore(add(mload(add(vk, 0x140)), 0x20), 0x0047c778636a21e506f97e520d5e643c36ddd5205b18c759d4db9e76a3185200)
            mstore(mload(add(vk, 0x160)), 0x2dd0486be21b59b299a912f3ace890b3adcf7f761b9441b134e1cf2f69ada728)//vk.QC
            mstore(add(mload(add(vk, 0x160)), 0x20), 0x1f474460d4e7144354c74bdacc7dd227522d931b14ec9fecd1ea8df5b776f9ad)
            mstore(mload(add(vk, 0x180)), 0x1defbdc77d4374006d627f2800375905256a04fa4d2e79fabb9d337331f5ad03)//vk.QARITH
            mstore(add(mload(add(vk, 0x180)), 0x20), 0x0629e6367556e465a5fe44d3c2964ad1ef4889c200c18c62c5fcd7ccf645c289)
            mstore(mload(add(vk, 0x1a0)), 0x03a77feaa966fab8e2f37b13c77926afd0dee9380beab8a399c267e7743764f1)//vk.QECC
            mstore(add(mload(add(vk, 0x1a0)), 0x20), 0x24e6bea13c06dea6f11612cf4d140c5f8f905ca586538ec882468f201c35e3be)
            mstore(mload(add(vk, 0x1c0)), 0x2b8f524664ebbd3bd20b1e1b6e89f9d9f75f5a4f41badc58d56ded2dee69d808)//vk.QRANGE
            mstore(add(mload(add(vk, 0x1c0)), 0x20), 0x072a92a8a92e99072c8a2a4a863ad90a32972a85967db451834f231af8c567b8)
            mstore(mload(add(vk, 0x1e0)), 0x2b3f5a828b5461b20bca52d88120c7ea369b6668ff3e1147f7fd1a757c023acb)//vk.QLOGIC
            mstore(add(mload(add(vk, 0x1e0)), 0x20), 0x1fa613eadf21d222bf645feaf9725ddf7b3d8cfc159d93b34eab566ec434ee75)
            mstore(mload(add(vk, 0x200)), 0x28fc1d455526135f45ccd99c1ce0163ff0204b2d0bfb20b93c2677805a4e584a)//vk.SIGMA1
            mstore(add(mload(add(vk, 0x200)), 0x20), 0x155e046bd3cd6bed80fe27e14b52c3efa6345a3b7f0bdf3e556ae55a47bfa2fa)
            mstore(mload(add(vk, 0x220)), 0x26288597d02f3dd11f7add2940c268e2295350abfb98b1437e2c09a41947baa2)//vk.SIGMA2
            mstore(add(mload(add(vk, 0x220)), 0x20), 0x0b03dde51e0404e0df32e9e580b9b7ce159e76ea93af976b0d151b31a5fdcdfb)
            mstore(mload(add(vk, 0x240)), 0x1a273df058ccf37082c7494ad5d0da4ad5da7a5c1b69abe7ad2e34dc5d00c2e4)//vk.SIGMA3
            mstore(add(mload(add(vk, 0x240)), 0x20), 0x024f0980fd6fba28c6b857b7b10bc89177ec047a5b8e5dcd2778c56abe70826a)
            mstore(mload(add(vk, 0x260)), 0x14407d6485af3c54c593edb5720cc9d5d76576063fae7deeff60f5e5e7bdd42e)//vk.SIGMA4
            mstore(add(mload(add(vk, 0x260)), 0x20), 0x1888e5d6820f195ab8a60862b88e41bac34d58143b8e19414a2547194a5a90f3)
            mstore(add(vk, 0x280), 0x01) // vk.contains_recursive_proof
            mstore(add(vk, 0x2a0), 26) // vk.recursive_proof_public_input_indices
            mstore(mload(add(vk, 0x2c0)), 0x260e01b251f6f1c7e7ff4e580791dee8ea51d87a358e038b4efe30fac09383c1) // vk.g2_x.X.c1
            mstore(add(mload(add(vk, 0x2c0)), 0x20), 0x0118c4d5b837bcc2bc89b5b398b5974e9f5944073b32078b7e231fec938883b0) // vk.g2_x.X.c0
            mstore(add(mload(add(vk, 0x2c0)), 0x40), 0x04fc6369f7110fe3d25156c1bb9a72859cf2a04641f99ba4ee413c80da6a5fe4) // vk.g2_x.Y.c1
            mstore(add(mload(add(vk, 0x2c0)), 0x60), 0x22febda3c0c0632a56475b4214e5615e11e6dd3f96e6cea2854a87d4dacc5e55) // vk.g2_x.Y.c0
        }
        return vk;
    }
}
