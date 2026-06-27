// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "./lib/Contract.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract COCO is ERC20Burnable, Contract, Ownable {
    using SafeMath for uint256;

    uint256 public bindValid;
    uint256 public startTime;
    address public pair;
    address public rewardPool;

    mapping(address => bool) public banList;

    event BindTop(address indexed sender, address indexed recipient);
    event FeeLog(
        address indexed sender,
        address indexed recipient,
        uint256 feeAmount
    );

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _totalSupply
    ) ERC20(_name, _symbol) {
        uint256 initSupply = _totalSupply * 10 ** uint256(decimals());
        _mint(msg.sender, initSupply);
    }

    function setBindValid(uint256 _bindValid) public onlyOwner {
        bindValid = _bindValid;
    }

    function setBanList(address _address, bool _bool) public onlyOwner {
        banList[_address] = _bool;
    }

    function setPair(address _pair) public onlyOwner {
        pair = _pair;
    }

    function setRewardPool(address _pool) public onlyOwner {
        rewardPool = _pool;
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual override {
        require(!banList[sender] && !banList[recipient], "Transaction error");

        if (pair == sender || pair == recipient) {
            _feeTransfer(sender, recipient, amount);
            return;
        } else if (
            amount >= bindValid &&
            bindValid > 0 &&
            !isContract(sender) &&
            !isContract(recipient)
        ) {
            emit BindTop(sender, recipient);
        }

        super._transfer(sender, recipient, amount);
    }

    function _feeTransfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        uint256 feeAmount = amount.div(100);
        super._transfer(sender, rewardPool, feeAmount);
        super._transfer(sender, recipient, amount.sub(feeAmount));

        emit FeeLog(sender, recipient, feeAmount);
    }

    function batchTransfer(
        address[] memory recipients,
        uint256[] memory amounts
    ) public {
        require(recipients.length == amounts.length, "Array lengths mismatch");
        require(recipients.length > 0, "Recipient list is empty");

        for (uint256 i = 0; i < recipients.length; i++) {
            super._transfer(msg.sender, recipients[i], amounts[i]);
        }
    }
}
