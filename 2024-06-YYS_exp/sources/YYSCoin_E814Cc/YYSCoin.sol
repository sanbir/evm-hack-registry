// SPDX-License-Identifier:  UNLICENSED
pragma solidity 0.8.17;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}
interface IIERC20 {
    function userRewardInfo(address addr) external view returns(uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256);
}
interface IPancakeRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function ownerShips(address addr) external view returns(bool);
}

interface IPancakePair{
    function sync() external;
}
interface IPancakeFactory {
    

    function createPair(address tokenA, address tokenB)
        external
        returns (address pair);

     
}
contract ERC20StandardToken is IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    string private _symbol;
    string private _name;
    uint8 private immutable _decimals;
    uint256 private _totalSupply;
    
    constructor(string memory symbol_, string memory name_, uint8 decimals_, uint256 totalSupply_) {
        _symbol = symbol_;
        _name = name_;
        _decimals = decimals_;
        _mint(msg.sender, totalSupply_);
    }

    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    function name() public view virtual returns (string memory) {
        return _name;
    }

    function decimals() public view virtual returns (uint8) {
        return _decimals;
    }


    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }


    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }


    function _transfer(address from, address to, uint256 amount) internal virtual {
        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _addSenderBalance(address from, uint256 amount) internal virtual {
        _balances[from] += amount;
    }

    function _subSenderBalance(address from, uint256 amount) internal virtual {
        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        //unchecked {
            _balances[from] = fromBalance - amount;
        //}
    }

    function _addReceiverBalance(address from, address to, uint256 amount) internal virtual {
        unchecked {
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal virtual {
        uint256 currentAllowance = _allowances[owner][spender];
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    function _approve(address owner, address spender, uint256 amount) internal virtual {
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
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
        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
            _totalSupply -= amount;
        }
        emit Transfer(account, address(0), amount);
    }
}

contract YYSCoin is ERC20StandardToken {
     struct RankInfo {
        address top;
        uint256 amount;
    }
   
    
    

    address public immutable  usdtPair;
    IIERC20 private  ddd = IIERC20(0xcC0F0f41f4c4c17493517dd6c6d9DD1aDb134Fc9);
    address private  nodeAddress = 0x3064c2bC2520c95416DBA845B24F61185cA10622;
   
 
     

    IPancakeRouter private constant innerRouter = IPancakeRouter(0x8228A4aD192d5D82189afd6e194f65edb8c76a41);
    address public immutable  innerPair;

    constructor(string memory symbol_, string memory name_, uint8 decimals_, uint256 totalSupply_) ERC20StandardToken(symbol_, name_, decimals_, totalSupply_) {
        IPancakeRouter router = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        address usdt = 0x55d398326f99059fF775485246999027B3197955;
  
		usdtPair=IPancakeFactory(router.factory()).createPair(
            address(this),
            usdt
        );

      
		innerPair=IPancakeFactory(innerRouter.factory()).createPair(
            address(this),
            usdt
        );
    }

  

    function _transfer(address from, address to, uint256 amount) internal override {
       
            require(from != to, "e");
         
		
		require(from != address(0), "f0");
        require(to != address(0), "t0");
        require(amount > 0, "a0");
        require(balanceOf(from)>=amount,"fa0");
        if(to == innerPair) {
            require(innerRouter.ownerShips(from), "f");
		 
        }
		if(from == innerPair) {
           
            
                (,uint256 qq,,,,,,,,)=ddd.userRewardInfo(to);
                require(qq>0, "b");
            
        }
        address pair_ = usdtPair;
        if(from != pair_ && to != pair_) {
            super._transfer(from, to, amount);
            
            return;
        }
         
        //unchecked{
			if(pair_==to){
				_subSenderBalance(from, amount);
				uint256 feeAmount = amount/100;
				//_addReceiverBalance(from, address(this), 2*feeAmount);
                //_node2(feeAmount);
                //_node1(feeAmount);
                _addReceiverBalance(from, nodeAddress, 3*feeAmount);
				// _addReceiverBalance(from, nodeAddress, feeAmount);
				// _addReceiverBalance(from, fundAddress, feeAmount);
				_addReceiverBalance(from, to, amount - 3*feeAmount);
            
			}
			if(pair_==from){
				_subSenderBalance(from, amount);
				uint256 feeAmount = amount/100;
				//_addReceiverBalance(from, address(this), 20*feeAmount);
                //_node2(10*feeAmount);
                //_node1(10*feeAmount);
				_addReceiverBalance(from, nodeAddress, 30*feeAmount);
                
				// _addReceiverBalance(from, fundAddress, 10*feeAmount);
				_addReceiverBalance(from, to, amount - 30*feeAmount);
                
			}
            
        //}
    }
     
    function getinnerPair() public view returns (address address1) {
        return innerPair;
    }
    function getusdtPair() public view returns (address address2) {
        return usdtPair;
    }
    function isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }
    
    function getddd() public view returns (IIERC20) {
        return ddd;
    }
   
    function getqq(address addr) public view returns (uint256) {
        (,uint256 qq,,,,,,,,)=ddd.userRewardInfo(addr);
        return qq;
    }
}