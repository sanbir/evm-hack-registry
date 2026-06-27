// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./interfaces/IPerpPair.sol";
import "./interfaces/ILostAndFound.sol";
import { PerpPair } from "./PerpPair.sol";
import { LostAndFound } from "./LostAndFound.sol";
import "./util/CurveMath.sol";
import "./util/MatrixMath.sol";
import "./util/UtilMath.sol";
import "./interfaces/IVault.sol";
import "./manager/FeeManager.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./CL_oracle_middleware/interfaces/IOracleMiddleware.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/metatx/ERC2771Context.sol";




/**
    Vault contract associated to a PerpPair contract. This contract holds the stablecoin of the users and provides the collateral information to the PerpPair contract.
    This contract also takes care of adding the PnL of users closing their positions to their stablecoin collateral.
    In the contract several error codes are present, here is a table of these errors' descriptions.
    | Error Code | Description                                                                  |
    |------------|------------------------------------------------------------------------------|
    | AC2        | Deposit amount below `minCollateralMovement`.                                |
    | AC3        | New vault ratios after deposit exceed snapshot thresholds.                    |
    | RC1        | Withdrawal amount exceeds user's collateral.                                 |
    | RC2        | Partial withdrawal amount below `minCollateralMovement`.                     |
    | RC3        | Withdrawal amount exceeds total vault collateral.                            |
    | RC4        | User margin ratio would fall below `MMR` after withdrawal.                   |
    | RC5        | Withdrawal amount plus unrealised loss exceeds user's collateral.            |
    | AS1        | Add-stablecoin timelock not expired or param hash mismatch.                  |
    | CONV1      | Amounts array length does not match number of stablecoins.                   |
    | UNINIT1    | Contract already initialized.                                               |
    | OnlyPerp   | Caller is not the PerpPair contract.                                         |
 */
contract Vault is AccessControl, ReentrancyGuardTransient, ERC2771Context {
    using Math for uint256;
    using SignedMath for int256;
    using SafeERC20 for IERC20;

        /// @notice address of the perpPair contract
    address public perpPair = address(0);
    /// @notice address of the lost and found contract
    address public lostAndFound = address(0);
    /// @notice address of the oracle
    address public oracle;
    /// @dev Status of the contract, if false a function to initialize some parameters can be called.
    bool private initialized;

    uint256 private immutable MMRDecimals;
    uint256 private immutable ratioDecimals;
    uint256 private immutable collateralDecimals;
    uint256 private immutable oracleDecimals;

    uint256 public addStableTimeLock;
    uint256 public addStableTimeLockDuration = 604800;
    bytes32 public addStableHash;

    /// @notice Total collateral in the vault
    uint256 public totalCollateral;
    /// @dev Minimum collateral removal/addition allowed.
    uint256 immutable public minCollateralMovement;

    /// @dev Role assigned to the perpPair contract address. 
    bytes32 public constant PERP_PAIR_ROLE = keccak256("PERP_PAIR_ROLE");
    /// @dev Role assigned to mods who can change parameters.
    bytes32 public constant MOD_ROLE = keccak256("MOD_ROLE");

    struct StableCoin {
        ERC20 stableCoin;
        uint256 depositRatioThreshold;
        uint256 withdrawalRatioThreshold;
        uint256 stableDecimals;
    }

    /// @dev List of allowed stablecoins.
    StableCoin[] public stableCoins;
    /// @dev Snapshot of the ratios, used to check for allowed new ratios. 
    uint256[] public ratiosSnapshot;
    /// @dev Timestamp of the ratioSnapshot. Used to compute when to take a new one.
    uint256 public lastSnapshotTimestamp;
    /// @dev Duration of the snapshot. Updated each time as 1 day + [0,2]h.
    uint256 private ratioLockTime = 3600*24;

    /// @notice Ratio of collateral of each user in each allowed stableCoin.
    mapping(address => mapping(ERC20 => uint256)) public userCollateralRatio;
    /// @notice Total collateral of each user
    mapping(address => uint256) public userCollateral;
    /// @notice Ratios of collateral in each stableCoin inside the vault.
    mapping(ERC20 => uint256) public totalCollateralRatio;

    event BlockedCollateralRemoval(address stablecoin, address user, uint256 amount);
    event ChangedRatioLockTime(uint256 newRatioLockTime);
    event AddingStableCoin(uint256 lockTime, address stableCoin, uint256 depositRatioThreshold, uint256 withdrawalRatioThreshold, uint256 stableDecimals, uint256 newTimeLockDuration);

    constructor(
        address _multiCallManager,
        address _oracle,
        uint256 _minCollateralMovement,
        address[] memory stableCoinAddresses,
        uint256[] memory depositThresholds,
        uint256[] memory withdrowalThresholds,
        uint256[] memory stableDecimals
    ) ERC2771Context(_multiCallManager) {
        initialized = false;
        MMRDecimals = 1e6;
        ratioDecimals = 1e8;
        collateralDecimals = 1e18;
        oracleDecimals = 1e8;
        oracle = _oracle;
        minCollateralMovement = _minCollateralMovement;
        for (uint256 i; i < stableCoinAddresses.length; i++) {
            StableCoin memory newStable = StableCoin(
                ERC20(stableCoinAddresses[i]), depositThresholds[i], withdrowalThresholds[i], stableDecimals[i]
            );
            stableCoins.push(newStable);
            ratiosSnapshot.push(ratioDecimals/stableCoinAddresses.length);
        }
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        ratioLockTime = 3600 * 24;
    }

    /// @notice Add collateral to the vault in the desired stablecoins
    /// @param collateral List of amounts of collterals to deposit **in order**, 0 if not depositing that stableCoin.
    function addCollateral(uint256[] memory collateral) external nonReentrant {
        for (uint256 i; i < collateral.length; i++) {
            if (collateral[i] > 0){
                IERC20(address(stableCoins[i].stableCoin)).safeTransferFrom(_msgSender(), address(this), collateral[i]);
            }
        }
        collateral = convertStablecollateralDecimals(collateral, true);
        _addCollateral(collateral, _msgSender());
    }

    /// @notice internal method to update mappings and global variables according to user deposit.
    /// @param collateral Collateral being added by the user
    /// @param user User adding the collateral
    function _addCollateral(uint256[] memory collateral, address user) private {
        updateSnapshot();
        uint256 len = stableCoins.length;
        uint256 totalColl = totalCollateral;
        uint256 userColl = userCollateral[user];

        uint256 ratioDec = ratioDecimals;
        uint256[] memory oldCollateral = new uint256[](len);
        uint256[] memory oldTotalCollateral = new uint256[](len);
        uint256 addedCollateral;
        for (uint256 i; i < len; ++i) {
            
            // Retrieve user’s previous collateral     
            oldCollateral[i] = userCollateralRatio[user][stableCoins[i].stableCoin] * userColl / ratioDec;
            // Compute old global collateral values
            oldTotalCollateral[i] = totalCollateralRatio[stableCoins[i].stableCoin] * totalColl / ratioDec;
            //Total added collateral
            addedCollateral += collateral[i];
        }

        require(addedCollateral >= minCollateralMovement, "AC2"); //deposit lower than minimum

        // Update global and user totals
        totalCollateral += addedCollateral;
        userCollateral[user] += addedCollateral;

        totalColl += addedCollateral;
        userColl += addedCollateral; 
        // Update user ratios and compute new global ratios
        for (uint256 i = 0; i < len; ++i) {
            userCollateralRatio[user][stableCoins[i].stableCoin] =
                (collateral[i] + oldCollateral[i]) * ratioDec / userColl;
            //NOTICE: oldCollateral here is not actually old collateral, it's "newRatios". For gas optimization we reuse the same array.
            oldCollateral[i] = (collateral[i] + oldTotalCollateral[i]) * ratioDec / totalColl;
        }

        if (totalColl != addedCollateral) {
            //NOTICE: oldCollateral here is not actually old collateral, it's "newRatios". For gas optimization we reused the same array.
            require(newRatiosAllowed(oldCollateral, true), "AC3"); //bad new ratios
        }
        //NOTICE: oldCollateral here is not actually old collateral, it's "newRatios". For gas optimization we reused the same array.
        _updateGlobalRatios(oldCollateral);
    }

    /// @notice Remove collateral from msg.sender balance in the vault. We try to give the collateral back with the ratio the user has put it in, but if its removal unbalances the vault too much the collateral is withdrawn with the same ratio of the vault.
    /// @param amount Amount of collateral to remove from the vault.
    /// @param unverifiedReport Chainlink report to verify price.
    function removeCollateral(uint256 amount, bytes memory unverifiedReport) public nonReentrant {
        PerpPair(perpPair).updateFG(unverifiedReport);
        address user = _msgSender();
        require(amount <= userCollateral[user], "RC1"); //Error on removeCollateral: Amount exceeds user collateral
        (uint256 pnl, bool pnlSign) = PerpPair(perpPair).calcPnL(user, SafeCast.toUint256(IOracleMiddleware(oracle).getPrice()));
        if (!pnlSign){
            require(amount + pnl <= userCollateral[user], "RC5");
        }
        if(amount != userCollateral[user]){
            require(amount >= minCollateralMovement, "RC2"); //withdrawal lower than minimum
        }
        require(amount <= totalCollateral, "RC3"); //Error on removeCollateral: Amount exceeds total collateral

        require(_checkMR(amount, user), "RC4"); //Error on removeCollateral: MMR check

        uint256[] memory removedCollateral = _removeCollateral(amount, user);
        
        removedCollateral = convertStablecollateralDecimals(removedCollateral, false);
        for (uint256 i; i < stableCoins.length; i++) {
            if (removedCollateral[i] > 0){
                (bool success, ) = address(stableCoins[i].stableCoin).call(
                    abi.encodeWithSelector(IERC20.transfer.selector, user, removedCollateral[i])
                );
                if(!success){
                    IERC20(address(stableCoins[i].stableCoin)).approve(lostAndFound, removedCollateral[i]);
                    ILostAndFound(lostAndFound).depositLostFunds(user, address(stableCoins[i].stableCoin), removedCollateral[i]);
                    emit BlockedCollateralRemoval(address(stableCoins[i].stableCoin), user, removedCollateral[i]);
                }
            }
        }
    }

    /// @notice Remove all of the msgSender's collateral from the vault. See removeCollateral() for description of how collateral is removed
    /// @param unverifiedReport Chainlink report to verify price.
    function removeAllCollateral(bytes memory unverifiedReport) external {
        uint256 amount = userCollateral[_msgSender()];
        removeCollateral(amount, unverifiedReport);
    }

    /// @dev Remove collateral from the user's collateral. We try to give the collateral back with the ratio the user has put it in, but if its removal unbalances the vault too much the collateral is withdrawn with the same ratio of the vault.
    /// @param amount Amount of collateral to remove from the vault.
    /// @param user address of the user.
    function _removeCollateral(uint256 amount, address user) private returns (uint256[] memory removedCollateral) {
        updateSnapshot();
        removedCollateral = new uint256[](stableCoins.length);
        uint256[] memory newGlobalRatios = new uint256[](stableCoins.length);
        
        //Check for user's ratios to be initialized. If not use vault ratios.
        bool hasRatios;
        for (uint256 i = 0; i < stableCoins.length; i++) {
            if (userCollateralRatio[user][stableCoins[i].stableCoin] != 0) {
                hasRatios = true;
                break;
            }
        }
        if (!hasRatios) {
            for (uint256 i = 0; i < stableCoins.length; i++) {
                userCollateralRatio[user][stableCoins[i].stableCoin] = totalCollateralRatio[stableCoins[i].stableCoin];
            }
        }

        //Edge case where all collateral is removed
        if(amount == totalCollateral){
            for (uint256 i = 0; i < stableCoins.length; i++) {
                removedCollateral[i] = totalCollateralRatio[stableCoins[i].stableCoin] * amount / ratioDecimals;
                totalCollateralRatio[stableCoins[i].stableCoin] = 0;
                userCollateralRatio[user][stableCoins[i].stableCoin] = 0;
            }
            totalCollateral = 0;
            userCollateral[user] = 0;
            return removedCollateral;
        }

        // 1. Compute removed collateral and new global ratios
        bool enoughCollat = _computeCollateralRemoval(amount, user, removedCollateral, newGlobalRatios);

        // 2. Check if new ratios are allowed
        bool goodRatios = newRatiosAllowed(newGlobalRatios, false);

        // 3. Update ratios accordingly
        if (enoughCollat && goodRatios) {
            _updateGlobalRatios(newGlobalRatios);
        } else {
            _updateUserRatios(amount, user, removedCollateral);
        }
        totalCollateral -= amount;
        userCollateral[user] -= amount;
        return removedCollateral;
    }

    /// @notice Can only be called from PerpPair. Remove all of an user's collateral from the vault. See removeCollateral() for description of how collateral is removed
    /// @param user address of the user.
    function removeAllCollateralForUser(address user) external onlyPerpPair {
        uint256 amount = userCollateral[user];
        uint256[] memory removedCollateral = _removeCollateral(amount, user);
        removedCollateral = convertStablecollateralDecimals(removedCollateral, false);
        for (uint256 i; i < stableCoins.length; i++) {
            if (removedCollateral[i] > 0){
                (bool success, ) = address(stableCoins[i].stableCoin).call(
                    abi.encodeWithSelector(IERC20.transfer.selector, user, removedCollateral[i])
                );
                if(!success){
                    IERC20(address(stableCoins[i].stableCoin)).approve(lostAndFound, removedCollateral[i]);
                    ILostAndFound(lostAndFound).depositLostFunds(user, address(stableCoins[i].stableCoin), removedCollateral[i]);
                    emit BlockedCollateralRemoval(address(stableCoins[i].stableCoin), user, removedCollateral[i]);
                }
            }
        }
    }

    /// @dev Helper function to compute removal of collateral from vault. Computes if there's enough collateral 
    /// @param amount The amount of collateral to remove.
    /// @param user The user that's removing the collateral.
    /// @param removedCollateral The list of removed collateral in different stablecoins.
    /// @param newGlobalRatios The list of ratio of stablecoins of the vault after removal.
    /// @return enoughCollat Whether there's enough collateral to remove in the vault.
    function _computeCollateralRemoval(
        uint256 amount,
        address user,
        uint256[] memory removedCollateral,
        uint256[] memory newGlobalRatios
    ) private view returns (bool enoughCollat) {
        enoughCollat = true;
        for (uint256 i = 0; i < stableCoins.length; i++) {
            removedCollateral[i] = userCollateralRatio[user][stableCoins[i].stableCoin] * amount / ratioDecimals;
            uint256 iStableCoinColl = totalCollateralRatio[stableCoins[i].stableCoin] * totalCollateral / ratioDecimals;
            if (removedCollateral[i] > iStableCoinColl) {
                enoughCollat = false;
                break;
            }
            newGlobalRatios[i] = (iStableCoinColl - removedCollateral[i]) * ratioDecimals / (totalCollateral - amount);
        }
    }

    ///@dev Update the global ratios of stablecoins.
    ///@param newGlobalRatios New ratios of collateral.
    function _updateGlobalRatios(uint256[] memory newGlobalRatios) private {
        for (uint256 i = 0; i < stableCoins.length; i++) {
            totalCollateralRatio[stableCoins[i].stableCoin] = newGlobalRatios[i];
        }
    }

    ///@dev Update user ratios of stablecoins
    ///@param amount Amount of stablecoins being moved by the user
    ///@param user User moving collateral
    ///@param removedCollateral List of collataerals removed.
    function _updateUserRatios(
        uint256 amount,
        address user,
        uint256[] memory removedCollateral
    ) private {
        uint256 normFact = 0;
        for (uint256 i = 0; i < stableCoins.length; i++) {
            // Recalculate removed collateral using vault ratios
            removedCollateral[i] = totalCollateralRatio[stableCoins[i].stableCoin] * amount / ratioDecimals;
            uint256 oldStableCoinAmount = userCollateralRatio[user][stableCoins[i].stableCoin] * userCollateral[user] / ratioDecimals;
            if (oldStableCoinAmount > removedCollateral[i] && userCollateral[user] > amount) {
                userCollateralRatio[user][stableCoins[i].stableCoin] = (oldStableCoinAmount - removedCollateral[i]) * ratioDecimals / (userCollateral[user] - amount);
            } else {
                userCollateralRatio[user][stableCoins[i].stableCoin] = 0;
            }
            normFact += userCollateralRatio[user][stableCoins[i].stableCoin];
        }
        if (normFact != ratioDecimals && normFact != 0) {
            for (uint256 i = 0; i < stableCoins.length; i++) {
                userCollateralRatio[user][stableCoins[i].stableCoin] = userCollateralRatio[user][stableCoins[i].stableCoin] * ratioDecimals / normFact;
            }
        }
    }

    ///@dev adds the pnl of the user to their collateral when they close their position. Only callable by perpPair
    ///@param user User closing the position
    ///@param pnl pnl of the user
    ///@param pnlSign sign of pnl
    function addPnlToCollateral(address user, uint256 pnl, bool pnlSign) external onlyPerpPair {

        if (pnlSign) {
            userCollateral[user] += pnl;
        } else {
            if(userCollateral[user] >= pnl){
                userCollateral[user] -= pnl;
            }
            else{
                userCollateral[user] = 0;
            }
        }
    }

    ///@dev returns total collateral of the user
    ///@param user Collateral's owner.
    function getUserTotalCollateral(address user) external view returns (uint256) {
        return userCollateral[user];
    }

    ///@dev returns list of collaterals of the user with collateral decimals, not decimals of the relative stablecoin.
    ///@param user Collateral's owner.
    function getUserCollaterals(address user) external view returns (uint256[] memory collateral) {
        collateral = new uint256[](stableCoins.length);
        for (uint256 i; i < stableCoins.length; i++) {
            collateral[i] = userCollateralRatio[user][stableCoins[i].stableCoin] * userCollateral[user] / ratioDecimals;
        }
    }

    ///@dev sets the parameters of the contract that cannot be initialized in the constructor. Should really only be called during deploy.
    ///@param _perpPairAddress Address of the perpPair contract.
    ///@param _lostAndFoundAddress Address of the lostAndFound contract.
    function initializeParameters(address _perpPairAddress, address _lostAndFoundAddress) external onlyRole(DEFAULT_ADMIN_ROLE) onlyUninitialized {
        require(_perpPairAddress != address(0) && _lostAndFoundAddress != address(0), "Invalid parameters");
        perpPair = _perpPairAddress;
        lostAndFound = _lostAndFoundAddress;
    }

    /// @notice Adds a stablecoin to the allowed stablecoins in the vault
    /// @param stableCoin the address of the coin to add
    /// @param depositRatioThreshold the threshold over which changes in the collateral ratio in the vault are not allowed on deposits
    /// @param withdrawalRatioThreshold the threshold over which changes in the collateral ratio in the vault are not allowed on removals
    /// @param stableDecimals decimals of the stablecoin
    /// @param newTimeLockDuration new duration for the timelock   
    function addStableCoin(
        address stableCoin,
        uint256 depositRatioThreshold,
        uint256 withdrawalRatioThreshold,
        uint256 stableDecimals,
        uint256 newTimeLockDuration
    )
        external
        onlyRole(MOD_ROLE)
    {
        bytes32 paramHash = keccak256(abi.encodePacked(stableCoin, depositRatioThreshold, withdrawalRatioThreshold, stableDecimals, newTimeLockDuration));
        require(addStableTimeLock <= block.timestamp && paramHash == addStableHash, "AS1");
        if (stableCoin != address(0)){
            StableCoin memory newStable =
            StableCoin(ERC20(stableCoin), depositRatioThreshold, withdrawalRatioThreshold, stableDecimals);
            stableCoins.push(newStable);
            ratiosSnapshot.push(0);
        }
        addStableTimeLockDuration = newTimeLockDuration;
        emit AddingStableCoin(0, stableCoin, depositRatioThreshold, withdrawalRatioThreshold, stableDecimals, newTimeLockDuration);
    }

    /// @notice prepare the addition of a stablecoin to the allowed stablecoins in the vault
    /// @param stableCoin the address of the coin to add
    /// @param depositRatioThreshold the threshold over which changes in the collateral ratio in the vault are not allowed on deposits
    /// @param withdrawalRatioThreshold the threshold over which changes in the collateral ratio in the vault are not allowed on removals
    /// @param stableDecimals decimals of the stablecoin
    /// @param newTimeLockDuration new duration of the timeLock period for adding a stablecoin
    function prepareAddStableCoin(
        address stableCoin,
        uint256 depositRatioThreshold,
        uint256 withdrawalRatioThreshold,
        uint256 stableDecimals,
        uint256 newTimeLockDuration
    )
        external
        onlyRole(MOD_ROLE)
    {
        addStableTimeLock = block.timestamp + addStableTimeLockDuration;
        addStableHash = keccak256(abi.encodePacked(stableCoin, depositRatioThreshold, withdrawalRatioThreshold, stableDecimals, newTimeLockDuration));
        emit AddingStableCoin(addStableTimeLock, stableCoin, depositRatioThreshold, withdrawalRatioThreshold, stableDecimals, newTimeLockDuration);
    }

    /// @notice Adds a stablecoin to the allowed stablecoins in the vault
    /// @param stableCoin the address of the coin to add
    /// @param depositRatioThreshold the threshold over which changes in the collateral ratio in the vault are not allowed on deposits
    function modifyDepositRatioThresholds(
        address stableCoin,
        uint256 depositRatioThreshold
    )
        external
        onlyRole(MOD_ROLE)
    {
        for (uint256 i; i < stableCoins.length; i++) {
            if (stableCoins[i].stableCoin == ERC20(stableCoin)) {
                stableCoins[i].depositRatioThreshold = depositRatioThreshold;
                return;
            }
        }
        revert("stableCoin not found");
    }

    /// @notice Adds a stablecoin to the allowed stablecoins in the vault
    /// @param stableCoin the address of the coin to add
    /// @param withdrawalRatioThreshold the threshold over which changes in the collateral ratio in the vault are not allowed on removals
    function modifyWithdrawalRatioThreshold(
        address stableCoin,
        uint256 withdrawalRatioThreshold
    )
        external
        onlyRole(MOD_ROLE)
    {
        for (uint256 i; i < stableCoins.length; i++) {
            if (stableCoins[i].stableCoin == ERC20(stableCoin)) {
                stableCoins[i].withdrawalRatioThreshold = withdrawalRatioThreshold;
                return;
            }
        }
        revert("stableCoin not found");
    }

    function modifyRatioLockTime(uint256 _ratioLockTime) external onlyRole(MOD_ROLE) {
        ratioLockTime = _ratioLockTime;
        emit ChangedRatioLockTime(_ratioLockTime);
    }

    //Ratios need to be higher (or even allow everything) at the start to decide good composition of collateral
    /// @notice Compare new ratios after collateral deposit/removal to old ratios in the vault, if all differences are lower than their threshold the operation is allowed.
    /// @param newRatios ratios after the deposit in the vault.
    /// @param isDeposit True if the thresholds to be used are the deposit ones, False for the withdrawal.
    /// @return allowed Wether the deposit is allowed or not.
    function newRatiosAllowed(uint256[] memory newRatios, bool isDeposit) private view returns (bool allowed) {
        uint256 threshold;
        for (uint256 i; i < newRatios.length; i++) {
            if (isDeposit) {
                threshold = stableCoins[i].depositRatioThreshold;
            } else {
                threshold = stableCoins[i].withdrawalRatioThreshold;
            }
            
            if (UtilMath.diffAbs(ratiosSnapshot[i], newRatios[i]) > threshold) {
                return false;
            }
        }
        return true;
    }

    /// @notice Convert values in amounts from decimals of each stable to collateral decimals or vice versa
    /// @param amounts The values to convert
    /// @param direction true for stable->collateral, false for collateral->stable
    function convertStablecollateralDecimals(
        uint256[] memory amounts,
        bool direction
    )
        private
        view
        returns (uint256[] memory newAmounts)
    {
        require(amounts.length == stableCoins.length, "CONV1"); //wrong len of amounts
        newAmounts = new uint256[](amounts.length);
        for (uint256 i; i < amounts.length; i++) {
            if (direction) {
                newAmounts[i] = amounts[i] * collateralDecimals / stableCoins[i].stableDecimals;
            } else {
                newAmounts[i] = amounts[i] * stableCoins[i].stableDecimals / collateralDecimals;
            }
        }
    }

    ///@dev Updates the snapshot of the timestamp of the ratios to look at when deciding if new ratios are acceptable.
    ///@dev Some randomness is introduced using hash of last operation on perpPair. This is to prevent the unlock time to be predictable.
    function updateSnapshot() private {
        //Random shift to time lock.
        uint256 lastOperationTimestamp = PerpPair(perpPair).lastOperationTimestamp();
        uint256 randomDelta = uint256(keccak256(abi.encodePacked(lastOperationTimestamp))) % (3600*2);
        if (block.timestamp > lastSnapshotTimestamp + ratioLockTime + randomDelta){
            for (uint256 i; i < stableCoins.length; ++i) {
                ratiosSnapshot[i] = totalCollateralRatio[stableCoins[i].stableCoin];
            }
            lastSnapshotTimestamp = block.timestamp;
        }
    }

    ///@dev check the margin ratio of the user, used when the user wants to remove some collateral from an active position.
    ///@param amount Amount of collateral to remove
    ///@param user User removing the collateral
    function _checkMR(uint256 amount, address user) private view returns (bool) {
        uint256 price = SafeCast.toUint256(IOracleMiddleware(oracle).getPrice());

        (
            uint256 balanceStable,
            uint256 balanceAsset,
            uint256 debtStable,
            uint256 debtAsset,
            ,
            ,
            ,
        ) = PerpPair(perpPair).userVirtualTraderPosition(user);

        
        (, , uint256 lpStableDebt, uint256 lpAssetDebt) = PerpPair(perpPair).liquidityPosition(user);
        (uint256 lpStableBalance, uint256 lpAssetBalance) = PerpPair(perpPair).getLpLiquidityBalance(user);
        
        uint256 hypotheticalCollateral = userCollateral[user] - amount;
        uint256 lastOpTimestamp = PerpPair(perpPair).lastOperationTimestamp();
        uint256 calculatedMMR = UtilMath.calcMR(
            user, 
            price, 
            perpPair, 
            hypotheticalCollateral, 
            lastOpTimestamp
        );
        
        debtStable = debtStable > balanceStable ? debtStable-balanceStable : 0;
        debtAsset = debtAsset > balanceAsset ? debtAsset-balanceAsset : 0;
        if(lpStableBalance+lpAssetBalance != 0){
            if (hypotheticalCollateral*PerpPair(perpPair).maxLpLeverage() < debtStable + lpStableDebt + (debtAsset + lpAssetDebt)*price/oracleDecimals){
                calculatedMMR = 0;
            }
        }
        return calculatedMMR >= PerpPair(perpPair).MMR();
    }

    function _msgSender() internal view override(Context, ERC2771Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }

    function _msgData() internal view override(Context, ERC2771Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }    
    
    function _contextSuffixLength() internal view virtual override(Context, ERC2771Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
    }

    modifier onlyUninitialized{
        require(!initialized, "UNINIT1"); //already initialized
        initialized = true;
        _;
    }

    modifier onlyPerpPair{
        require(msg.sender == perpPair, "OnlyPerp"); //not perpPair
        _;
    }

}
