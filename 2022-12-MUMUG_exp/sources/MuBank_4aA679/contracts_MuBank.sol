// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface Token {
 function decimals() external view  returns (uint8);
}

interface MuMoneyMinter{
    function mint(address recipient, uint amount) external;
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}

interface Router {
    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint256[] memory amounts);
    function getAmountsIn(uint256 amountOut, address[] calldata path)external view returns (uint256[] memory amounts);
    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory amounts);  
    function swapTokensForExactTokens(uint256 amountOut,uint256 amountInMax,address[] calldata path,address to,uint256 deadline) external returns (uint256[] memory amounts);
    function addLiquidity(address tokenA,address tokenB,uint256 amountADesired,uint256 amountBDesired,uint256 amountAMin,uint256 amountBMin,address to,uint256 deadline)external returns (uint256 amountA,uint256 amountB,uint256 liquidity);
    function removeLiquidity(address tokenA,address tokenB,uint256 liquidity,uint256 amountAMin,uint256 amountBMin,address to,uint256 deadline) external returns (uint256 amountA, uint256 amountB);

    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) external pure returns (uint256 amountB);

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountOut);

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountIn);

}

interface Pair {
  function token0() external view returns (address);
  function token1() external view returns (address);
  function swap(uint256 amount0Out,	uint256 amount1Out,	address to,	bytes calldata data) external;
  function getReserves()external view returns (uint112 reserve0, uint112 reserve1);
}
interface Factory {
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);
}

contract MuBank is  Context, Ownable, ERC20, ERC20Burnable, ReentrancyGuard {

    using SafeMath for uint256;

    address[] _stable_coins;

    address private _MuMoney = 0x5EA63080E67925501c5c61B9C0581Dbd87860019;
    address _MuCoin = 0xD036414fa2BCBb802691491E323BFf1348C5F4Ba;
    address _MuGold = 0xF7ed17f0Fb2B7C9D3DDBc9F0679b2e1098993e81;

    constructor() ERC20("Mu Bank", "MuBank"){
        _stable_coins.push(0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664);//add usdc.e coin
        _stable_coins.push(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);//add usdc coin
        _stable_coins.push(0x19860CCB0A68fd4213aB9D8266F7bBf05A8dDe98);//add busd.e coin
        _stable_coins.push(0xd586E7F844cEa2F87f50152665BCbc2C279D8d70);//add dai.e coin
        _stable_coins.push(0x130966628846BFd36ff31a822705796e8cb8C18D);//add MIM coin
        _stable_coins.push(0xc7198437980c041c805A1EDcbA50c1Ce5db95118);//add usdt.e coin
    }

    function mint(address _to, uint256 amount) public onlyOwner {
        _mint(_to, amount);
    }


    //function to add a stable coin to the approved stable coins accepted for bonding
    function add_stable_coin(address stable_coin) public onlyOwner{
        _stable_coins.push(stable_coin);
    }

    //function to remove a stable coin from the approved stable coins for bonding
    function remove_stable_coin(address stable_coin) public onlyOwner{
        for(uint256 i = 0; i < _stable_coins.length; i++){
            if(_stable_coins[i] == stable_coin)
                _stable_coins[i] = _stable_coins[_stable_coins.length-1];
        }
        _stable_coins.pop();
    }

    //gives the array of all approved stable coins
    function get_stable_coins() public view returns(address[] memory stables){
        return _stable_coins;
    }

    //function that allows you to check if a stable coin is approved for bonding
    function check_if_approved_stable_coin(address stable)public view returns (bool _is_approved_stable_coin){
        return is_approved_stable_coin(stable);
    }

    function setMuMoneyAddress(address token) public onlyOwner{
        _MuMoney = token;
    }

    function showMuMoneyAddress() public view returns(address  muMoneyAddress){
        return _MuMoney;
    }

    //allows a participant to provide an approved stable coin as collertal and receive an equal amount of mu money in a bond
    function stable_coin_bond(address stable, uint256 amount) public nonReentrant{
        require(is_approved_stable_coin(stable) ,"Only accepting approved stable coins for bonding");
            IERC20 _stable = IERC20(stable);
            Token token = Token(stable);
            //decimals() external view  returns (uint8)
            uint8  _decimals = token.decimals();
            if((18 - _decimals) == 0){
                _stable.transferFrom(msg.sender, address(this), amount);
            }else{
                uint8 div = 18 - _decimals;
                _stable.transferFrom(msg.sender, address(this), (amount/10**div));
            }
            //transferFrom(address sender, address recipient, uint amount)
            MuMoneyMinter(_MuMoney).mint(_msgSender(), amount);
    }

    function recoverTokens(address tokenAddress) external onlyOwner {
		IERC20 token = IERC20(tokenAddress);
		token.transfer(msg.sender, token.balanceOf(address(this)));
	}

    //quotes the amount of Mu Coin you can get for a specific amount of approved stable coin
    function mu_bond_quote(uint256 amount) public view returns(uint256 swapAmount, uint256 bondAmount){
        return _mu_bond_quote(amount);
    }
    //quotes the amount of Mu Gold you can get for a specific amount of approved stable coin
    function mu_gold_bond_quote(uint256 amount) public view returns (uint256 swapAmount, uint256 bondAmount){           
            //return amount of Mu Gold that could be achived via swap vs achived via bonding from the bank
            return _get_mug_bond_quote(amount);
    }


    //internal function only to see if a stable coin is approved
    function is_approved_stable_coin(address stable) internal view returns(bool){
        for(uint256 i = 0; i < _stable_coins.length; i++){
            if(_stable_coins[i] == stable)
                return true;
        }
            return false;    
    }

    function adjust_amount(uint256 amount, uint256 _decimals) public  pure returns(uint256 _adujusted_amount){
        if(18 - _decimals == 0)
            return amount;
        else {
            return (amount/(10**(18-_decimals)));
        }
    }

    function mu_bond(address stable, uint256 amount) public nonReentrant {
        require(is_approved_stable_coin(stable) ,"Only accepting approved stable coins for bonding");
        IERC20 _stable = IERC20(stable);
        Token token = Token(stable);
        uint8 _decimals = token.decimals();
        uint256 _adjusted_amount;
        if(18 - _decimals == 0)
            _adjusted_amount = amount;
        else {
            _adjusted_amount = (amount/(10**(18-_decimals)));
        }
        require(_stable.balanceOf(msg.sender) >= _adjusted_amount, "You don't have enough of that token to bond that amount");
        (uint256 mu_coin_swap_amount, uint256 mu_coin_amount) = _mu_bond_quote(amount);
        require(IERC20(_MuCoin).balanceOf(address(this)) >= mu_coin_amount, "This contract does not have enough Mu Coin");
        _stable.transferFrom(msg.sender, address(this), _adjusted_amount);
        IERC20(_MuCoin).transfer(msg.sender, mu_coin_amount);
        MuMoneyMinter(_MuMoney).mint(address(this), amount);    
    }

    function mu_gold_bond(address stable, uint256 amount) public nonReentrant{
        require(is_approved_stable_coin(stable) ,"Only accepting approved stable coins for bonding");
        
        IERC20 _stable = IERC20(stable);
        Token token = Token(stable);
        uint8 _decimals = token.decimals();
        uint256 _adjusted_amount;
        if(18 - _decimals == 0)
            _adjusted_amount = amount;
        else {
            _adjusted_amount = (amount/(10**(18-_decimals)));
        }
        require(_stable.balanceOf(msg.sender) >= _adjusted_amount, "You don't have enough of that token to bond that amount");
            (uint256 mu_gold_swap_amount, uint256 mu_gold_bond_amount)  = _get_mug_bond_quote(amount);
            require(IERC20(_MuGold).balanceOf(address(this)) >= mu_gold_bond_amount, "This contract does not have enough Mu Coin");
            _stable.transferFrom(msg.sender, address(this), _adjusted_amount);
            IERC20(_MuGold).transfer(msg.sender, mu_gold_bond_amount);
            MuMoneyMinter(_MuMoney).mint(address(this), amount);

    }


    function _get_mug_bond_quote(uint256 amount) internal view returns (uint256 swapAmount, uint256 bondAmount){
            Router router = Router(0x60aE616a2155Ee3d9A68541Ba4544862310933d4);
            address muMugPool = 0x67d9aAb77BEDA392b1Ed0276e70598bf2A22945d;
            address muPool = 0xfacB3892F9A8D55Eb50fDeee00F2b3fA8a85DED5;
            
            //get swap amount and bond amount of Mu Coin
            (uint112 reserve0, uint112 reserve1) = Pair(muPool).getReserves();//MU/USDC.e TJ LP
            reserve0 = reserve0 * (10 ** 12);
            uint256 amountIN = router.getAmountIn(amount, reserve1, reserve0);
            uint256 amountOUT = router.getAmountOut(amount, reserve0, reserve1);
            uint256 mu_coin_swap_amount = amountOUT;
            uint256 mu_coin_bond_amount = (((((amountIN + amountOUT)*10))/2)/10);

            //mu/mug pool token0 is mu coin (18) and token1 is mu gold (18)
            ( reserve0,  reserve1) = Pair(muMugPool).getReserves();//MU/USDC.e TJ LP
            uint256 mugSwapamountOUT = router.getAmountOut(mu_coin_swap_amount, reserve0, reserve1);

            uint256 mugBondamountIN = router.getAmountIn(mu_coin_bond_amount, reserve1, reserve0);
            uint256 mugBondamountOUT = router.getAmountOut(mu_coin_bond_amount, reserve0, reserve1);
            uint256 mu_gold_bond_amount = (((((mugBondamountIN + mugBondamountOUT)*10))/2)/10);

            
            //return amount of Mu Gold that could be achived via swap vs achived via bonding from the bank
            return(mugSwapamountOUT, mu_gold_bond_amount);

    }

     //quotes the amount of Mu Coin you can get for a specific amount of approved stable coin
    function _mu_bond_quote(uint256 amount) internal view returns(uint256 swapAmount, uint256 bondAmount){
        Router router = Router(0x60aE616a2155Ee3d9A68541Ba4544862310933d4);
        //Pair USDC.e/MU token0 is USDC.e (6) token1 is Mu Coin (18)
        (uint112 reserve0, uint112 reserve1) = Pair(0xfacB3892F9A8D55Eb50fDeee00F2b3fA8a85DED5).getReserves();//MU/USDC.e TJ LP
        reserve0 = reserve0 * (10 ** 12);
        uint256 amountIN = router.getAmountIn(amount, reserve1, reserve0);
        uint256 amountOUT = router.getAmountOut(amount, reserve0, reserve1);
        uint256 mu_coin_bond_amount = (((((amountIN + amountOUT)*10))/2)/10);
        return (amountOUT, mu_coin_bond_amount);

    }

    //this function allows anyone to redeem Mu Money for any approved stable coin in our reserves
    
    function redeem_mu_money(address stable, uint256 amount) public nonReentrant {
            //still need to build out this function
            require(is_approved_stable_coin(stable) ,"Only accepting approved stable coins for bonding");
            IERC20 _stable = IERC20(stable);
            Token token = Token(stable);
            IERC20 _mu_money = IERC20(_MuMoney);
            require(_mu_money.balanceOf(msg.sender) >= amount);
            uint8 _decimals = token.decimals();
            uint256 _adjusted_amount;
            if(18 - _decimals == 0)
                _adjusted_amount = amount;
            else {
                _adjusted_amount = (amount/(10**(18-_decimals)));
            }
            require(_stable.balanceOf(address(this)) >= _adjusted_amount);
            MuMoneyMinter(_MuMoney).burnFrom(msg.sender, amount);
            _stable.transfer(msg.sender, _adjusted_amount);
    }

    function _adjust_amount(uint8 decimals, uint256 amount) internal pure returns(uint256 _amount){
            uint256 _adjusted_amount;
            if(18 - decimals == 0)
                _adjusted_amount = amount;
            else {
                _adjusted_amount = (amount/(10**(18-decimals)));
            }
            return _adjusted_amount;
    }
    

}