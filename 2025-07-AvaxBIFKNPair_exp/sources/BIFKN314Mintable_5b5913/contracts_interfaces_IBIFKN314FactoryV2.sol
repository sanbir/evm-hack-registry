// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./IERC314.sol";

interface IBIFKN314FactoryV2 {
    function feeTo() external view returns (address);

    function feeRate() external view returns (uint256);

    function feeDistributionThreshold() external view returns (uint256);

    function allTokens(uint256) external view returns (address);

    function getAllTokens() external view returns (address[] memory);

    function allTokensLength() external view returns (uint256);

    function tokenInfoByTokenAddress(
        address _tokenAddress
    )
        external
        view
        returns (
            string memory name,
            string memory symbol,
            uint256 totalSupply,
            address tokenAddress,
            address lpAddress,
            address deployer
        );

    function getTokensByDeployer(
        address deployer
    ) external view returns (address[] memory);

    function deployBIFKN314(
        string memory tokenName,
        string memory tokenSymbol,
        uint256 totalSupply,
        address owner_,
        uint256 tradingFee,
        uint256 maxWalletPercent,
        string memory metadataURI
    )
        external
        payable
        returns (address contractAddress, address liquidityTokenAddress);

    function deployBIFKN314WithSalt(
        string memory tokenName,
        string memory tokenSymbol,
        uint256 totalSupply,
        address owner_,
        uint256 tradingFee,
        uint256 maxWalletPercent,
        string memory metadataURI,
        bytes32 salt
    )
        external
        payable
        returns (address contractAddress, address liquidityTokenAddress);

    function deployBurst(
        string memory tokenName,
        string memory tokenSymbol,
        uint256 totalSupply,
        address owner_,
        uint256 tradingFee,
        uint256 maxWalletPercent,
        string memory metadataURI,
        bytes32 salt
    ) external returns (address contractAddress, address liquidityTokenAddress);

    function addBIFKN314(IERC314 bifkn314) external;

    function removeBIFKN314(address bifkn314Address) external;

    function getDeterministicAddress(
        bytes32 salt,
        bool isBurst
    ) external view returns (address clone);

    function calculateDeterministicAddress(
        uint256 occur,
        address desiredPrefix,
        uint8 bytesDesired,
        bytes32 startSalt,
        bool isBurst
    ) external view returns (bytes32 salt);

    function getFees(
        address token,
        uint256 inputAmount
    )
        external
        view
        returns (uint256 baseSwapRate, uint256 lpFee, uint256 protocolFee);

    function getBaseSwapRate(
        address token
    ) external view returns (uint256 swapRate);

    event TokenCreated(
        address indexed deployer,
        string name,
        string symbol,
        address ammAddress,
        address lpAddress,
        uint256 allAMMLength
    );

    event TokenRemoved(
        address indexed deployer,
        string name,
        string symbol,
        address ammAddress,
        address lpAddress,
        uint256 allAMMLength
    );

    event FeeDistributed(address indexed feeTo, uint256 nativeAmount);
    event FeeHookImplementationRegistered(
        uint8 hookType,
        address implementation
    );
    event FeeHookCreated(address token, uint8 hookType, address hookAddress);
    event FeeHookUpdated(
        address token,
        uint256 baseSwapRate,
        uint256 lpFeePortion,
        uint256 protocolFeePortion
    );
    event FeeHookRemoved(address token, address hookAddress);
    event EmergencyFeeHookReset(address token);

    error InvalidAddress();
    error NameMustNotBeEmpty();
    error SymbolMustNotBeEmpty();
    error NameTooLong();
    error SymbolTooLong();
    error OnlyFeeToSetter(address sender);
    error InvalidTradingFee();
    error SupplyMustBeGreaterThanZero();
    error InsufficientDeploymentFee();
    error InvalidFeeRate();
    error InvalidMaxWalletPercent();
    error DistributionFailed();
    error ImplementationAlreadyDeployed();
    error PreviousFactoryNotSet();
    error InvalidRange();
    error OutOfBounds();
    error FeeHookAlreadyExists();
    error FeeHookImplementationNotFound();
    error FeeHookNotFound();
    error InvalidFeePortions();
}
