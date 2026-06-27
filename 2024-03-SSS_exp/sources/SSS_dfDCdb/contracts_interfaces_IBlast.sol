interface IBlast {
  // Note: the full interface for IBlast can be found below
  function configureClaimableGas() external;
  function claimAllGas(address contractAddress, address recipient) external returns (uint256);
  function claimMaxGas(address contractAddress, address recipient) external returns (uint256);
}
interface IBlastPoints {
	function configurePointsOperator(address operator) external;
}