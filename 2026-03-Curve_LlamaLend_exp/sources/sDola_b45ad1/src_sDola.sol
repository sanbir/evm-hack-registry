// SPDX-License-Identifier: MIT License
pragma solidity 0.8.21;

import "lib/solmate/src/mixins/ERC4626.sol";

interface IDolaSavings {
    function balanceOf(address user) external view returns (uint);
    function stake(uint amount, address recipient) external;
    function unstake(uint amount) external;
    function claim(address to) external;
    function claimable(address user) external view returns (uint);
    function dbr() external view returns (address);
}

interface IERC20 {
    function transfer(address, uint) external returns (bool);
    function transferFrom(address, address, uint) external returns (bool);
    function balanceOf(address) external view returns (uint);
}

/**
 * @title sDola
 * @dev Auto-compounding ERC4626 wrapper for DolaSacings utilizing xy=k auctions.
 * WARNING: While this vault is safe to be used as collateral in lending markets, it should not be allowed as a borrowable asset.
 * Any protocol in which sudden, large and atomic increases in the value of an asset may be a securit risk should not integrate this vault.
 */
contract sDola is ERC4626 {
    
    uint constant MIN_BALANCE = 10**16; // 1 cent
    uint public constant MIN_SHARES = 10**18;
    uint public constant MAX_ASSETS = 10**32; // 100 trillion DOLA
    IDolaSavings public immutable savings;
    ERC20 public immutable dbr;
    address public gov;
    address public pendingGov;
    address public operator;
    uint public prevK;
    uint public targetK;
    uint public lastKUpdate;
    mapping (uint => uint) public weeklyRevenue;

    /**
     * @dev Constructor for sDola contract.
     * WARNING: MIN_SHARES will always be unwithdrawable from the vault. Deployer should deposit enough to mint MIN_SHARES to avoid causing user grief.
     * @param _dola Address of the DOLA token.
     * @param _savings Address of the DolaSavings contract.
     * @param _gov Address of the governance.
     * @param _K Initial value for the K variable used in calculations.
     */
    constructor(
        address _dola,
        address _savings,
        address _gov,
        address _operator,
        uint _K
    ) ERC4626(ERC20(_dola), "Staked Dola", "sDOLA") {
        require(_K > 0, "_K must be positive");
        savings = IDolaSavings(_savings);
        dbr = ERC20(IDolaSavings(_savings).dbr());
        gov = _gov;
        operator = _operator;
        targetK = _K;
        asset.approve(_savings, type(uint).max);
    }

    modifier onlyGov() {
        require(msg.sender == gov, "ONLY GOV");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == gov || msg.sender == operator, "ONLY OPERATOR");
        _;
    }

    /**
     * @dev Hook that is called after tokens are deposited into the contract.
     * @param assets The amount of assets that were deposited.
     */    
    function afterDeposit(uint256 assets, uint256) internal override {
        require(totalSupply >= MIN_SHARES, "Shares below MIN_SHARES");
        savings.stake(assets, address(this));
    }

    /**
     * @dev Hook that is called before tokens are withdrawn from the contract.
     * @param assets The amount of assets to withdraw.
     * @param shares The amount of shares to withdraw
     */
    function beforeWithdraw(uint256 assets, uint256 shares) internal override {
        require(totalAssets() >= assets + MIN_BALANCE, "Insufficient assets");
        require(totalSupply - shares >= MIN_SHARES, "Shares below MIN_SHARES");
        savings.unstake(assets);
    }

    /**
     * @dev Calculates the total assets controlled by the contract.
     * Weekly revenue is distributed linearly over the following week.
     * @return The total assets in the contract.
     */
    function totalAssets() public view override returns (uint) {
        uint week = block.timestamp / 7 days;
        uint timeElapsed = block.timestamp % 7 days;
        uint remainingLastRevenue = weeklyRevenue[week - 1] * (7 days - timeElapsed) / 7 days;
        uint actualAssets = savings.balanceOf(address(this)) - remainingLastRevenue - weeklyRevenue[week];
        return actualAssets < MAX_ASSETS ? actualAssets : MAX_ASSETS;
    }

    /**
     * @dev Returns the current value of K, which is a weighted average between prevK and targetK.
     * @return The current value of K.
     */
    function getK() public view returns (uint) {
        uint duration = 7 days;
        uint timeElapsed = block.timestamp - lastKUpdate;
        if(timeElapsed > duration) {
            return targetK;
        }
        uint targetWeight = timeElapsed;
        uint prevWeight = duration - timeElapsed;
        return (prevK * prevWeight + targetK * targetWeight) / duration;
    }

    /**
     * @dev Calculates the DOLA reserve based on the current DBR reserve.
     * @return The calculated DOLA reserve.
     */
    function getDolaReserve() public view returns (uint) {
        return getK() / getDbrReserve();
    }

    /**
     * @dev Calculates the DOLA reserve for a given DBR reserve.
     * @param dbrReserve The DBR reserve value.
     * @return The calculated DOLA reserve.
     */
    function getDolaReserve(uint dbrReserve) public view returns (uint) {
        return getK() / dbrReserve;
    }

    /**
     * @dev Returns the current DBR reserve as the sum of dbr balance and claimable dbr
     * @return The current DBR reserve.
     */
    function getDbrReserve() public view returns (uint) {
        return dbr.balanceOf(address(this)) + savings.claimable(address(this));
    }

    /**
     * @dev Sets a new target K value.
     * @param _K The new target K value.
     */
    function setTargetK(uint _K) external onlyOperator {
        require(_K > getDbrReserve(), "K must be larger than dbr reserve");
        prevK = getK();
        targetK = _K;
        lastKUpdate = block.timestamp;
        emit SetTargetK(_K);
    }

    /**
     * @dev Allows users to buy DBR with DOLA.
     * WARNING: Never expose this directly to a UI as it's likely to cause a loss unless a transaction is executed immediately.
     * Instead use the sDolaHelper function or custom smart contract code.
     * @param exactDolaIn The exact amount of DOLA to spend.
     * @param exactDbrOut The exact amount of DBR to receive.
     * @param to The address that will receive the DBR.
     */
    function buyDBR(uint exactDolaIn, uint exactDbrOut, address to) external {
        require(to != address(0), "Zero address");
        savings.claim(address(this));
        uint k = getK();
        uint dbrBalance = dbr.balanceOf(address(this));
        uint dbrReserve = dbrBalance - exactDbrOut;
        uint dolaReserve = k / dbrBalance + exactDolaIn;
        require(dolaReserve * dbrReserve >= k, "Invariant");
        asset.transferFrom(msg.sender, address(this), exactDolaIn);
        savings.stake(exactDolaIn, address(this));
        weeklyRevenue[block.timestamp / 7 days] += exactDolaIn;
        dbr.transfer(to, exactDbrOut);
        emit Buy(msg.sender, to, exactDolaIn, exactDbrOut);
    }

    /**
     * @dev Sets a new pending governance address.
     * @param _gov The address of the new pending governance.
     */
    function setPendingGov(address _gov) external onlyGov {
        pendingGov = _gov;
    }

    /**
     * @dev Sets a new operator address.
     * @param _operator New operator address.
     */
    function setOperator(address _operator) external onlyGov {
        operator = _operator;
    }

    /**
     * @dev Allows the pending governance to accept its role.
     */
    function acceptGov() external {
        require(msg.sender == pendingGov, "ONLY PENDINGGOV");
        gov = pendingGov;
        pendingGov = address(0);
    }

    /**
     * @dev Re-approves the DOLA token to be spent by the DolaSavings contract.
     */
    function reapprove() external {
        asset.approve(address(savings), type(uint).max);
    }

    /**
     * @dev Allows governance to sweep any ERC20 token from the contract.
     * @dev Excludes the ability to sweep DBR tokens.
     * @param token The address of the ERC20 token to sweep.
     * @param amount The amount of tokens to sweep.
     * @param to The recipient address of the swept tokens.
     */
    function sweep(address token, uint amount, address to) public onlyGov {
        require(address(dbr) != token, "Not authorized");
        IERC20(token).transfer(to, amount);
    }

    event Buy(address indexed caller, address indexed to, uint exactDolaIn, uint exactDbrOut);
    event SetTargetK(uint newTargetK);
}
