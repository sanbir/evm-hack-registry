// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Perennial MarketFactory — protocol fee from Market.claimFee is locked
    (Sherlock 2023-07, finding 24301 / H-3). SYNTHETIC, cheatcode-free.
    fund and _claimFee are the audited functions (@> VULN).
    Root cause: fund calls claimFee, and _claimFee pushes the protocol fee to the
    factory because msg.sender is the factory. The factory never approves a spender
    and has no withdraw, so the tokens sit there. The treasury balance stays 0. */

type UFixed6 is uint256;
type UFixed18 is uint256;

library UFixed6Lib {
    UFixed6 internal constant ZERO = UFixed6.wrap(0);
}

library UFixed18Lib {
    function from(UFixed6 fee) internal pure returns (UFixed18) {
        return UFixed18.wrap(UFixed6.unwrap(fee));
    }
}

interface IInstance {}

interface IMarket {
    function claimFee() external;
}

interface IMarketFactory {
    function oracleFactory() external view returns (address);
}

struct Global {
    UFixed6 protocolFee;
    UFixed6 oracleFee;
    UFixed6 riskFee;
    UFixed6 donation;
}

struct GlobalStorage {
    UFixed6 protocolFee;
    UFixed6 oracleFee;
    UFixed6 riskFee;
    UFixed6 donation;
}

library GlobalLib {
    function read(GlobalStorage storage self) internal view returns (Global memory) {
        return Global(self.protocolFee, self.oracleFee, self.riskFee, self.donation);
    }

    function store(GlobalStorage storage self, Global memory next) internal {
        self.protocolFee = next.protocolFee;
        self.oracleFee = next.oracleFee;
        self.riskFee = next.riskFee;
        self.donation = next.donation;
    }
}

contract Token18 {
    string public name = "Perennial Settlement";
    string public symbol = "TOK";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function push(address to, UFixed18 amount) external {
        uint256 amt = UFixed18.unwrap(amount);
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
    }
}

contract Market is IMarket {
    using GlobalLib for GlobalStorage;

    error MarketNotFactoryError();

    Token18 public token;
    address public coordinator;
    address public beneficiary;
    address private _factory;
    GlobalStorage private _global;

    event FeeClaimed(address receiver, UFixed6 fee);

    constructor(address token_) {
        token = Token18(token_);
    }

    function bind(address factory_, address coordinator_, address beneficiary_, uint256 fee) external {
        require(_factory == address(0), "bound");
        _factory = factory_;
        coordinator = coordinator_;
        beneficiary = beneficiary_;
        _global.protocolFee = UFixed6.wrap(fee);
    }

    function factory() public view returns (address) {
        return _factory;
    }

    function protocolFee() external view returns (uint256) {
        return UFixed6.unwrap(_global.protocolFee);
    }

    /// @notice Claims any available fee that the sender has accrued
    /// @dev Applicable fees include: protocol, oracle, risk, and donation
    function claimFee() external {
        Global memory newGlobal = _global.read();

        if (_claimFee(address(factory()), newGlobal.protocolFee)) newGlobal.protocolFee = UFixed6Lib.ZERO;
        if (_claimFee(address(IMarketFactory(address(factory())).oracleFactory()), newGlobal.oracleFee))
            newGlobal.oracleFee = UFixed6Lib.ZERO;
        if (_claimFee(coordinator, newGlobal.riskFee)) newGlobal.riskFee = UFixed6Lib.ZERO;
        if (_claimFee(beneficiary, newGlobal.donation)) newGlobal.donation = UFixed6Lib.ZERO;

        _global.store(newGlobal);
    }

    /// @notice Helper function to handle a singular fee claim
    /// @param receiver The address to receive the fee
    /// @param fee The amount of the fee to claim
    function _claimFee(address receiver, UFixed6 fee) private returns (bool) {
        if (msg.sender != receiver) return false;

        token.push(receiver, UFixed18Lib.from(fee));
        emit FeeClaimed(receiver, fee);
        return true;
    }
}

contract MarketFactory {
    error FactoryNotInstanceError();

    address public immutable oracleFactory;
    mapping(address => bool) private _instances;

    constructor(address oracleFactory_) {
        oracleFactory = oracleFactory_;
    }

    function instances(IInstance instance) public view returns (bool) {
        return _instances[address(instance)];
    }

    function register(address market) external {
        _instances[market] = true;
    }

    /// @notice Claims the protocol's fee from the given market
    /// @param market The market to claim from
    function fund(IMarket market) external {
        if (!instances(IInstance(address(market)))) revert FactoryNotInstanceError();
        // @> VULN: claimFee pays the protocol fee to this factory, which has no withdraw and no allowance out
        market.claimFee();
    }
}

contract Exploit {
    uint256 public constant FEE = 250e18;
    address public constant TREASURY = 0x000000000000000000000000000000000000bEEF;
    address public constant ORACLE_FACTORY = 0x0000000000000000000000000000000000002222;
    address public constant COORDINATOR = 0x0000000000000000000000000000000000003333;
    address public constant BENEFICIARY = 0x0000000000000000000000000000000000004444;

    Token18 public token; // nonce 1
    Market public market; // nonce 2
    MarketFactory public factory; // nonce 3

    constructor() {
        token = new Token18();
        market = new Market(address(token));
        factory = new MarketFactory(ORACLE_FACTORY);
        market.bind(address(factory), COORDINATOR, BENEFICIARY, FEE);
        factory.register(address(market));
        token.mint(address(market), FEE);
    }

    function run() external {
        uint256 escrowed = token.balanceOf(address(market));
        require(escrowed == FEE, "market not funded");

        uint256 owed = market.protocolFee();
        require(owed == FEE, "fee not accrued");

        uint256 factoryBefore = token.balanceOf(address(factory));
        require(factoryBefore == 0, "factory not empty");

        uint256 treasuryBefore = token.balanceOf(TREASURY);
        require(treasuryBefore == 0, "treasury not empty");

        factory.fund(market);

        uint256 locked = token.balanceOf(address(factory));
        require(locked == FEE, "fee not locked");
        require(token.balanceOf(TREASURY) == 0, "treasury was paid");
        require(token.balanceOf(address(market)) == 0, "market still holds fee");
        require(market.protocolFee() == 0, "fee still accrued");

        factory.fund(market);
        require(token.balanceOf(address(factory)) == FEE, "second claim changed the lock");
        require(token.balanceOf(TREASURY) == 0, "treasury paid on the second claim");
    }
}
