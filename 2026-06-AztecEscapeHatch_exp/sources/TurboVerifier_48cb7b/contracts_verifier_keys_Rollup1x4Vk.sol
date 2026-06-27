// SPDX-License-Identifier: GPL-2.0-only
// Copyright 2020 Spilsbury Holdings Ltd

pragma solidity >=0.6.0 <0.8.0;
pragma experimental ABIEncoderV2;

import {Types} from '../cryptography/Types.sol';
import {Bn254Crypto} from '../cryptography/Bn254Crypto.sol';

library Rollup1x4Vk {
    using Bn254Crypto for Types.G1Point;
    using Bn254Crypto for Types.G2Point;

    function get_verification_key() internal pure returns (Types.VerificationKey memory) {
        Types.VerificationKey memory vk;

        assembly {
            mstore(add(vk, 0x00), 4194304) // vk.circuit_size
            mstore(add(vk, 0x20), 78) // vk.num_inputs
            mstore(add(vk, 0x40),0x1ad92f46b1f8d9a7cda0ceb68be08215ec1a1f05359eebbba76dde56a219447e) // vk.work_root
            mstore(add(vk, 0x60),0x30644db14ff7d4a4f1cf9ed5406a7e5722d273a7aa184eaa5e1fb0846829b041) // vk.domain_inverse
            mstore(add(vk, 0x80),0x2eb584390c74a876ecc11e9c6d3c38c3d437be9d4beced2343dc52e27faa1396) // vk.work_root_inverse
            mstore(mload(add(vk, 0xa0)), 0x28e2dc4d41a97418b68e76d6518ac79b13e390c7b6b568af036dcb271378b597)//vk.Q1
            mstore(add(mload(add(vk, 0xa0)), 0x20), 0x073ce114861cdaaae4313b903d7eb7d2a2ea38a0b6918de16dee1ff36ca3ffcf)
            mstore(mload(add(vk, 0xc0)), 0x102861c039336568f0f963bd87e55f6b408b9f61f605cf41d3ee095c555f9a68)//vk.Q2
            mstore(add(mload(add(vk, 0xc0)), 0x20), 0x18a0fc6b4cba424f2559bac0194a9d05e5c89fb6c3173353bb7dcfe08425f5ec)
            mstore(mload(add(vk, 0xe0)), 0x25a6c4eb8bd3fb96a99f199728fad649124cedda2812c7d7b7ad61020389c462)//vk.Q3
            mstore(add(mload(add(vk, 0xe0)), 0x20), 0x0f5473a71a3ab78bb549c7c66cc82b900c12a3f92001861b668bd79320efc2c7)
            mstore(mload(add(vk, 0x100)), 0x241b70a4499449eaf96a4f252229e5d64fc24982043eb821775af1f56b7b8d18)//vk.Q4
            mstore(add(mload(add(vk, 0x100)), 0x20), 0x2174bbccc30bd0226139395a16f13ff1386a291141516e84c69e535787f35bd6)
            mstore(mload(add(vk, 0x120)), 0x1eea328645f3f0b06d737700081814c40be1ac776a7c5dbd41e3a3f54b5427a1)//vk.Q5
            mstore(add(mload(add(vk, 0x120)), 0x20), 0x1337a66dcf19958a704528d3419992e95ce6c039ce5b4afc9ef56eaba14af289)
            mstore(mload(add(vk, 0x140)), 0x1cbb6f35d89df061c34702519ba37d94177400cd1f9240445bf8cb09b0355f6d)//vk.QM
            mstore(add(mload(add(vk, 0x140)), 0x20), 0x2daa9313384117ce327bc20fef03732470d4f71bdb437672b5d7bc2d58ca735e)
            mstore(mload(add(vk, 0x160)), 0x27be02bddae7b8e9bc832daa5f51a8187efa2efc05138aee807c5e677973e4c4)//vk.QC
            mstore(add(mload(add(vk, 0x160)), 0x20), 0x0c6b670a901b6c661f4dc10db0dbae393bf06e2f7b2740c81533252ff6ead495)
            mstore(mload(add(vk, 0x180)), 0x104fecd620915be515c6a194db63d530ae08cbe7a4bb4e4a33b4f5d87ade4590)//vk.QARITH
            mstore(add(mload(add(vk, 0x180)), 0x20), 0x29aa75228021bd8e0abd3385cdd5c51e9837ce83f8ac937b37e9f31f2ab23f3f)
            mstore(mload(add(vk, 0x1a0)), 0x1199f06997fcc01ae52b41e729780ce67ce20975d9bb24eab31c480cd4450594)//vk.QECC
            mstore(add(mload(add(vk, 0x1a0)), 0x20), 0x22a9eaa0251518928f8544fda7b1dcee93203094aeb02989644c5153dbba5e8f)
            mstore(mload(add(vk, 0x1c0)), 0x0cc6f3e6965a94ab887425127d1724d1e9cd8a60480136e3d80fb7f2ba064d36)//vk.QRANGE
            mstore(add(mload(add(vk, 0x1c0)), 0x20), 0x227de08ed5cce6383680cfe72a723135d18fee7a3836f305992e233ae6e2b4ac)
            mstore(mload(add(vk, 0x1e0)), 0x0e245970f42b60ad8c293dd6ff3d4dd45f9854a622c28302eafc57a38134947d)//vk.QLOGIC
            mstore(add(mload(add(vk, 0x1e0)), 0x20), 0x2f3640e7f19d74c928a1ff12006aacfb0963cafe61f56c32e3f78e7fea95d881)
            mstore(mload(add(vk, 0x200)), 0x1fd2ac486e1afef0d98e7723f856c6f0c2ad623fd947d00a470df056f03b0bb5)//vk.SIGMA1
            mstore(add(mload(add(vk, 0x200)), 0x20), 0x031e0c2054fc8b2a321f4aedae68aa10070786dd75d5a5a9d7fbd20652b1ddda)
            mstore(mload(add(vk, 0x220)), 0x20590efe268ded4948bf54eb33610a1dff4f53feb6a42add8d9eb82f66b15b21)//vk.SIGMA2
            mstore(add(mload(add(vk, 0x220)), 0x20), 0x02bc6f5bc1a5c496e549ba69484d3d446e5ac87a07b6c2e1322312359b4caf86)
            mstore(mload(add(vk, 0x240)), 0x1df08b11a5c4a05f29f678763174324c82b0d44e14904cf887e8bc14372d8c5c)//vk.SIGMA3
            mstore(add(mload(add(vk, 0x240)), 0x20), 0x1d634a44443161c06a84d6933d16df1656a06f54997d25738b06e191650ac4b8)
            mstore(mload(add(vk, 0x260)), 0x09718fbc5952c990dba4fa5a78e59d4dff589ba50adad3ca79b5418b54f905df)//vk.SIGMA4
            mstore(add(mload(add(vk, 0x260)), 0x20), 0x1d20b1a67fcd758e2e188277e4c290c0d33b90fa2a3cbd5f4a3354147f4eb2c9)
            mstore(add(vk, 0x280), 0x01) // vk.contains_recursive_proof
            mstore(add(vk, 0x2a0), 62) // vk.recursive_proof_public_input_indices
            mstore(mload(add(vk, 0x2c0)), 0x260e01b251f6f1c7e7ff4e580791dee8ea51d87a358e038b4efe30fac09383c1) // vk.g2_x.X.c1
            mstore(add(mload(add(vk, 0x2c0)), 0x20), 0x0118c4d5b837bcc2bc89b5b398b5974e9f5944073b32078b7e231fec938883b0) // vk.g2_x.X.c0
            mstore(add(mload(add(vk, 0x2c0)), 0x40), 0x04fc6369f7110fe3d25156c1bb9a72859cf2a04641f99ba4ee413c80da6a5fe4) // vk.g2_x.Y.c1
            mstore(add(mload(add(vk, 0x2c0)), 0x60), 0x22febda3c0c0632a56475b4214e5615e11e6dd3f96e6cea2854a87d4dacc5e55) // vk.g2_x.Y.c0
        }
        return vk;
    }
}
