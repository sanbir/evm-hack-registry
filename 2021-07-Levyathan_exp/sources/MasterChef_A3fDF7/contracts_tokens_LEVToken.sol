// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

// import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "contracts/interfaces/IBurnable.sol";
import "contracts/interfaces/IMintable.sol";

contract LEVToken is ERC20, IBurnable, IMintable, Ownable {
    uint256 immutable _createdAtBlock;
    uint256 immutable _initialSupply;

    // the LEV token! Masterchef contract is the owner and can mint
    constructor(
        address initialSupplyTarget,
        uint256 initialSupply
    ) ERC20("Levyathan", "LEV") {
        _mint(initialSupplyTarget, initialSupply);
        _initialSupply = initialSupply;
        _createdAtBlock = block.number;
    }

    function burn(uint256 amount) external override {
        _burn(msg.sender, amount);
    }

    function getCreatedAtBlock() external view returns(uint) {
        return _createdAtBlock;
    }

    // owner should be MasterChef
    function mint(address receiver, uint256 amount) override external onlyOwner {
        _mint(receiver, amount);
    }
}
