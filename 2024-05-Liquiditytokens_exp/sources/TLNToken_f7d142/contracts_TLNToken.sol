// contracts/TLNToken.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TLNToken is ERC20 {
    address public governance;
    mapping(address => bool) private issuers;

    event SetIssuer(address indexed issuerAddress);
    event IssuerRemoved(address indexed issuerAddress);
    event GovernanceTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() ERC20("TLN Token", "TLN") {
        governance = _msgSender();
    }

    /**
     * @dev Throws if called by any account other than the governance.
     */
    modifier onlyGovernance() {
        require(_msgSender() == governance, "!governance");
        _;
    }

    /**
     * @dev Throws if called by any account other than the issuer.
     */
    modifier onlyIssuer() {
        require(issuers[_msgSender()], "!issuer");
        _;
    }

    function transferGovernance(address newGovernance) public onlyGovernance {
        require(newGovernance != address(0));
        emit GovernanceTransferred(governance, newGovernance);
        governance = newGovernance;
    }

    function renounceGovernance() public onlyGovernance {
        governance = address(0);
        emit GovernanceTransferred(governance, address(0));
    }

    function setIssuer(address _issuerAddress) public onlyGovernance returns(bool) {
        require(!issuers[_issuerAddress], "Issuer already set");
        issuers[_issuerAddress] = true;
        emit SetIssuer(_issuerAddress);
        return true;
    }

    function renounceIssuer(address _issuerAddress) public onlyGovernance {
        require(issuers[_issuerAddress], "Issuer not set");
        issuers[_issuerAddress] = false;
        emit IssuerRemoved(_issuerAddress);
    }

    function mint(address _account, uint256 _amount) public onlyIssuer returns (bool) {
        _mint(_account, _amount);
        return true;
    }

    function burn(uint256 amount) public returns (bool) {
        _burn(_msgSender(), amount);
        return true;
    }

    function isIssuer(address _issuerAddress) public view returns(bool issuerStatus)  {
        return issuers[_issuerAddress];
    }
}