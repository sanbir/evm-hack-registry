// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "./ERC20Permit.sol";
import "../Permissions.sol";
import "../interfaces/ITransferService.sol";
import "../interfaces/IGlobalImpliedCollateralService.sol";

/// @title Malt V2 Token
/// @author 0xScotch <scotch@malt.money>
/// @notice The ERC20 token contract for Malt V2
contract Malt is ERC20Permit, Permissions {
  // Can mint/burn Malt
  bytes32 public immutable MONETARY_MINTER_ROLE;
  bytes32 public immutable MONETARY_BURNER_ROLE;
  bytes32 public immutable MONETARY_MANAGER_ROLE;

  ITransferService public transferService;
  IGlobalImpliedCollateralService public globalImpliedCollateral;

  bool internal initialSetup;
  address public proposedManager;
  address public monetaryManager;
  address internal immutable deployer;

  string private __name;
  string private __ticker;

  event SetTransferService(address service);
  event SetGlobalImpliedCollateralService(address service);
  event AddBurner(address burner);
  event AddMinter(address minter);
  event RemoveBurner(address burner);
  event RemoveMinter(address minter);
  event ChangeMonetaryManager(address manager);
  event ProposeMonetaryManager(address manager);
  event NewName(string name, string ticker);

  constructor(
    string memory name,
    string memory ticker,
    address _repository,
    address _transferService,
    address _deployer
  ) ERC20Permit(name, ticker) {
    require(_repository != address(0), "Malt: Repo addr(0)");
    require(_transferService != address(0), "Malt: XferSvc addr(0)");
    _initialSetup(_repository);

    MONETARY_MINTER_ROLE = 0x264fdff7d4ea2a3fb35856e2af3bd6f38e90e6c378f1161af7f84f529e94bf2a;
    MONETARY_BURNER_ROLE = 0xd584181ebe1991e362d5d6203c152ec1f1401c6e1f04cf8f89206dc82e0bddf1;
    MONETARY_MANAGER_ROLE = 0x8d0a7a26d784bd81e4cc5cff08474890ceb6d51b1bb1f416caff0e31cd01d8d2;

    // These roles aren't set up using _roleSetup as ADMIN_ROLE
    // should not be the admin of these roles like it is for all
    // other roles
    _setRoleAdmin(
      0x264fdff7d4ea2a3fb35856e2af3bd6f38e90e6c378f1161af7f84f529e94bf2a,
      TIMELOCK_ROLE
    );
    _setRoleAdmin(
      0xd584181ebe1991e362d5d6203c152ec1f1401c6e1f04cf8f89206dc82e0bddf1,
      TIMELOCK_ROLE
    );
    _setRoleAdmin(
      0x8d0a7a26d784bd81e4cc5cff08474890ceb6d51b1bb1f416caff0e31cd01d8d2,
      TIMELOCK_ROLE
    );

    deployer = _deployer;
    __name = name;
    __ticker = ticker;

    transferService = ITransferService(_transferService);
    emit SetTransferService(_transferService);
  }

  function totalSupply() public view override returns (uint256) {
    return super.totalSupply() - globalImpliedCollateral.totalPhantomMalt();
  }

  /// @dev Returns the name of the token.
  function name() public view override returns (string memory) {
    return __name;
  }

  /// @dev Returns the symbol of the token, usually a shorter version of the name.
  function symbol() public view override returns (string memory) {
    return __ticker;
  }

  function setupContracts(
    address _globalIC,
    address _manager,
    address[] memory minters,
    address[] memory burners
  ) external {
    // This should only be called once
    require(msg.sender == deployer, "Only deployer");
    require(!initialSetup, "Malt: Already setup");
    require(_globalIC != address(0), "Malt: GlobalIC addr(0)");
    require(_manager != address(0), "Malt: Manager addr(0)");
    initialSetup = true;

    globalImpliedCollateral = IGlobalImpliedCollateralService(_globalIC);

    _grantRole(MONETARY_MANAGER_ROLE, _manager);
    monetaryManager = _manager;

    for (uint256 i = 0; i < minters.length; i = i + 1) {
      require(minters[i] != address(0), "Malt: Minter addr(0)");
      _setupRole(MONETARY_MINTER_ROLE, minters[i]);
    }
    for (uint256 i = 0; i < burners.length; i = i + 1) {
      require(burners[i] != address(0), "Malt: Burner addr(0)");
      _setupRole(MONETARY_BURNER_ROLE, burners[i]);
    }
  }

  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 amount
  ) internal override {
    (bool success, string memory reason) = transferService
      .verifyTransferAndCall(from, to, amount);
    require(success, reason);
  }

  function mint(address to, uint256 amount)
    external
    onlyRoleMalt(MONETARY_MINTER_ROLE, "Must have monetary minter role")
  {
    _mint(to, amount);
  }

  function burn(address from, uint256 amount)
    external
    onlyRoleMalt(MONETARY_BURNER_ROLE, "Must have monetary burner role")
  {
    _burn(from, amount);
  }

  function addBurner(address _burner)
    external
    onlyRoleMalt(MONETARY_MANAGER_ROLE, "Must have manager role")
  {
    require(_burner != address(0), "No addr(0)");
    _grantRole(MONETARY_BURNER_ROLE, _burner);
    emit AddBurner(_burner);
  }

  function addMinter(address _minter)
    external
    onlyRoleMalt(MONETARY_MANAGER_ROLE, "Must have manager role")
  {
    require(_minter != address(0), "No addr(0)");
    _grantRole(MONETARY_MINTER_ROLE, _minter);
    emit AddMinter(_minter);
  }

  function removeBurner(address _burner)
    external
    onlyRoleMalt(MONETARY_MANAGER_ROLE, "Must have manager role")
  {
    _revokeRole(MONETARY_BURNER_ROLE, _burner);
    emit RemoveBurner(_burner);
  }

  function removeMinter(address _minter)
    external
    onlyRoleMalt(MONETARY_MANAGER_ROLE, "Must have manager role")
  {
    _revokeRole(MONETARY_MINTER_ROLE, _minter);
    emit RemoveMinter(_minter);
  }

  /// @notice Privileged method changing the name and ticker of the token
  /// @param _name The new full name of the token
  /// @param _ticker The new ticker for the token
  /// @dev Only callable via the timelock contract
  function setNewName(string memory _name, string memory _ticker)
    external
    onlyRoleMalt(TIMELOCK_ROLE, "Must have timelock role")
  {
    __name = _name;
    __ticker = _ticker;
    emit NewName(_name, _ticker);
  }

  /// @notice Privileged method for proposing a new monetary manager
  /// @param _manager The address of the newly proposed manager contract
  /// @dev Only callable via the existing monetary manager contract
  function proposeNewManager(address _manager)
    external
    onlyRoleMalt(MONETARY_MANAGER_ROLE, "Must have monetary manager role")
  {
    require(_manager != address(0), "Cannot use addr(0)");
    proposedManager = _manager;
    emit ProposeMonetaryManager(_manager);
  }

  /// @notice Method for a proposed verifier manager contract to accept the role
  /// @dev Only callable via the proposedManager
  function acceptManagerRole() external {
    require(msg.sender == proposedManager, "Must be proposedManager");
    _transferRole(proposedManager, monetaryManager, MONETARY_MANAGER_ROLE);
    proposedManager = address(0);
    monetaryManager = msg.sender;
    emit ChangeMonetaryManager(msg.sender);
  }

  function setTransferService(address _service)
    external
    onlyRoleMalt(ADMIN_ROLE, "Must have admin role")
  {
    require(_service != address(0), "Cannot use address 0 as transfer service");
    transferService = ITransferService(_service);
    emit SetTransferService(_service);
  }

  function setGlobalImpliedCollateralService(address _service)
    external
    onlyRoleMalt(ADMIN_ROLE, "Must have admin role")
  {
    require(_service != address(0), "Cannot use address 0 as global ic");
    globalImpliedCollateral = IGlobalImpliedCollateralService(_service);
    emit SetGlobalImpliedCollateralService(_service);
  }
}
