// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  ULTI — active pumper bonus is 0.03% instead of 3% (Pashov H-01, November 2024)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: ACTIVE_PUMPERS_BONUS_PERCENTAGE is 3 (ULTI_NUMBER / 10) but the
    bonus multiplies by (10000 + 3) / 10000. On a 10000 token guardian bonus the
    pumper receives 10003 instead of 10300. 297 tokens stay in the distributor. */

contract UltiToken {
    string public symbol = "ULTI";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract Distributor {
    uint256 public constant ACTIVE_PUMPERS_BONUS_PERCENTAGE = 3;
    UltiToken public token;
    mapping(address => bool) public isActivePumper;
    uint256 public lastPaid;

    constructor(UltiToken token_) {
        token = token_;
    }

    function setActive(address pumper) external {
        isActivePumper[pumper] = true;
    }

    function allocate(address contributor, uint256 bonus) external returns (uint256 paid) {
        if (isActivePumper[contributor] && bonus > 0) {
            paid = bonus * (10000 + ACTIVE_PUMPERS_BONUS_PERCENTAGE) / 10000; // @> VULN: denominator 10000 turns the +3 bonus into 0.03%
            // FIX: paid = bonus * (100 + ACTIVE_PUMPERS_BONUS_PERCENTAGE) / 100;
        }
        lastPaid = paid;
        token.transfer(contributor, paid);
    }
}

contract Pumper {}

contract Exploit {
    UltiToken public token; // CREATE nonce 1
    Distributor public distributor; // CREATE nonce 2
    Pumper public pumper; // CREATE nonce 3
    uint256 public shortfall;

    constructor() {
        token = new UltiToken();
        distributor = new Distributor(token);
        pumper = new Pumper();
        token.mint(address(distributor), 10300 ether);
    }

    function run() external {
        distributor.setActive(address(pumper));
        uint256 base = 10000 ether;
        distributor.allocate(address(pumper), base);
        uint256 intended = base * 103 / 100;
        shortfall = intended - distributor.lastPaid();
        require(distributor.lastPaid() == 10003 ether, "paid");
        require(shortfall == 297 ether, "shortfall");
        require(token.balanceOf(address(pumper)) == 10003 ether, "pumper balance");
        require(token.balanceOf(address(distributor)) == 297 ether, "retained");
    }
}
