// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal real ERC20 used as an opaque pool coin (e.g. stETH-like) and LP token.
contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        emit Approval(msg.sender, s, a);
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _transfer(msg.sender, to, a);
        return true;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[from][msg.sender];
        if (al != type(uint256).max) allowance[from][msg.sender] = al - a;
        _transfer(from, to, a);
        return true;
    }

    function _transfer(address from, address to, uint256 a) internal {
        balanceOf[from] -= a;
        balanceOf[to] += a;
        emit Transfer(from, to, a);
    }

    function mint(address to, uint256 a) external {
        totalSupply += a;
        balanceOf[to] += a;
        emit Transfer(address(0), to, a);
    }

    function burn(address from, uint256 a) external {
        balanceOf[from] -= a;
        totalSupply -= a;
        emit Transfer(from, address(0), a);
    }
}

/// @notice Minimal real WETH9 (deposit/withdraw), matches Pino's IWETH9 usage.
contract MockWETH9 {
    string public constant name = "Wrapped Ether";
    string public constant symbol = "WETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);
    event Transfer(address indexed src, address indexed dst, uint256 wad);
    event Approval(address indexed src, address indexed guy, uint256 wad);

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        balanceOf[msg.sender] -= wad;
        (bool ok,) = msg.sender.call{value: wad}("");
        require(ok, "WETH: send fail");
        emit Withdrawal(msg.sender, wad);
    }

    function totalSupply() external view returns (uint256) {
        return address(this).balance;
    }

    function approve(address guy, uint256 wad) external returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    function transfer(address dst, uint256 wad) external returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint256 wad) public returns (bool) {
        require(balanceOf[src] >= wad, "WETH: bal");
        if (src != msg.sender && allowance[src][msg.sender] != type(uint256).max) {
            allowance[src][msg.sender] -= wad;
        }
        balanceOf[src] -= wad;
        balanceOf[dst] += wad;
        emit Transfer(src, dst, wad);
        return true;
    }
}

/// @notice Minimal Curve-style 2-coin pool where coin0 is native ETH and coin1 is an ERC20.
/// @dev This is the opaque external venue. On remove_liquidity it returns coin0 as NATIVE ETH
///      to the caller (exactly like real Curve ETH pools, e.g. the stETH pool), which is the
///      precondition that the Pino `Curve.withdraw` bug mishandles.
///      The pool contract itself is the LP token (like many real Curve pools).
contract MockCurveEthPool {
    uint8 public constant ETH_INDEX = 0; // coin0 = ETH (native)
    IERC20 public immutable coin1; // coin1 = stETH-like ERC20

    // LP accounting (this contract acts as the LP token)
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    // reserves
    uint256 public tokenReserve; // coin1 reserve

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(IERC20 _coin1) {
        coin1 = _coin1;
    }

    receive() external payable {}

    function coins(uint256 i) external view returns (address) {
        return i == 0 ? address(0) : address(coin1);
    }

    /// @notice Deposit [ethAmount, tokenAmount]; mints LP = sum of deposited value.
    function add_liquidity(uint256[2] calldata _amounts, uint256 _min_mint_amount) external payable {
        require(msg.value == _amounts[0], "eth mismatch");
        if (_amounts[1] > 0) {
            require(coin1.transferFrom(msg.sender, address(this), _amounts[1]), "pull coin1");
            tokenReserve += _amounts[1];
        }
        uint256 minted = _amounts[0] + _amounts[1];
        require(minted >= _min_mint_amount, "slippage");
        totalSupply += minted;
        balanceOf[msg.sender] += minted;
        emit Transfer(address(0), msg.sender, minted);
    }

    /// @notice Burn LP, receive proportional coin0 (ETH, native) and coin1 (ERC20).
    function remove_liquidity(uint256 _amount, uint256[2] calldata _min_amounts) external {
        uint256 supply = totalSupply;
        uint256 ethOut = (address(this).balance * _amount) / supply;
        uint256 tokenOut = (tokenReserve * _amount) / supply;
        require(ethOut >= _min_amounts[0] && tokenOut >= _min_amounts[1], "slippage");

        balanceOf[msg.sender] -= _amount;
        totalSupply -= _amount;
        tokenReserve -= tokenOut;
        emit Transfer(msg.sender, address(0), _amount);

        if (tokenOut > 0) require(coin1.transfer(msg.sender, tokenOut), "send coin1");
        if (ethOut > 0) {
            (bool ok,) = msg.sender.call{value: ethOut}(""); // NATIVE ETH back to caller
            require(ok, "send eth");
        }
    }

    function remove_liquidity_one_coin(uint256 _amount, uint256 _i, uint256 _min) public returns (uint256 out) {
        balanceOf[msg.sender] -= _amount;
        totalSupply -= _amount;
        if (_i == 0) {
            out = _amount; // 1:1 for simplicity
            require(out >= _min, "slippage");
            (bool ok,) = msg.sender.call{value: out}(""); // NATIVE ETH back to caller
            require(ok, "send eth");
        } else {
            out = _amount;
            require(out >= _min, "slippage");
            tokenReserve -= out;
            require(coin1.transfer(msg.sender, out), "send coin1");
        }
    }

    function remove_liquidity_one_coin(uint256 _amount, int128 _i, uint256 _min) external returns (uint256) {
        return remove_liquidity_one_coin(_amount, uint256(uint128(_i)), _min);
    }
}
