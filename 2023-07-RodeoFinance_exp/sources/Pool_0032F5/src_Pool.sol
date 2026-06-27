// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Util} from "./Util.sol";
import {ERC20} from "./ERC20.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {IRateModel} from "./interfaces/IRateModel.sol";

contract Pool is Util, ERC20 {
    error CapReached();
    error BorrowTooSmall();
    error UtilizationTooHigh();
    error InsufficientAmountForRepay();

    IERC20 public immutable asset;
    IRateModel public rateModel;
    IOracle public oracle;
    uint256 public borrowMin;
    uint256 public borrowFactor;
    uint256 public liquidationFactor;
    uint256 public amountCap;
    uint256 public lastUpdate;
    uint256 public index = 1e18;
    uint256 public totalBorrow;

    event FileInt(bytes32 indexed what, uint256 data);
    event FileAddress(bytes32 indexed what, address data);
    event Deposit(address indexed who, address indexed usr, uint256 amt, uint256 sha);
    event Withdraw(address indexed who, address indexed usr, uint256 amt, uint256 sha);
    event Borrow(address indexed who, uint256 amt, uint256 bor);
    event Repay(address indexed who, uint256 amt, uint256 bor);
    event Loss(address indexed who, uint256 amt, uint256 amttre, uint256 amtava);

    constructor(address _asset, address _rateModel, address _oracle, uint256 _borrowMin, uint256 _borrowFactor, uint256 _liquidationFactor, uint256 _amountCap)
        ERC20(
            string(abi.encodePacked("Rodeo Interest Bearing ", IERC20(_asset).name())),
            string(abi.encodePacked("rib", IERC20(_asset).symbol())),
            IERC20(_asset).decimals()
        )
    {
        asset = IERC20(_asset);
        rateModel = IRateModel(_rateModel);
        oracle = IOracle(_oracle);
        borrowMin = _borrowMin;
        borrowFactor = _borrowFactor;
        liquidationFactor = _liquidationFactor;
        amountCap = _amountCap;
        lastUpdate = block.timestamp;
        exec[msg.sender] = true;
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "paused") paused = data == 1;
        if (what == "borrowMin") borrowMin = data;
        if (what == "borrowFactor") borrowFactor = data;
        if (what == "liquidationFactor") liquidationFactor = data;
        if (what == "amountCap") amountCap = data;
        emit FileInt(what, data);
    }

    function file(bytes32 what, address data) external auth {
        if (what == "exec") exec[data] = !exec[data];
        if (what == "rateModel") rateModel = IRateModel(data);
        if (what == "oracle") oracle = IOracle(data);
        emit FileAddress(what, data);
    }

    // Supply asset for lending
    function mint(uint256 amt, address usr) external live {
        update();
        uint256 totalLiquidity = getTotalLiquidity();
        if (totalLiquidity + amt > amountCap) revert CapReached();
        uint256 sha = amt;
        if (totalSupply > 0) {
            sha = amt * totalSupply / totalLiquidity;
        }
        pull(asset, msg.sender, amt);
        _mint(usr, sha);
        emit Deposit(msg.sender, usr, amt, sha);
    }

    // Withdraw supplied asset
    function burn(uint256 sha, address usr) external live {
        update();
        uint256 amt = sha * getTotalLiquidity() / totalSupply;
        if (balanceOf[msg.sender] < sha) revert InsufficientBalance();
        if (asset.balanceOf(address(this)) < amt) revert UtilizationTooHigh();
        _burn(msg.sender, sha);
        push(asset, usr, amt);
        emit Withdraw(msg.sender, usr, amt, sha);
    }

    // Borrow from pool (called by Investor)
    function borrow(uint256 amt) external live auth returns (uint256) {
        update();
        if (amt < borrowMin) revert BorrowTooSmall();
        if (asset.balanceOf(address(this)) < amt) revert UtilizationTooHigh();
        uint256 bor = amt * 1e18 / index;
        totalBorrow += bor;
        push(asset, msg.sender, amt);
        emit Borrow(msg.sender, amt, bor);
        return bor;
    }

    // Repay pool (called by Investor)
    function repay(uint256 bor) external live auth returns (uint256) {
        update();
        uint256 amt = bor * index / 1e18;
        uint256 amtava = min(asset.allowance(msg.sender, address(this)), asset.balanceOf(msg.sender));
        // If the caller has less assest than debt to repay, try to burn reserves to make up the
        // gap, else, simply write off the borrow and let lenders take the hit
        if (amtava < amt) {
            uint256 totalLiquidity = getTotalLiquidity();
            uint256 amttre = balanceOf[address(0)] * totalLiquidity / totalSupply;
            uint256 usetre = min(amttre, amt - amtava);
            if (usetre > 0) {
                _burn(address(0), usetre * totalSupply / totalLiquidity);
            }
            emit Loss(msg.sender, amt, usetre, amtava);
            amt = amtava;
        }
        totalBorrow -= bor;
        pull(asset, msg.sender, amt);
        emit Repay(msg.sender, amt, bor);
        return amt;
    }

    // Levy allows an admin to collect some of the protocol reserves
    function levy(uint256 sha) external live auth {
        update();
        uint256 amt = sha * getTotalLiquidity() / totalSupply;
        _burn(address(0), sha);
        push(asset, msg.sender, amt);
        emit Withdraw(msg.sender, address(0), amt, sha);
    }

    // A minimal `burn()` to be used by users in case of emergency / frontend not working
    function emergency() external live {
        uint256 sha = balanceOf[msg.sender];
        uint256 amt = sha * getTotalLiquidity() / totalSupply;
        if (asset.balanceOf(address(this)) < amt) revert UtilizationTooHigh();
        _burn(msg.sender, sha);
        push(asset, msg.sender, amt);
        emit Withdraw(msg.sender, msg.sender, amt, sha);
    }

    // Accrue interest to index
    function update() public {
        uint256 time = block.timestamp - lastUpdate;
        if (time > 0) {
            uint256 utilization = getUtilization();
            index += (index * rateModel.rate(utilization) * time) / 1e18;
            lastUpdate = block.timestamp;
        }
    }

    function getUtilization() public view returns (uint256) {
        uint256 totalLiquidity = getTotalLiquidity();
        if (totalLiquidity == 0) return 0;
        return getTotalBorrow() * 1e18 / totalLiquidity;
    }

    function getTotalLiquidity() public view returns (uint256) {
        return asset.balanceOf(address(this)) + getTotalBorrow();
    }

    function getTotalBorrow() public view returns (uint256) {
        return totalBorrow * index / 1e18;
    }

    function getUpdatedIndex() public view returns (uint256) {
        uint256 time = block.timestamp - lastUpdate;
        uint256 utilization = getUtilization();
        return index + ((index * rateModel.rate(utilization) * time) / 1e18);
    }
}
