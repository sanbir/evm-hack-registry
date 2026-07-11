// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;




interface IERC20 {

    function totalSupply() external view returns (uint256);

    
    function balanceOf(address account) external view returns (uint256);

   
    
    function transfer(address recipient, uint256 amount) external returns (bool);


    function allowance(address owner, address spender) external view returns (uint256);

    
    function approve(address spender, uint256 amount) external returns (bool);

    
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    
    event Transfer(address indexed from, address indexed to, uint256 value);

   
    event Approval(address indexed owner, address indexed spender, uint256 value);
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
        this; 
        return msg.data;
    }
}

abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor () {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

   
    function owner() public view virtual returns (address) {
        return _owner;
    }

  
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

   
    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

   
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

contract WDOGE is Ownable, IERC20, IERC20Metadata {
    // VULNERABILITY SUMMARY (2022-04-Wdoge):
    // The WDOGE token implements a time-gated fee-on-transfer with reflection (redistribute 4%), burn (4%), and dev/fee fees (2%).
    // Critical flaws:
    // - Double debit on sender (full amount + burn amount).
    // - Reflection tokens created for all tracked holders, *including* PancakePair contracts.
    // - No pair/router exclusion (common safeguard missing).
    // - After the initial window, every transfer to/from the WDOGE/WBNB pair leaves balanceOf(pair) != pair's internal reserves.
    // This breaks the invariant that V2 pairs (PancakePair) rely on: reserves represent true balances.
    // Combined with public skim()/sync()/swap(), allows the reserves-out-of-sync drain documented below.
    mapping (address => BalanceOwner) private _balances;
    
    mapping (address => mapping (address => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;
    address[] private _balanceOwners;
    address feeWallet = 0x3dDC46Ea7357aE90eeD5cb1B995B1949a235F9e6;
    address dev = 0xc5598e18869B6e645093a6219f1E273cB7D3629C;
    uint256 private constant basePercent = 100;
    uint256 openingTime = 1622686000; 
    uint256 closingTime = 1623002400;    

    struct BalanceOwner {
        uint256 amount;
        bool exists;
    }

    constructor () {
        _name = "Wiener Doge ";
        _symbol = "WDOGE";

        uint256 initSupply = 10000000000000*10**18;
        _mint(msg.sender, initSupply);
    }

   
    function name() public view virtual override returns (string memory) {
        return _name;
    }

   
    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

   
     
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

  
    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    
    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account].amount;
    }

    function findOnePercent(uint256 value) public pure  returns (uint256)  {
        uint256 onePercent = value * basePercent / 10000;
        return onePercent;
    }


   
    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

  
    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

   
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    
    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = _allowances[sender][_msgSender()];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        _approve(sender, _msgSender(), currentAllowance - amount);

        return true;
    }

    
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender] + addedValue);
        return true;
    }

   
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        uint256 currentAllowance = _allowances[_msgSender()][spender];
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        _approve(_msgSender(), spender, currentAllowance - subtractedValue);

        return true;
    }

    
    function _transfer(address sender, address recipient, uint256 amount) internal virtual returns (bool) {
        require(_balances[sender].amount >= amount, "ERC20: transfer amount exceeds balance");
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        if(block.timestamp >=  openingTime && block.timestamp <= closingTime)
        {
            _balances[sender].amount -= amount;
            _balances[recipient].amount += amount;
            emit Transfer(sender, recipient, amount);
        }
        else
        {
            uint256 onePercent = findOnePercent(amount);
            uint256 tokensToBurn = onePercent *4;
            uint256 tokensToRedistribute = onePercent * 4;
            uint256 toFeeWallet = onePercent*1;
            uint256 todev = onePercent* 1;
            uint256 tokensToTransfer = amount - tokensToBurn - tokensToRedistribute - toFeeWallet-todev;

            // VULNERABILITY: fee-on-transfer + reflection (redistribute) + burn logic.
            // 1. Sender is debited FULL `amount`, then _burn subtracts ANOTHER `tokensToBurn` from sender -> over-debit.
            // 2. Recipient receives only `tokensToTransfer` (~90%). Fees siphoned to wallet/dev.
            // 3. `redistribute` CREATES tokens for other holders (including PancakePair once it holds WDOGE) by just `+=` without increasing totalSupply.
            // 4. No exclusion of DEX pairs/LPs from redistribution -> reflections accrue inside the pair contract's balanceOf.
            // Result: pair's actual balanceOf(WDOGE) diverges from its stored `reserve1` (or reserve0).
            // Standard V2 pair's skim() + sync() + swap() can then be abused because they trust balance/reserve consistency.
            _balances[sender].amount -= amount;
            _balances[recipient].amount += tokensToTransfer;
            _balances[feeWallet].amount += toFeeWallet;
            _balances[dev].amount  += todev;
            if (!_balances[recipient].exists){
                _balanceOwners.push(recipient);
                _balances[recipient].exists = true;
            }

            redistribute(sender, tokensToRedistribute);
            _burn(sender, tokensToBurn);
            emit Transfer(sender, recipient, tokensToTransfer);
        }
        return true;
    }

    function redistribute(address sender, uint256 amount) internal {
      uint256 remaining = amount;
      for (uint256 i = 0; i < _balanceOwners.length; i++) {
        if (_balances[_balanceOwners[i]].amount == 0 || _balanceOwners[i] == sender) continue;
        
        uint256 ownedAmount = _balances[_balanceOwners[i]].amount;
        // VULNERABILITY (continued): broken reflection math + pair is a normal holder.
        // ownedPercentage = total/owned (reciprocal), toReceive = amt / pct == amt * owned / total (approx due to trunc).
        // Adds directly to ANY holder's balance (incl. the WDOGE/WBNB pair contract) WITHOUT mint or reducing totalSupply.
        // When attacker transfers WDOGE into the pair, pair receives its explicit share + a redistribute share -> excess balance.
        // Anyone can then call pair.skim() to steal the excess (reflections + fee remnants) because pair has no access control on skim.
        uint256 ownedPercentage = _totalSupply / ownedAmount;
        uint256 toReceive = amount / ownedPercentage;
        if (toReceive == 0) continue;
        if (remaining < toReceive) break;        
        remaining -= toReceive;
        _balances[_balanceOwners[i]].amount += toReceive;
      }
    }

     function multiTransfer(address[] memory receivers, uint256[] memory amounts) public {
        for (uint256 i = 0; i < receivers.length; i++) {
            _transfer(msg.sender, receivers[i], amounts[i]);
        }
    }

    
    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply += amount;
        _balances[account].amount += amount;
        emit Transfer(address(0), account, amount);
    }

    
    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account].amount;
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        _balances[account].amount = accountBalance - amount;
        _totalSupply -= amount;

        emit Transfer(account, address(0), amount);
    }

    
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /*
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual { }
}