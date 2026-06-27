// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../../utils/Constants.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IFeeManager.sol";
import "./LibBrokerManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

library LibFeeManager {

    using SafeERC20 for IERC20;

    bytes32 constant FEE_MANAGER_STORAGE_POSITION = keccak256("apollox.fee.manager.storage");

    struct FeeConfig {
        string name;
        uint16 index;
        uint16 openFeeP;     // 1e4
        uint16 closeFeeP;    // 1e4
        bool enable;
        uint24 shareP;       // 1e5
        uint24 minCloseFeeP; // 1e5
    }

    struct FeeManagerStorage {
        // 0/1/2/3/.../ => FeeConfig
        mapping(uint16 => FeeConfig) feeConfigs;
        // feeConfig index => pair.base[]
        mapping(uint16 => address[]) feeConfigPairs;
        // USDT/BUSD/.../ => FeeDetail
        mapping(address => IFeeManager.FeeDetail) feeDetails;
        address daoRepurchase;
        address revenueAddress;
        // USDT/BUSD/.../ => Commission
        mapping(address token => LibBrokerManager.Commission) revenues;
    }

    function feeManagerStorage() internal pure returns (FeeManagerStorage storage fms) {
        bytes32 position = FEE_MANAGER_STORAGE_POSITION;
        assembly {
            fms.slot := position
        }
    }

    event AddFeeConfig(
        uint16 indexed index, uint16 openFeeP, uint16 closeFeeP, uint24 shareP, uint24 minCloseFeeP, string name
    );
    event RemoveFeeConfig(uint16 indexed index);
    event UpdateFeeConfig(uint16 indexed index,
        uint16 openFeeP, uint16 closeFeeP,
        uint24 shareP, uint24 minCloseFeeP
    );
    event SetDaoRepurchase(address indexed oldDaoRepurchase, address daoRepurchase);
    event SetRevenueAddress(address indexed oldRevenueAddress, address revenueAddress);

    function initialize(address daoRepurchase, address revenueAddress) internal {
        FeeManagerStorage storage fms = feeManagerStorage();
        require(fms.daoRepurchase == address(0), "LibFeeManager: Already initialized");
        setDaoRepurchase(daoRepurchase);
        setRevenueAddress(revenueAddress);
        // default fee config
        fms.feeConfigs[0] = FeeConfig("Default Fee Rate", 0, 8, 8, true, 0, 0);
        emit AddFeeConfig(0, 8, 8, 0, 0, "Default Fee Rate");
    }

    function addFeeConfig(
        uint16 index, string calldata name, uint16 openFeeP, uint16 closeFeeP, uint24 shareP, uint24 minCloseFeeP
    ) internal {
        FeeManagerStorage storage fms = feeManagerStorage();
        FeeConfig storage config = fms.feeConfigs[index];
        require(!config.enable, "LibFeeManager: Configuration already exists");
        config.index = index;
        config.name = name;
        config.openFeeP = openFeeP;
        config.closeFeeP = closeFeeP;
        config.enable = true;
        config.shareP = shareP;
        config.minCloseFeeP = minCloseFeeP;
        emit AddFeeConfig(index, openFeeP, closeFeeP, shareP, minCloseFeeP, name);
    }

    function removeFeeConfig(uint16 index) internal {
        FeeManagerStorage storage fms = feeManagerStorage();
        FeeConfig storage config = fms.feeConfigs[index];
        require(config.enable, "LibFeeManager: Configuration not enabled");
        require(fms.feeConfigPairs[index].length == 0, "LibFeeManager: Cannot remove a configuration that is still in use");
        delete fms.feeConfigs[index];
        emit RemoveFeeConfig(index);
    }

    function updateFeeConfig(uint16 index, uint16 openFeeP, uint16 closeFeeP, uint24 shareP, uint24 minCloseFeeP) internal {
        FeeManagerStorage storage fms = feeManagerStorage();
        FeeConfig storage config = fms.feeConfigs[index];
        require(config.enable, "LibFeeManager: Configuration not enabled");
        config.openFeeP = openFeeP;
        config.closeFeeP = closeFeeP;
        config.shareP = shareP;
        config.minCloseFeeP = minCloseFeeP;
        emit UpdateFeeConfig(index, openFeeP, closeFeeP, shareP, minCloseFeeP);
    }

    function setDaoRepurchase(address daoRepurchase) internal {
        require(daoRepurchase != address(0), "LibFeeManager: daoRepurchase cannot be 0 address");
        FeeManagerStorage storage fms = feeManagerStorage();
        address oldDaoRepurchase = fms.daoRepurchase;
        fms.daoRepurchase = daoRepurchase;
        emit SetDaoRepurchase(oldDaoRepurchase, daoRepurchase);
    }

    function setRevenueAddress(address revenueAddress) internal {
        require(revenueAddress != address(0), "LibFeeManager: revenueAddress cannot be 0 address");
        FeeManagerStorage storage fms = feeManagerStorage();
        address oldRevenueAddress = fms.revenueAddress;
        fms.revenueAddress = revenueAddress;
        emit SetRevenueAddress(oldRevenueAddress, revenueAddress);
    }

    function getFeeConfigByIndex(uint16 index) internal view returns (FeeConfig memory, address[] storage) {
        FeeManagerStorage storage fms = feeManagerStorage();
        return (fms.feeConfigs[index], fms.feeConfigPairs[index]);
    }

    function chargeFee(address token, uint256 feeAmount, uint24 broker) internal returns (uint24 brokerId, uint256 brokerAmount, uint256 daoAmount, uint256 alpPoolAmount){
        FeeManagerStorage storage fms = feeManagerStorage();
        IFeeManager.FeeDetail storage detail = fms.feeDetails[token];
        detail.total += feeAmount;

        (brokerAmount, brokerId, daoAmount, alpPoolAmount) = LibBrokerManager.updateBrokerCommission(token, feeAmount, broker);
        detail.brokerAmount += brokerAmount;

        if (daoAmount > 0) {
            // The buyback address prefers to receive wrapped tokens since LPs are composed of wrapped tokens, for example: WBNB-APX LP.
            IERC20(token).safeTransfer(fms.daoRepurchase, daoAmount);
            detail.daoAmount += daoAmount;
        }

        if (alpPoolAmount > 0) {
            IVault(address(this)).increase(token, alpPoolAmount);
            detail.alpPoolAmount += alpPoolAmount;
        }

        uint256 revenue = feeAmount - brokerAmount - daoAmount - alpPoolAmount;
        if (revenue > 0) {
            LibBrokerManager.Commission storage c = fms.revenues[token];
            c.total += revenue;
            c.pending += revenue;
        }
        return (brokerId, brokerAmount, daoAmount, alpPoolAmount);
    }
}
