// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

error CustomError(string errorMsg);

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint amount) external;
}

interface AaveActionsConnector {
    function executeAaveAction(address _dsaAddress, uint256 _connectorId, address _tokenIn, uint256 _inAmount, address _tokenOut, uint256 _outAmount, uint256 _actionId) external payable;
}

interface IDoughDsa {
    function doughCall(uint256 _connectorId, uint256 _actionId, address _token, uint256 _amount, bool _opt, bytes[] calldata _swapData) external payable;
    function executeAction(uint256 _connectorId, address tokenIn, uint256 inAmount, address tokenOut, uint256 outAmount, uint256 actionId) external payable;
    function dsaOwner() external view returns (address);
    function doughIndex() external view returns (address);
}

interface IDoughIndex {
    function aaveActionsAddress() external view returns (address);
    function setDsaMasterClone(address _dsaMasterCopy) external;
    function setNewBorrowFormula(address _newBorrowFormula) external;
    function setNewAaveActions(address _newAaveActions) external;
    function apyFee() external view returns (uint256);
    function getFlashBorrowers(address _flashBorrower) external view returns (bool);
    function deleverageAutomation() external view returns (address);
    function shieldAutomation() external view returns (address);
    function vaultAutomation() external view returns (address);
    function getWhitelistedTokenList() external view returns (address[] memory);
    function multisig() external view returns (address);
    function treasury() external view returns (address);
    function deleverageAsset() external view returns (address);
    function getDoughConnector (uint256 _connectorId) external view returns (address);
    function getOwnerOfDoughDsa(address dsaAddress) external view returns (address);
    function getDoughDsa(address dsaAddress) external view returns (address);
    function getTokenDecimals(address _token) external view returns (uint8);
    function getTokenMinInterest(address _token) external view returns (uint256);
    function getTokenIndex(address _token) external view returns (uint256);
    function borrowFormula (address _token, address _dsaAddress) external returns (uint256, uint256, uint256, uint256);
    function borrowFormulaInterest (address _token, address _dsaAddress) external returns (uint256);
    function getDsaBorrowStartDate (address _dsaAddress, address _token) external view returns (uint256);
    function updateBorrowDate(uint256 _connectorID, uint256 _time, address _dsaAddress, address _token) external;
    function minDeleveragingRatio() external view returns (uint256);
    function minHealthFactor() external view returns (uint256);
}

interface IBorrowManagementConnector {
    function borrowFormula(address _token, address _dsaAddress) external view returns (uint256, uint256, uint256, uint256);
    function borrowFormulaInterest(address _token, address _dsaAddress) external view returns (uint256);
}

interface IConnectorMultiFlashloan {
    function flashloanReq(address[] memory flashloanTokens, uint256[] memory flashloanAmounts, uint256[] memory flashLoanInterestRateModes, bytes[] memory swapData) external;
}

interface IConnectorMultiFlashloanOnchain {
    function flashloanReq(address[] memory flashloanTokens, uint256[] memory flashloanAmount, uint256[] memory flashLoanInterestRateModes, address[] memory flashLoanTokensCollateral, uint256[] memory flashLoanAmountsCollateral) external;
}

interface IConnectorFlashloan {
    function flashloanReq(address dsaOwnerAddress, address flashloanToken, uint256 flashloanAmount, uint256 flashActionId, bytes calldata _swapData) external;
}