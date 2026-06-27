// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// ═══════════════════════════════════════════════════════════════════════════════
//  AISOTH — Remix Deployment Version (Simplified)
//  Buy 2% · Sell 3% · Multi-Pool · Governance · PCS · BSC
//
//  Security features:
//  [SEC-01] setIsPool: onlyGov — no arbitrary pool marking
//  [SEC-02] _transfer: DEAD bypass (blacklist removed)
//  [SEC-03] burnPool: capped + 24h window limits
//  [SEC-04] MAX_TAX_RATIO = 10% — governance cannot raise sell tax beyond 10%
//  [SEC-05] MintingManager capped at MAX_SUPPLY
//  [SEC-06] taxActive cannot be turned off while any tax ratio is non-zero
// ═══════════════════════════════════════════════════════════════════════════════

// ─── PancakeSwap Interfaces ──────────────────────────────────────────────────

interface IERC20 {

    function totalSupply() external view returns (uint256);

    function balanceOf(address) external view returns (uint256);

    function transfer(address, uint256) external returns (bool);

    function allowance(address, address) external view returns (uint256);

    function approve(address, uint256) external returns (bool);

    function transferFrom(address, address, uint256) external returns (bool);

}

interface IPancakeRouter {

    function factory() external pure returns (address);

    function WETH() external pure returns (address);

    function swapExactTokensForETH(
        uint256 amountIn, uint256 amountOutMin,
        address[] calldata path, address to, uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactETHForTokens(
        uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external view returns (uint256[] memory amounts);

    function addLiquidity(
        address tokenA, address tokenB,
        uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function addLiquidityETH(
        address token, uint256 amountTokenDesired,
        uint256 amountTokenMin, uint256 amountETHMin,
        address to, uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

}

interface IPancakeFactory {

    function getPair(address, address) external view returns (address);

    function createPair(address, address) external returns (address);

}

interface IPancakePair {

    function getReserves() external view returns (uint256, uint256, uint256);

    function sync() external;

}

// ─── Roles ──────────────────────────────────────────────────────────────────

abstract contract Context {
    function _msgSender() internal view virtual returns (address) { return msg.sender; }
}

abstract contract Ownable is Context {
    address public governance;
    address public multisig;
    event OwnershipTransferred(address indexed previousGov, address indexed newGov);
    event MultisigUpdated(address indexed multisig);
    constructor() {
        governance = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }
    modifier onlyGov() {
        require(_msgSender() == governance || _msgSender() == multisig, "AISOTH: not governance");
        _;
    }
    function owner() external view returns (address) { return governance; }

    function transferOwnership(address _newOwner) external onlyGov {
        require(_newOwner != address(0), "AISOTH: zero address");
        emit OwnershipTransferred(governance, _newOwner);
        governance = _newOwner;
        multisig = address(0);
        emit MultisigUpdated(address(0));
    }

    function transferGovernance(address _newGov) external onlyGov {
        require(_newGov != address(0), "AISOTH: zero address");
        emit OwnershipTransferred(governance, _newGov);
        governance = _newGov;
        multisig = address(0);
        emit MultisigUpdated(address(0));
    }

    function setMultisig(address _ms) external onlyGov {
        multisig = _ms;
        emit MultisigUpdated(_ms);
    }

    /// @notice Permanently relinquish all governance control.
    /// @dev IRREVERSIBLE — sets both governance and multisig to address(0).
    ///      After calling, no further admin operations are possible on this contract.
    ///      WARNING: once executed, the contract becomes immutable and cannot be
    ///      upgraded, paused, or recovered.
    function renounceOwnership() external onlyGov {
        emit OwnershipTransferred(governance, address(0));
        governance = address(0);
        multisig = address(0);
    }
}

abstract contract MinterRole is Ownable {
    address public mintingManager;
    event MintingManagerSet(address indexed oldMinter, address indexed newMinter);

    modifier onlyMinter() {
        require(_msgSender() == mintingManager, "AISOTH: not minter");
        _;
    }

    function setMintingManager(address _minter) external onlyGov {
        require(_minter != address(0), "AISOTH: zero minter");
        emit MintingManagerSet(mintingManager, _minter);
        mintingManager = _minter;
    }
}

contract ERC20 is Context, IERC20 {

    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;

    string private _symbol;

    event Transfer(address indexed from, address indexed to, uint256 value);

    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    function name() public view returns (string memory) { return _name; }

    function symbol() public view returns (string memory) { return _symbol; }

    function decimals() public pure returns (uint8) { return 18; }

    function totalSupply() public view override returns (uint256) { return _totalSupply; }

    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), to, amount);
        return true;
    }

    function allowance(address owner_, address spender) public view override returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, _msgSender(), amount);
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(from != address(0), "ERC20: transfer from zero");
        require(to != address(0), "ERC20: transfer to zero");
        _beforeTokenTransfer(from, to, amount);
        uint256 fromBal = _balances[from];
        require(fromBal >= amount, "ERC20: insufficient balance");
        _balances[from] = fromBal - amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to zero");
        _beforeTokenTransfer(address(0), account, amount);
        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from zero");
        _beforeTokenTransfer(account, address(0), amount);
        uint256 accBal = _balances[account];
        require(accBal >= amount, "ERC20: burn exceeds balance");
        _balances[account] = accBal - amount;
        _totalSupply -= amount;
        emit Transfer(account, address(0), amount);
    }

    function _approve(address owner_, address spender, uint256 amount) internal virtual {
        require(owner_ != address(0), "ERC20: approve from zero");
        require(spender != address(0), "ERC20: approve to zero");
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    function _spendAllowance(address owner_, address spender, uint256 amount) internal virtual {
        uint256 currAllow = _allowances[owner_][spender];
        if (currAllow != type(uint256).max) {
            require(currAllow >= amount, "ERC20: insufficient allowance");
            _allowances[owner_][spender] = currAllow - amount;
            emit Approval(owner_, spender, _allowances[owner_][spender]);
        }
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender] + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        uint256 currAllow = _allowances[_msgSender()][spender];
        require(currAllow >= subtractedValue, "ERC20: decreased allowance below zero");
        _approve(_msgSender(), spender, currAllow - subtractedValue);
        return true;
    }

    function _beforeTokenTransfer(address, address, uint256) internal virtual {}

}

// ─── AISOTH Token ────────────────────────────────────────────────────────────

contract AISOTH is ERC20, Ownable, MinterRole {

    // ─── Constants ───────────────────────────────────────────────────────────

    uint256 public constant BASIS_POINTS = 10000;

    // [SEC-TAX] Max sell tax capped at 10% (1000 bp)
    uint256 public constant MAX_TAX_RATIO = 1000;

    uint256 public constant MAX_BURN_POOL_PCT = 200;

    uint256 public constant MAX_DAILY_BURN_PCT = 1000; // 10% per pool per 24h

    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10**18; // 1B

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ─── PancakeSwap ─────────────────────────────────────────────────────────

    address public pcsRouter;

    address public pcsFactory;

    address public quoteToken;

    function getPCSROUTER() external view returns (address) { return pcsRouter; }

    function getQuoteToken() external view returns (address) { return quoteToken; }

    function getPCSPAIR() external view returns (address) {
        if (pcsFactory == address(0) || quoteToken == address(0)) {
            return address(0);
        }
        return IPancakeFactory(pcsFactory).getPair(address(this), quoteToken);
    }

    function verifyPCSPair(address _tokenA, address _tokenB) external view returns (bool) {
        if (pcsFactory == address(0)) return false;
        return IPancakeFactory(pcsFactory).getPair(_tokenA, _tokenB) != address(0);
    }

    // ─── Taxes ───────────────────────────────────────────────────────────────

    uint256 public buyRatio  = 200;  // 2%

    uint256 public sellRatio = 300;  // 3%

    uint256 public maxBuyTax  = 500;  // 5%

    uint256 public maxSellTax = 1000; // 10%

    // [SEC-TAX-GUARD] Cannot turn taxes OFF if any tax rate is non-zero
    bool public taxActive = true;

    // ─── Addresses ───────────────────────────────────────────────────────────

    address public treasury;

    address public reserveFund;

    address public lpPool;

    mapping(address => bool) public isPool;

    mapping(address => bool) public whitelist;

    mapping(address => bool) public taxExempt;

    // ─── Transaction & Wallet Limits ────────────────────────────────────────

    bool public maxWalletEnabled;

    bool public maxTxEnabled;

    uint256 public maxWallet = type(uint256).max;

    uint256 public maxTx    = type(uint256).max;

    // ─── Pool Burn Rate-Limiting ─────────────────────────────────────────────

    mapping(address => uint256) public lastBurnTime;
    mapping(address => uint256) public dailyBurnAmt;

    // ─── Events ─────────────────────────────────────────────────────────────

    event TreasurySet(address indexed treasury);

    event ReserveFundSet(address indexed reserveFund);

    event LpPoolSet(address indexed lpPool);

    event TargetPoolSet(address indexed pool, bool active);

    event BuyTaxChanged(uint256 ratio);

    event SellTaxChanged(uint256 ratio);

    event TaxToggled(bool active);

    event WhitelistAdded(address indexed addr);

    event WhitelistRemoved(address indexed addr);

    event PoolBurned(uint256 amount, address indexed pool);

    event TaxDustBurned(uint256 dust);

    event MaxWalletSet(uint256 maxWallet);

    event MaxTxSet(uint256 maxTx);

    event MaxWalletToggled(bool enabled);

    event MaxTxToggled(bool enabled);

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor() ERC20("AISOTH", "AIS") {}

    /// @notice Mint tokens — only MintingManager can call
    /// @dev Minting capped at MAX_SUPPLY (1B tokens)
    function mint(address to, uint256 amount) external onlyMinter {
        require(totalSupply() + amount <= MAX_SUPPLY, "AISOTH: exceeds max supply");
        _mint(to, amount);
    }

    // ─── Transfer Hook ────────────────────────────────────────────────────

    function _transfer(address _from, address _to, uint256 _amount) internal override {

        if (_to == DEAD) {
            super._transfer(_from, _to, _amount);
            return;
        }

        if (maxWalletEnabled && !isPool[_to] && _to != governance && _to != multisig && !whitelist[_to]) {
            require(balanceOf(_to) + _amount <= maxWallet, "AISOTH: max wallet exceeded");
        }

        if (maxTxEnabled && _from != governance && _from != multisig && !whitelist[_from]) {
            require(_amount <= maxTx, "AISOTH: tx amount exceeds limit");
        }

        uint256 tax = 0;

        if (taxActive && !taxExempt[_from] && !taxExempt[_to]) {
            if (isPool[_from] && !whitelist[_to]) {
                tax = (_amount * buyRatio) / BASIS_POINTS;
            } else if (isPool[_to] && !whitelist[_from]) {
                tax = (_amount * sellRatio) / BASIS_POINTS;
            }
        }

        if (tax > 0) {
            // Tax split: 5% reserve | 10% LP | 5% DEAD | 80% treasury
            uint256 toReserve  = (tax * 500)  / BASIS_POINTS;
            uint256 toLp       = (tax * 1000) / BASIS_POINTS;
            uint256 toBurn     = (tax * 500)  / BASIS_POINTS;
            uint256 toTreasury = (tax * 8000) / BASIS_POINTS;
            uint256 dust       = tax - toReserve - toLp - toBurn - toTreasury;

            super._transfer(_from, address(this), tax);

            if (toReserve > 0) {
                address rDest = isPool[reserveFund] ? DEAD : (reserveFund == address(0) ? DEAD : reserveFund);
                super._transfer(address(this), rDest, toReserve);
            }

            if (toLp > 0) {
                address lDest = isPool[lpPool] ? DEAD : (lpPool == address(0) ? DEAD : lpPool);
                super._transfer(address(this), lDest, toLp);
            }

            if (toBurn > 0) {
                super._transfer(address(this), DEAD, toBurn);
            }

            if (toTreasury > 0) {
                address tDest = isPool[treasury] ? DEAD : (treasury == address(0) ? DEAD : treasury);
                super._transfer(address(this), tDest, toTreasury);
            }

            if (dust > 0) {
                super._transfer(address(this), DEAD, dust);
                emit TaxDustBurned(dust);
            }

            _amount -= tax;
        }

        super._transfer(_from, _to, _amount);
    }

    // ─── Pool Burn ──────────────────────────────────────────────────────────

    function burnPool(address _pool, uint256 _pct) external onlyGov {
        require(_pct <= MAX_BURN_POOL_PCT, "AISOTH: pct too high");
        require(isPool[_pool], "AISOTH: not a pool");

        uint256 last = lastBurnTime[_pool];

        if (last == 0 || block.timestamp >= last + 24 hours) {
            lastBurnTime[_pool] = block.timestamp;
            dailyBurnAmt[_pool] = _pct;
        } else {
            require(dailyBurnAmt[_pool] + _pct <= MAX_DAILY_BURN_PCT, "AISOTH: daily burn limit exceeded");
            dailyBurnAmt[_pool] += _pct;
        }

        uint256 lpBal = balanceOf(_pool);
        uint256 burnAmt = (lpBal * _pct) / BASIS_POINTS;
        require(burnAmt > 0, "AISOTH: nothing to burn");

        super._transfer(_pool, DEAD, burnAmt);
        IPancakePair(_pool).sync();

        emit PoolBurned(burnAmt, _pool);
    }

    function getBurnStatus(address _pool) external view returns (bool canBurn, uint256 dailyUsed, uint256 dailyLeft, uint256 resetAt) {
        uint256 last = lastBurnTime[_pool];
        if (last == 0 || block.timestamp >= last + 24 hours) {
            return (true, 0, MAX_DAILY_BURN_PCT, block.timestamp);
        }
        dailyUsed = dailyBurnAmt[_pool];
        dailyLeft = (dailyUsed >= MAX_DAILY_BURN_PCT) ? 0 : MAX_DAILY_BURN_PCT - dailyUsed;
        canBurn   = dailyUsed < MAX_DAILY_BURN_PCT;
        resetAt   = last + 24 hours;
    }

    function getPCSReserves() external view returns (uint256 r0, uint256 r1) {
        if (pcsFactory == address(0) || quoteToken == address(0)) {
            return (0, 0);
        }
        address pair = IPancakeFactory(pcsFactory).getPair(address(this), quoteToken);
        if (pair == address(0)) return (0, 0);
        (r0, r1, ) = IPancakePair(pair).getReserves();
    }

    // ─── Admin Setters ───────────────────────────────────────────────────────

    function setPancakeSwap(address _router, address _factory, address _quote) external onlyGov {
        require(_router != address(0) && _factory != address(0), "AISOTH: zero address");
        require(_quote != address(0), "AISOTH: zero quote token");
        pcsRouter    = _router;
        pcsFactory   = _factory;
        quoteToken   = _quote;
    }

    function setTreasury(address _t) external onlyGov {
        require(!isPool[_t], "AISOTH: treasury cannot be a pool");
        treasury = _t;
        emit TreasurySet(_t);
    }

    function setReserveFund(address _r) external onlyGov {
        require(!isPool[_r], "AISOTH: reserve cannot be a pool");
        reserveFund = _r;
        emit ReserveFundSet(_r);
    }

    function setLpPool(address _l) external onlyGov {
        require(!isPool[_l], "AISOTH: lpPool cannot be a pool");
        lpPool = _l;
        emit LpPoolSet(_l);
    }

    function setTargetPool(address _pool, bool _active) external onlyGov {
        require(pcsFactory != address(0) && quoteToken != address(0), "AISOTH: PCS not configured");

        if (_active) {
            address pairAB = IPancakeFactory(pcsFactory).getPair(address(this), quoteToken);
            address pairBA = IPancakeFactory(pcsFactory).getPair(quoteToken, address(this));
            require(pairAB == _pool || pairBA == _pool, "AISOTH: not a verified PCS pair");

            (uint256 r0, uint256 r1,) = IPancakePair(_pool).getReserves();
            require(!(r0 == 0 && r1 == 0), "AISOTH: pool empty");
            isPool[_pool] = true;
        } else {
            isPool[_pool] = false;
        }

        emit TargetPoolSet(_pool, _active);
    }

    function setIsPool(address _pool, bool _is) external onlyGov {
        require(_pool != address(0), "AISOTH: zero address");
        if (_is) {
            require(pcsFactory != address(0) && quoteToken != address(0), "PCS not configured");
            address pairAB = IPancakeFactory(pcsFactory).getPair(address(this), quoteToken);
            address pairBA = IPancakeFactory(pcsFactory).getPair(quoteToken, address(this));
            require(pairAB == _pool || pairBA == _pool, "AISOTH: not a verified PCS pair");
        }
        isPool[_pool] = _is;
        emit TargetPoolSet(_pool, _is);
    }

    function setBuyTax(uint256 _ratio) external onlyGov {
        require(_ratio <= maxBuyTax, "AISOTH: exceeds max buy tax");
        buyRatio = _ratio;
        emit BuyTaxChanged(_ratio);
    }

    function setSellTax(uint256 _ratio) external onlyGov {
        require(_ratio <= maxSellTax, "AISOTH: exceeds max sell tax");
        sellRatio = _ratio;
        emit SellTaxChanged(_ratio);
    }

    function setMaxBuyTax(uint256 _max) external onlyGov {
        require(_max <= MAX_TAX_RATIO, "AISOTH: max too high");
        maxBuyTax = _max;
    }

    function setMaxSellTax(uint256 _max) external onlyGov {
        require(_max <= MAX_TAX_RATIO, "AISOTH: max too high");
        maxSellTax = _max;
    }

    function setTaxActive(bool _active) external onlyGov {
        if (_active == false) {
            require(buyRatio == 0 && sellRatio == 0, "AISOTH: disable taxes first");
        }
        taxActive = _active;
        emit TaxToggled(_active);
    }

    function addWhitelist(address _addr) external onlyGov {
        whitelist[_addr] = true;
        emit WhitelistAdded(_addr);
    }

    function removeWhitelist(address _addr) external onlyGov {
        whitelist[_addr] = false;
        emit WhitelistRemoved(_addr);
    }

    function setTaxExempt(address _addr, bool _exempt) external onlyGov {
        taxExempt[_addr] = _exempt;
    }

    function burn(uint256 _amount) external onlyGov {
        _burn(msg.sender, _amount);
    }

    receive() external payable {}

    function setMaxWallet(uint256 _max) external onlyGov {
        require(_max > 0, "AISOTH: zero max wallet");
        maxWallet = _max;
        emit MaxWalletSet(_max);
    }

    function setMaxTx(uint256 _max) external onlyGov {
        require(_max > 0, "AISOTH: zero max tx");
        maxTx = _max;
        emit MaxTxSet(_max);
    }

    function toggleMaxWallet(bool _enabled) external onlyGov {
        maxWalletEnabled = _enabled;
        emit MaxWalletToggled(_enabled);
    }

    function toggleMaxTx(bool _enabled) external onlyGov {
        maxTxEnabled = _enabled;
        emit MaxTxToggled(_enabled);
    }

}