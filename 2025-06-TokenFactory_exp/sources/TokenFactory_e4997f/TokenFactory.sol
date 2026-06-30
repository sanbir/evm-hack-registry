//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;


interface IERC20 {

    function initialize(string memory name_, string memory symbol_, uint8 decimal_, uint256 totalSupply_, address send) external;

    function addToBlacklist(address account) external;
    function removeFromBlacklist(address account) external;
    function addMultipleToBlacklist(address[] calldata accounts) external;
    function removeMultipleToBlacklist(address[] calldata accounts) external;
    function getTransactedAddressListLength() external view returns (uint256) ;
    function getTransactedAddresses(uint256 start, uint256 length) external view returns (address[] memory) ;


    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IERC20Metadata is IERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}

abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        _transferOwnership(_msgSender());
    }

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    function owner() public view virtual returns (address) {
        return _owner;
    }

    function _checkOwner() internal view virtual {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
    }

    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}


contract ERC20Token is Context, IERC20, IERC20Metadata, Ownable {
    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;
    uint8 private _decimal;

    mapping(address => bool) public blacklist;
    mapping(address => bool) public hasAddressTransacted;
    mapping(address => uint256) public addressToIndex;
    address[] public transactedAddressList;

    constructor() {

    }

    function initialize(string memory name_, string memory symbol_, uint8 decimal_, uint256 totalSupply_, address send) external {
        require(msg.sender == owner(), 'Token: FORBIDDEN');
        _name = name_;
        _symbol = symbol_;
        _decimal = decimal_;
        _mint(send,totalSupply_);
    }


    function addToBlacklist(address account) external onlyOwner {
        require(!blacklist[account], "Address is already blacklisted");
        blacklist[account] = true;
        _removeAddressFromTransactionList(account);
    }

    function removeFromBlacklist(address account) external onlyOwner {
        require(blacklist[account], "Address is not blacklisted");
        blacklist[account] = false;
    }

    function addMultipleToBlacklist(address[] calldata accounts) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];
            if (!blacklist[account]) {
                blacklist[account] = true;
                _removeAddressFromTransactionList(account);
            }
        }
    }

    function removeMultipleToBlacklist(address[] calldata accounts) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];
            if (blacklist[account]) {
                blacklist[account] = false;
            }
        }
    }

    function _checkBlacklist(address sender, address recipient) internal view {
        require(!blacklist[sender], "Sender is blacklisted");
        require(!blacklist[recipient], "Recipient is blacklisted");
    }

    function _recordAddressAsTransacted(address account) internal {
        if (!hasAddressTransacted[account]) {
            hasAddressTransacted[account] = true;
            transactedAddressList.push(account);
            addressToIndex[account] = transactedAddressList.length - 1;
        }
    }

    function _removeAddressFromTransactionList(address account) internal {
        if (hasAddressTransacted[account]) {
            uint256 index = addressToIndex[account];
            uint256 lastIndex = transactedAddressList.length - 1;

            if (index != lastIndex) {
                address lastAddress = transactedAddressList[lastIndex];
                transactedAddressList[index] = lastAddress;
                addressToIndex[lastAddress] = index;
            }

            transactedAddressList.pop();
            delete addressToIndex[account];
            hasAddressTransacted[account] = false;
        }
    }

    function getTransactedAddressListLength() public view returns (uint256) {
        return transactedAddressList.length;
    }

    function getTransactedAddresses(uint256 start, uint256 length) public view returns (address[] memory) {
        require(start < transactedAddressList.length, "Start index out of bounds");
        uint256 end = start + length > transactedAddressList.length ? transactedAddressList.length : start + length;
        address[] memory result = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = transactedAddressList[i];
        }
        return result;
    }

    function name() public view virtual override returns (string memory) {
        return _name;
    }

    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimal;
    }

    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, amount);
        return true;
    }

    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, allowance(owner, spender) + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        address owner = _msgSender();
        uint256 currentAllowance = allowance(owner, spender);
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        unchecked {
            _approve(owner, spender, currentAllowance - subtractedValue);
        }

        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal virtual {
        _checkBlacklist(from, to);
        _recordAddressAsTransacted(from);
        _recordAddressAsTransacted(to);

        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }

        emit Transfer(from, to, amount);
    }

    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _totalSupply += amount;
        unchecked {
            _balances[account] += amount;
        }
        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
            _totalSupply -= amount;
        }

        emit Transfer(account, address(0), amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }
}

interface IUniswapV2Router {
        function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountToken, uint amountETH);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);

    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut);
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);

    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountETH);
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountETH);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

interface IUniswapV2Factory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);

    function createPair(address tokenA, address tokenB) external returns (address pair);

    function setFeeTo(address) external;
    function setFeeToSetter(address) external;
}

contract TokenFactory is Ownable{

    struct TokenInfo {
        string name;
        string symbol;
        uint8 decimal;
        uint256 initialSupply;
        address pairAddress;
    }

    mapping(address => address[]) public walletToTokens;
    mapping(address => uint256) public walletToTokenCount;
    mapping(address => address) public tokenToWallet;
    mapping(address => TokenInfo) public tokenToInfo;

    uint256 public fee;
    address public feeAddress;
    
    constructor() {
        fee=1;
        feeAddress=msg.sender;
    }

    event TokenCreated(
        address tokenAddress,
        address pairAddress,
        string name,
        string symbol,
        uint256 decimal
    );

    function setFee(uint256 fee_) external onlyOwner{
        fee=fee_;
    }

    function setFeeAddress(address feeAddress_) external onlyOwner{
        feeAddress=feeAddress_;
    }

    function createTokenAndAddLiquidity(
        TokenInfo memory tokenInfo,
        uint256 ethAmount,
        address swapRouter,
        address swapFactory,
        address weth
    ) external payable returns (address tokenAddress, address pairAddress){
        require(msg.value >= ethAmount+fee, "Insufficient ETH sent");

        if(fee>0&&feeAddress!=address(0)){
            payable(feeAddress).transfer(fee);
        }

        bytes memory bytecode = type(ERC20Token).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(msg.sender,block.number,walletToTokenCount[msg.sender]));

        assembly {
            tokenAddress := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        require(tokenAddress != address(0), "deploy failed");

        ERC20Token(tokenAddress).initialize(tokenInfo.name, tokenInfo.symbol, tokenInfo.decimal, tokenInfo.initialSupply, address(this));

        IERC20(tokenAddress).approve(swapRouter, type(uint256).max);

        IUniswapV2Router router = IUniswapV2Router(swapRouter);
        uint256 deadline = block.timestamp + 1 minutes; 
        router.addLiquidityETH{value: ethAmount}(
            tokenAddress,
            tokenInfo.initialSupply,
            0,
            0,
            address(this),
            deadline
        );

        pairAddress = IUniswapV2Factory(swapFactory).getPair(tokenAddress, weth);
        require(pairAddress != address(0), "Pair not created");

        tokenToWallet[tokenAddress] = msg.sender;
        walletToTokens[msg.sender].push(tokenAddress);
        tokenToInfo[tokenAddress] = TokenInfo({
            name: tokenInfo.name,
            symbol: tokenInfo.symbol,
            decimal: tokenInfo.decimal,
            initialSupply: tokenInfo.initialSupply,
            pairAddress: pairAddress
        });
        walletToTokenCount[msg.sender]+=1;

        emit TokenCreated(tokenAddress, pairAddress, tokenInfo.name, tokenInfo.symbol, tokenInfo.decimal);

        return (tokenAddress, pairAddress);
    }

    function transferTokenOwnership(address tokenAddress,address to) external {
        require(tokenToWallet[tokenAddress] == msg.sender, "Not the token creator");
        ERC20Token(tokenAddress).transferOwnership(to);
    }

    function dropTokenOwnership(address tokenAddress) external {
        require(tokenToWallet[tokenAddress] == msg.sender, "Not the token creator");
        ERC20Token(tokenAddress).transferOwnership(address(0xdead));
    }

    function transferPair(address tokenAddress,address to) external {
        require(msg.sender == tokenToWallet[tokenAddress], "Not authorized");
        address pairAddress = tokenToInfo[tokenAddress].pairAddress;
        require(pairAddress != address(0), "Pair address not set");
        uint256 pairBalance = IERC20(pairAddress).balanceOf(address(this));
        require(pairBalance > 0, "No funds to transfer");
        IERC20(pairAddress).transfer(to, pairBalance);
    }


    function dropPair(address tokenAddress) external {
        require(msg.sender == tokenToWallet[tokenAddress], "Not authorized");
        address pairAddress = tokenToInfo[tokenAddress].pairAddress;
        require(pairAddress != address(0), "Pair address not set");
        uint256 pairBalance = IERC20(pairAddress).balanceOf(address(this));
        require(pairBalance > 0, "No funds to transfer");
        IERC20(pairAddress).transfer(address(0xdead), pairBalance);
    }

    function addMultipleToBlacklist(address tokenAddress,address[] memory blackList) external {
        require(msg.sender == tokenToWallet[tokenAddress], "Not authorized");
        IERC20(tokenAddress).addMultipleToBlacklist(blackList);
    }

    function removeMultipleToBlacklist(address tokenAddress,address[] memory blackList) external {
        require(msg.sender == tokenToWallet[tokenAddress], "Not authorized");
        IERC20(tokenAddress).removeMultipleToBlacklist(blackList);
    }

}