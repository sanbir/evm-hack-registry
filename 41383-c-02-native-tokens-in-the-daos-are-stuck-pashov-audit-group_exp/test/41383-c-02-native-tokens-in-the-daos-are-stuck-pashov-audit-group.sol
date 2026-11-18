// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  StationX — C-02 (Pashov, June 2024)
    Native deposits are forwarded to the DAO. updateProposalAndExecution
    calls the target with no value, so the deposited ETH cannot leave.
    Lines quoted from the StationX security review.
*/

contract Sink {
    uint256 public received;

    function take() external payable {
        received = msg.value; // STORY: zero value
    }
}

contract ERC20DAO {
    address public factoryAddress;

    constructor(address factory_) {
        factoryAddress = factory_;
    }

    receive() external payable {}

    function updateProposalAndExecution(address _contract, bytes memory _data) external {
        // onlyGnosis / nonReentrant omitted so this execution path can run.
        (bool success,) = _contract.call(_data); // @> VULN: the call forwards no value, so native deposits on the DAO cannot be moved
        require(success);
    }
}

contract Factory {
    address public constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    struct DaoDetails {
        address depositTokenAddress;
        bool assetsStoredOnGnosis;
        address gnosisAddress;
    }

    DaoDetails public _daoDetails;
    address public dao;

    constructor(address dao_) {
        dao = dao_;
        _daoDetails.depositTokenAddress = NATIVE_TOKEN_ADDRESS;
    }

    function _buyGovernanceTokenERC20DAO(uint256 _totalAmount) external payable {
        if (_daoDetails.depositTokenAddress == NATIVE_TOKEN_ADDRESS) {
            payable(_daoDetails.assetsStoredOnGnosis ? _daoDetails.gnosisAddress : dao).call{value: _totalAmount}(""); // STORY: deposit
        }
    }
}

contract Exploit {
    ERC20DAO public dao;
    Factory public factory;
    Sink public sink;
    uint256 public stillThere;
    uint256 public forwarded;

    constructor() {
        dao = new ERC20DAO(address(this));
        factory = new Factory(address(dao));
        sink = new Sink();
    }

    function run() external {
        factory._buyGovernanceTokenERC20DAO{value: 1 ether}(1 ether); // STORY: buy
        bytes memory data = abi.encodeWithSelector(Sink.take.selector);
        dao.updateProposalAndExecution(address(sink), data); // STORY: execute
        forwarded = sink.received();
        stillThere = address(dao).balance; // STORY: stuck balance
        require(forwarded == 0, "value moved");
        require(stillThere == 1 ether, "not stuck"); // STORY: harm
    }
}
