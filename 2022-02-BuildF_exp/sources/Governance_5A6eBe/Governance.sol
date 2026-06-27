pragma solidity ^0.6.12;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

library SafeMath {

    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }

    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;

        return c;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }

    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold

        return c;
    }

    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return mod(a, b, "SafeMath: modulo by zero");
    }

    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b != 0, errorMessage);
        return a % b;
    }
}

library Address {

    function isContract(address account) internal view returns (bool) {
        // This method relies in extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.

        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(account) }
        return size > 0;
    }

    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        // solhint-disable-next-line avoid-low-level-calls, avoid-call-value
        (bool success, ) = recipient.call{ value: amount }("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
      return functionCall(target, data, "Address: low-level call failed");
    }

    function functionCall(address target, bytes memory data, string memory errorMessage) internal returns (bytes memory) {
        return _functionCallWithValue(target, data, 0, errorMessage);
    }

    function functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
    }

    function functionCallWithValue(address target, bytes memory data, uint256 value, string memory errorMessage) internal returns (bytes memory) {
        require(address(this).balance >= value, "Address: insufficient balance for call");
        return _functionCallWithValue(target, data, value, errorMessage);
    }

    function _functionCallWithValue(address target, bytes memory data, uint256 weiValue, string memory errorMessage) private returns (bytes memory) {
        require(isContract(target), "Address: call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.call{ value: weiValue }(data);
        if (success) {
            return returndata;
        } else {
            // Look for revert reason and bubble it up if present
            if (returndata.length > 0) {
                // The easiest way to bubble the revert reason is using memory via assembly

                // solhint-disable-next-line no-inline-assembly
                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert(errorMessage);
            }
        }
    }
}

contract Governance {

  using SafeMath for uint;

  /// @notice The duration of voting on a proposal
  uint public constant votingPeriod = 86000;

  /// @notice Time since submission before the proposal can be executed
  uint public constant executionPeriod = 86000 * 2;

  /// @notice The required minimum number of votes in support of a proposal for it to succeed
  uint public constant quorumVotes = 5000e18;

  /// @notice The minimum number of votes required for an account to create a proposal
  uint public constant proposalThreshold = 100e18;

  IERC20 public votingToken;

  /// @notice The total number of proposals
  uint public proposalCount;

  /// @notice The record of all proposals ever proposed
  mapping (uint256 => Proposal) public proposals;

  /// @notice The time until which tokens used for voting will be locked
  mapping (address => uint) public voteLock;

  /// @notice Keeps track of locked tokens per address
  mapping(address => uint) public balanceOf;

  struct Proposal {
    /// @notice Unique id for looking up a proposal
    uint id;

    /// @notice Creator of the proposal
    address proposer;

    /// @notice The time at which voting starts
    uint startTime;

    /// @notice Current number of votes in favor of this proposal
    uint forVotes;

    /// @notice Current number of votes in opposition to this proposal
    uint againstVotes;

    // @notice Queued transaction hash
    bytes32 txHash;

    bool executed;

    /// @notice Receipts of ballots for the entire set of voters
    mapping (address => Receipt) receipts;
  }

  /// @notice Ballot receipt record for a voter
  struct Receipt {
    /// @notice Whether or not a vote has been cast
    bool hasVoted;

    /// @notice Whether or not the voter supports the proposal
    bool support;

    /// @notice The number of votes the voter had, which were cast
    uint votes;
  }

  /// @notice Possible states that a proposal may be in
  enum ProposalState {
    Active,
    Defeated,
    PendingExecution,
    ReadyForExecution,
    Executed
  }

  /// @notice If the votingPeriod is changed and the user votes again, the lock period will be reset.
  modifier lockVotes() {
    uint tokenBalance = votingToken.balanceOf(msg.sender);
    votingToken.transferFrom(msg.sender, address(this), tokenBalance);
    _mint(msg.sender, tokenBalance);
    voteLock[msg.sender] = block.timestamp.add(votingPeriod);
    _;
  }

  constructor(IERC20 _votingToken) public {
      votingToken = _votingToken;
  }

  function state(uint proposalId)
    public
    view
    returns (ProposalState)
  {
    require(proposalCount >= proposalId && proposalId > 0, "Governance::state: invalid proposal id");
    Proposal storage proposal = proposals[proposalId];

    if (block.timestamp <= proposal.startTime.add(votingPeriod)) {
      return ProposalState.Active;

    } else if (proposal.executed == true) {
      return ProposalState.Executed;

    } else if (proposal.forVotes <= proposal.againstVotes || proposal.forVotes < quorumVotes) {
      return ProposalState.Defeated;

    } else if (block.timestamp < proposal.startTime.add(executionPeriod)) {
      return ProposalState.PendingExecution;

    } else {
      return ProposalState.ReadyForExecution;
    }
  }

  function getVote(uint _proposalId, address _voter)
    public
    view
    returns (bool)
  {
    return proposals[_proposalId].receipts[_voter].support;
  }

  function execute(uint _proposalId, address _target, uint _value, bytes memory _data)
    public
    payable
    returns (bytes memory)
  {
    bytes32 txHash = keccak256(abi.encode(_target, _value, _data));
    Proposal storage proposal = proposals[_proposalId];

    require(proposal.txHash == txHash, "Governance::execute: Invalid proposal");
    require(state(_proposalId) == ProposalState.ReadyForExecution, "Governance::execute: Cannot be executed");

    (bool success, bytes memory returnData) = _target.call.value(_value)(_data);
    require(success, "Governance::execute: Transaction execution reverted.");
    proposal.executed = true;

    return returnData;
  }

  function propose(address _target, uint _value, bytes memory _data)
    public
    lockVotes
    returns (uint)
  {

    require(balanceOf[msg.sender] > proposalThreshold, "Governance::propose: proposer votes below proposal threshold");

    bytes32 txHash = keccak256(abi.encode(_target, _value, _data));

    proposalCount++;
    Proposal memory newProposal = Proposal({
      id: proposalCount,
      proposer: msg.sender,
      startTime: block.timestamp,
      forVotes: 0,
      againstVotes: 0,
      txHash: txHash,
      executed: false
    });

    proposals[newProposal.id] = newProposal;
  }

  function vote(uint _proposalId, bool _support) public lockVotes {

    require(state(_proposalId) == ProposalState.Active, "Governance::vote: voting is closed");
    Proposal storage proposal = proposals[_proposalId];
    Receipt storage receipt = proposal.receipts[msg.sender];
    require(receipt.hasVoted == false, "Governance::vote: voter already voted");

    uint votes = balanceOf[msg.sender];

    if (_support) {
      proposal.forVotes = proposal.forVotes.add(votes);
    } else {
      proposal.againstVotes = proposal.againstVotes.add(votes);
    }

    receipt.hasVoted = true;
    receipt.support = _support;
    receipt.votes = votes;
  }

  function withdraw() public {
    require(block.timestamp > voteLock[msg.sender], "Governance::withdraw: wait until voteLock expiration");
    votingToken.transfer(msg.sender, balanceOf[msg.sender]);
    _burn(msg.sender, balanceOf[msg.sender]);
  }

  function _mint(address _account, uint _amount) internal {
    balanceOf[_account] = balanceOf[_account].add(_amount);
  }

  function _burn(address _account, uint _amount) internal {
    balanceOf[_account] = balanceOf[_account].sub(_amount, "ERC20: burn amount exceeds balance");
  }
}