interface CTokenInterface {
    function mint(uint256 mintAmount) external returns (uint256);

    function redeem(uint256 redeemTokens) external returns (uint256);

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);

    function exchangeRateStored() external view returns (uint256);

    function balanceOfUnderlying(address _owner) external view returns (uint256);
}

interface CErc20Interface {
    function underlying() external view returns (address);

    function mint(uint256 mintAmount) external returns (uint256);

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
}
