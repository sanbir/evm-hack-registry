
// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0;
import "./SafeMath.sol";
import "./Ownable.sol";
import "./IBEP20.sol";
  
contract FCNToken is Ownable
{
    using SafeMath for uint256;
    string constant  _name = 'FCN-TRUST';
    string constant _symbol = 'FCN';
    uint8 immutable _decimals = 18;
    uint256 _totalsupply;
    uint256 starttradetime=1e40;
    address _ammpool;
  
    mapping (address => mapping (address => uint256)) private _allowances;
    mapping(address=>uint256) _balances;
    mapping(address=>bool) _exclude;
    mapping(address=>bool) _whiteList;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor()
    {
        _totalsupply =  263 * 1e18;
        _balances[msg.sender] = 263 * 1e18;
        _exclude[msg.sender]=true;
        _exclude[0x58485CC3eD4F21a77e82Bf4B01ABebf58825659c]=true;
        emit Transfer(address(0),msg.sender , 263 * 1e18);
    }

    function setStarttradetime(uint256 stime) public onlyOwner 
    {
        starttradetime = stime;
    }

    function setExclude(address user,bool ok) public onlyOwner 
    {
        _exclude[user]=ok;
    }

    function setwhiteList(address user,bool ok) public onlyOwner 
    {
        _whiteList[user]= ok;
    }

    function setAMMPool(address pool) public onlyOwner 
    {
        _ammpool=pool;
    }
 
    function name() public  pure returns (string memory) {
        return _name;
    }

    function symbol() public  pure returns (string memory) {
        return _symbol;
    }

    function decimals() public pure returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view  returns (uint256) {
        return _totalsupply;
    }
 
    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function OutErrorTransfer(address tokenaddress,address to,uint256 amount) public onlyOwner
    {
        IBEP20(tokenaddress).transfer(to, amount);
    }

    function balanceOf(address account) public view  returns (uint256) {
        return _balances[account];
    }
  
    function allowance(address owner, address spender) public view  returns (uint256) {
        return _allowances[owner][spender];
    }
 
    function approve(address spender, uint256 amount) public  returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public  returns (bool) {
        _approve(sender, msg.sender, _allowances[sender][msg.sender].sub(amount, "ERC20: transfer amount exceeds allowance"));
        _transfer(sender, recipient, amount);
        return true;
    }

   function transfer(address recipient, uint256 amount) public  returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

   function increaseAllowance(address spender, uint256 addedValue) public  returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public  returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    function burnFrom(address sender, uint256 amount) public   returns (bool)
    {
        _approve(sender, msg.sender, _allowances[sender][msg.sender].sub(amount, "ERC20: transfer amount exceeds allowance"));
        _burn(sender,amount);
        return true;
    }

    function burn(uint256 amount) public  returns (bool)
    {
        _burn(msg.sender,amount);
        return true;
    }
 
    function _burn(address sender,uint256 tAmount) private
    {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(tAmount > 0, "Transfer amount must be greater than zero");
        _balances[sender] = _balances[sender].sub(tAmount);
        _balances[address(0)] = _balances[address(0)].add(tAmount); 
         emit Transfer(sender, address(0), tAmount);
    }

    function _transfer(address sender, address recipient, uint256 amount) private {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");
        _balances[sender]= _balances[sender].sub(amount);
        uint256 toamount=amount;
        if(!_exclude[sender] && !_exclude[recipient])
        { 
            require(_ammpool !=address(0),"not start trade");
             if(!_whiteList[sender] && !_whiteList[recipient] )
             {
               require(block.timestamp > starttradetime,"not start trade");
             }

              if(sender== _ammpool)
                {
                    uint256 onepct = amount.div(100);
                    _balances[address(0)] = _balances[address(0)].add(onepct.mul(5)); 
                    emit Transfer(sender, address(0), onepct.mul(5));
                    toamount=toamount.sub(onepct.mul(5));
                }

                if(recipient==_ammpool)
                {
                    uint256 onepct = amount.div(100);
                    _balances[address(0)] = _balances[address(0)].add(onepct.mul(15)); 
                    emit Transfer(sender, address(0), onepct.mul(15));
                    toamount=toamount.sub(onepct.mul(15));
                }
        }

         _balances[recipient] = _balances[recipient].add(toamount); 
         emit Transfer(sender, recipient, toamount);
        
    }
}