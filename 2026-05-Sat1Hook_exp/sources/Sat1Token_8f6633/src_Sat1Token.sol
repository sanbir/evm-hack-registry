// SPDX-License-Identifier: MIT
// https://www.sat1.io/
pragma solidity 0.8.26;

/// @title Sat1Token
/// @notice Plain ERC-20 with one designated minter locked once, following SATO's token model.
contract Sat1Token {
    string public constant name = "sat1";
    string public constant symbol = "sat1";
    uint8 public constant decimals = 18;

    /// @notice The designated minter (the Sat1Hook). Locked once `setMinter` is called.
    address public minter;

    /// @notice The address that deployed this contract, allowed to set the minter exactly once.
    address public immutable DEPLOYER;

    /// @notice Marker that asserts this contract makes no use of any restriction primitive.
    bool public immutable RESTRICTIONS_FORBIDDEN = true;

    /// @notice The block at which this contract was deployed.
    uint256 public immutable GENESIS_BLOCK;

    /// @notice The hash of the block immediately preceding deployment.
    bytes32 public immutable GENESIS_HASH;

    uint256 public totalSupply;

    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 allowance)) public allowance;

    error NotDeployer();
    error NotMinter();
    error MinterAlreadySet();
    error MinterIsZero();
    error ERC20InvalidReceiver();
    error ERC20InvalidSender();
    error ERC20InvalidSpender();
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event MinterLocked(address indexed minter);

    constructor() {
        DEPLOYER = msg.sender;
        GENESIS_BLOCK = block.number;
        GENESIS_HASH = blockhash(block.number - 1);
    }

    /// @notice Set the minter exactly once, then lock forever.
    function setMinter(address newMinter) external {
        if (msg.sender != DEPLOYER) revert NotDeployer();
        if (minter != address(0)) revert MinterAlreadySet();
        if (newMinter == address(0)) revert MinterIsZero();
        minter = newMinter;
        emit MinterLocked(newMinter);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        if (currentAllowance < value) revert ERC20InsufficientAllowance(msg.sender, currentAllowance, value);

        unchecked {
            _approve(from, msg.sender, currentAllowance - value);
        }
        _transfer(from, to, value);
        return true;
    }

    /// @notice Mint sat1. Callable only by the locked-in minter.
    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        if (to == address(0)) revert ERC20InvalidReceiver();

        totalSupply += amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    /// @notice Burn sat1 held by `from`. Callable only by the locked-in minter.
    function burn(address from, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        if (from == address(0)) revert ERC20InvalidSender();

        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert ERC20InsufficientBalance(from, fromBalance, amount);
        unchecked {
            balanceOf[from] = fromBalance - amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) revert ERC20InvalidSender();
        if (to == address(0)) revert ERC20InvalidReceiver();

        uint256 fromBalance = balanceOf[from];
        if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
        unchecked {
            balanceOf[from] = fromBalance - value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function _approve(address owner, address spender, uint256 value) internal {
        if (owner == address(0)) revert ERC20InvalidSender();
        if (spender == address(0)) revert ERC20InvalidSpender();

        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }
}
