// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import '@openzeppelin/contracts/token/ERC20/ERC20Capped.sol';
import '../core/SafeOwnable.sol';

contract P2EToken is ERC20Capped, SafeOwnable {
    using SafeMath for uint256;

    event MinterChanged(address indexed minter, uint maxAmount);

    uint256 public constant MAX_SUPPLY = 10 * 10 ** 8 * 10 ** 18;
    mapping(address => uint) public minters;

    constructor() ERC20Capped(MAX_SUPPLY) ERC20("P2E Token", "P2E") SafeOwnable(msg.sender) {
        addMinter(msg.sender, uint(-1));
    }

    function addMinter(address _minter, uint _maxAmount) public onlyOwner {
        require(_minter != address(0), "illegal minter");
        require(minters[_minter] == 0, "already minter");
        minters[_minter] = _maxAmount;
        emit MinterChanged(_minter, _maxAmount);
    }

    function delMinter(address _minter) public onlyOwner {
        require(_minter != address(0), "illegal minter");
        require(minters[_minter] > 0, "not minter");
        delete minters[_minter];
        emit MinterChanged(_minter, 0);
    }

    modifier onlyMinter(uint _amount) {
        require(minters[msg.sender] >= _amount, "caller is not minter or not enough");
        _;
    }

    function mint(address to, uint256 amount) public onlyMinter(amount) returns (uint) {
        if (amount > MAX_SUPPLY.sub(totalSupply())) {
            return 0;
        }
        if (minters[msg.sender] < amount) {
            amount = minters[msg.sender];
        }
        minters[msg.sender] = minters[msg.sender].sub(amount);
        _mint(to, amount);
        return amount; 
    }
}
